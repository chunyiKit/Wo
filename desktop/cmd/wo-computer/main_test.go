package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http/cookiejar"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/chunyiKit/Wo/desktop/internal/backup"
	"github.com/chunyiKit/Wo/desktop/internal/portable"
	"github.com/chunyiKit/Wo/desktop/internal/server"
)

func writeTest(t *testing.T, path string, data []byte) {
	t.Helper()
	if e := os.WriteFile(path, data, 0600); e != nil {
		t.Fatal(e)
	}
}
func jsonTest(t *testing.T, path string, value any) {
	t.Helper()
	raw, e := json.Marshal(value)
	if e != nil {
		t.Fatal(e)
	}
	writeTest(t, path, raw)
}
func invoke(t *testing.T, args ...string) ([]byte, error) {
	t.Helper()
	var out, errOut bytes.Buffer
	e := run(context.Background(), args, &out, &errOut)
	return out.Bytes(), e
}
func digestTest(data []byte) string { sum := sha256.Sum256(data); return hex.EncodeToString(sum[:]) }
func fixture(t *testing.T) (string, string, portable.Manifest, []byte) {
	t.Helper()
	dir := t.TempDir()
	if e := os.Chmod(dir, 0700); e != nil {
		t.Fatal(e)
	}
	files := filepath.Join(dir, "sources")
	if e := os.Mkdir(files, 0700); e != nil {
		t.Fatal(e)
	}
	data := bytes.Repeat([]byte("synthetic-original-with-exif-placeholder\x00"), 6000)
	writeTest(t, filepath.Join(files, "image.bin"), data)
	records := []byte(`{"synthetic":true,"old_uri":"not-applied"}`)
	writeTest(t, filepath.Join(files, "records.bin"), records)
	m := portable.Manifest{Version: 1, FamilyID: "family", Entries: []portable.Entry{
		{ID: "records", Kind: portable.Records, Size: int64(len(records)), SHA256: digestTest(records)},
		{ID: "image", Kind: portable.Photo, Size: int64(len(data)), SHA256: digestTest(data), SourceExact: true},
		{ID: "missing-video", Kind: portable.Video, MissingReason: portable.SourceUnavailable},
	}}
	manifest := filepath.Join(dir, "manifest.json")
	jsonTest(t, manifest, m)
	return dir, manifest, m, data
}
func TestFlagsRejectWithoutSideEffects(t *testing.T) {
	for _, args := range [][]string{nil, {"bad-command"}, {"serve", "--unknown"}, {"pair"}, {"pair", "--token", "secret"}, {"pack-public", "unexpected"}, {"restore-sealed", "--file", "one"}} {
		if _, e := invoke(t, args...); e == nil {
			t.Fatalf("accepted %q", args)
		}
	}
}
func TestSafePathsRejectGitSymlinksAndRoot(t *testing.T) {
	if _, e := safePath(string(filepath.Separator)); e == nil {
		t.Fatal("accepted root")
	}
	dir := t.TempDir()
	repo := filepath.Join(dir, "repo")
	if e := os.Mkdir(repo, 0700); e != nil {
		t.Fatal(e)
	}
	writeTest(t, filepath.Join(repo, ".git"), []byte("gitdir: elsewhere"))
	if _, e := safeDir(filepath.Join(repo, "data"), true, true); e == nil {
		t.Fatal("accepted Git ancestor")
	}
	if _, e := os.Stat(filepath.Join(repo, "data")); !errors.Is(e, os.ErrNotExist) {
		t.Fatal("created refused data")
	}
	if runtime.GOOS != "windows" {
		real := filepath.Join(dir, "real")
		if e := os.Mkdir(real, 0700); e != nil {
			t.Fatal(e)
		}
		link := filepath.Join(dir, "link")
		if e := os.Symlink(real, link); e != nil {
			t.Fatal(e)
		}
		if _, e := safeDir(link, true, true); e == nil {
			t.Fatal("accepted root symlink")
		}
		if _, e := safePath(filepath.Join(link, "child")); e == nil {
			t.Fatal("accepted ancestor symlink")
		}
		writeTest(t, filepath.Join(real, "source.bin"), []byte("outside"))
		if e := os.Symlink(filepath.Join(real, "source.bin"), filepath.Join(real, "alias.bin")); e != nil {
			t.Fatal(e)
		}
		root, e := os.OpenRoot(real)
		if e != nil {
			t.Fatal(e)
		}
		defer root.Close()
		if f, e := openSource(root, "alias"); e == nil {
			f.Close()
			t.Fatal("accepted source symlink")
		}
	}
}
func TestSealedRoundTripWrongKeyFamilyAndNoOverwrite(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("native Windows private ACL intentionally unavailable")
	}
	dir, manifest, _, original := fixture(t)
	keyFile := filepath.Join(dir, "key")
	writeTest(t, keyFile, bytes.Repeat([]byte{17}, 32))
	archive := filepath.Join(dir, "restricted.woseal")
	pack := []string{"pack-sealed", "--manifest", manifest, "--files", filepath.Join(dir, "sources"), "--key-file", keyFile, "--backup", "backup", "--entry", "sealed", "--out", archive}
	out, e := invoke(t, pack...)
	if e != nil {
		t.Fatal(e)
	}
	var summary map[string]any
	if e = json.Unmarshal(out, &summary); e != nil {
		t.Fatal(e)
	}
	cipher, e := os.ReadFile(archive)
	if e != nil {
		t.Fatal(e)
	}
	if len(summary) != 2 || summary["sha256"] != digestTest(cipher) || summary["size"] != float64(len(cipher)) {
		t.Fatal("not ciphertext-only summary", summary)
	}
	if bytes.Contains(cipher, original[:80]) {
		t.Fatal("plaintext appears in sealed archive")
	}
	if _, e = invoke(t, pack...); e == nil {
		t.Fatal("overwrote archive")
	}
	unchanged, _ := os.ReadFile(archive)
	if !bytes.Equal(cipher, unchanged) {
		t.Fatal("existing archive changed")
	}
	// Wrong key and context never publish a directory or leave our staging behind.
	wrong := filepath.Join(dir, "wrong-key")
	writeTest(t, wrong, bytes.Repeat([]byte{18}, 32))
	restore := func(key, family, bid, dest string) ([]byte, error) {
		return invoke(t, "restore-sealed", "--file", archive, "--key-file", key, "--family", family, "--backup", bid, "--entry", "sealed", "--out", dest)
	}
	for i, trial := range [][3]string{{wrong, "family", "backup"}, {keyFile, "other", "backup"}, {keyFile, "family", "wrong-backup"}} {
		dest := filepath.Join(dir, "failed-"+string(rune('a'+i)))
		if _, e = restore(trial[0], trial[1], trial[2], dest); e == nil {
			t.Fatal("accepted wrong key/context")
		}
		if _, e = os.Stat(dest); !errors.Is(e, os.ErrNotExist) {
			t.Fatal("failed restore published output")
		}
	}
	dest := filepath.Join(dir, "restored")
	out, e = restore(keyFile, "family", "backup", dest)
	if e != nil {
		t.Fatal(e)
	}
	var result portable.Result
	if e = json.Unmarshal(out, &result); e != nil {
		t.Fatal(e)
	}
	if result.RecordsApplied || result.Complete || result.Missing["missing-video"] != portable.SourceUnavailable {
		t.Fatal("misstated inert/incomplete restore", result)
	}
	if result.NewFamilyID == "family" || result.NewDeviceID == "" {
		t.Fatal("old identity reused")
	}
	saved, e := os.ReadFile(result.Files["image"].Path)
	if e != nil || !bytes.Equal(saved, original) {
		t.Fatal("original digest mismatch", e)
	}
	if _, e = restore(keyFile, "family", "backup", dest); e == nil {
		t.Fatal("overwrote restored directory")
	}
	// Corruption also leaves no destination.
	cipher[len(cipher)/2] ^= 1
	damaged := filepath.Join(dir, "damaged.woseal")
	writeTest(t, damaged, cipher)
	badOut := filepath.Join(dir, "damaged-output")
	if _, e = invoke(t, "restore-sealed", "--file", damaged, "--key-file", keyFile, "--family", "family", "--backup", "backup", "--entry", "sealed", "--out", badOut); e == nil {
		t.Fatal("accepted corruption")
	}
	if _, e = os.Stat(badOut); !errors.Is(e, os.ErrNotExist) {
		t.Fatal("corrupt archive published output")
	}
	stages, e := filepath.Glob(filepath.Join(dir, ".wo-private-*"))
	if e != nil || len(stages) != 0 {
		t.Fatal("temporary plaintext stage remains", stages, e)
	}
}
func TestPublicPackRestoreAndFailedPackCleanup(t *testing.T) {
	dir, manifest, m, original := fixture(t)
	archive := filepath.Join(dir, "public.wotar")
	if _, e := invoke(t, "pack-public", "--manifest", manifest, "--files", filepath.Join(dir, "sources"), "--out", archive); e != nil {
		t.Fatal(e)
	}
	out, e := invoke(t, "restore-public", "--file", archive, "--family", "family", "--out", filepath.Join(dir, "restored"))
	if e != nil {
		t.Fatal(e)
	}
	var result portable.Result
	if e = json.Unmarshal(out, &result); e != nil {
		t.Fatal(e)
	}
	saved, e := os.ReadFile(result.Files["image"].Path)
	if e != nil || !bytes.Equal(saved, original) {
		t.Fatal("public original mismatch", e)
	}
	m.Entries[1].SHA256 = strings.Repeat("0", 64)
	jsonTest(t, manifest, m)
	failed := filepath.Join(dir, "failed.wotar")
	if _, e = invoke(t, "pack-public", "--manifest", manifest, "--files", filepath.Join(dir, "sources"), "--out", failed); e == nil {
		t.Fatal("accepted changed source")
	}
	if _, e = os.Stat(failed); !errors.Is(e, os.ErrNotExist) {
		t.Fatal("failed own output remains")
	}
	if _, e = invoke(t, "pack-public", "--manifest", manifest, "--files", filepath.Join(dir, "sources"), "--out", filepath.Join(dir, "wrong-extension")); e == nil {
		t.Fatal("accepted suffix")
	}
}
func TestServeLockStartupAndGracefulShutdown(t *testing.T) {
	dir := t.TempDir()
	if e := os.Chmod(dir, 0700); e != nil {
		t.Fatal(e)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	read, write := io.Pipe()
	defer read.Close()
	done := make(chan error, 1)
	go func() {
		e := serve(ctx, []string{"--data", dir, "--listen", "127.0.0.1:0"}, write, io.Discard)
		write.Close()
		done <- e
	}()
	var startup map[string]string
	if e := json.NewDecoder(read).Decode(&startup); e != nil {
		t.Fatal(e, <-done)
	}
	if startup["event"] != "listening" || !strings.HasPrefix(startup["url"], "https://127.0.0.1:") || len(startup["pin"]) != 64 || len(startup["admin_code"]) != 64 {
		t.Fatal(startup)
	}
	if e := serve(ctx, []string{"--data", dir, "--listen", "127.0.0.1:0"}, io.Discard, io.Discard); e == nil {
		t.Fatal("second serve acquired lock")
	}
	cancel()
	select {
	case e := <-done:
		if e != nil {
			t.Fatal(e)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("shutdown timeout")
	}
	if _, e := os.Stat(filepath.Join(dir, ".state", "serve.lock")); !errors.Is(e, os.ErrNotExist) {
		t.Fatal("own lock remains", e)
	}
	if e := os.Mkdir(filepath.Join(dir, ".state", "serve.lock"), 0700); e != nil {
		t.Fatal(e)
	}
	if e := serve(context.Background(), []string{"--data", dir}, io.Discard, io.Discard); e == nil {
		t.Fatal("deleted stale lock")
	}
	if _, e := os.Stat(filepath.Join(dir, ".state", "serve.lock")); e != nil {
		t.Fatal("stale lock removed")
	}
}
func TestKeyFilesAndCredentialPermissions(t *testing.T) {
	dir := t.TempDir()
	hexKey := filepath.Join(dir, "hex-key")
	writeTest(t, hexKey, []byte(strings.Repeat("ab", 32)+"\n"))
	key, e := loadKey(hexKey)
	if e != nil || len(key) != 32 || key[0] != 0xab {
		t.Fatal("hex key", e)
	}
	clear(key)
	writeTest(t, hexKey, []byte("invalid"))
	if _, e = loadKey(hexKey); e == nil {
		t.Fatal("accepted invalid key")
	}
	if runtime.GOOS != "windows" {
		writeTest(t, hexKey, bytes.Repeat([]byte{7}, 32))
		if e = os.Chmod(hexKey, 0644); e != nil {
			t.Fatal(e)
		}
		if _, e = loadKey(hexKey); e == nil {
			t.Fatal("accepted world-readable key")
		}
	}
}
func TestPairUploadFetchWithTLSAndNewCredentialFile(t *testing.T) {
	dir := t.TempDir()
	store, e := backup.New(filepath.Join(dir, "server"))
	if e != nil {
		t.Fatal(e)
	}
	defer store.Close()
	secret := server.NewAdminSecret()
	handler, e := server.New(store, secret, filepath.Join(dir, "devices.json"))
	if e != nil {
		t.Fatal(e)
	}
	cert, pin, e := server.Certificate(filepath.Join(dir, "tls"))
	if e != nil {
		t.Fatal(e)
	}
	srv := httptest.NewUnstartedServer(handler)
	srv.TLS = &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{cert}}
	srv.StartTLS()
	defer srv.Close()
	jar, _ := cookiejar.New(nil)
	admin := srv.Client()
	admin.Jar = jar
	post := func(path string, value any) map[string]any {
		t.Helper()
		raw, _ := json.Marshal(value)
		res, e := admin.Post(srv.URL+path, "application/json", bytes.NewReader(raw))
		if e != nil {
			t.Fatal(e)
		}
		defer res.Body.Close()
		if res.StatusCode < 200 || res.StatusCode > 299 {
			t.Fatal("admin", res.StatusCode)
		}
		var out map[string]any
		if e = json.NewDecoder(res.Body).Decode(&out); e != nil {
			t.Fatal(e)
		}
		return out
	}
	post("/admin/session", map[string]string{"secret": secret})
	invite := post("/admin/pair", map[string]string{"family": "family"})
	pairingPath := filepath.Join(dir, "pair.json")
	jsonTest(t, pairingPath, pairing{srv.URL, pin, invite["code"].(string), "family", "phone"})
	conn := filepath.Join(dir, "connection.json")
	writeTest(t, conn, []byte("existing"))
	if _, e = invoke(t, "pair", "--pairing-file", pairingPath, "--out", conn); e == nil {
		t.Fatal("overwrote credential")
	}
	if e = os.Remove(conn); e != nil {
		t.Fatal(e)
	}
	out, e := invoke(t, "pair", "--pairing-file", pairingPath, "--out", conn)
	if e != nil {
		t.Fatal(e)
	}
	var c connection
	if e = readJSON(conn, true, &c); e != nil {
		t.Fatal(e)
	}
	if !validSecret(c.Token) || bytes.Contains(out, []byte(c.Token)) || bytes.Contains(out, []byte(invite["code"].(string))) {
		t.Fatal("credential printed or invalid")
	}
	files := filepath.Join(dir, "files")
	if e = os.Mkdir(files, 0700); e != nil {
		t.Fatal(e)
	}
	payload := bytes.Repeat([]byte("synthetic"), 1000)
	writeTest(t, filepath.Join(files, "records.bin"), payload)
	m := backup.Manifest{Version: 1, FamilyID: "family", BackupID: "snapshot", Entries: []backup.Entry{{ID: "records", Kind: "records", Size: int64(len(payload)), SHA256: digestTest(payload)}}}
	manifest := filepath.Join(dir, "backup.json")
	jsonTest(t, manifest, m)
	for i := 0; i < 2; i++ {
		if _, e = invoke(t, "upload", "--connection", conn, "--manifest", manifest, "--files", files); e != nil {
			t.Fatal("upload", e)
		}
		if _, e = invoke(t, "fetch", "--connection", conn, "--backup", "snapshot", "--cache", filepath.Join(dir, "cache")); e != nil {
			t.Fatal("fetch", e)
		}
	}
	cache, e := backup.New(filepath.Join(dir, "cache"))
	if e != nil {
		t.Fatal(e)
	}
	defer cache.Close()
	f, _, e := cache.OpenVerified("family", "snapshot", "records", false)
	if e != nil {
		t.Fatal(e)
	}
	defer f.Close()
	received, e := io.ReadAll(f)
	if e != nil || !bytes.Equal(received, payload) {
		t.Fatal("fetched bytes", e)
	}
	c.Family = "other"
	jsonTest(t, conn, c)
	if _, e = invoke(t, "fetch", "--connection", conn, "--backup", "snapshot", "--cache", filepath.Join(dir, "wrong-family")); e == nil {
		t.Fatal("accepted connection family mismatch")
	}
	if _, e = os.Stat(filepath.Join(dir, "wrong-family")); !errors.Is(e, os.ErrNotExist) {
		t.Fatal("family check wrote cache")
	}
}

func TestDefaultDataAvoidsSyncedDirectories(t *testing.T) {
	base := t.TempDir()
	for _, platform := range []string{"darwin", "windows", "linux"} {
		path, e := platformDataPath(platform, base, filepath.Join(base, "config"), filepath.Join(base, "LocalAppData"))
		if e != nil || !strings.HasSuffix(path, filepath.Join("Wo", "Backups")) {
			t.Fatal(platform, path, e)
		}
		if _, e = platformDataPath(platform, filepath.Join(base, "Documents"), filepath.Join(base, "OneDrive", "config"), filepath.Join(base, "Desktop", "LocalAppData")); e == nil {
			t.Fatal("accepted synced default", platform)
		}
	}
}
