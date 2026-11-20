package backup

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"github.com/chunyiKit/Wo/desktop/internal/vault"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func setup(t *testing.T) (*Store, string) {
	t.Helper()
	dir := t.TempDir()
	s, e := New(dir)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { s.Close() })
	return s, dir
}
func sample(data []byte) Manifest {
	return Manifest{Version: 1, FamilyID: "family-a", BackupID: "backup-a", Entries: []Entry{{ID: "original", Kind: "photo", Size: int64(len(data)), SHA256: digest(data), SourceExact: true}}}
}
func appendAll(t *testing.T, s *Store, m Manifest, data []byte) {
	t.Helper()
	for off := int64(0); off < int64(len(data)); {
		end := min(off+ChunkSize, int64(len(data)))
		n, e := s.Append(m.FamilyID, m.BackupID, m.Entries[0].ID, off, end-off, digest(data[off:end]), bytes.NewReader(data[off:end]))
		if e != nil {
			t.Fatal(e)
		}
		off = n
	}
}

type interrupted struct{ data []byte }

func (r *interrupted) Read(p []byte) (int, error) {
	if len(r.data) == 0 {
		return 0, io.ErrUnexpectedEOF
	}
	n := copy(p, r.data)
	r.data = r.data[n:]
	return n, nil
}
func TestResumeAfterDisconnectAndDuplicate(t *testing.T) {
	s, _ := setup(t)
	data := []byte("source-exif-GPS-original")
	m := sample(data)
	if e := s.Create(m); e != nil {
		t.Fatal(e)
	}
	if _, e := s.Append(m.FamilyID, m.BackupID, "original", 0, 8, digest(data[:8]), &interrupted{data[:3]}); e == nil {
		t.Fatal("interrupted accepted")
	}
	st, _ := s.Status(m.FamilyID, m.BackupID)
	if st.Entries[0].Offset != 0 {
		t.Fatal(st)
	}
	for i := 0; i < 2; i++ {
		n, e := s.Append(m.FamilyID, m.BackupID, "original", 0, 8, digest(data[:8]), bytes.NewReader(data[:8]))
		if e != nil || n != 8 {
			t.Fatal(n, e)
		}
	}
	if _, e := s.Append(m.FamilyID, m.BackupID, "original", 1, 3, digest(data[1:4]), bytes.NewReader(data[1:4])); !errors.Is(e, ErrConflict) {
		t.Fatal(e)
	}
	if _, e := s.Append(m.FamilyID, m.BackupID, "original", 8, int64(len(data)-8), digest(data[8:]), bytes.NewReader(data[8:])); e != nil {
		t.Fatal(e)
	}
	done, e := s.Finalize(m.FamilyID, m.BackupID)
	if e != nil || !done.Complete {
		t.Fatal(done, e)
	}
	f, en, e := s.OpenVerified(m.FamilyID, m.BackupID, "original", false)
	if e != nil {
		t.Fatal(e)
	}
	defer f.Close()
	got, _ := io.ReadAll(f)
	if !bytes.Equal(got, data) || en.SHA256 != digest(data) {
		t.Fatal("source changed")
	}
}
func TestBadChunkAndFinalHashRefuse(t *testing.T) {
	s, _ := setup(t)
	data := []byte("correct")
	m := sample(data)
	s.Create(m)
	for _, bad := range [][]byte{[]byte("bad"), append(append([]byte{}, data...), 0)} {
		if _, e := s.Append(m.FamilyID, m.BackupID, "original", 0, int64(len(data)), digest(data), bytes.NewReader(bad)); e == nil {
			t.Fatal("bad chunk")
		}
	}
	if _, e := s.Finalize(m.FamilyID, m.BackupID); !errors.Is(e, ErrIncomplete) {
		t.Fatal(e)
	}
	wrong := []byte("WRONG!!")
	s.Append(m.FamilyID, m.BackupID, "original", 0, int64(len(wrong)), digest(wrong), bytes.NewReader(wrong))
	if _, e := s.Finalize(m.FamilyID, m.BackupID); e == nil {
		t.Fatal("bad final hash")
	}
}
func TestRestartTruncatesUncommittedTail(t *testing.T) {
	s, dir := setup(t)
	data := []byte("0123456789")
	m := sample(data)
	s.Create(m)
	s.Append(m.FamilyID, m.BackupID, "original", 0, 5, digest(data[:5]), bytes.NewReader(data[:5]))
	s.Close()
	p := filepath.Join(dir, "backups/family-a/backup-a/entries/original.part")
	f, e := os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0600)
	if e != nil {
		t.Fatal(e)
	}
	f.Write([]byte("crash-tail"))
	f.Close()
	r, e := New(dir)
	if e != nil {
		t.Fatal(e)
	}
	defer r.Close()
	st, e := r.Status(m.FamilyID, m.BackupID)
	if e != nil || st.Entries[0].Offset != 5 {
		t.Fatal(st, e)
	}
	stat, _ := os.Stat(p)
	if stat.Size() != 5 {
		t.Fatal(stat.Size())
	}
}
func TestRestartRejectsCorruptedAcknowledgedChunk(t *testing.T) {
	s, dir := setup(t)
	data := []byte("0123456789")
	m := sample(data)
	s.Create(m)
	appendAll(t, s, m, data)
	s.Close()
	os.WriteFile(filepath.Join(dir, "backups/family-a/backup-a/entries/original.part"), []byte("X123456789"), 0600)
	r, e := New(dir)
	if e != nil {
		t.Fatal(e)
	}
	defer r.Close()
	if _, e = r.Status(m.FamilyID, m.BackupID); e == nil {
		t.Fatal("corrupt accepted")
	}
}
func TestDiskCorruptionInvalidatesVerifiedMarker(t *testing.T) {
	s, dir := setup(t)
	data := []byte("original")
	m := sample(data)
	s.Create(m)
	appendAll(t, s, m, data)
	s.Finalize(m.FamilyID, m.BackupID)
	os.WriteFile(filepath.Join(dir, "backups/family-a/backup-a/entries/original.blob"), []byte("corrupt!"), 0600)
	if _, e := s.Check(m.FamilyID, m.BackupID); e == nil {
		t.Fatal("corrupt verified")
	}
	if _, _, e := s.OpenVerified(m.FamilyID, m.BackupID, "original", false); !errors.Is(e, ErrIncomplete) {
		t.Fatal(e)
	}
}
func TestMissingAndUnprovenOriginalNeverComplete(t *testing.T) {
	s, _ := setup(t)
	m := Manifest{Version: 1, FamilyID: "family-a", BackupID: "missing", Entries: []Entry{{ID: "photo", Kind: "photo", Missing: "cloud_only"}, {ID: "thumb", Kind: "thumbnail", Size: 0, SHA256: digest(nil)}}}
	s.Create(m)
	st, e := s.Finalize(m.FamilyID, m.BackupID)
	if e != nil || st.Complete || st.State != "incomplete" {
		t.Fatal(st, e)
	}
	data := []byte("redacted source")
	m = sample(data)
	m.BackupID = "unproven"
	m.Entries[0].SourceExact = false
	s.Create(m)
	appendAll(t, s, m, data)
	st, e = s.Finalize(m.FamilyID, m.BackupID)
	if e != nil || st.Complete {
		t.Fatal(st, e)
	}
}
func TestOpaqueRestrictedNotDownloadableByBrowser(t *testing.T) {
	s, _ := setup(t)
	var cipher bytes.Buffer
	key := sha256.Sum256([]byte("synthetic unit key"))
	vault.Encrypt(&cipher, strings.NewReader("synthetic restricted bytes"), key[:], vault.Context{Family: "family-a", Backup: "backup-a", Entry: "opaque"}, vault.Limits{})
	data := cipher.Bytes()
	m := sample(data)
	m.Entries[0] = Entry{ID: "opaque", Kind: "sealed", Size: int64(len(data)), SHA256: digest(data)}
	s.Create(m)
	appendAll(t, s, m, data)
	st, e := s.Finalize(m.FamilyID, m.BackupID)
	if e != nil || st.Complete || st.Entries[0].Label != "" {
		t.Fatal(st, e)
	}
	if _, _, e := s.OpenVerified(m.FamilyID, m.BackupID, "opaque", false); !errors.Is(e, os.ErrPermission) {
		t.Fatal(e)
	}
	f, _, e := s.OpenVerified(m.FamilyID, m.BackupID, "opaque", true)
	if e != nil {
		t.Fatal(e)
	}
	f.Close()
	m.BackupID = "leak"
	m.Entries[0].Label = "private title"
	if e := s.Create(m); e == nil {
		t.Fatal("private metadata accepted")
	}
}
func TestManifestImmutableAndPathsRejected(t *testing.T) {
	s, _ := setup(t)
	m := sample([]byte("data"))
	if e := s.Create(m); e != nil {
		t.Fatal(e)
	}
	if e := s.Create(m); e != nil {
		t.Fatal(e)
	}
	m.Entries[0].SHA256 = strings.Repeat("0", 64)
	if e := s.Create(m); !errors.Is(e, ErrConflict) {
		t.Fatal(e)
	}
	for _, id := range []string{"../escape", "a/b", "", "a\\b", "中文"} {
		m = sample([]byte("data"))
		m.FamilyID = id
		if e := s.Create(m); e == nil {
			t.Fatal(id)
		}
	}
	m = sample([]byte("data"))
	m.Entries = append(m.Entries, m.Entries[0])
	if e := s.Create(m); e == nil {
		t.Fatal("duplicate")
	}
}
func TestSymbolicRootAndEntryRefused(t *testing.T) {
	s, dir := setup(t)
	m := sample([]byte("data"))
	s.Create(m)
	outside := filepath.Join(t.TempDir(), "untouched")
	os.WriteFile(outside, []byte("safe"), 0600)
	link := filepath.Join(dir, "backups/family-a/backup-a/entries/original.part")
	if e := os.Symlink(outside, link); e != nil {
		t.Skip(e)
	}
	if _, e := s.Append(m.FamilyID, m.BackupID, "original", 0, 4, digest([]byte("data")), strings.NewReader("data")); e == nil {
		t.Fatal("symlink accepted")
	}
	got, _ := os.ReadFile(outside)
	if string(got) != "safe" {
		t.Fatal("outside changed")
	}
	rl := filepath.Join(t.TempDir(), "link")
	os.Symlink(dir, rl)
	if _, e := New(rl); e == nil {
		t.Fatal("root symlink accepted")
	}
}
func TestConcurrentLostResponseRetryNoDuplicate(t *testing.T) {
	s, _ := setup(t)
	data := []byte("same chunk")
	m := sample(data)
	s.Create(m)
	var wg sync.WaitGroup
	errs := make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, e := s.Append(m.FamilyID, m.BackupID, "original", 0, int64(len(data)), digest(data), bytes.NewReader(data))
			errs <- e
		}()
	}
	wg.Wait()
	close(errs)
	for e := range errs {
		if e != nil {
			t.Fatal(e)
		}
	}
	st, _ := s.Status(m.FamilyID, m.BackupID)
	if st.Entries[0].Offset != int64(len(data)) {
		t.Fatal(st)
	}
}
func TestMultipleStreamingChunksMatchWholeSource(t *testing.T) {
	s, _ := setup(t)
	data := bytes.Repeat([]byte("synthetic-original-media"), 900000)
	m := sample(data)
	m.Entries[0].Kind = "video"
	s.Create(m)
	appendAll(t, s, m, data)
	st, e := s.Finalize(m.FamilyID, m.BackupID)
	if e != nil || !st.Complete {
		t.Fatal(st, e)
	}
	if _, e = s.Check(m.FamilyID, m.BackupID); e != nil {
		t.Fatal(e)
	}
}

