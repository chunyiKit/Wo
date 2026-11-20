package server_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"github.com/chunyiKit/Wo/desktop/internal/backup"
	"github.com/chunyiKit/Wo/desktop/internal/client"
	"github.com/chunyiKit/Wo/desktop/internal/server"
	"github.com/chunyiKit/Wo/desktop/internal/vault"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
)

type env struct {
	s      *server.Server
	store  *backup.Store
	ts     *httptest.Server
	admin  *http.Client
	pin    string
	secret string
	root   string
}

func setup(t *testing.T) *env {
	t.Helper()
	root := t.TempDir()
	s, e := backup.New(root)
	if e != nil {
		t.Fatal(e)
	}
	secret := server.NewAdminSecret()
	handler, e := server.New(s, secret, filepath.Join(root, ".state/auth.json"))
	if e != nil {
		t.Fatal(e)
	}
	ts := httptest.NewTLSServer(handler)
	sum := sha256.Sum256(ts.Certificate().Raw)
	c := ts.Client()
	c.Jar, _ = cookiejar.New(nil)
	out := &env{handler, s, ts, c, hex.EncodeToString(sum[:]), secret, root}
	t.Cleanup(func() { ts.Close(); s.Close() })
	return out
}
func request(t *testing.T, e *env, method, path string, body any, token string) (int, []byte) {
	t.Helper()
	var r io.Reader
	if body != nil {
		b, er := json.Marshal(body)
		if er != nil {
			t.Fatal(er)
		}
		r = bytes.NewReader(b)
	}
	req, er := http.NewRequest(method, e.ts.URL+path, r)
	if er != nil {
		t.Fatal(er)
	}
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, er := e.admin.Do(req)
	if er != nil {
		t.Fatal(er)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	return res.StatusCode, b
}
func login(t *testing.T, e *env) {
	t.Helper()
	code, _ := request(t, e, "POST", "/admin/session", map[string]string{"secret": e.secret}, "")
	if code != 200 {
		t.Fatal(code)
	}
}
func pair(t *testing.T, e *env, family, device string) *client.Client {
	t.Helper()
	login(t, e)
	code, b := request(t, e, "POST", "/admin/pair", map[string]string{"family": family}, "")
	if code != 201 {
		t.Fatal(code, string(b))
	}
	var inv struct {
		Code string `json:"code"`
	}
	json.Unmarshal(b, &inv)
	c, er := client.New(e.ts.URL, e.pin, "")
	if er != nil {
		t.Fatal(er)
	}
	if _, er = c.Pair(context.Background(), inv.Code, family, device); er != nil {
		t.Fatal(er)
	}
	t.Cleanup(c.Close)
	return c
}
func sh(b []byte) string { x := sha256.Sum256(b); return hex.EncodeToString(x[:]) }
func TestTLSClientUploadAndRangeRestoreWholeSource(t *testing.T) {
	e := setup(t)
	c := pair(t, e, "family-a", "phone-a")
	source := bytes.Repeat([]byte("synthetic original bytes keep all metadata"), 600000)
	m := backup.Manifest{Version: 1, FamilyID: "family-a", BackupID: "backup-a", Entries: []backup.Entry{{ID: "video", Kind: "video", Size: int64(len(source)), SHA256: sh(source), SourceExact: true}}}
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "video.bin"), source, 0600)
	open := func(id string) (*os.File, error) { return os.Open(filepath.Join(dir, id+".bin")) }
	st, er := c.Upload(context.Background(), m, open)
	if er != nil || !st.Complete {
		t.Fatal(st, er)
	}
	dest, er := backup.New(t.TempDir())
	if er != nil {
		t.Fatal(er)
	}
	defer dest.Close()
	st, er = c.Fetch(context.Background(), m, dest)
	if er != nil || !st.Complete {
		t.Fatal(st, er)
	}
	f, entry, er := dest.OpenVerified("family-a", "backup-a", "video", false)
	if er != nil {
		t.Fatal(er)
	}
	got, _ := io.ReadAll(f)
	f.Close()
	if sh(got) != sh(source) || entry.SHA256 != sh(source) {
		t.Fatal("source/backup/restore differ")
	}
	st, er = c.Upload(context.Background(), m, open)
	if er != nil || !st.Complete {
		t.Fatal("idempotent upload", st, er)
	}
	st, er = c.Fetch(context.Background(), m, dest)
	if er != nil || !st.Complete {
		t.Fatal("idempotent fetch", st, er)
	}
}
func TestUnauthorizedCrossFamilyAndRevokedToken(t *testing.T) {
	e := setup(t)
	if code, _ := request(t, e, "GET", "/admin/backups", nil, ""); code != 401 {
		t.Fatal(code)
	}
	c := pair(t, e, "family-a", "phone-a")
	if code, _ := request(t, e, "POST", "/v1/backups", backup.Manifest{Version: 1, FamilyID: "family-b", BackupID: "other", Entries: []backup.Entry{{ID: "record", Kind: "records", SHA256: sh(nil)}}}, c.Token()); code != 403 {
		t.Fatal(code)
	}
	code, _ := request(t, e, "POST", "/admin/revoke", map[string]string{"family": "family-a", "device": "phone-a"}, "")
	if code != 200 {
		t.Fatal(code)
	}
	if code, _ = request(t, e, "GET", "/v1/backups", nil, c.Token()); code != 401 {
		t.Fatal(code)
	}
	b, er := os.ReadFile(filepath.Join(e.root, ".state/auth.json"))
	if er != nil || bytes.Contains(b, []byte(c.Token())) {
		t.Fatal("raw token persisted", er)
	}
}
func TestPairCodeScopeOneUseAndWrongPin(t *testing.T) {
	e := setup(t)
	login(t, e)
	_, b := request(t, e, "POST", "/admin/pair", map[string]string{"family": "family-a"}, "")
	var inv struct {
		Code string `json:"code"`
	}
	json.Unmarshal(b, &inv)
	body := map[string]string{"code": inv.Code, "family": "family-b", "device": "phone-a"}
	if code, _ := request(t, e, "POST", "/v1/pair", body, ""); code != 401 {
		t.Fatal(code)
	}
	body["family"] = "family-a"
	if code, _ := request(t, e, "POST", "/v1/pair", body, ""); code != 201 {
		t.Fatal(code)
	}
	body["device"] = "phone-b"
	if code, _ := request(t, e, "POST", "/v1/pair", body, ""); code != 401 {
		t.Fatal(code)
	}
	c, er := client.New(e.ts.URL, strings.Repeat("0", 64), "")
	if er != nil {
		t.Fatal(er)
	}
	defer c.Close()
	if _, er = c.Pair(context.Background(), inv.Code, "family-a", "phone-c"); er == nil {
		t.Fatal("wrong certificate accepted")
	}
}
func TestRestrictedCiphertextOpaqueToManagement(t *testing.T) {
	e := setup(t)
	c := pair(t, e, "family-a", "phone-a")
	var sealed bytes.Buffer
	key := sha256.Sum256([]byte("synthetic key generated per test context"))
	_, er := vault.Encrypt(&sealed, strings.NewReader("synthetic private title and EXIF original"), key[:], vault.Context{Family: "family-a", Backup: "sealed-backup", Entry: "opaque"}, vault.Limits{})
	if er != nil {
		t.Fatal(er)
	}
	data := sealed.Bytes()
	m := backup.Manifest{Version: 1, FamilyID: "family-a", BackupID: "sealed-backup", Entries: []backup.Entry{{ID: "opaque", Kind: "sealed", Size: int64(len(data)), SHA256: sh(data)}}}
	src := filepath.Join(t.TempDir(), "opaque.bin")
	os.WriteFile(src, data, 0600)
	st, er := c.Upload(context.Background(), m, func(string) (*os.File, error) { return os.Open(src) })
	if er != nil || st.Complete {
		t.Fatal(st, er)
	}
	code, b := request(t, e, "GET", "/admin/backups", nil, "")
	if code != 200 || bytes.Contains(b, []byte("synthetic private")) {
		t.Fatal(code, string(b))
	}
	if code, _ = request(t, e, "GET", "/admin/backups/family-a/sealed-backup/files/opaque", nil, ""); code != 403 {
		t.Fatal(code)
	}
	if code, b = request(t, e, "GET", "/v1/backups/sealed-backup/files/opaque", nil, c.Token()); code != 200 || !bytes.Equal(b, data) {
		t.Fatal(code)
	}
}
func TestHostOriginRemoteManagementAndTLSRequired(t *testing.T) {
	e := setup(t)
	login(t, e)
	for _, tc := range []struct {
		remote, host, origin string
		tls                  bool
		want                 int
	}{{"127.0.0.1:1", "127.0.0.1", "https://evil.invalid", true, 403}, {"127.0.0.1:1", "evil.invalid", "", true, 403}, {"192.0.2.2:1", "127.0.0.1", "", true, 403}, {"127.0.0.1:1", "127.0.0.1", "", false, 426}} {
		r := httptest.NewRequest("GET", "https://"+tc.host+"/", nil)
		r.RemoteAddr = tc.remote
		r.Host = tc.host
		r.Header.Set("Origin", tc.origin)
		if tc.tls {
			r.TLS = &tls.ConnectionState{}
		} else {
			r.TLS = nil
		}
		w := httptest.NewRecorder()
		e.s.ServeHTTP(w, r)
		if w.Code != tc.want {
			t.Fatal(tc, w.Code)
		}
	}
}
func TestUnknownFieldsQueryAndActiveDownloadsBlocked(t *testing.T) {
	e := setup(t)
	c := pair(t, e, "family-a", "phone-a")
	if code, _ := request(t, e, "POST", "/v1/backups", map[string]any{"version": 1, "family_id": "family-a", "password": "synthetic"}, c.Token()); code != 400 {
		t.Fatal(code)
	}
	if code, _ := request(t, e, "GET", "/admin/backups?token=synthetic", nil, ""); code != 400 {
		t.Fatal(code)
	}
	data := []byte("<script>alert('not executed')</script>")
	m := backup.Manifest{Version: 1, FamilyID: "family-a", BackupID: "html", Entries: []backup.Entry{{ID: "record", Kind: "records", Size: int64(len(data)), SHA256: sh(data), Label: "<img src=x onerror=alert(1)>"}}}
	src := filepath.Join(t.TempDir(), "src")
	os.WriteFile(src, data, 0600)
	if _, er := c.Upload(context.Background(), m, func(string) (*os.File, error) { return os.Open(src) }); er != nil {
		t.Fatal(er)
	}
	res, er := e.admin.Get(e.ts.URL + "/admin/backups/family-a/html/files/record")
	if er != nil {
		t.Fatal(er)
	}
	defer res.Body.Close()
	if res.Header.Get("Content-Type") != "application/octet-stream" || !strings.Contains(res.Header.Get("Content-Disposition"), "attachment") || !strings.Contains(res.Header.Get("Content-Security-Policy"), "sandbox") {
		t.Fatal(res.Header)
	}
	res2, er := e.admin.Get(e.ts.URL + "/app.js")
	if er != nil {
		t.Fatal(er)
	}
	js, _ := io.ReadAll(res2.Body)
	res2.Body.Close()
	if bytes.Contains(js, []byte("innerHTML")) || bytes.Contains(js, []byte("localStorage")) {
		t.Fatal("unsafe UI sink")
	}
}
func TestTransportCertificatePersistsAndRefusesPartialIdentity(t *testing.T) {
	dir := t.TempDir()
	_, pin, er := server.Certificate(dir)
	if er != nil {
		t.Fatal(er)
	}
	_, again, er := server.Certificate(dir)
	if er != nil || pin != again {
		t.Fatal(pin, again, er)
	}
	os.Remove(filepath.Join(dir, "transport-cert.pem"))
	if _, _, er = server.Certificate(dir); er == nil {
		t.Fatal("silently replaced partial identity")
	}
}

