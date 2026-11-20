package server

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/chunyiKit/Wo/desktop/internal/backup"
	"github.com/chunyiKit/Wo/desktop/internal/webui"
)

type device struct {
	Family string `json:"family"`
	ID     string `json:"id"`
	Hash   string `json:"hash"`
}
type invitation struct {
	Family  string
	Expires time.Time
}
type Server struct {
	Store      *backup.Store
	mu         sync.Mutex
	secretHash [32]byte
	sessions   map[string]time.Time
	invites    map[string]invitation
	devices    []device
	authPath   string
	uploads    chan struct{}
}

func random() string {
	var b [32]byte
	if _, e := rand.Read(b[:]); e != nil {
		panic(e)
	}
	return hex.EncodeToString(b[:])
}
func hash(s string) string { x := sha256.Sum256([]byte(s)); return hex.EncodeToString(x[:]) }
func New(store *backup.Store, adminSecret string, authPath string) (*Server, error) {
	if len(adminSecret) < 32 {
		return nil, errors.New("admin secret too short")
	}
	s := &Server{Store: store, secretHash: sha256.Sum256([]byte(adminSecret)), sessions: map[string]time.Time{}, invites: map[string]invitation{}, authPath: authPath, uploads: make(chan struct{}, 4)}
	if authPath != "" {
		b, e := os.ReadFile(authPath)
		if e == nil {
			if len(b) > 1<<20 {
				return nil, errors.New("auth state too large")
			}
			if e = json.Unmarshal(b, &s.devices); e != nil {
				return nil, e
			}
			for _, d := range s.devices {
				if !backup.ValidID(d.Family) || !backup.ValidID(d.ID) || len(d.Hash) != 64 {
					return nil, errors.New("invalid auth state")
				}
			}
		} else if !errors.Is(e, os.ErrNotExist) {
			return nil, e
		}
	}
	return s, nil
}
func NewAdminSecret() string { return random() }
func (s *Server) saveAuth() error {
	if s.authPath == "" {
		return nil
	}
	if e := os.MkdirAll(filepath.Dir(s.authPath), 0700); e != nil {
		return e
	}
	b, _ := json.Marshal(s.devices)
	f, e := os.CreateTemp(filepath.Dir(s.authPath), ".auth-*")
	if e != nil {
		return e
	}
	name := f.Name()
	defer os.Remove(name)
	if e = f.Chmod(0600); e == nil {
		_, e = f.Write(b)
	}
	if e == nil {
		e = f.Sync()
	}
	if er := f.Close(); e == nil {
		e = er
	}
	if e != nil {
		return e
	}
	return os.Rename(name, s.authPath)
}
func local(r *http.Request) bool {
	host, _, e := net.SplitHostPort(r.RemoteAddr)
	if e != nil {
		return false
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return false
	}
	u, e := url.Parse("https://" + r.Host)
	if e != nil {
		return false
	}
	h := u.Hostname()
	return h == "localhost" || h == "127.0.0.1" || h == "::1"
}
func (s *Server) admin(r *http.Request) bool {
	if !local(r) {
		return false
	}
	c, e := r.Cookie("wo_admin")
	if e != nil {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	expires, ok := s.sessions[hash(c.Value)]
	return ok && time.Now().Before(expires)
}
func (s *Server) identity(r *http.Request) (device, bool) {
	auth := r.Header.Get("Authorization")
	if !strings.HasPrefix(auth, "Bearer ") || len(auth) > 100 {
		return device{}, false
	}
	h := hash(strings.TrimPrefix(auth, "Bearer "))
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, d := range s.devices {
		if subtle.ConstantTimeCompare([]byte(h), []byte(d.Hash)) == 1 {
			return d, true
		}
	}
	return device{}, false
}
func jsonBody(w http.ResponseWriter, r *http.Request, out any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 2<<20)
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if e := d.Decode(out); e != nil {
		problem(w, 400, "invalid_json")
		return false
	}
	if d.Decode(new(any)) != io.EOF {
		problem(w, 400, "trailing_json")
		return false
	}
	return true
}
func send(w http.ResponseWriter, code int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(value)
}
func problem(w http.ResponseWriter, code int, kind string) {
	send(w, code, map[string]string{"error": kind})
}
func failure(w http.ResponseWriter, e error) {
	code := 400
	if errors.Is(e, os.ErrNotExist) {
		code = 404
	} else if errors.Is(e, os.ErrPermission) {
		code = 403
	} else if errors.Is(e, backup.ErrConflict) || errors.Is(e, backup.ErrIncomplete) {
		code = 409
	}
	problem(w, code, "backup_operation_failed")
}
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
	if r.TLS == nil {
		problem(w, 426, "tls_required")
		return
	}
	if origin := r.Header.Get("Origin"); origin != "" && origin != "https://"+r.Host {
		problem(w, 403, "origin_forbidden")
		return
	}
	if r.URL.RawQuery != "" { // 只允许续传 offset 查询；认证材料绝不放 URL
		if !strings.HasPrefix(r.URL.Path, "/v1/backups/") || r.Method != "PUT" || len(r.URL.Query()) != 1 || r.URL.Query().Get("offset") == "" {
			problem(w, 400, "query_forbidden")
			return
		}
	}
	if r.URL.Path == "/" || r.URL.Path == "/app.js" || r.URL.Path == "/app.css" {
		if r.Method != "GET" || !local(r) {
			problem(w, 403, "local_management_only")
			return
		}
		webui.Serve(w, r)
		return
	}
	if r.URL.Path == "/admin/session" && r.Method == "POST" {
		if !local(r) {
			problem(w, 403, "local_management_only")
			return
		}
		var body struct {
			Secret string `json:"secret"`
		}
		if !jsonBody(w, r, &body) {
			return
		}
		h := sha256.Sum256([]byte(body.Secret))
		if subtle.ConstantTimeCompare(h[:], s.secretHash[:]) != 1 {
			problem(w, 401, "unauthorized")
			return
		}
		raw := random()
		s.mu.Lock()
		now := time.Now()
		for key, exp := range s.sessions {
			if !now.Before(exp) {
				delete(s.sessions, key)
			}
		}
		if len(s.sessions) >= 64 {
			s.mu.Unlock()
			problem(w, 429, "session_limit")
			return
		}
		s.sessions[hash(raw)] = now.Add(8 * time.Hour)
		s.mu.Unlock()
		http.SetCookie(w, &http.Cookie{Name: "wo_admin", Value: raw, Path: "/", Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode, MaxAge: 28800})
		send(w, 200, map[string]bool{"ok": true})
		return
	}
	if strings.HasPrefix(r.URL.Path, "/admin/") {
		if !s.admin(r) {
			problem(w, 401, "unauthorized")
			return
		}
		s.adminRoute(w, r)
		return
	}
	if r.URL.Path == "/v1/pair" && r.Method == "POST" {
		s.pair(w, r)
		return
	}
	who, ok := s.identity(r)
	if !ok {
		problem(w, 401, "unauthorized")
		return
	}
	s.deviceRoute(w, r, who)
}
func (s *Server) adminRoute(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.URL.Path == "/admin/pair" && r.Method == "POST":
		var body struct {
			Family string `json:"family"`
		}
		if !jsonBody(w, r, &body) {
			return
		}
		if !backup.ValidID(body.Family) {
			problem(w, 400, "invalid_family")
			return
		}
		code := random()
		s.mu.Lock()
		now := time.Now()
		for k, v := range s.invites {
			if now.After(v.Expires) {
				delete(s.invites, k)
			}
		}
		if len(s.invites) >= 32 {
			s.mu.Unlock()
			problem(w, 429, "invitation_limit")
			return
		}
		s.invites[hash(code)] = invitation{Family: body.Family, Expires: now.Add(5 * time.Minute)}
		s.mu.Unlock()
		send(w, 201, map[string]any{"code": code, "family": body.Family, "expires_seconds": 300})
	case r.URL.Path == "/admin/devices" && r.Method == "GET":
		s.mu.Lock()
		out := []map[string]string{}
		for _, d := range s.devices {
			out = append(out, map[string]string{"family": d.Family, "id": d.ID})
		}
		s.mu.Unlock()
		send(w, 200, out)
	case r.URL.Path == "/admin/revoke" && r.Method == "POST":
		var body struct {
			Family string `json:"family"`
			Device string `json:"device"`
		}
		if !jsonBody(w, r, &body) {
			return
		}
		s.mu.Lock()
		old := append([]device(nil), s.devices...)
		next := []device{}
		for _, d := range s.devices {
			if d.Family != body.Family || d.ID != body.Device {
				next = append(next, d)
			}
		}
		s.devices = next
		err := s.saveAuth()
		if err != nil {
			s.devices = old
		}
		s.mu.Unlock()
		if err != nil {
			failure(w, err)
			return
		}
		send(w, 200, map[string]bool{"ok": true})
	case r.URL.Path == "/admin/backups" && r.Method == "GET":
		list, err := s.Store.List()
		if err != nil {
			failure(w, err)
			return
		}
		send(w, 200, list)
	default:
		p := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
		if len(p) == 6 && p[0] == "admin" && p[1] == "backups" && p[4] == "files" && r.Method == "GET" {
			s.download(w, r, p[2], p[3], p[5], false)
			return
		}
		if len(p) == 5 && p[0] == "admin" && p[1] == "backups" && p[4] == "check" && r.Method == "POST" {
			st, err := s.Store.Check(p[2], p[3])
			if err != nil {
				failure(w, err)
				return
			}
			send(w, 200, st)
			return
		}
		problem(w, 404, "not_found")
	}
}
func (s *Server) pair(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Code   string `json:"code"`
		Family string `json:"family"`
		Device string `json:"device"`
	}
	if !jsonBody(w, r, &body) {
		return
	}
	if !backup.ValidID(body.Family) || !backup.ValidID(body.Device) || len(body.Code) != 64 {
		problem(w, 400, "invalid_pairing")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	inv, ok := s.invites[hash(body.Code)]
	if !ok || time.Now().After(inv.Expires) || body.Family != inv.Family {
		problem(w, 401, "invalid_pairing")
		return
	}
	for _, d := range s.devices {
		if d.Family == body.Family && d.ID == body.Device {
			problem(w, 409, "device_exists")
			return
		}
	}
	if len(s.devices) >= 256 {
		problem(w, 429, "device_limit")
		return
	}
	raw := random()
	s.devices = append(s.devices, device{Family: body.Family, ID: body.Device, Hash: hash(raw)})
	if err := s.saveAuth(); err != nil {
		s.devices = s.devices[:len(s.devices)-1]
		failure(w, err)
		return
	}
	delete(s.invites, hash(body.Code))
	send(w, 201, map[string]string{"token": raw, "family": body.Family, "device": body.Device})
}
func (s *Server) deviceRoute(w http.ResponseWriter, r *http.Request, who device) {
	if r.URL.Path == "/v1/backups" {
		if r.Method == "POST" {
			var m backup.Manifest
			if !jsonBody(w, r, &m) {
				return
			}
			if m.FamilyID != who.Family {
				problem(w, 403, "family_forbidden")
				return
			}
			if err := s.Store.Create(m); err != nil {
				failure(w, err)
				return
			}
			send(w, 201, map[string]bool{"ok": true})
			return
		}
		if r.Method == "GET" {
			list, err := s.Store.ListFamily(who.Family)
			if err != nil {
				failure(w, err)
				return
			}
			out := []backup.Status{}
			for _, st := range list {
				if st.FamilyID == who.Family {
					out = append(out, st)
				}
			}
			send(w, 200, out)
			return
		}
	}
	p := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(p) < 3 || p[0] != "v1" || p[1] != "backups" || !backup.ValidID(p[2]) {
		problem(w, 404, "not_found")
		return
	}
	bid := p[2]
	switch {
	case len(p) == 3 && r.Method == "GET":
		st, err := s.Store.Status(who.Family, bid)
		if err != nil {
			failure(w, err)
			return
		}
		send(w, 200, st)
	case len(p) == 4 && p[3] == "manifest" && r.Method == "GET":
		st, err := s.Store.Status(who.Family, bid)
		if err != nil {
			failure(w, err)
			return
		}
		if st.VerifiedAt == "" {
			failure(w, backup.ErrIncomplete)
			return
		}
		m, err := s.Store.Manifest(who.Family, bid)
		if err != nil {
			failure(w, err)
			return
		}
		send(w, 200, m)
	case len(p) == 4 && p[3] == "finalize" && r.Method == "POST":
		st, err := s.Store.Finalize(who.Family, bid)
		if err != nil {
			failure(w, err)
			return
		}
		send(w, 200, st)
	case len(p) == 4 && p[3] == "check" && r.Method == "POST":
		st, err := s.Store.Check(who.Family, bid)
		if err != nil {
			failure(w, err)
			return
		}
		send(w, 200, st)
	case len(p) == 5 && p[3] == "entries" && r.Method == "PUT":
		select {
		case s.uploads <- struct{}{}:
			defer func() { <-s.uploads }()
		default:
			problem(w, 429, "upload_limit")
			return
		}
		off, err := strconv.ParseInt(r.URL.Query().Get("offset"), 10, 64)
		if err != nil || r.ContentLength < 1 || r.ContentLength > backup.ChunkSize {
			problem(w, 400, "invalid_chunk")
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, backup.ChunkSize+1)
		n, err := s.Store.Append(who.Family, bid, p[4], off, r.ContentLength, r.Header.Get("X-Chunk-SHA256"), r.Body)
		if err != nil {
			if errors.Is(err, backup.ErrConflict) {
				send(w, 409, map[string]any{"error": "offset_conflict", "offset": n})
				return
			}
			failure(w, err)
			return
		}
		send(w, 200, map[string]int64{"offset": n})
	case len(p) == 5 && p[3] == "files" && r.Method == "GET":
		s.download(w, r, who.Family, bid, p[4], true)
	default:
		problem(w, 404, "not_found")
	}
}
func (s *Server) download(w http.ResponseWriter, r *http.Request, fid, bid, eid string, restricted bool) {
	f, e, err := s.Store.OpenVerified(fid, bid, eid, restricted)
	if err != nil {
		failure(w, err)
		return
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		failure(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=\"%s%s\"", eid, downloadExtension(f, e.Kind)))
	w.Header().Set("Content-Security-Policy", "sandbox; default-src 'none'")
	w.Header().Set("ETag", "\""+e.SHA256+"\"")
	w.Header().Set("X-Content-SHA256", e.SHA256)
	http.ServeContent(w, r, eid, st.ModTime(), f)
}

// 只从原文件魔数选择下载扩展名，不使用发送者文件名或活动MIME。
func downloadExtension(f *os.File, kind string) string {
	if kind == "sealed" {
		return ".woseal"
	}
	var prefix [512]byte
	n, _ := f.Read(prefix[:])
	_, _ = f.Seek(0, io.SeekStart)
	data := prefix[:n]
	switch http.DetectContentType(data) {
	case "image/jpeg":
		return ".jpg"
	case "image/png":
		return ".png"
	case "image/webp":
		return ".webp"
	case "image/gif":
		return ".gif"
	case "video/mp4":
		return ".mp4"
	case "video/webm":
		return ".webm"
	}
	if n >= 12 && string(data[4:8]) == "ftyp" {
		brand := string(data[8:12])
		switch brand {
		case "heic", "heix", "hevc", "hevx", "heim", "heis", "mif1":
			return ".heic"
		case "avif", "avis":
			return ".avif"
		case "qt  ":
			return ".mov"
		}
	}
	return ".bin"
}