func TestCanonicalManifestSizeBeforeWrite(t *testing.T) {
	s, dir := setup(t)
	m := sample(nil)
	m.BackupID = "expansion"
	m.Entries = nil
	for i := 0; i < 4096; i++ {
		m.Entries = append(m.Entries, Entry{ID: fmt.Sprint("e", i), Kind: "records", SHA256: digest(nil), Label: strings.Repeat("<", 240)})
	}
	if e := s.Create(m); e == nil {
		t.Fatal("escaped canonical JSON exceeded read limit")
	}
	if _, e := os.Stat(filepath.Join(dir, "backups/family-a/expansion")); !errors.Is(e, os.ErrNotExist) {
		t.Fatal("invalid manifest left directory", e)
	}
}
func TestCorruptForeignManifestDoesNotBreakFamilyList(t *testing.T) {
	s, dir := setup(t)
	m := sample([]byte("data"))
	s.Create(m)
	other := sample([]byte("other"))
	other.FamilyID = "foreign"
	s.Create(other)
	os.WriteFile(filepath.Join(dir, "backups/foreign/backup-a/manifest.json"), []byte("broken"), 0600)
	list, e := s.ListFamily("family-a")
	if e != nil || len(list) != 1 || list[0].FamilyID != "family-a" {
		t.Fatal(list, e)
	}
	all, e := s.List()
	if e != nil || len(all) != 2 {
		t.Fatal(all, e)
	}
}
func TestPartialBinaryJournalAfterCrash(t *testing.T) {
	s, dir := setup(t)
	data := []byte("source bytes")
	m := sample(data)
	s.Create(m)
	s.Append(m.FamilyID, m.BackupID, "original", 0, 6, digest(data[:6]), bytes.NewReader(data[:6]))
	s.Close()
	p := filepath.Join(dir, "backups/family-a/backup-a/entries/original.journal")
	f, e := os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0600)
	if e != nil {
		t.Fatal(e)
	}
	f.Write([]byte{1, 2, 3, 4, 5})
	f.Close()
	r, e := New(dir)
	if e != nil {
		t.Fatal(e)
	}
	defer r.Close()
	st, e := r.Status(m.FamilyID, m.BackupID)
	if e != nil || st.Entries[0].Offset != 6 {
		t.Fatal(st, e)
	}
	info, _ := os.Stat(p)
	if info.Size() != 48 {
		t.Fatal(info.Size())
	}
}