func TestRealTLSDisconnectResumesUploadAndDownload(t *testing.T) {
	e := setup(t)
	var uploadAllowed, downloadAllowed atomic.Bool
	e.ts.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		dropUpload := r.Method == "PUT" && r.URL.Query().Get("offset") == strconv.FormatInt(backup.ChunkSize, 10) && !uploadAllowed.Load()
		dropDownload := r.Method == "GET" && strings.Contains(r.URL.Path, "/files/") && strings.HasPrefix(r.Header.Get("Range"), fmt.Sprintf("bytes=%d-", backup.ChunkSize)) && !downloadAllowed.Load()
		if dropUpload || dropDownload {
			conn, _, er := w.(http.Hijacker).Hijack()
			if er == nil {
				conn.Close()
			}
			return
		}
		e.s.ServeHTTP(w, r)
	})
	c := pair(t, e, "family-a", "phone-a")
	data := bytes.Repeat([]byte("actual TLS disconnect synthetic media"), 600000)
	m := backup.Manifest{Version: 1, FamilyID: "family-a", BackupID: "resume", Entries: []backup.Entry{{ID: "video", Kind: "video", Size: int64(len(data)), SHA256: sh(data), SourceExact: true}}}
	source := filepath.Join(t.TempDir(), "video.bin")
	os.WriteFile(source, data, 0600)
	open := func(string) (*os.File, error) { return os.Open(source) }
	if _, er := c.Upload(context.Background(), m, open); er == nil {
		t.Fatal("injected connection loss not observed")
	}
	st, er := c.Status(context.Background(), m.BackupID)
	if er != nil || st.Entries[0].Offset != backup.ChunkSize {
		t.Fatal("lost upload prefix", st, er)
	}
	uploadAllowed.Store(true)
	if st, er = c.Upload(context.Background(), m, open); er != nil || !st.Complete {
		t.Fatal(st, er)
	}
	dst, _ := backup.New(t.TempDir())
	defer dst.Close()
	if _, er = c.Fetch(context.Background(), m, dst); er == nil {
		t.Fatal("injected download loss not observed")
	}
	local, er := dst.Status(m.FamilyID, m.BackupID)
	if er != nil || local.Entries[0].Offset != backup.ChunkSize {
		t.Fatal("lost downloaded prefix", local, er)
	}
	downloadAllowed.Store(true)
	if st, er = c.Fetch(context.Background(), m, dst); er != nil || !st.Complete {
		t.Fatal(st, er)
	}
	f, _, er := dst.OpenVerified(m.FamilyID, m.BackupID, "video", false)
	if er != nil {
		t.Fatal(er)
	}
	h := sha256.New()
	io.Copy(h, f)
	f.Close()
	if hex.EncodeToString(h.Sum(nil)) != m.Entries[0].SHA256 {
		t.Fatal("resume changed source")
	}
}
