// Package backup 保存发送端声明的归档；电脑不参与手机资料合并。
package backup

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/chunyiKit/Wo/desktop/internal/vault"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

const ChunkSize int64 = 8 << 20
const MaxAttachmentSize int64 = 20 << 20
const FileVersion = 2
const MaxFileSize int64 = 64 << 30
const MaxTotalSize int64 = 1 << 40

var ErrConflict = errors.New("offset or immutable manifest conflict")
var ErrIncomplete = errors.New("backup is incomplete")
var idPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,100}$`)
var hashPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)

func ValidID(id string) bool {
	if !idPattern.MatchString(id) {
		return false
	}
	upper := strings.ToUpper(id)
	switch upper {
	case "CON", "PRN", "AUX", "NUL":
		return false
	}
	if len(upper) == 4 && (strings.HasPrefix(upper, "COM") || strings.HasPrefix(upper, "LPT")) && upper[3] >= '1' && upper[3] <= '9' {
		return false
	}
	return true
}

type Entry struct {
	ID          string `json:"id"`
	Kind        string `json:"kind"` // records/photo/video/thumbnail/sealed/file (file requires v2)
	Size        int64  `json:"size"`
	SHA256      string `json:"sha256,omitempty"`
	Label       string `json:"label,omitempty"` // 仅公开显示，不作为路径
	Missing     string `json:"missing,omitempty"`
	SourceExact bool   `json:"source_exact,omitempty"` // 发送端声明，电脑无法证明平台未脱敏
}
type Manifest struct {
	Version  int     `json:"version"`
	FamilyID string  `json:"family_id"`
	BackupID string  `json:"backup_id"`
	Entries  []Entry `json:"entries"`
}
type EntryStatus struct {
	ID      string `json:"id"`
	Kind    string `json:"kind"`
	Label   string `json:"label,omitempty"`
	Offset  int64  `json:"offset"`
	Size    int64  `json:"size"`
	Missing string `json:"missing,omitempty"`
}
type Status struct {
	Scope              string        `json:"scope"`
	FullDeviceComplete bool          `json:"full_device_complete"`
	FamilyID           string        `json:"family_id"`
	BackupID           string        `json:"backup_id"`
	State              string        `json:"state"`
	Complete           bool          `json:"complete"`
	VerifiedAt         string        `json:"verified_at,omitempty"`
	Issues             []string      `json:"issues"`
	Entries            []EntryStatus `json:"entries"`
}
type chunk struct {
	Offset int64  `json:"offset"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}
type journal struct {
	Chunks []chunk `json:"chunks"`
}
type marker struct {
	ManifestSHA string `json:"manifest_sha"`
	VerifiedAt  string `json:"verified_at"`
}
type journalCache struct {
	J        journal
	Offset   int64
	DataTime time.Time
	LogTime  time.Time
	LogSize  int64
}
type Store struct {
	mu    sync.Mutex
	root  *os.Root
	path  string
	cache map[string]journalCache
}