type slowReader struct {
	Started, Resume chan struct{}
	done            bool
}

func (r *slowReader) Read(p []byte) (int, error) {
	if r.done {
		return 0, io.EOF
	}
	r.done = true
	close(r.Started)
	<-r.Resume
	return copy(p, []byte("data")), nil
}
func TestSlowPhoneDoesNotBlockOtherFamilyStatus(t *testing.T) {
	s, _ := setup(t)
	m := sample([]byte("data"))
	s.Create(m)
	other := sample([]byte("other"))
	other.FamilyID = "foreign"
	s.Create(other)
	r := &slowReader{Started: make(chan struct{}), Resume: make(chan struct{})}
	done := make(chan error, 1)
	go func() {
		_, e := s.Append(m.FamilyID, m.BackupID, "original", 0, 4, digest([]byte("data")), r)
		done <- e
	}()
	<-r.Started
	status := make(chan error, 1)
	go func() { _, e := s.Status("foreign", "backup-a"); status <- e }()
	select {
	case e := <-status:
		if e != nil {
			t.Fatal(e)
		}
	case <-time.After(time.Second):
		close(r.Resume)
		t.Fatal("slow reader held global lock")
	}
	close(r.Resume)
	if e := <-done; e != nil {
		t.Fatal(e)
	}
}
func TestDownloadRefusesCorruptMarkerAndChangedLength(t *testing.T) {
	s, dir := setup(t)
	data := []byte("data")
	m := sample(data)
	s.Create(m)
	appendAll(t, s, m, data)
	s.Finalize(m.FamilyID, m.BackupID)
	base := filepath.Join(dir, "backups/family-a/backup-a")
	marker, _ := os.ReadFile(filepath.Join(base, "verified.json"))
	os.WriteFile(filepath.Join(base, "verified.json"), []byte("broken"), 0600)
	if f, _, e := s.OpenVerified(m.FamilyID, m.BackupID, "original", false); e == nil {
		f.Close()
		t.Fatal("corrupt marker allowed")
	}
	os.WriteFile(filepath.Join(base, "verified.json"), marker, 0600)
	os.WriteFile(filepath.Join(base, "entries/original.blob"), []byte("short"), 0600)
	if f, _, e := s.OpenVerified(m.FamilyID, m.BackupID, "original", false); e == nil {
		f.Close()
		t.Fatal("changed file length allowed")
	}
}

func TestDirectoryQuotaAndWindowsNames(t *testing.T) {
	s, _ := setup(t)
	for _, id := range []string{"CON", "com1", "AUX", "LPT9"} {
		m := sample([]byte("x"))
		m.Entries[0].ID = id
		if e := s.Create(m); e == nil {
			t.Fatal(id)
		}
	}
	m := sample([]byte("x"))
	m.Entries = append(m.Entries, Entry{ID: "ORIGINAL", Kind: "records", SHA256: digest(nil)})
	if e := s.Create(m); e == nil {
		t.Fatal("case collision")
	}
	large := Manifest{Version: 1, FamilyID: "family-a", BackupID: "reserved", Entries: []Entry{}}
	for i := 0; i < 16; i++ {
		large.Entries = append(large.Entries, Entry{ID: fmt.Sprint("e", i), Kind: "video", Size: MaxFileSize, SHA256: strings.Repeat("0", 64)})
	}
	if e := s.Create(large); e != nil {
		t.Fatal(e)
	}
	if e := s.Create(sample([]byte("x"))); e == nil {
		t.Fatal("directory reservation quota ignored")
	}
	if e := s.Create(large); e != nil {
		t.Fatal("existing retry blocked by quota", e)
	}
}
