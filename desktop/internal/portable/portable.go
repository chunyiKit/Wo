// Package portable streams local snapshot bytes into an inert archive and verifies
// them before publication to a new directory. It never imports a database or applies
// source device identities, URI grants, bookmarks, permissions, or record semantics.
package portable

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"time"
)

const Version = 1
const FileVersion = 2
const MaxAttachmentBytes int64 = 20 << 20

type Kind string

const (
	Records   Kind = "records"
	Photo     Kind = "photo"
	Video     Kind = "video"
	Thumbnail Kind = "thumbnail"
	File      Kind = "file"
)

type MissingReason string

const (
	NotOnDevice       MissingReason = "not_on_device"
	PermissionDenied  MissingReason = "permission_denied"
	SourceMissing     MissingReason = "source_missing"
	SourceUnavailable MissingReason = "source_unavailable"
	Unsupported       MissingReason = "unsupported"
	NotAuthorized     MissingReason = "not_authorized"
	SourceNotExact    MissingReason = "source_not_exact"
)

type Entry struct {
	ID            string        `json:"id"`
	Kind          Kind          `json:"kind"`
	Size          int64         `json:"size"`
	SHA256        string        `json:"sha256"`
	MissingReason MissingReason `json:"missing_reason"`
	// SourceExact is a caller's explicit source-provenance declaration. A SHA
	// verifies saved bytes, not whether a platform redacted or transcoded them.
	SourceExact bool `json:"source_exact"`
}

type Manifest struct {
	Version  int     `json:"version"`
	FamilyID string  `json:"family_id"`
	Entries  []Entry `json:"entries"`
}

type Limits struct {
	MaxEntries       int
	MaxManifestBytes int64
	MaxFileBytes     int64
	MaxTotalBytes    int64
}

type OpenSource func(entryID string) (io.ReadCloser, error)

type RestoreOptions struct {
	// RequirePrivateACL must be true for restricted plaintext. Windows fails
	// closed until a native user-only ACL check is available.
	RequirePrivateACL bool
	ExpectedFamilyID  string
	Destination       string
	Limits            Limits
}

type RestoredFile struct {
	NewID       string `json:"new_id"`
	Kind        Kind   `json:"kind"`
	Path        string `json:"path"`
	Size        int64  `json:"size"`
	SHA256      string `json:"sha256"`
	SourceExact bool   `json:"source_exact"`
}

type Result struct {
	SourceFamilyID      string                   `json:"source_family_id"`
	NewFamilyID         string                   `json:"new_family_id"`
	NewDeviceID         string                   `json:"new_device_id"`
	RestoreID           string                   `json:"restore_id"`
	Directory           string                   `json:"directory"`
	CompletionMarker    string                   `json:"completion_marker"`
	Files               map[string]RestoredFile  `json:"files"`
	Missing             map[string]MissingReason `json:"missing"`
	UnverifiedOriginals map[string]MissingReason `json:"unverified_originals"`
	// Complete means declared byte entries exist and original source provenance
	// is affirmed. It does not mean the inert records were imported into an app.
	Complete       bool `json:"complete"`
	RecordsApplied bool `json:"records_applied"`
}