func New(path string) (*Store, error) {
	path, err := filepath.Abs(path)
	if err != nil {
		return nil, err
	}
	if info, e := os.Lstat(path); e == nil && (!info.IsDir() || info.Mode()&os.ModeSymlink != 0) {
		return nil, errors.New("backup root must be a real directory")
	}
	if err = os.MkdirAll(path, 0700); err != nil {
		return nil, err
	}
	r, err := os.OpenRoot(path)
	if err != nil {
		return nil, err
	}
	if err = r.MkdirAll("backups", 0700); err != nil {
		r.Close()
		return nil, err
	}
	return &Store{root: r, path: path, cache: map[string]journalCache{}}, nil
}
func (s *Store) Close() error { return s.root.Close() }
func (s *Store) Path() string { return s.path }
func token() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b[:])
}
func digest(b []byte) string { x := sha256.Sum256(b); return hex.EncodeToString(x[:]) }
func RequiredVersion(entries []Entry) int {
	for _, e := range entries {
		if e.Kind == "file" {
			return FileVersion
		}
	}
	return 1
}
func Validate(m Manifest) error {
	if (m.Version != 1 && m.Version != FileVersion) || !ValidID(m.FamilyID) || !ValidID(m.BackupID) || len(m.Entries) < 1 || len(m.Entries) > 4096 {
		return errors.New("invalid manifest")
	}
	seen := map[string]bool{}
	var total int64
	sealed := 0
	for _, e := range m.Entries {
		if !ValidID(e.ID) || seen[strings.ToLower(e.ID)] || e.Size < 0 || e.Size > MaxFileSize {
			return errors.New("invalid or duplicate entry")
		}
		seen[strings.ToLower(e.ID)] = true
		if e.Kind != "records" && e.Kind != "photo" && e.Kind != "video" && e.Kind != "thumbnail" && e.Kind != "sealed" && e.Kind != "file" {
			return errors.New("invalid kind")
		}
		if e.Kind == "file" && (m.Version != FileVersion || e.Size > MaxAttachmentSize || e.Missing == "" && e.Size == 0) || e.SourceExact && e.Kind != "photo" && e.Kind != "video" {
			return errors.New("invalid file or source_exact")
		}
		if len(e.Label) > 240 {
			return errors.New("label too long")
		}
		for _, r := range e.Label {
			if r < 32 || r == 127 {
				return errors.New("invalid label")
			}
		}
		if e.Kind == "sealed" {
			sealed++
			if e.Label != "" || e.Missing != "" || e.SourceExact || e.Size < vault.MinCiphertextBytes {
				return errors.New("restricted archive must be opaque")
			}
		}
		if sealed > 1 {
			return errors.New("one opaque restricted container per backup")
		}
		if e.Missing != "" {
			if e.Missing != "permission_denied" && e.Missing != "cloud_only" && e.Missing != "source_unavailable" && e.Missing != "not_exact_original" {
				return errors.New("invalid missing reason")
			}
			if e.Size != 0 || e.SHA256 != "" {
				return errors.New("missing entry cannot claim bytes")
			}
		} else if !hashPattern.MatchString(e.SHA256) {
			return errors.New("invalid digest")
		}
		if (e.Kind == "photo" || e.Kind == "video") && e.Missing == "" && e.Size == 0 {
			return errors.New("empty original")
		}
		total += e.Size
		if total > MaxTotalSize {
			return errors.New("backup too large")
		}
	}
	encoded, err := json.Marshal(m)
	if err != nil || len(encoded) > 2<<20 {
		return errors.New("canonical manifest too large")
	}
	return nil
}
func base(fid, bid string) (string, error) {
	if !ValidID(fid) || !ValidID(bid) {
		return "", errors.New("invalid scope")
	}
	return "backups/" + fid + "/" + bid, nil
}
func (s *Store) atomic(name string, b []byte) error {
	tmp := name + ".tmp-" + token()
	f, err := s.root.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	defer s.root.Remove(tmp)
	if _, err = f.Write(b); err == nil {
		err = f.Sync()
	}
	if e := f.Close(); err == nil {
		err = e
	}
	if err != nil {
		return err
	}
	return s.root.Rename(tmp, name)
}
func (s *Store) regular(name string) (*os.File, error) {
	info, err := s.root.Lstat(name)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, errors.New("not regular file")
	}
	return s.root.Open(name)
}
func (s *Store) manifest(fid, bid string) (Manifest, error) {
	var m Manifest
	p, err := base(fid, bid)
	if err != nil {
		return m, err
	}
	f, err := s.regular(p + "/manifest.json")
	if err != nil {
		return m, err
	}
	defer f.Close()
	d := json.NewDecoder(io.LimitReader(f, 2<<20))
	d.DisallowUnknownFields()
	err = d.Decode(&m)
	if err == nil {
		err = Validate(m)
	}
	if err == nil && (m.FamilyID != fid || m.BackupID != bid) {
		err = errors.New("scope mismatch")
	}
	return m, err
}
func (s *Store) Create(m Manifest) error {
	if err := Validate(m); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	p, _ := base(m.FamilyID, m.BackupID)
	if _, err := s.root.Lstat(p); err == nil {
		old, e := s.manifest(m.FamilyID, m.BackupID)
		if e != nil {
			return e
		}
		a, _ := json.Marshal(old)
		b, _ := json.Marshal(m)
		if !bytes.Equal(a, b) {
			return ErrConflict
		}
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := s.capacity(m); err != nil {
		return err
	}
	if err := s.root.MkdirAll("backups/"+m.FamilyID, 0700); err != nil {
		return err
	}
	if err := s.root.Mkdir(p, 0700); err != nil {
		if !errors.Is(err, os.ErrExist) {
			return err
		}
		old, e := s.manifest(m.FamilyID, m.BackupID)
		if e != nil {
			return e
		}
		a, _ := json.Marshal(old)
		b, _ := json.Marshal(m)
		if string(a) != string(b) {
			return ErrConflict
		}
		return nil
	}
	if err := s.root.Mkdir(p+"/entries", 0700); err != nil {
		return err
	}
	b, _ := json.Marshal(m)
	return s.atomic(p+"/manifest.json", b)
}

// 全目录最多256个归档、声明总大小最多1TiB；无自动删除旧备份。
func (s *Store) capacity(next Manifest) error {
	var reserved int64
	for _, e := range next.Entries {
		reserved += e.Size
	}
	count := 0
	f, e := s.root.Open("backups")
	if e != nil {
		return e
	}
	families, e := f.ReadDir(-1)
	f.Close()
	if e != nil {
		return e
	}
	for _, family := range families {
		if !family.IsDir() || !ValidID(family.Name()) {
			continue
		}
		d, e := s.root.Open("backups/" + family.Name())
		if e != nil {
			return e
		}
		dirs, e := d.ReadDir(-1)
		d.Close()
		if e != nil {
			return e
		}
		for _, dir := range dirs {
			if !dir.IsDir() || !ValidID(dir.Name()) {
				continue
			}
			count++
			m, e := s.manifest(family.Name(), dir.Name())
			if e != nil {
				return errors.New("capacity cannot be verified")
			}
			for _, entry := range m.Entries {
				reserved += entry.Size
				if reserved > MaxTotalSize {
					return errors.New("backup directory quota reached")
				}
			}
		}
	}
	if count >= 256 || reserved > MaxTotalSize {
		return errors.New("backup directory quota reached")
	}
	return nil
}
func entry(m Manifest, id string) (Entry, error) {
	if !ValidID(id) {
		return Entry{}, errors.New("invalid entry")
	}
	for _, e := range m.Entries {
		if e.ID == id {
			return e, nil
		}
	}
	return Entry{}, os.ErrNotExist
}
func (s *Store) readJournal(path string) (journal, error) {
	var j journal
	if info, err := s.root.Lstat(path); err == nil && !info.Mode().IsRegular() {
		return j, errors.New("invalid journal")
	}
	f, err := s.root.OpenFile(path, os.O_RDWR, 0600)
	if errors.Is(err, os.ErrNotExist) {
		return j, nil
	}
	if err != nil {
		return j, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return j, err
	}
	if info.Size() > 65536*48 {
		return j, errors.New("journal too large")
	}
	for {
		var record [48]byte
		n, e := io.ReadFull(f, record[:])
		if e == io.EOF {
			break
		}
		if e == io.ErrUnexpectedEOF {
			if err = f.Truncate(info.Size() - int64(n)); err != nil {
				return j, err
			}
			if err = f.Sync(); err != nil {
				return j, err
			}
			break
		}
		if e != nil {
			return j, e
		}
		j.Chunks = append(j.Chunks, chunk{Offset: int64(binary.BigEndian.Uint64(record[:8])), Size: int64(binary.BigEndian.Uint64(record[8:16])), SHA256: hex.EncodeToString(record[16:])})
	}
	return j, nil
}
func (s *Store) remember(path string, j journal, offset int64) {
	data, e := s.root.Lstat(path + ".part")
	if e != nil {
		return
	}
	log, e := s.root.Lstat(path + ".journal")
	var stamp time.Time
	var size int64
	if e == nil {
		stamp = log.ModTime()
		size = log.Size()
	}
	s.cache[path] = journalCache{J: j, Offset: offset, DataTime: data.ModTime(), LogTime: stamp, LogSize: size}
}
func (s *Store) appendJournal(path string, c chunk, previous int64) error {
	f, e := s.root.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0600)
	if e != nil {
		return e
	}
	defer f.Close()
	info, e := s.root.Lstat(path)
	if e != nil || !info.Mode().IsRegular() {
		return errors.New("invalid journal")
	}
	var record [48]byte
	binary.BigEndian.PutUint64(record[:8], uint64(c.Offset))
	binary.BigEndian.PutUint64(record[8:16], uint64(c.Size))
	raw, e := hex.DecodeString(c.SHA256)
	if e != nil {
		return e
	}
	copy(record[16:], raw)
	if _, e = f.Write(record[:]); e == nil {
		e = f.Sync()
	}
	if e != nil {
		_ = f.Truncate(previous)
		_ = f.Sync()
	}
	return e
}

