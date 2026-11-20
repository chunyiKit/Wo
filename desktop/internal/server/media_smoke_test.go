package server_test

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"github.com/chunyiKit/Wo/desktop/internal/backup"
	"github.com/chunyiKit/Wo/desktop/internal/portable"
	"github.com/chunyiKit/Wo/desktop/internal/vault"
	"io"
	"os"
	"path/filepath"
	"testing"
)

func fixtures(t *testing.T) (string, backup.Manifest) {
	t.Helper()
	dir := os.Getenv("WO_SYNTHETIC_FIXTURE_DIR")
	if dir == "" {
		t.Skip("optional independently generated GPS/HDR fixture not supplied")
	}
	evidence, err := os.ReadFile(filepath.Join(dir, "source-evidence.json"))
	if err != nil {
		t.Fatal(err)
	}
	var marker struct {
		Fixture string `json:"fixture"`
		User    bool   `json:"contains_user_data"`
		Before  bool   `json:"sha_recorded_before_app_upload"`
	}
	if json.Unmarshal(evidence, &marker) != nil || marker.Fixture != "wo-generated-synthetic-media-v1" || marker.User || !marker.Before {
		t.Fatal("not the generated synthetic fixture")
	}
	raw, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var m backup.Manifest
	if json.Unmarshal(raw, &m) != nil || backup.Validate(m) != nil || m.FamilyID != "synthetic-family" {
		t.Fatal("fixture manifest invalid")
	}
	return dir, m
}
func fileHash(t *testing.T, path string) string {
	t.Helper()
	f, e := os.Open(path)
	if e != nil {
		t.Fatal(e)
	}
	defer f.Close()
	h := sha256.New()
	if _, e = io.Copy(h, f); e != nil {
		t.Fatal(e)
	}
	return hex.EncodeToString(h.Sum(nil))
}
func TestSyntheticGPSAndHDRSourceToTLSBackupRestore(t *testing.T) {
	dir, m := fixtures(t)
	e := setup(t)
	c := pair(t, e, m.FamilyID, "synthetic-phone")
	for _, entry := range m.Entries {
		if fileHash(t, filepath.Join(dir, entry.ID+".bin")) != entry.SHA256 {
			t.Fatal("pre-upload independent source mismatch")
		}
	}
	st, er := c.Upload(context.Background(), m, func(id string) (*os.File, error) { return os.Open(filepath.Join(dir, id+".bin")) })
	if er != nil || !st.Complete {
		t.Fatal(st, er)
	}
	dst, _ := backup.New(t.TempDir())
	defer dst.Close()
	st, er = c.Fetch(context.Background(), m, dst)
	if er != nil || !st.Complete {
		t.Fatal(st, er)
	}
	for _, entry := range m.Entries {
		f, _, er := dst.OpenVerified(m.FamilyID, m.BackupID, entry.ID, false)
		if er != nil {
			t.Fatal(er)
		}
		h := sha256.New()
		io.Copy(h, f)
		f.Close()
		if hex.EncodeToString(h.Sum(nil)) != entry.SHA256 {
			t.Fatal("restored SHA differs", entry.ID)
		}
		t.Logf("independent_source_equals_computer_equals_restore id=%s bytes=%d sha256=%s", entry.ID, entry.Size, entry.SHA256)
	}
}
func TestSyntheticRestrictedOriginalsRestoreAndRebackup(t *testing.T) {
	dir, m := fixtures(t)
	e := setup(t)
	c := pair(t, e, m.FamilyID, "synthetic-phone")
	inner := portable.Manifest{Version: 1, FamilyID: m.FamilyID, Entries: []portable.Entry{}}
	for _, entry := range m.Entries {
		inner.Entries = append(inner.Entries, portable.Entry{ID: entry.ID, Kind: portable.Kind(entry.Kind), Size: entry.Size, SHA256: entry.SHA256, SourceExact: entry.SourceExact})
	}
	record := []byte(`{"device_id":"old-device","uri":"content://synthetic-old-media","visibility":"couple","title":"synthetic-private-title-do-not-display"}`)
	recordPath := filepath.Join(t.TempDir(), "record")
	os.WriteFile(recordPath, record, 0600)
	inner.Entries = append(inner.Entries, portable.Entry{ID: "records", Kind: portable.Records, Size: int64(len(record)), SHA256: sh(record)})
	key := make([]byte, 32)
	rand.Read(key)
	defer clear(key)
	ctx := vault.Context{Family: m.FamilyID, Backup: "restricted-media", Entry: "opaque"}
	sealedPath := filepath.Join(t.TempDir(), "opaque.bin")
	sealed, er := os.OpenFile(sealedPath, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0600)
	if er != nil {
		t.Fatal(er)
	}
	pr, pw := io.Pipe()
	packErr := make(chan error, 1)
	go func() {
		er := portable.Pack(context.Background(), pw, inner, func(id string) (io.ReadCloser, error) {
			if id == "records" {
				return os.Open(recordPath)
			}
			return os.Open(filepath.Join(dir, id+".bin"))
		})
		pw.CloseWithError(er)
		packErr <- er
	}()
	_, er = vault.Encrypt(sealed, pr, key, ctx, vault.Limits{})
	pr.CloseWithError(er)
	pe := <-packErr
	sealed.Sync()
	sealed.Close()
	if er != nil || pe != nil {
		t.Fatal(er, pe)
	}
	info, _ := os.Stat(sealedPath)
	outer := backup.Manifest{Version: 1, FamilyID: m.FamilyID, BackupID: ctx.Backup, Entries: []backup.Entry{{ID: ctx.Entry, Kind: "sealed", Size: info.Size(), SHA256: fileHash(t, sealedPath)}}}
	st, er := c.Upload(context.Background(), outer, func(string) (*os.File, error) { return os.Open(sealedPath) })
	if er != nil || st.Complete || len(st.Entries) != 1 || st.Entries[0].Label != "" {
		t.Fatal(st, er)
	}
	_, body := request(t, e, "GET", "/admin/backups", nil, "")
	if bytes.Contains(body, []byte("synthetic-private-title")) || bytes.Contains(body, []byte("photo")) {
		t.Fatal("restricted contents/entry list leaked")
	}
	dst, _ := backup.New(t.TempDir())
	defer dst.Close()
	if _, er = c.Fetch(context.Background(), outer, dst); er != nil {
		t.Fatal(er)
	}
	cipher, _, er := dst.OpenVerified(m.FamilyID, ctx.Backup, ctx.Entry, true)
	if er != nil {
		t.Fatal(er)
	}
	defer cipher.Close()
	private := t.TempDir()
	root, _ := os.OpenRoot(private)
	defer root.Close()
	if _, er = vault.RestoreFile(root, "verified.wotar", cipher, key, ctx, vault.Limits{}); er != nil {
		t.Fatal(er)
	}
	tar, er := root.Open("verified.wotar")
	if er != nil {
		t.Fatal(er)
	}
	defer tar.Close()
	result, er := portable.Restore(context.Background(), tar, portable.RestoreOptions{ExpectedFamilyID: m.FamilyID, Destination: filepath.Join(t.TempDir(), "new-device"), RequirePrivateACL: true})
	if er != nil || !result.Complete || result.RecordsApplied || result.NewFamilyID == m.FamilyID || result.NewDeviceID == "old-device" {
		t.Fatal(result, er)
	}
	again := portable.Manifest{Version: 1, FamilyID: result.NewFamilyID, Entries: []portable.Entry{}}
	paths := map[string]string{}
	for id, file := range result.Files {
		if fileHash(t, file.Path) != file.SHA256 || file.NewID == id {
			t.Fatal("new reference/source digest mismatch", id)
		}
		again.Entries = append(again.Entries, portable.Entry{ID: file.NewID, Kind: file.Kind, Size: file.Size, SHA256: file.SHA256, SourceExact: file.SourceExact})
		paths[file.NewID] = file.Path
	}
	var repacked bytes.Buffer
	if er = portable.Pack(context.Background(), &repacked, again, func(id string) (io.ReadCloser, error) { return os.Open(paths[id]) }); er != nil {
		t.Fatal(er)
	}
	second, er := portable.Restore(context.Background(), bytes.NewReader(repacked.Bytes()), portable.RestoreOptions{ExpectedFamilyID: result.NewFamilyID, Destination: filepath.Join(t.TempDir(), "second-new-device"), RequirePrivateACL: true})
	if er != nil || !second.Complete || second.RecordsApplied {
		t.Fatal(second, er)
	}
	for id, file := range second.Files {
		if fileHash(t, file.Path) != result.Files[findSourceID(result.Files, id)].SHA256 {
			t.Fatal("rebackup digest changed")
		}
	}
	t.Logf("restricted media authenticated/restored/rebacked up; original files=%d; records_applied=false; no old device/URI applied", len(result.Files))
}
func findSourceID(files map[string]portable.RestoredFile, newID string) string {
	for id, f := range files {
		if f.NewID == newID {
			return id
		}
	}
	return ""
}
