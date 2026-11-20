// Package packagebinding verifies the inventory link inside an authenticated
// private archive. A binding is byte/package evidence, never business permission,
// historical author authorization, or permission to publish restricted contents.
package packagebinding

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/chunyiKit/Wo/desktop/internal/backup"
	"github.com/chunyiKit/Wo/desktop/internal/portable"
	"github.com/chunyiKit/Wo/desktop/internal/vault"
)

const (
	EntryID                    = "wo_backup_package_binding_v1"
	Version                    = 1
	Kind                       = "wo_backup_package_binding"
	MaxBytes                   = 8 << 20
	MaxPublicEntries           = 4095
	MaxRestrictedEntries       = 19999
	MaxCombinedBytes     int64 = 100 << 30
)

var (
	ErrInvalid  = errors.New("packagebinding: invalid binding")
	ErrMismatch = errors.New("packagebinding: package inventory or context mismatch")
	ErrUnbound  = errors.New("packagebinding: legacy archive has no package binding")
	ErrSource   = errors.New("packagebinding: public source unavailable or changed")
	portableID  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$`)
	digest      = regexp.MustCompile(`^[a-f0-9]{64}$`)
)

// Index describes inventories, not a verified identity or authorization receipt.
// Fields must not be used as filesystem paths. Restricted entries retain their
// private status even when this index lists publicly readable outer entries.
type Index struct {
	Version           int              `json:"version"`
	Kind              string           `json:"kind"`
	FamilyID          string           `json:"family_id"`
	BackupID          string           `json:"backup_id"`
	SealedID          string           `json:"sealed_id"`
	PublicEntries     []backup.Entry   `json:"public_entries"`
	RestrictedEntries []portable.Entry `json:"restricted_entries"`
}

// Build is called before encryption, so it deliberately does not need the
// ciphertext's size/hash. Source inventories must not contain the reserved ID.
// The returned JSON bytes themselves must be a records entry in the inner tar.
func Build(authContext vault.Context, public []backup.Entry, restricted []portable.Entry) ([]byte, error) {
	index := Index{Version: Version, Kind: Kind, FamilyID: authContext.Family, BackupID: authContext.Backup, SealedID: authContext.Entry,
		PublicEntries: append([]backup.Entry{}, public...), RestrictedEntries: append([]portable.Entry{}, restricted...)}
	if err := validateIndex(index); err != nil {
		return nil, err
	}
	sort.Slice(index.PublicEntries, func(a, b int) bool { return index.PublicEntries[a].ID < index.PublicEntries[b].ID })
	sort.Slice(index.RestrictedEntries, func(a, b int) bool { return index.RestrictedEntries[a].ID < index.RestrictedEntries[b].ID })
	raw, err := json.Marshal(index)
	if err != nil || len(raw) > MaxBytes || !combinedFits(index, int64(len(raw))) {
		return nil, ErrInvalid
	}
	return raw, nil
}

// Decode rejects duplicate keys at every depth, unknown/missing keys, nulls,
// malformed numbers/types, and inventories with case-insensitive ID collisions.
// Decode alone is NOT authentication. Only Validate after successful vault
// authentication can associate public files with the private archive.
func Decode(raw []byte) (Index, error) {
	if len(raw) == 0 || len(raw) > MaxBytes || !utf8.Valid(raw) {
		return Index{}, ErrInvalid
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := checkValue(decoder, 0); err != nil {
		return Index{}, err
	}
	if _, err := decoder.Token(); err != io.EOF {
		return Index{}, ErrInvalid
	}
	var root map[string]json.RawMessage
	if err := json.Unmarshal(raw, &root); err != nil || !keys(root, []string{"version", "kind", "family_id", "backup_id", "sealed_id", "public_entries", "restricted_entries"}, nil) {
		return Index{}, ErrInvalid
	}
	for key, value := range root {
		if bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return Index{}, fmt.Errorf("%w: null %s", ErrInvalid, key)
		}
	}
	var public, restricted []json.RawMessage
	if err := json.Unmarshal(root["public_entries"], &public); err != nil || public == nil || len(public) > MaxPublicEntries {
		return Index{}, ErrInvalid
	}
	if err := json.Unmarshal(root["restricted_entries"], &restricted); err != nil || restricted == nil || len(restricted) > MaxRestrictedEntries {
		return Index{}, ErrInvalid
	}
	for _, rawEntry := range public {
		var object map[string]json.RawMessage
		if err := json.Unmarshal(rawEntry, &object); err != nil || !keys(object, []string{"id", "kind", "size"}, []string{"sha256", "label", "missing", "source_exact"}) {
			return Index{}, ErrInvalid
		}
		if hasNull(object) {
			return Index{}, ErrInvalid
		}
		// Match BackupEntry.toJson's exact optional-field shape. Keeping a
		// present false/empty optional would differ from Dart's canonical map.
		for _, key := range []string{"sha256", "label", "missing"} {
			if value, present := object[key]; present {
				var text string
				if json.Unmarshal(value, &text) != nil || text == "" {
					return Index{}, ErrInvalid
				}
			}
		}
		if value, present := object["source_exact"]; present && !bytes.Equal(bytes.TrimSpace(value), []byte("true")) {
			return Index{}, ErrInvalid
		}
	}
	for _, rawEntry := range restricted {
		var object map[string]json.RawMessage
		if err := json.Unmarshal(rawEntry, &object); err != nil || !keys(object, []string{"id", "kind", "size", "sha256", "missing_reason", "source_exact"}, nil) {
			return Index{}, ErrInvalid
		}
		if hasNull(object) {
			return Index{}, ErrInvalid
		}
	}
	var result Index
	strict := json.NewDecoder(bytes.NewReader(raw))
	strict.DisallowUnknownFields()
	if err := strict.Decode(&result); err != nil {
		return Index{}, ErrInvalid
	}
	if err := validateIndex(result); err != nil {
		return Index{}, err
	}
	if !combinedFits(result, int64(len(raw))) {
		return Index{}, ErrInvalid
	}
	return result, nil
}

// Validate must be called with the actual context used for a successfully
// authenticated vault RestoreFile/Verify; context inferred from unauthenticated
// JSON or an ordinary portable restore is not source authentication. It compares
// ALL inventory metadata and the original index's exact size/SHA, regardless of
// JSON key or inventory order. The sealed entry itself is separately authenticated
// and hashed by the vault/backup layers, not by this pure metadata validator.
// ErrUnbound permits retaining an old sealed archive read-only in isolation;
// it never permits associating public files by UUID or copying active identities.
func Validate(raw []byte, outer backup.Manifest, inner portable.Manifest, authenticatedContext vault.Context) (Index, error) {
	if err := backup.Validate(outer); err != nil {
		return Index{}, ErrInvalid
	}
	if inner.Version != portable.Version || !portableID.MatchString(inner.FamilyID) || inner.Entries == nil || len(inner.Entries) > MaxRestrictedEntries+1 {
		return Index{}, ErrInvalid
	}
	if err := validatePortable(inner.Entries, true); err != nil {
		return Index{}, err
	}
	var marker *portable.Entry
	for i := range inner.Entries {
		entry := &inner.Entries[i]
		if strings.EqualFold(entry.ID, EntryID) {
			if entry.ID != EntryID || marker != nil {
				return Index{}, ErrInvalid
			}
			marker = entry
		}
	}
	if marker == nil {
		return Index{}, ErrUnbound
	}
	index, err := Decode(raw)
	if err != nil {
		return Index{}, err
	}
	if index.FamilyID != outer.FamilyID || index.FamilyID != inner.FamilyID || index.FamilyID != authenticatedContext.Family ||
		index.BackupID != outer.BackupID || index.BackupID != authenticatedContext.Backup || index.SealedID != authenticatedContext.Entry {
		return Index{}, ErrMismatch
	}
	sum := sha256.Sum256(raw)
	if marker.Kind != portable.Records || marker.MissingReason != "" || marker.SourceExact || marker.Size != int64(len(raw)) || marker.SHA256 != hex.EncodeToString(sum[:]) {
		return Index{}, ErrMismatch
	}
	public := make([]backup.Entry, 0, len(outer.Entries))
	sealed := 0
	for _, entry := range outer.Entries {
		if entry.Kind == "sealed" {
			sealed++
			if entry.ID != index.SealedID {
				return Index{}, ErrMismatch
			}
		} else {
			public = append(public, entry)
		}
	}
	if sealed != 1 {
		return Index{}, ErrMismatch
	}
	restricted := make([]portable.Entry, 0, len(inner.Entries)-1)
	for _, entry := range inner.Entries {
		if entry.ID != EntryID {
			restricted = append(restricted, entry)
		}
	}
	if !samePublic(public, index.PublicEntries) || !sameRestricted(restricted, index.RestrictedEntries) {
		return Index{}, ErrMismatch
	}
	return index, nil
}

func validateIndex(index Index) error {
	if !combinedFits(index, 0) {
		return ErrInvalid
	}
	if index.Version != Version || index.Kind != Kind || !backup.ValidID(index.FamilyID) || !portableID.MatchString(index.FamilyID) || !backup.ValidID(index.BackupID) || !backup.ValidID(index.SealedID) ||
		strings.EqualFold(index.SealedID, EntryID) || index.PublicEntries == nil || index.RestrictedEntries == nil || len(index.PublicEntries) > MaxPublicEntries || len(index.RestrictedEntries) > MaxRestrictedEntries || len(index.PublicEntries)+len(index.RestrictedEntries) > MaxRestrictedEntries {
		return ErrInvalid
	}
	// Reuse the outer production validator with an opaque placeholder. Its fields
	// are excluded from the index because authenticated ciphertext does not exist yet.
	entries := append([]backup.Entry{}, index.PublicEntries...)
	entries = append(entries, backup.Entry{ID: index.SealedID, Kind: "sealed", Size: vault.MinCiphertextBytes, SHA256: strings.Repeat("0", 64)})
	if err := backup.Validate(backup.Manifest{Version: 1, FamilyID: index.FamilyID, BackupID: index.BackupID, Entries: entries}); err != nil {
		return ErrInvalid
	}
	seen := map[string]bool{strings.ToLower(EntryID): true, strings.ToLower(index.SealedID): true}
	for _, entry := range index.PublicEntries {
		folded := strings.ToLower(entry.ID)
		if entry.Size > 20<<30 || (entry.Kind != "photo" && entry.Kind != "video" && entry.Kind != "thumbnail") || seen[folded] || !utf8.ValidString(entry.Label) || entry.Missing != "" && entry.SourceExact || entry.SourceExact && entry.Kind != "photo" && entry.Kind != "video" {
			return ErrInvalid
		}
		seen[folded] = true
	}
	if err := validatePortable(index.RestrictedEntries, false); err != nil {
		return err
	}
	for _, entry := range index.RestrictedEntries {
		folded := strings.ToLower(entry.ID)
		if seen[folded] {
			return ErrInvalid
		}
		seen[folded] = true
	}
	return nil
}

// The mobile package importer reconstructs ONE portable manifest. This limit
// includes both inventories and the exact index bytes, unlike the generic outer
// backup.Store's independent 1TiB storage allowance.
func combinedFits(index Index, indexBytes int64) bool {
	if indexBytes < 0 || indexBytes > MaxCombinedBytes {
		return false
	}
	total := indexBytes
	for _, entry := range index.PublicEntries {
		if entry.Size < 0 || entry.Size > MaxCombinedBytes-total {
			return false
		}
		total += entry.Size
	}
	for _, entry := range index.RestrictedEntries {
		if entry.Size < 0 || entry.Size > MaxCombinedBytes-total {
			return false
		}
		total += entry.Size
	}
	return true
}
func validatePortable(entries []portable.Entry, allowIndex bool) error {
	seen := map[string]bool{}
	var total int64
	for _, entry := range entries {
		folded := strings.ToLower(entry.ID)
		if !portableID.MatchString(entry.ID) || seen[folded] || !allowIndex && folded == strings.ToLower(EntryID) {
			return ErrInvalid
		}
		seen[folded] = true
		switch entry.Kind {
		case portable.Records, portable.Photo, portable.Video, portable.Thumbnail:
		default:
			return ErrInvalid
		}
		if entry.MissingReason != "" {
			switch entry.MissingReason {
			case portable.NotOnDevice, portable.PermissionDenied, portable.SourceMissing, portable.SourceUnavailable, portable.Unsupported, portable.NotAuthorized, portable.SourceNotExact:
			default:
				return ErrInvalid
			}
			if entry.Size != 0 || entry.SHA256 != "" || entry.SourceExact {
				return ErrInvalid
			}
			continue
		}
		if entry.Size < 1 || entry.Size > 20<<30 || !digest.MatchString(entry.SHA256) || entry.SourceExact && entry.Kind != portable.Photo && entry.Kind != portable.Video {
			return ErrInvalid
		}
		if entry.Size > 100<<30-total {
			return ErrInvalid
		}
		total += entry.Size
	}
	return nil
}
func samePublic(a, b []backup.Entry) bool {
	if len(a) != len(b) {
		return false
	}
	a = append([]backup.Entry{}, a...)
	b = append([]backup.Entry{}, b...)
	sort.Slice(a, func(i, j int) bool { return a[i].ID < a[j].ID })
	sort.Slice(b, func(i, j int) bool { return b[i].ID < b[j].ID })
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
func sameRestricted(a, b []portable.Entry) bool {
	if len(a) != len(b) {
		return false
	}
	a = append([]portable.Entry{}, a...)
	b = append([]portable.Entry{}, b...)
	sort.Slice(a, func(i, j int) bool { return a[i].ID < a[j].ID })
	sort.Slice(b, func(i, j int) bool { return b[i].ID < b[j].ID })
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
func keys(object map[string]json.RawMessage, required, optional []string) bool {
	if object == nil {
		return false
	}
	allowed := map[string]bool{}
	for _, key := range required {
		if _, ok := object[key]; !ok {
			return false
		}
		allowed[key] = true
	}
	for _, key := range optional {
		allowed[key] = true
	}
	for key := range object {
		if !allowed[key] {
			return false
		}
	}
	return true
}
func hasNull(object map[string]json.RawMessage) bool {
	for _, value := range object {
		if bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return true
		}
	}
	return false
}
func checkValue(decoder *json.Decoder, depth int) error {
	if depth > 16 {
		return ErrInvalid
	}
	token, err := decoder.Token()
	if err != nil {
		return ErrInvalid
	}
	delimiter, container := token.(json.Delim)
	if !container {
		return nil
	}
	switch delimiter {
	case '{':
		seen := map[string]bool{}
		for decoder.More() {
			key, err := decoder.Token()
			if err != nil {
				return ErrInvalid
			}
			name, ok := key.(string)
			if !ok || seen[name] {
				return ErrInvalid
			}
			seen[name] = true
			if err := checkValue(decoder, depth+1); err != nil {
				return err
			}
		}
		closing, err := decoder.Token()
		if err != nil || closing != json.Delim('}') {
			return ErrInvalid
		}
	case '[':
		for decoder.More() {
			if err := checkValue(decoder, depth+1); err != nil {
				return err
			}
		}
		closing, err := decoder.Token()
		if err != nil || closing != json.Delim(']') {
			return ErrInvalid
		}
	default:
		return ErrInvalid
	}
	return nil
}

// OpenPublic must open only a caller-controlled source for the exact opaque ID.
type OpenPublic func(entryID string) (io.ReadCloser, error)

// VerifyPublic streams and checks declared PRESENT public bytes. Missing entries
// remain missing: nil error is not a complete backup or exact-original attestation.
// Use only after Validate with an authenticated context to link these bytes.
func VerifyPublic(ctx context.Context, index Index, open OpenPublic) error {
	if err := validateIndex(index); err != nil {
		return err
	}
	if open == nil {
		return ErrSource
	}
	for _, entry := range index.PublicEntries {
		if err := ctx.Err(); err != nil {
			return err
		}
		if entry.Missing != "" {
			continue
		}
		source, err := open(entry.ID)
		if err != nil || source == nil {
			return ErrSource
		}
		hash := sha256.New()
		n, readErr := io.Copy(hash, io.LimitReader(&contextReader{ctx: ctx, reader: source}, entry.Size+1))
		closeErr := source.Close()
		if err := ctx.Err(); err != nil {
			return err
		}
		if readErr != nil {
			return ErrSource
		}
		if closeErr != nil || n != entry.Size || hex.EncodeToString(hash.Sum(nil)) != entry.SHA256 {
			return ErrSource
		}
	}
	return nil
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