// reconcile 只承认已 fsync 并记录在日志中的完整块；崩溃尾部被截去，已确认块须重验摘要。
func (s *Store) reconcile(p string, e Entry) (journal, int64, error) {
	if cached, ok := s.cache[p]; ok {
		data, de := s.root.Lstat(p + ".part")
		log, le := s.root.Lstat(p + ".journal")
		logOK := le == nil && log.Mode().IsRegular() && log.Size() == cached.LogSize && log.ModTime().Equal(cached.LogTime)
		if errors.Is(le, os.ErrNotExist) && cached.LogSize == 0 {
			logOK = true
		}
		if de == nil && data.Mode().IsRegular() && data.Size() == cached.Offset && data.ModTime().Equal(cached.DataTime) && logOK {
			return cached.J, cached.Offset, nil
		}
		delete(s.cache, p)
	}
	j, err := s.readJournal(p + ".journal")
	if err != nil {
		return j, 0, err
	}
	if len(j.Chunks) > 65536 {
		return j, 0, errors.New("too many chunks")
	}
	f, err := s.root.OpenFile(p+".part", os.O_RDWR|os.O_CREATE, 0600)
	if err != nil {
		return j, 0, err
	}
	defer f.Close()
	info, err := s.root.Lstat(p + ".part")
	if err != nil || !info.Mode().IsRegular() {
		return j, 0, errors.New("invalid partial file")
	}
	var offset int64
	for _, c := range j.Chunks {
		if c.Offset != offset || c.Size <= 0 || c.Size > ChunkSize || offset+c.Size > e.Size || !hashPattern.MatchString(c.SHA256) {
			return j, 0, errors.New("invalid chunk journal")
		}
		h := sha256.New()
		n, er := io.CopyN(h, f, c.Size)
		if er != nil || n != c.Size || hex.EncodeToString(h.Sum(nil)) != c.SHA256 {
			return j, 0, errors.New("partial data corrupt")
		}
		offset += c.Size
	}
	stat, err := f.Stat()
	if err != nil {
		return j, 0, err
	}
	if stat.Size() < offset {
		return j, 0, errors.New("partial data truncated")
	}
	if stat.Size() > offset {
		if err = f.Truncate(offset); err != nil {
			return j, 0, err
		}
		if err = f.Sync(); err != nil {
			return j, 0, err
		}
	}
	s.remember(p, j, offset)
	return j, offset, nil
}
func (s *Store) Append(fid, bid, eid string, offset, length int64, sha string, r io.Reader) (int64, error) {
	if offset < 0 || length <= 0 || length > ChunkSize || !hashPattern.MatchString(sha) {
		return 0, errors.New("invalid chunk")
	}
	// 不持全库锁读取网络：一个慢手机不能阻塞别的家庭或本机管理。
	s.mu.Lock()
	m, err := s.manifest(fid, bid)
	var e Entry
	if err == nil {
		e, err = entry(m, eid)
	}
	s.mu.Unlock()
	if err != nil {
		return 0, err
	}
	if e.Missing != "" || offset+length > e.Size {
		return 0, ErrConflict
	}
	p, _ := base(fid, bid)
	p += "/entries/" + eid
	tmp := p + ".incoming-" + token()
	f, err := s.root.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return 0, err
	}
	defer s.root.Remove(tmp)
	h := sha256.New()
	n, copyErr := io.Copy(io.MultiWriter(f, h), io.LimitReader(r, length+1))
	closeErr := f.Close()
	if copyErr != nil || closeErr != nil || n != length || hex.EncodeToString(h.Sum(nil)) != sha {
		return 0, errors.New("chunk size or digest mismatch")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	latest, err := s.manifest(fid, bid)
	if err != nil {
		return 0, err
	}
	same, err := entry(latest, eid)
	if err != nil || same != e {
		return 0, ErrConflict
	}
	if _, err = s.root.Stat(p + ".blob"); err == nil {
		return e.Size, ErrConflict
	}
	j, current, err := s.reconcile(p, e)
	if err != nil {
		return 0, err
	}
	retry := false
	if offset < current {
		for _, c := range j.Chunks {
			if c.Offset == offset && c.Size == length && c.SHA256 == sha {
				retry = true
				break
			}
		}
	}
	if offset != current && !retry {
		return current, ErrConflict
	}
	if len(j.Chunks) >= 65536 && !retry {
		return current, errors.New("chunk limit")
	}
	if retry {
		return current, nil
	}
	src, err := s.regular(tmp)
	if err != nil {
		return current, err
	}
	defer src.Close()
	dst, err := s.root.OpenFile(p+".part", os.O_WRONLY, 0600)
	if err != nil {
		return current, err
	}
	defer dst.Close()
	if _, err = dst.Seek(current, io.SeekStart); err == nil {
		_, err = io.Copy(dst, src)
	}
	if err == nil {
		err = dst.Sync()
	}
	if err != nil {
		_ = dst.Truncate(current)
		return current, err
	}
	next := chunk{Offset: current, Size: length, SHA256: sha}
	if err = s.appendJournal(p+".journal", next, int64(len(j.Chunks))*48); err != nil {
		_ = dst.Truncate(current)
		_ = dst.Sync()
		return current, err
	}
	j.Chunks = append(j.Chunks, next)
	s.remember(p, j, current+length)
	return current + length, nil
}
func (s *Store) Manifest(fid, bid string) (Manifest, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.manifest(fid, bid)
}
func fileSHA(f *os.File) (string, int64, error) {
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return "", 0, err
	}
	h := sha256.New()
	n, err := io.CopyBuffer(h, f, make([]byte, 128<<10))
	return hex.EncodeToString(h.Sum(nil)), n, err
}
func (s *Store) verify(m Manifest, publish bool) error {
	p, _ := base(m.FamilyID, m.BackupID)
	for _, e := range m.Entries {
		if e.Missing != "" {
			continue
		}
		name := p + "/entries/" + e.ID
		f, err := s.regular(name + ".blob")
		partial := false
		if errors.Is(err, os.ErrNotExist) {
			_, offset, er := s.reconcile(name, e)
			if er != nil {
				return er
			}
			if offset != e.Size {
				return ErrIncomplete
			}
			f, err = s.regular(name + ".part")
			partial = true
		}
		if err != nil {
			return err
		}
		if e.Kind == "sealed" {
			if _, headerErr := vault.InspectHeader(f); headerErr != nil {
				f.Close()
				return errors.New("invalid sealed header")
			}
		}
		sha, n, err := fileSHA(f)
		f.Close()
		if err != nil || n != e.Size || sha != e.SHA256 {
			return errors.New("final digest mismatch")
		}
		if partial && publish {
			if err = s.root.Rename(name+".part", name+".blob"); err != nil {
				return err
			}
		}
	}
	return nil
}
func (s *Store) Finalize(fid, bid string) (Status, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, err := s.manifest(fid, bid)
	if err != nil {
		return Status{}, err
	}
	if err = s.verify(m, true); err != nil {
		return Status{}, err
	}
	p, _ := base(fid, bid)
	b, _ := json.Marshal(m)
	done, _ := json.Marshal(marker{ManifestSHA: digest(b), VerifiedAt: time.Now().UTC().Format(time.RFC3339Nano)})
	if err = s.atomic(p+"/verified.json", done); err != nil {
		return Status{}, err
	}
	return s.status(m)
}
func (s *Store) Check(fid, bid string) (Status, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, err := s.manifest(fid, bid)
	if err != nil {
		return Status{}, err
	}
	if err = s.verify(m, false); err != nil {
		p, _ := base(fid, bid)
		_ = s.root.Remove(p + "/verified.json")
		return Status{}, err
	}
	return s.status(m)
}
func (s *Store) status(m Manifest) (Status, error) {
	st := Status{FamilyID: m.FamilyID, BackupID: m.BackupID, State: "uploading", Scope: "declared_public_files", Issues: []string{}, Entries: []EntryStatus{}}
	p, _ := base(m.FamilyID, m.BackupID)
	var done marker
	b, er := s.root.ReadFile(p + "/verified.json")
	if er == nil {
		if json.Unmarshal(b, &done) != nil {
			return st, errors.New("bad marker")
		}
		mb, _ := json.Marshal(m)
		if digest(mb) != done.ManifestSHA {
			return st, errors.New("manifest changed")
		}
		st.VerifiedAt = done.VerifiedAt
		st.State = "verified"
		st.Complete = true
	} else if !errors.Is(er, os.ErrNotExist) {
		return st, er
	}
	for _, e := range m.Entries {
		es := EntryStatus{ID: e.ID, Kind: e.Kind, Label: e.Label, Size: e.Size, Missing: e.Missing}
		if e.Missing != "" {
			st.Issues = append(st.Issues, e.ID+":"+e.Missing)
			st.Complete = false
		} else if _, err := s.root.Stat(p + "/entries/" + e.ID + ".blob"); err == nil {
			info, statErr := s.root.Lstat(p + "/entries/" + e.ID + ".blob")
			if statErr != nil || !info.Mode().IsRegular() || info.Size() != e.Size {
				return st, errors.New("verified file changed")
			}
			es.Offset = e.Size
		} else {
			if st.VerifiedAt != "" {
				return st, errors.New("verified file missing")
			}
			_, offset, err := s.reconcile(p+"/entries/"+e.ID, e)
			if err != nil {
				return st, err
			}
			es.Offset = offset
		}
		if e.Kind == "sealed" {
			st.Scope = "opaque_restricted_unverified"
			st.Issues = append(st.Issues, "restricted_archive_requires_key_holder_verification")
			st.Complete = false
		}
		if (e.Kind == "photo" || e.Kind == "video") && !e.SourceExact && e.Missing == "" {
			st.Issues = append(st.Issues, e.ID+":original_provenance_unverified")
			st.Complete = false
		}
		st.Entries = append(st.Entries, es)
	}
	if st.VerifiedAt != "" && !st.Complete {
		st.State = "incomplete"
	}
	return st, nil
}
func (s *Store) Status(fid, bid string) (Status, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, err := s.manifest(fid, bid)
	if err != nil {
		return Status{}, err
	}
	return s.status(m)
}
func (s *Store) List() ([]Status, error) { return s.ListFamily("") }
func (s *Store) ListFamily(family string) (out []Status, err error) {
	if family != "" && !ValidID(family) {
		return nil, errors.New("invalid family")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	out = []Status{}
	root, err := s.root.Open("backups")
	if err != nil {
		return nil, err
	}
	families, err := root.ReadDir(-1)
	root.Close()
	if err != nil {
		return nil, err
	}
	for _, fam := range families {
		if !fam.IsDir() || !ValidID(fam.Name()) || (family != "" && family != fam.Name()) {
			continue
		}
		f, e := s.root.Open("backups/" + fam.Name())
		if e != nil {
			return nil, e
		}
		dirs, e := f.ReadDir(-1)
		f.Close()
		if e != nil {
			return nil, e
		}
		for _, d := range dirs {
			if !d.IsDir() || !ValidID(d.Name()) {
				continue
			}
			m, e := s.manifest(fam.Name(), d.Name())
			if e != nil {
				out = append(out, Status{FamilyID: fam.Name(), BackupID: d.Name(), State: "unreadable", Issues: []string{"manifest_unreadable"}, Entries: []EntryStatus{}})
				continue
			}
			st, e := s.status(m)
			if e != nil {
				out = append(out, Status{FamilyID: fam.Name(), BackupID: d.Name(), State: "unreadable", Issues: []string{"data_unreadable"}, Entries: []EntryStatus{}})
				continue
			}
			out = append(out, st)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		return fmt.Sprint(out[i].FamilyID, out[i].BackupID) < fmt.Sprint(out[j].FamilyID, out[j].BackupID)
	})
	return out, nil
}

// OpenVerified 只读且不支持电脑反向覆盖。restricted 仅允许设备恢复接口拿密文。
func (s *Store) OpenVerified(fid, bid, eid string, allowRestricted bool) (*os.File, Entry, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, err := s.manifest(fid, bid)
	if err != nil {
		return nil, Entry{}, err
	}
	e, err := entry(m, eid)
	if err != nil {
		return nil, e, err
	}
	if e.Kind == "sealed" && !allowRestricted {
		return nil, e, os.ErrPermission
	}
	if e.Missing != "" {
		return nil, e, os.ErrNotExist
	}
	p, _ := base(fid, bid)
	raw, err := s.root.ReadFile(p + "/verified.json")
	if err != nil {
		return nil, e, ErrIncomplete
	}
	var mark marker
	mb, _ := json.Marshal(m)
	if json.Unmarshal(raw, &mark) != nil || mark.ManifestSHA != digest(mb) || mark.VerifiedAt == "" {
		return nil, e, errors.New("invalid verified marker")
	}
	f, err := s.regular(p + "/entries/" + eid + ".blob")
	if err != nil {
		return nil, e, err
	}
	info, err := f.Stat()
	if err != nil || info.Size() != e.Size {
		f.Close()
		return nil, e, errors.New("verified size changed")
	}
	return f, e, nil
}
