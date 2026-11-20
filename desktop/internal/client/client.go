// Package client 只由手机适配/显式命令调用；不会自动反向合并或覆盖业务库。
package client

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/chunyiKit/Wo/desktop/internal/backup"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

type Client struct {
	base  string
	http  *http.Client
	token string
}

func New(server, pin, token string) (*Client, error) {
	u, e := url.Parse(server)
	raw, e2 := hex.DecodeString(pin)
	if e != nil || e2 != nil || len(raw) != 32 || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.Path != "" {
		return nil, errors.New("HTTPS origin and explicit certificate SHA256 required")
	}
	transport := &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS13, InsecureSkipVerify: true, VerifyConnection: func(cs tls.ConnectionState) error {
		if len(cs.PeerCertificates) == 0 {
			return errors.New("certificate missing")
		}
		cert := cs.PeerCertificates[0]
		now := time.Now()
		if now.Before(cert.NotBefore) || now.After(cert.NotAfter) {
			return errors.New("certificate not currently valid")
		}
		sum := sha256.Sum256(cert.Raw)
		if subtle.ConstantTimeCompare(sum[:], raw) != 1 {
			return errors.New("certificate fingerprint mismatch")
		}
		return nil
	}}, Proxy: nil}
	return &Client{base: server, http: &http.Client{Transport: transport, Timeout: 15 * time.Minute, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}, token: token}, nil
}
func (c *Client) Close() { c.http.CloseIdleConnections() }
func (c *Client) request(ctx context.Context, method, path string, body io.Reader) (*http.Request, error) {
	r, e := http.NewRequestWithContext(ctx, method, c.base+path, body)
	if e != nil {
		return nil, e
	}
	if c.token != "" {
		r.Header.Set("Authorization", "Bearer "+c.token)
	}
	return r, nil
}
func (c *Client) json(ctx context.Context, method, path string, body any, out any) error {
	var reader io.Reader
	if body != nil {
		b, e := json.Marshal(body)
		if e != nil {
			return e
		}
		reader = bytes.NewReader(b)
	}
	r, e := c.request(ctx, method, path, reader)
	if e != nil {
		return e
	}
	r.Header.Set("Content-Type", "application/json")
	res, e := c.http.Do(r)
	if e != nil {
		return errors.New("connection failed; retry can resume")
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode > 299 {
		return fmt.Errorf("backup HTTP %d", res.StatusCode)
	}
	d := json.NewDecoder(io.LimitReader(res.Body, 2<<20))
	d.DisallowUnknownFields()
	if e = d.Decode(out); e != nil {
		return e
	}
	if d.Decode(new(any)) != io.EOF {
		return errors.New("trailing response")
	}
	return nil
}
func (c *Client) Pair(ctx context.Context, code, family, device string) (string, error) {
	var out struct {
		Token  string `json:"token"`
		Family string `json:"family"`
		Device string `json:"device"`
	}
	e := c.json(ctx, "POST", "/v1/pair", map[string]string{"code": code, "family": family, "device": device}, &out)
	if e != nil {
		return "", e
	}
	if out.Family != family || out.Device != device || len(out.Token) != 64 {
		return "", errors.New("pair response mismatch")
	}
	c.token = out.Token
	return out.Token, nil
}
func (c *Client) Status(ctx context.Context, bid string) (backup.Status, error) {
	var out backup.Status
	if !backup.ValidID(bid) {
		return out, errors.New("invalid backup")
	}
	e := c.json(ctx, "GET", "/v1/backups/"+bid, nil, &out)
	return out, e
}
func (c *Client) Manifest(ctx context.Context, bid string) (backup.Manifest, error) {
	var out backup.Manifest
	if !backup.ValidID(bid) {
		return out, errors.New("invalid backup")
	}
	e := c.json(ctx, "GET", "/v1/backups/"+bid+"/manifest", nil, &out)
	if e == nil {
		e = backup.Validate(out)
	}
	if e == nil && out.BackupID != bid {
		e = errors.New("backup response mismatch")
	}
	return out, e
}
func sha(data []byte) string { s := sha256.Sum256(data); return hex.EncodeToString(s[:]) }

// Upload 可再次调用恢复已确认偏移；源完整SHA先独立读取再上传，最终电脑再次全文校验。
func (c *Client) Upload(ctx context.Context, m backup.Manifest, open func(string) (*os.File, error)) (backup.Status, error) {
	if e := backup.Validate(m); e != nil {
		return backup.Status{}, e
	}
	var created map[string]bool
	if e := c.json(ctx, "POST", "/v1/backups", m, &created); e != nil {
		return backup.Status{}, e
	}
	st, e := c.Status(ctx, m.BackupID)
	if e != nil {
		return st, e
	}
	if st.FamilyID != m.FamilyID {
		return st, errors.New("family mismatch")
	}
	offsets := map[string]int64{}
	for _, e := range st.Entries {
		offsets[e.ID] = e.Offset
	}
	for _, entry := range m.Entries {
		if entry.Missing != "" {
			continue
		}
		f, e := open(entry.ID)
		if e != nil {
			return st, e
		}
		e = func() error {
			defer f.Close()
			h := sha256.New()
			n, er := io.CopyBuffer(h, f, make([]byte, 128<<10))
			if er != nil || n != entry.Size || hex.EncodeToString(h.Sum(nil)) != entry.SHA256 {
				return errors.New("source changed or digest mismatch")
			}
			off := offsets[entry.ID]
			if off < 0 || off > entry.Size {
				return errors.New("invalid remote offset")
			}
			if _, er = f.Seek(off, io.SeekStart); er != nil {
				return er
			}
			buf := make([]byte, backup.ChunkSize)
			for off < entry.Size {
				length := min(backup.ChunkSize, entry.Size-off)
				if _, er = io.ReadFull(f, buf[:length]); er != nil {
					return er
				}
				req, er := c.request(ctx, "PUT", "/v1/backups/"+m.BackupID+"/entries/"+entry.ID+"?offset="+strconv.FormatInt(off, 10), bytes.NewReader(buf[:length]))
				if er != nil {
					return er
				}
				req.Header.Set("X-Chunk-SHA256", sha(buf[:length]))
				res, er := c.http.Do(req)
				if er != nil {
					return errors.New("upload interrupted; rerun resumes acknowledged chunks")
				}
				var answer struct {
					Offset int64 `json:"offset"`
				}
				if res.StatusCode != 200 {
					res.Body.Close()
					return fmt.Errorf("upload HTTP %d", res.StatusCode)
				}
				er = json.NewDecoder(io.LimitReader(res.Body, 1024)).Decode(&answer)
				res.Body.Close()
				if er != nil || answer.Offset != off+length {
					return errors.New("invalid acknowledgment")
				}
				off = answer.Offset
			}
			return nil
		}()
		if e != nil {
			return st, e
		}
	}
	var done backup.Status
	e = c.json(ctx, "POST", "/v1/backups/"+m.BackupID+"/finalize", nil, &done)
	return done, e
}

// Fetch 将恢复字节放进专用 Store；再次调用可续传。它不解码业务或应用旧设备身份。
func (c *Client) Fetch(ctx context.Context, m backup.Manifest, destination *backup.Store) (backup.Status, error) {
	if e := backup.Validate(m); e != nil {
		return backup.Status{}, e
	}
	remote, e := c.Manifest(ctx, m.BackupID)
	if e != nil {
		return backup.Status{}, e
	}
	a, _ := json.Marshal(m)
	b, _ := json.Marshal(remote)
	if !bytes.Equal(a, b) {
		return backup.Status{}, errors.New("immutable manifest mismatch")
	}
	if e = destination.Create(m); e != nil {
		return backup.Status{}, e
	}
	st, e := destination.Status(m.FamilyID, m.BackupID)
	if e != nil {
		return st, e
	}
	offsets := map[string]int64{}
	for _, entry := range st.Entries {
		offsets[entry.ID] = entry.Offset
	}
	for _, entry := range m.Entries {
		if entry.Missing != "" {
			continue
		}
		off := offsets[entry.ID]
		for off < entry.Size {
			end := min(off+backup.ChunkSize, entry.Size) - 1
			req, er := c.request(ctx, "GET", "/v1/backups/"+m.BackupID+"/files/"+entry.ID, nil)
			if er != nil {
				return st, er
			}
			req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", off, end))
			req.Header.Set("If-Range", "\""+entry.SHA256+"\"")
			res, er := c.http.Do(req)
			if er != nil {
				return st, errors.New("download interrupted; rerun resumes verified chunks")
			}
			expected := fmt.Sprintf("bytes %d-%d/%d", off, end, entry.Size)
			if res.StatusCode != 206 || res.Header.Get("Content-Range") != expected || res.Header.Get("ETag") != "\""+entry.SHA256+"\"" || res.ContentLength != end-off+1 {
				res.Body.Close()
				return st, errors.New("range or immutable digest mismatch")
			}
			data, er := io.ReadAll(io.LimitReader(res.Body, backup.ChunkSize+1))
			res.Body.Close()
			if er != nil || int64(len(data)) != end-off+1 {
				return st, errors.New("partial range; retry")
			}
			next, er := destination.Append(m.FamilyID, m.BackupID, entry.ID, off, int64(len(data)), sha(data), bytes.NewReader(data))
			if er != nil {
				return st, er
			}
			off = next
		}
	}
	return destination.Finalize(m.FamilyID, m.BackupID)
}

// Token 仅供显式配对命令写入私有凭据文件；服务端持久化的仅是其哈希。
func (c *Client) Token() string { return strings.Clone(c.token) }