var (
	ErrInvalid               = errors.New("portable: invalid archive")
	ErrLimit                 = errors.New("portable: limit exceeded")
	ErrSource                = errors.New("portable: source unavailable or changed")
	ErrFamily                = errors.New("portable: family does not match")
	ErrDestinationExists     = errors.New("portable: destination already exists")
	ErrPrivateACLUnavailable = errors.New("portable: private Windows ACL not verified")
	identifier               = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}$`)
	digestPattern            = regexp.MustCompile(`^[a-f0-9]{64}$`)
)

func normalizeLimits(l Limits) (Limits, error) {
	if l.MaxEntries == 0 {
		l.MaxEntries = 20000
	}
	if l.MaxManifestBytes == 0 {
		l.MaxManifestBytes = 8 << 20
	}
	if l.MaxFileBytes == 0 {
		l.MaxFileBytes = 20 << 30
	}
	if l.MaxTotalBytes == 0 {
		l.MaxTotalBytes = 100 << 30
	}
	if l.MaxEntries < 1 || l.MaxEntries > 100000 || l.MaxManifestBytes < 1 || l.MaxManifestBytes > 64<<20 ||
		l.MaxFileBytes < 1 || l.MaxFileBytes > 1<<40 || l.MaxTotalBytes < 1 || l.MaxTotalBytes > 1<<40 {
		return l, ErrLimit
	}
	return l, nil
}

func validReason(r MissingReason) bool {
	switch r {
	case NotOnDevice, PermissionDenied, SourceMissing, SourceUnavailable, Unsupported, NotAuthorized, SourceNotExact:
		return true
	default:
		return false
	}
}

func RequiredVersion(entries []Entry) int {
	for _, e := range entries {
		if e.Kind == File {
			return FileVersion
		}
	}
	return Version
}
func validate(m Manifest, l Limits) error {
	if (m.Version != Version && m.Version != FileVersion) || !identifier.MatchString(m.FamilyID) || m.Entries == nil {
		return ErrInvalid
	}
	if len(m.Entries) > l.MaxEntries {
		return ErrLimit
	}
	seen := make(map[string]bool, len(m.Entries))
	var total int64
	for _, e := range m.Entries {
		if !identifier.MatchString(e.ID) || seen[e.ID] {
			return ErrInvalid
		}
		seen[e.ID] = true
		switch e.Kind {
		case Records, Photo, Video, Thumbnail:
		case File:
			if m.Version != FileVersion || e.Size > MaxAttachmentBytes {
				return ErrInvalid
			}
		default:
			return ErrInvalid
		}
		if e.MissingReason != "" {
			if !validReason(e.MissingReason) || e.Size != 0 || e.SHA256 != "" || e.SourceExact {
				return ErrInvalid
			}
			continue
		}
		if e.Size < 1 || !digestPattern.MatchString(e.SHA256) {
			return ErrInvalid
		}
		if e.Kind != Photo && e.Kind != Video && e.SourceExact {
			return ErrInvalid
		}
		if e.Size > l.MaxFileBytes || e.Size > l.MaxTotalBytes-total {
			return ErrLimit
		}
		total += e.Size
	}
	return nil
}

func paddingSize(size int64) int64 { return (size + 511) / 512 * 512 }
func archiveSize(manifestSize int64, m Manifest) int64 {
	result := int64(512) + paddingSize(manifestSize) + 1024
	for _, e := range m.Entries {
		if e.MissingReason == "" {
			result += 512 + paddingSize(e.Size)
		}
	}
	return result
}

func header(name string, size int64) *tar.Header {
	return &tar.Header{Name: name, Typeflag: tar.TypeReg, Mode: 0600, Size: size, ModTime: time.Unix(0, 0), Format: tar.FormatGNU}
}

// Pack writes only the fixed manifest path and opaque entries/<ID> paths. Missing
// items must be declared before this call. If a present source disappears or is
// modified, Pack fails and the caller must discard its partial output.
func Pack(ctx context.Context, destination io.Writer, m Manifest, open OpenSource) error {
	return PackWithLimits(ctx, destination, m, open, Limits{})
}

func PackWithLimits(ctx context.Context, destination io.Writer, m Manifest, open OpenSource, limits Limits) error {
	l, err := normalizeLimits(limits)
	if err != nil {
		return err
	}
	if err = validate(m, l); err != nil {
		return err
	}
	manifest, err := json.Marshal(m)
	if err != nil {
		return fmt.Errorf("%w: manifest", ErrInvalid)
	}
	if int64(len(manifest)) > l.MaxManifestBytes {
		return ErrLimit
	}
	if err = ctx.Err(); err != nil {
		return err
	}
	tw := tar.NewWriter(&contextWriter{ctx: ctx, writer: destination})
	if err = tw.WriteHeader(header("manifest.json", int64(len(manifest)))); err != nil {
		return err
	}
	if _, err = tw.Write(manifest); err != nil {
		return err
	}
	for _, e := range m.Entries {
		if e.MissingReason != "" {
			continue
		}
		if open == nil {
			return ErrSource
		}
		if err = ctx.Err(); err != nil {
			return err
		}
		source, openErr := open(e.ID)
		if openErr != nil || source == nil {
			return fmt.Errorf("%w: %s", ErrSource, e.ID)
		}
		if err = tw.WriteHeader(header("entries/"+e.ID, e.Size)); err == nil {
			h := sha256.New()
			var n int64
			n, err = io.CopyBuffer(io.MultiWriter(tw, h), io.LimitReader(&contextReader{ctx: ctx, reader: source}, e.Size), make([]byte, 64<<10))
			if err == nil && (n != e.Size || hex.EncodeToString(h.Sum(nil)) != e.SHA256) {
				err = ErrSource
			}
			if err == nil {
				var extra [1]byte
				count, readErr := io.ReadFull(&contextReader{ctx: ctx, reader: source}, extra[:])
				if count != 0 || readErr != io.EOF {
					err = ErrSource
				}
			}
		}
		closeErr := source.Close()
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return fmt.Errorf("%w: %s: %v", ErrSource, e.ID, err)
		}
		if closeErr != nil {
			return fmt.Errorf("%w: close %s", ErrSource, e.ID)
		}
	}
	return tw.Close()
}

type contextReader struct {
	ctx    context.Context
	reader io.Reader
}

func (r *contextReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.reader.Read(p)
}

type contextWriter struct {
	ctx    context.Context
	writer io.Writer
}

func (w *contextWriter) Write(p []byte) (int, error) {
	if err := w.ctx.Err(); err != nil {
		return 0, err
	}
	return w.writer.Write(p)
}

type boundedReader struct {
	ctx          context.Context
	reader       io.Reader
	count, limit int64
}

func (r *boundedReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	if r.count >= r.limit {
		return 0, ErrLimit
	}
	if int64(len(p)) > r.limit-r.count {
		p = p[:int(r.limit-r.count)]
	}
	n, err := r.reader.Read(p)
	r.count += int64(n)
	return n, err
}

// checkJSON rejects duplicate keys before encoding/json can silently keep the
// last one. Exact field names and null rejection are checked separately below.
func checkJSON(raw []byte) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	var value func(int) error
	value = func(depth int) error {
		if depth > 12 {
			return ErrInvalid
		}
		token, err := dec.Token()
		if err != nil {
			return ErrInvalid
		}
		delim, ok := token.(json.Delim)
		if !ok {
			return nil
		}
		switch delim {
		case '{':
			seen := map[string]bool{}
			for dec.More() {
				key, err := dec.Token()
				if err != nil {
					return ErrInvalid
				}
				name, ok := key.(string)
				if !ok || seen[name] {
					return ErrInvalid
				}
				seen[name] = true
				if err = value(depth + 1); err != nil {
					return err
				}
			}
			end, err := dec.Token()
			if err != nil || end != json.Delim('}') {
				return ErrInvalid
			}
		case '[':
			for dec.More() {
				if err := value(depth + 1); err != nil {
					return err
				}
			}
			end, err := dec.Token()
			if err != nil || end != json.Delim(']') {
				return ErrInvalid
			}
		default:
			return ErrInvalid
		}
		return nil
	}
	if err := value(0); err != nil {
		return err
	}
	if _, err := dec.Token(); err != io.EOF {
		return ErrInvalid
	}
	return nil
}
func exactFields(raw []byte, names ...string) error {
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil || len(fields) != len(names) {
		return ErrInvalid
	}
	for _, name := range names {
		v, ok := fields[name]
		if !ok || bytes.Equal(bytes.TrimSpace(v), []byte("null")) {
			return ErrInvalid
		}
	}
	return nil
}
func decodeManifest(raw []byte, l Limits) (Manifest, error) {
	var m Manifest
	if err := checkJSON(raw); err != nil {
		return m, err
	}
	if err := exactFields(raw, "version", "family_id", "entries"); err != nil {
		return m, err
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil || len(bytes.TrimSpace(fields["entries"])) == 0 || bytes.TrimSpace(fields["entries"])[0] != '[' {
		return m, ErrInvalid
	}
	var entries []json.RawMessage
	if json.Unmarshal(fields["entries"], &entries) != nil {
		return m, ErrInvalid
	}
	if len(entries) > l.MaxEntries {
		return m, ErrLimit
	}
	for _, entry := range entries {
		if err := exactFields(entry, "id", "kind", "size", "sha256", "missing_reason", "source_exact"); err != nil {
			return m, err
		}
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if dec.Decode(&m) != nil {
		return m, ErrInvalid
	}
	return m, validate(m, l)
}

func checkHeader(h *tar.Header, name string, size int64) error {
	if h.Name != name || h.Typeflag != tar.TypeReg || h.Linkname != "" || h.Size != size || h.Format != tar.FormatGNU || len(h.PAXRecords) != 0 {
		return ErrInvalid
	}
	return nil
}

// readWireHeader parses exactly one physical block. Passing the entire stream
// to tar.Reader would silently consume GNU/PAX extension entries before Next.
func readWireHeader(reader io.Reader) (*tar.Header, error) {
	var block [512]byte
	if _, err := io.ReadFull(reader, block[:]); err != nil {
		return nil, ErrInvalid
	}
	if block[156] != tar.TypeReg {
		return nil, ErrInvalid
	}
	h, err := tar.NewReader(bytes.NewReader(block[:])).Next()
	if err != nil {
		return nil, ErrInvalid
	}
	return h, nil
}
func readZeroPadding(reader io.Reader, size int64) error {
	n := paddingSize(size) - size
	var padding [511]byte
	if _, err := io.ReadFull(reader, padding[:n]); err != nil {
		return ErrInvalid
	}
	for _, b := range padding[:n] {
		if b != 0 {
			return ErrInvalid
		}
	}
	return nil
}

func randomID() (string, error) {
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(id[:]), nil
}

// Restore fully verifies the source into private staging before reserving a new
// destination with Mkdir. Publication copies verified files using O_EXCL and
// writes a completion marker last; it never renames over an existing directory.
// Records remain inert files: Result is not a completed application import.
func Restore(ctx context.Context, source io.Reader, opts RestoreOptions) (result Result, err error) {
	l, err := normalizeLimits(opts.Limits)
	if err != nil {
		return result, err
	}
	if !identifier.MatchString(opts.ExpectedFamilyID) || opts.Destination == "" {
		return result, ErrInvalid
	}
	if opts.RequirePrivateACL && runtime.GOOS == "windows" {
		return result, ErrPrivateACLUnavailable
	}
	destination, err := filepath.Abs(opts.Destination)
	if err != nil {
		return result, err
	}
	if _, statErr := os.Lstat(destination); statErr == nil {
		return result, ErrDestinationExists
	} else if !errors.Is(statErr, os.ErrNotExist) {
		return result, statErr
	}
	parent := filepath.Dir(destination)
	parentInfo, err := os.Stat(parent)
	if err != nil || !parentInfo.IsDir() {
		return result, fmt.Errorf("portable: destination parent unavailable")
	}
	stage, err := os.MkdirTemp(parent, ".wo-verified-")
	if err != nil {
		return result, err
	}
	defer os.RemoveAll(stage)
	reader := &boundedReader{ctx: ctx, reader: source, limit: l.MaxManifestBytes + 1024}
	first, err := readWireHeader(reader)
	if err != nil {
		return result, fmt.Errorf("%w: manifest header", ErrInvalid)
	}
	if first.Size < 1 || first.Size > l.MaxManifestBytes {
		return result, ErrLimit
	}
	if err = checkHeader(first, "manifest.json", first.Size); err != nil {
		return result, err
	}
	raw, err := io.ReadAll(io.LimitReader(reader, first.Size))
	if err != nil || int64(len(raw)) != first.Size {
		return result, fmt.Errorf("%w: manifest data", ErrInvalid)
	}
	if err = readZeroPadding(reader, first.Size); err != nil {
		return result, err
	}
	m, err := decodeManifest(raw, l)
	if err != nil {
		return result, err
	}
	if m.FamilyID != opts.ExpectedFamilyID {
		return result, ErrFamily
	}
	expectedSize := archiveSize(int64(len(raw)), m)
	reader.limit = expectedSize + 1
	result = Result{SourceFamilyID: m.FamilyID, Directory: destination, Files: map[string]RestoredFile{}, Missing: map[string]MissingReason{}, UnverifiedOriginals: map[string]MissingReason{}, Complete: true, RecordsApplied: false}
	result.NewFamilyID, err = randomID()
	if err != nil {
		return Result{}, err
	}
	if result.NewFamilyID == m.FamilyID {
		result.NewFamilyID, err = randomID()
		if err != nil {
			return Result{}, err
		}
	}
	result.NewDeviceID, err = randomID()
	if err != nil {
		return Result{}, err
	}
	result.RestoreID, err = randomID()
	if err != nil {
		return Result{}, err
	}
	for _, e := range m.Entries {
		if e.MissingReason != "" {
			result.Missing[e.ID] = e.MissingReason
			result.Complete = false
			continue
		}
		h, nextErr := readWireHeader(reader)
		if nextErr != nil {
			return Result{}, fmt.Errorf("%w: entry missing", ErrInvalid)
		}
		if err = checkHeader(h, "entries/"+e.ID, e.Size); err != nil {
			return Result{}, err
		}
		id, idErr := randomID()
		if idErr != nil {
			return Result{}, idErr
		}
		file, createErr := os.OpenFile(filepath.Join(stage, id+".blob"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if createErr != nil {
			return Result{}, createErr
		}
		hash := sha256.New()
		n, copyErr := io.CopyBuffer(io.MultiWriter(file, hash), io.LimitReader(reader, e.Size), make([]byte, 64<<10))
		if copyErr == nil {
			copyErr = file.Sync()
		}
		closeErr := file.Close()
		if copyErr != nil || closeErr != nil || n != e.Size || hex.EncodeToString(hash.Sum(nil)) != e.SHA256 {
			return Result{}, fmt.Errorf("%w: entry integrity", ErrInvalid)
		}
		if err = readZeroPadding(reader, e.Size); err != nil {
			return Result{}, err
		}
		result.Files[e.ID] = RestoredFile{NewID: id, Kind: e.Kind, Path: filepath.Join(destination, "data", id+".blob"), Size: e.Size, SHA256: e.SHA256, SourceExact: e.SourceExact}
		if (e.Kind == Photo || e.Kind == Video) && !e.SourceExact {
			result.UnverifiedOriginals[e.ID] = SourceNotExact
			result.Complete = false
		}
	}
	var terminator [1024]byte
	if _, readErr := io.ReadFull(reader, terminator[:]); readErr != nil {
		return Result{}, fmt.Errorf("%w: incomplete tar terminator", ErrInvalid)
	}
	for _, b := range terminator {
		if b != 0 {
			return Result{}, fmt.Errorf("%w: unexpected tar entry or terminator", ErrInvalid)
		}
	}
	if reader.count != expectedSize {
		return Result{}, fmt.Errorf("%w: incomplete tar terminator", ErrInvalid)
	}
	var extra [1]byte
	if n, readErr := io.ReadFull(reader, extra[:]); n != 0 || readErr != io.EOF {
		return Result{}, fmt.Errorf("%w: trailing bytes", ErrInvalid)
	}
	if err = ctx.Err(); err != nil {
		return Result{}, err
	}
	if err = os.Mkdir(destination, 0700); err != nil {
		if errors.Is(err, os.ErrExist) {
			return Result{}, ErrDestinationExists
		}
		return Result{}, err
	}
	publication := newPublication(destination)
	defer func() {
		if err != nil {
			publication.cleanup()
		}
	}()
	if err = publication.makeData(); err != nil {
		return Result{}, err
	}
	for _, e := range m.Entries {
		f, exists := result.Files[e.ID]
		if !exists {
			continue
		}
		if err = publication.copyVerified(ctx, filepath.Join(stage, f.NewID+".blob"), f.Path, f.Size, f.SHA256); err != nil {
			return Result{}, err
		}
	}
	result.CompletionMarker = filepath.Join(destination, "restore.complete.json")
	metadata, err := json.Marshal(result)
	if err != nil {
		return Result{}, err
	}
	if err = publication.writeExclusive(filepath.Join(destination, "manifest.json"), raw); err != nil {
		return Result{}, err
	}
	if err = publication.writeExclusive(result.CompletionMarker, metadata); err != nil {
		return Result{}, err
	}
	return result, nil
}

type ownedFile struct {
	path string
	info os.FileInfo
}
type publication struct {
	destination string
	files       []ownedFile
	dataCreated bool
}

func newPublication(destination string) *publication { return &publication{destination: destination} }
func (p *publication) makeData() error {
	err := os.Mkdir(filepath.Join(p.destination, "data"), 0700)
	p.dataCreated = err == nil
	return err
}
func (p *publication) create(path string) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return nil, err
	}
	info, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, err
	}
	p.files = append(p.files, ownedFile{path, info})
	return f, nil
}
func (p *publication) writeExclusive(path string, raw []byte) error {
	f, err := p.create(path)
	if err != nil {
		return err
	}
	_, err = f.Write(raw)
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	return closeErr
}
func (p *publication) copyVerified(ctx context.Context, source, target string, size int64, expected string) error {
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := p.create(target)
	if err != nil {
		return err
	}
	h := sha256.New()
	n, err := io.CopyBuffer(io.MultiWriter(out, h), &contextReader{ctx: ctx, reader: io.LimitReader(in, size+1)}, make([]byte, 64<<10))
	if err == nil && (n != size || hex.EncodeToString(h.Sum(nil)) != expected) {
		err = ErrInvalid
	}
	if err == nil {
		err = out.Sync()
	}
	closeErr := out.Close()
	if err != nil {
		return err
	}
	return closeErr
}
func (p *publication) cleanup() {
	for i := len(p.files) - 1; i >= 0; i-- {
		f := p.files[i]
		if current, err := os.Lstat(f.path); err == nil && os.SameFile(current, f.info) {
			os.Remove(f.path)
		}
	}
	if p.dataCreated {
		os.Remove(filepath.Join(p.destination, "data"))
	}
	os.Remove(p.destination)
}
