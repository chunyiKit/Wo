// Package peersyncoracle 是当前 Dart 同步 wire 的独立合成协议 oracle。
// 不接入生产服务，不实现成员/家庭权限或业务同步策略。不得在生产复用测试 nonce。
package peersyncoracle

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"strconv"
	"unicode/utf8"
)

const MaxFrameBytes = 4 * 1024 * 1024
const MaxPlainBytes = 2 * 1024 * 1024
const maxSequence = 9007199254740991

var ErrProtocol = errors.New("peer oracle: invalid frame or protocol")
var ErrAuthentication = errors.New("peer oracle: authentication failed")
var ErrSequence = errors.New("peer oracle: session or sequence mismatch")
var ErrLimit = errors.New("peer oracle: resource limit")
var idPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,100}$`)
var linkPattern = regexp.MustCompile(`^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$`)
var encoding = base64.RawURLEncoding.Strict()

// Link 的 family/role 授权仍须由真实 PeerRegistry 在握手前后校验；不是此 oracle 的能力。
type Link struct {
	ID, From, To string
	Secret       []byte
}

func (l Link) valid() bool {
	return linkPattern.MatchString(l.ID) && idPattern.MatchString(l.From) && idPattern.MatchString(l.To) && l.From != l.To && len(l.Secret) == 32
}

type Keys struct {
	Transcript                                    string
	ServerProof, ClientProof, Salt, PRK, C2S, S2C []byte
	SessionID                                     string
}

func b64(b []byte) string { return encoding.EncodeToString(b) }
func un64(s string) ([]byte, error) {
	b, e := encoding.DecodeString(s)
	if e != nil || b64(b) != s {
		return nil, ErrProtocol
	}
	return b, nil
}
func mac(key, data []byte) []byte { h := hmac.New(sha256.New, key); h.Write(data); return h.Sum(nil) }
func Canonical(value any) ([]byte, error) {
	var b bytes.Buffer
	e := json.NewEncoder(&b)
	e.SetEscapeHTML(false)
	if err := e.Encode(value); err != nil {
		return nil, ErrProtocol
	}
	return bytes.TrimSuffix(b.Bytes(), []byte{'\n'}), nil
}
func Derive(link Link, nc, ns []byte) (Keys, error) {
	if !link.valid() || len(nc) != 32 || len(ns) != 32 {
		return Keys{}, ErrProtocol
	}
	transcript, err := Canonical([]string{link.ID, link.From, link.To, b64(nc), b64(ns)})
	if err != nil {
		return Keys{}, err
	}
	salt := sha256.Sum256(append([]byte("WO-SYNC/1/session\n"), transcript...))
	prk := mac(salt[:], link.Secret)
	return Keys{Transcript: string(transcript), ServerProof: mac(link.Secret, append([]byte("WO-SYNC/1/server\n"), transcript...)), ClientProof: mac(link.Secret, append([]byte("WO-SYNC/1/client\n"), transcript...)),
		Salt: bytes.Clone(salt[:]), PRK: prk, C2S: mac(prk, []byte{'c', '2', 's', 1}), S2C: mac(prk, []byte{'s', '2', 'c', 1}), SessionID: b64(salt[:])}, nil
}
func Framed(value any) ([]byte, error) {
	raw, e := Canonical(value)
	if e != nil {
		return nil, e
	}
	if len(raw) < 2 || len(raw) > MaxFrameBytes {
		return nil, ErrLimit
	}
	out := make([]byte, 4+len(raw))
	binary.BigEndian.PutUint32(out[:4], uint32(len(raw)))
	copy(out[4:], raw)
	return out, nil
}
func WriteFrame(w io.Writer, value any) error {
	b, e := Framed(value)
	if e != nil {
		return e
	}
	for len(b) > 0 {
		n, e := w.Write(b)
		if n < 0 || n > len(b) {
			return io.ErrShortWrite
		}
		b = b[n:]
		if e != nil {
			return e
		}
		if n == 0 {
			return io.ErrShortWrite
		}
	}
	return nil
}
func ReadFrame(r io.Reader) (map[string]any, error) {
	var header [4]byte
	if _, e := io.ReadFull(r, header[:]); e != nil {
		return nil, ErrProtocol
	}
	size := binary.BigEndian.Uint32(header[:])
	if size < 2 || size > MaxFrameBytes {
		return nil, ErrLimit
	}
	raw := make([]byte, int(size))
	if _, e := io.ReadFull(r, raw); e != nil {
		return nil, ErrProtocol
	}
	return object(raw)
}

// 独立检查重复键/深度后解码，避免 encoding/json 静默采用重复键最后值。
func object(raw []byte) (map[string]any, error) {
	if !utf8.Valid(raw) || !json.Valid(raw) {
		return nil, ErrProtocol
	}
	tokens := json.NewDecoder(bytes.NewReader(raw))
	tokens.UseNumber()
	var walk func(int) error
	walk = func(depth int) error {
		if depth > 12 {
			return ErrLimit
		}
		token, e := tokens.Token()
		if e != nil {
			return ErrProtocol
		}
		delim, ok := token.(json.Delim)
		if !ok {
			return nil
		}
		switch delim {
		case '{':
			seen := map[string]bool{}
			for tokens.More() {
				key, e := tokens.Token()
				s, ok := key.(string)
				if e != nil || !ok || seen[s] {
					return ErrProtocol
				}
				seen[s] = true
				if e = walk(depth + 1); e != nil {
					return e
				}
			}
			last, e := tokens.Token()
			if e != nil || last != json.Delim('}') {
				return ErrProtocol
			}
		case '[':
			for tokens.More() {
				if e = walk(depth + 1); e != nil {
					return e
				}
			}
			last, e := tokens.Token()
			if e != nil || last != json.Delim(']') {
				return ErrProtocol
			}
		default:
			return ErrProtocol
		}
		return nil
	}
	if e := walk(0); e != nil {
		return nil, e
	}
	if _, e := tokens.Token(); e != io.EOF {
		return nil, ErrProtocol
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	var value map[string]any
	if e := d.Decode(&value); e != nil || value == nil {
		return nil, ErrProtocol
	}
	return value, nil
}
func fields(m map[string]any, names ...string) bool {
	if len(m) != len(names) {
		return false
	}
	for _, n := range names {
		if _, ok := m[n]; !ok {
			return false
		}
	}
	return true
}
func version(m map[string]any) bool                    { n, ok := m["v"].(json.Number); return ok && n == "1" }
func text(m map[string]any, key string) (string, bool) { s, ok := m[key].(string); return s, ok }
func nonce(m map[string]any) ([]byte, error) {
	s, ok := text(m, "n")
	if !ok {
		return nil, ErrProtocol
	}
	b, e := un64(s)
	if e != nil || len(b) != 32 {
		return nil, ErrProtocol
	}
	return b, nil
}
func proof(m map[string]any, expected []byte) error {
	s, ok := text(m, "proof")
	if !ok {
		return ErrProtocol
	}
	b, e := un64(s)
	if e != nil || subtle.ConstantTimeCompare(b, expected) != 1 {
		return ErrAuthentication
	}
	return nil
}

// AuthenticateClient/Server 的 nonce 由测试显式注入；真实端必须每次取安全随机32字节。
func AuthenticateClient(rw io.ReadWriter, link Link, nc []byte) (*Session, error) {
	if !link.valid() || len(nc) != 32 {
		return nil, ErrProtocol
	}
	if e := WriteFrame(rw, map[string]any{"v": 1, "t": "hello", "link": link.ID, "from": link.From, "to": link.To, "n": b64(nc)}); e != nil {
		return nil, e
	}
	challenge, e := ReadFrame(rw)
	if e != nil {
		return nil, e
	}
	if !fields(challenge, "v", "t", "n", "proof") || !version(challenge) || challenge["t"] != "challenge" {
		return nil, ErrProtocol
	}
	ns, e := nonce(challenge)
	if e != nil {
		return nil, e
	}
	keys, e := Derive(link, nc, ns)
	if e != nil {
		return nil, e
	}
	if e = proof(challenge, keys.ServerProof); e != nil {
		return nil, e
	}
	if e = WriteFrame(rw, map[string]any{"v": 1, "t": "proof", "proof": b64(keys.ClientProof)}); e != nil {
		return nil, e
	}
	return NewSession(keys, true), nil
}
func AuthenticateServer(rw io.ReadWriter, link Link, ns []byte) (*Session, error) {
	if !link.valid() || len(ns) != 32 {
		return nil, ErrProtocol
	}
	hello, e := ReadFrame(rw)
	if e != nil {
		return nil, e
	}
	if !fields(hello, "v", "t", "link", "from", "to", "n") || !version(hello) || hello["t"] != "hello" || hello["link"] != link.ID || hello["from"] != link.From || hello["to"] != link.To {
		return nil, ErrProtocol
	}
	nc, e := nonce(hello)
	if e != nil {
		return nil, e
	}
	keys, e := Derive(link, nc, ns)
	if e != nil {
		return nil, e
	}
	if e = WriteFrame(rw, map[string]any{"v": 1, "t": "challenge", "n": b64(ns), "proof": b64(keys.ServerProof)}); e != nil {
		return nil, e
	}
	response, e := ReadFrame(rw)
	if e != nil {
		return nil, e
	}
	if !fields(response, "v", "t", "proof") || !version(response) || response["t"] != "proof" {
		return nil, ErrProtocol
	}
	if e = proof(response, keys.ClientProof); e != nil {
		return nil, e
	}
	return NewSession(keys, false), nil
}

type Session struct {
	keys           Keys
	client         bool
	sent, received uint64
}

func NewSession(keys Keys, client bool) *Session { return &Session{keys: keys, client: client} }
func Nonce(sequence uint64, clientDirection bool) []byte {
	b := make([]byte, 12)
	prefix := uint32(0x57535331)
	if clientDirection {
		prefix = 0x57534331
	}
	binary.BigEndian.PutUint32(b[:4], prefix)
	binary.BigEndian.PutUint64(b[4:], sequence)
	return b
}
func AAD(sid, direction string, sequence uint64) []byte {
	return []byte("WO-SYNC/1/" + sid + "/" + direction + "/" + strconv.FormatUint(sequence, 10))
}
func aead(key []byte) (cipher.AEAD, error) {
	if len(key) != 32 {
		return nil, ErrProtocol
	}
	block, e := aes.NewCipher(key)
	if e != nil {
		return nil, e
	}
	return cipher.NewGCM(block)
}
func (s *Session) Send(w io.Writer, value map[string]any) error {
	if s.sent >= maxSequence {
		return ErrLimit
	}
	plain, e := Canonical(value)
	if e != nil {
		return e
	}
	if len(plain) > MaxPlainBytes {
		return ErrLimit
	}
	sequence := s.sent
	s.sent++
	key, direction := s.keys.S2C, "s2c"
	if s.client {
		key, direction = s.keys.C2S, "c2s"
	}
	gcm, e := aead(key)
	if e != nil {
		return e
	}
	sealed := gcm.Seal(nil, Nonce(sequence, s.client), plain, AAD(s.keys.SessionID, direction, sequence))
	return WriteFrame(w, map[string]any{"v": 1, "t": "sealed", "sid": s.keys.SessionID, "seq": sequence, "data": b64(sealed)})
}
func (s *Session) Receive(r io.Reader) (map[string]any, error) {
	outer, e := ReadFrame(r)
	if e != nil {
		return nil, e
	}
	if !fields(outer, "v", "t", "sid", "seq", "data") || !version(outer) || outer["t"] != "sealed" || outer["sid"] != s.keys.SessionID {
		return nil, ErrSequence
	}
	number, ok := outer["seq"].(json.Number)
	if !ok {
		return nil, ErrSequence
	}
	sequence, e := strconv.ParseUint(string(number), 10, 64)
	if e != nil || sequence != s.received {
		return nil, ErrSequence
	}
	encoded, ok := text(outer, "data")
	if !ok {
		return nil, ErrProtocol
	}
	ciphertext, e := un64(encoded)
	if e != nil {
		return nil, e
	}
	if len(ciphertext) > MaxPlainBytes+16 {
		return nil, ErrLimit
	}
	key, direction := s.keys.C2S, "c2s"
	if s.client {
		key, direction = s.keys.S2C, "s2c"
	}
	gcm, e := aead(key)
	if e != nil {
		return nil, e
	}
	plain, e := gcm.Open(nil, Nonce(sequence, !s.client), ciphertext, AAD(s.keys.SessionID, direction, sequence))
	if e != nil {
		return nil, ErrAuthentication
	}
	s.received++
	return object(plain)
}
