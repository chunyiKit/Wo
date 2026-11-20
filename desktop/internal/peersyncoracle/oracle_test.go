package peersyncoracle

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testLink() Link {
	return Link{ID: "11111111-2222-3333-4444-555555555555", From: "device-a", To: "device-b", Secret: bytes.Repeat([]byte{0x4b}, 32)}
}
func testNonces() ([]byte, []byte) {
	nc, ns := make([]byte, 32), make([]byte, 32)
	for i := range nc {
		nc[i] = byte(i)
		ns[i] = byte(160 + i)
	}
	return nc, ns
}
func keys(t *testing.T) Keys {
	t.Helper()
	nc, ns := testNonces()
	k, e := Derive(testLink(), nc, ns)
	if e != nil {
		t.Fatal(e)
	}
	return k
}
func frame(t *testing.T, value any) []byte {
	t.Helper()
	b, e := Framed(value)
	if e != nil {
		t.Fatal(e)
	}
	return b
}
func sealed(t *testing.T, session *Session, payload map[string]any) []byte {
	t.Helper()
	var out bytes.Buffer
	if e := session.Send(&out, payload); e != nil {
		t.Fatal(e)
	}
	return out.Bytes()
}
func payload(direction string) map[string]any {
	return map[string]any{"oracle": "synthetic-wire-only", "direction": direction, "counter": 0}
}

type frameVector struct {
	Sequence   uint64 `json:"sequence"`
	Nonce      string `json:"nonce_hex"`
	AAD        string `json:"aad"`
	Plaintext  string `json:"plaintext_utf8"`
	Ciphertext string `json:"ciphertext_hex"`
	Frame      string `json:"frame_hex"`
}
type kat struct {
	Scope        string        `json:"scope"`
	Secret       string        `json:"synthetic_secret_hex"`
	Link         string        `json:"link"`
	From         string        `json:"from"`
	To           string        `json:"to"`
	NonceC       string        `json:"nonce_c_hex"`
	NonceS       string        `json:"nonce_s_hex"`
	Transcript   string        `json:"transcript_utf8"`
	ServerProof  string        `json:"server_proof_hex"`
	ClientProof  string        `json:"client_proof_hex"`
	Salt         string        `json:"salt_hex"`
	PRK          string        `json:"prk_hex"`
	C2S          string        `json:"c2s_key_hex"`
	S2C          string        `json:"s2c_key_hex"`
	SID          string        `json:"sid"`
	Hello        string        `json:"hello_frame_hex"`
	Challenge    string        `json:"challenge_frame_hex"`
	Proof        string        `json:"proof_frame_hex"`
	ClientFrames []frameVector `json:"client_frames"`
	ServerFrames []frameVector `json:"server_frames"`
}

func makeKAT(t *testing.T) kat {
	t.Helper()
	link := testLink()
	nc, ns := testNonces()
	k := keys(t)
	hx := hex.EncodeToString
	v := kat{Scope: "Go oracle only; synthetic public key/nonces; not Dart execution or app-policy proof", Secret: hx(link.Secret), Link: link.ID, From: link.From, To: link.To, NonceC: hx(nc), NonceS: hx(ns), Transcript: k.Transcript, ServerProof: hx(k.ServerProof), ClientProof: hx(k.ClientProof), Salt: hx(k.Salt), PRK: hx(k.PRK), C2S: hx(k.C2S), S2C: hx(k.S2C), SID: k.SessionID}
	v.Hello = hx(frame(t, map[string]any{"v": 1, "t": "hello", "link": link.ID, "from": link.From, "to": link.To, "n": b64(nc)}))
	v.Challenge = hx(frame(t, map[string]any{"v": 1, "t": "challenge", "n": b64(ns), "proof": b64(k.ServerProof)}))
	v.Proof = hx(frame(t, map[string]any{"v": 1, "t": "proof", "proof": b64(k.ClientProof)}))
	for _, client := range []bool{true, false} {
		direction := "s2c"
		if client {
			direction = "c2s"
		}
		s := NewSession(k, client)
		for seq := uint64(0); seq < 2; seq++ {
			p := payload(direction)
			p["counter"] = seq
			raw := sealed(t, s, p)
			j, e := ReadFrame(bytes.NewReader(raw))
			if e != nil {
				t.Fatal(e)
			}
			cipher, e := un64(j["data"].(string))
			if e != nil {
				t.Fatal(e)
			}
			plain, e := Canonical(p)
			if e != nil {
				t.Fatal(e)
			}
			f := frameVector{Sequence: seq, Nonce: hx(Nonce(seq, client)), AAD: string(AAD(k.SessionID, direction, seq)), Plaintext: string(plain), Ciphertext: hx(cipher), Frame: hx(raw)}
			if client {
				v.ClientFrames = append(v.ClientFrames, f)
			} else {
				v.ServerFrames = append(v.ServerFrames, f)
			}
		}
	}
	return v
}
func TestKnownAnswerFixture(t *testing.T) {
	v := makeKAT(t)
	raw, e := json.MarshalIndent(v, "", "  ")
	if e != nil {
		t.Fatal(e)
	}
	raw = append(raw, '\n')
	paths := []string{"testdata/peer-v1.json", "../../../test/local/sync/fixtures/peer-v1.json"}
	if os.Getenv("WO_WRITE_PEER_FIXTURES") == "1" {
		for _, p := range paths {
			if e = os.MkdirAll(filepath.Dir(p), 0700); e != nil {
				t.Fatal(e)
			}
			if e = os.WriteFile(p, raw, 0600); e != nil {
				t.Fatal(e)
			}
		}
	}
	for _, p := range paths {
		stored, e := os.ReadFile(p)
		if e != nil {
			t.Fatal(e)
		}
		if !bytes.Equal(stored, raw) {
			t.Fatalf("固定KAT不同 %s", p)
		}
	}
	k := keys(t)
	for _, client := range []bool{true, false} {
		receiver := NewSession(k, !client)
		vectors := v.ServerFrames
		if client {
			vectors = v.ClientFrames
		}
		for _, f := range vectors {
			wire, e := hex.DecodeString(f.Frame)
			if e != nil {
				t.Fatal(e)
			}
			got, e := receiver.Receive(bytes.NewReader(wire))
			if e != nil {
				t.Fatal(e)
			}
			plain, e := Canonical(got)
			if e != nil || string(plain) != f.Plaintext {
				t.Fatal(string(plain), e)
			}
		}
	}
	if bytes.Equal(k.C2S, k.S2C) || bytes.Equal(k.ServerProof, k.ClientProof) {
		t.Fatal("方向与角色必须域分离")
	}
}
func TestRealTwoEndpointLoopbackHandshakeAndAEAD(t *testing.T) {
	listener, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer listener.Close()
	done := make(chan error, 1)
	nc, ns := testNonces()
	go func() {
		conn, e := listener.Accept()
		if e != nil {
			done <- e
			return
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(5 * time.Second))
		server, e := AuthenticateServer(conn, testLink(), ns)
		if e != nil {
			done <- e
			return
		}
		got, e := server.Receive(conn)
		if e == nil && got["direction"] != "c2s" {
			e = ErrProtocol
		}
		if e == nil {
			e = server.Send(conn, payload("s2c"))
		}
		done <- e
	}()
	conn, e := net.DialTimeout("tcp", listener.Addr().String(), time.Second)
	if e != nil {
		t.Fatal(e)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	client, e := AuthenticateClient(conn, testLink(), nc)
	if e != nil {
		t.Fatal(e)
	}
	if e = client.Send(conn, payload("c2s")); e != nil {
		t.Fatal(e)
	}
	got, e := client.Receive(conn)
	if e != nil || got["direction"] != "s2c" {
		t.Fatal(got, e)
	}
	if e = <-done; e != nil {
		t.Fatal(e)
	}
}

type script struct {
	r io.Reader
	w bytes.Buffer
}

func (s *script) Read(p []byte) (int, error)  { return s.r.Read(p) }
func (s *script) Write(p []byte) (int, error) { return s.w.Write(p) }
func TestHandshakeRejectsWrongKeyReflectionAndCrossPeer(t *testing.T) {
	link := testLink()
	nc, ns := testNonces()
	k := keys(t)
	hello := func(l Link) []byte {
		return frame(t, map[string]any{"v": 1, "t": "hello", "link": l.ID, "from": l.From, "to": l.To, "n": b64(nc)})
	}
	for _, mode := range []string{"wrongkey", "reflected-server-proof", "cross-peer-from", "cross-peer-to", "cross-link", "wrong-nonce"} {
		t.Run(mode, func(t *testing.T) {
			l := testLink()
			candidate := bytes.Clone(k.ClientProof)
			input := hello(l)
			switch mode {
			case "wrongkey":
				l.Secret[0] ^= 1
			case "reflected-server-proof":
				candidate = bytes.Clone(k.ServerProof)
			case "cross-peer-from":
				l.From = "device-c"
			case "cross-peer-to":
				l.To = "device-c"
			case "cross-link":
				l.ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
			case "wrong-nonce":
				ns = bytes.Repeat([]byte{9}, 32)
			}
			input = append(input, frame(t, map[string]any{"v": 1, "t": "proof", "proof": b64(candidate)})...)
			if _, e := AuthenticateServer(&script{r: bytes.NewReader(input)}, l, ns); e == nil {
				t.Fatal("服务端接受错误身份或证明")
			}
		})
	}
	nc, ns = testNonces() // 每条客户端拒绝路径独立使用原始挑战，避免其它子用例的nonce影响。
	for _, candidate := range [][]byte{k.ClientProof, bytes.Repeat([]byte{0}, 32)} {
		challenge := frame(t, map[string]any{"v": 1, "t": "challenge", "n": b64(ns), "proof": b64(candidate)})
		if _, e := AuthenticateClient(&script{r: bytes.NewReader(challenge)}, link, nc); !errors.Is(e, ErrAuthentication) {
			t.Fatal("客户端接受反射/错误serverproof", e)
		}
	}
}
func rewrite(t *testing.T, wire []byte, change func(map[string]any)) []byte {
	t.Helper()
	j, e := ReadFrame(bytes.NewReader(wire))
	if e != nil {
		t.Fatal(e)
	}
	change(j)
	return frame(t, j)
}
func TestAEADRejectsReflectionReplaySequenceAndCrossContext(t *testing.T) {
	k := keys(t)
	wire := sealed(t, NewSession(k, true), payload("c2s"))
	server := NewSession(k, false)
	if _, e := server.Receive(bytes.NewReader(wire)); e != nil {
		t.Fatal(e)
	}
	if _, e := server.Receive(bytes.NewReader(wire)); !errors.Is(e, ErrSequence) {
		t.Fatal("重放未拒绝", e)
	}
	if _, e := NewSession(k, true).Receive(bytes.NewReader(wire)); !errors.Is(e, ErrAuthentication) {
		t.Fatal("方向反射未拒绝", e)
	}
	wrongKey := k
	wrongKey.C2S = bytes.Clone(k.C2S)
	wrongKey.C2S[0] ^= 1
	if _, e := NewSession(wrongKey, false).Receive(bytes.NewReader(wire)); !errors.Is(e, ErrAuthentication) {
		t.Fatal(e)
	}
	for _, seq := range []any{1, -1, "0", json.Number("0.0")} {
		bad := rewrite(t, wire, func(j map[string]any) { j["seq"] = seq })
		if _, e := NewSession(k, false).Receive(bytes.NewReader(bad)); !errors.Is(e, ErrSequence) {
			t.Fatal("接受错误seq", seq, e)
		}
	}
	link := testLink()
	link.To = "device-c"
	nc, ns := testNonces()
	cross, e := Derive(link, nc, ns)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = NewSession(cross, false).Receive(bytes.NewReader(wire)); !errors.Is(e, ErrSequence) {
		t.Fatal(e)
	}
	forged := rewrite(t, wire, func(j map[string]any) { j["sid"] = cross.SessionID })
	if _, e = NewSession(cross, false).Receive(bytes.NewReader(forged)); !errors.Is(e, ErrAuthentication) {
		t.Fatal("改sid后仍接受跨peer密文", e)
	}
	ns[0] ^= 1
	fresh, e := Derive(testLink(), nc, ns)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = NewSession(fresh, false).Receive(bytes.NewReader(wire)); !errors.Is(e, ErrSequence) {
		t.Fatal("新会话接受旧帧", e)
	}
}
func TestTruncationTamperAndLimits(t *testing.T) {
	k := keys(t)
	wire := sealed(t, NewSession(k, true), payload("c2s"))
	for cut := 0; cut < len(wire); cut++ {
		if _, e := NewSession(k, false).Receive(bytes.NewReader(wire[:cut])); e == nil {
			t.Fatalf("接受截断 %d", cut)
		}
	}
	for _, part := range []string{"data", "sid", "v", "t", "extra"} {
		bad := rewrite(t, wire, func(j map[string]any) {
			switch part {
			case "data":
				b, _ := un64(j["data"].(string))
				b[0] ^= 1
				j["data"] = b64(b)
			case "sid":
				j["sid"] = "wrong"
			case "v":
				j["v"] = 2
			case "t":
				j["t"] = "hello"
			case "extra":
				j["extra"] = true
			}
		})
		if _, e := NewSession(k, false).Receive(bytes.NewReader(bad)); e == nil {
			t.Fatal("接受篡改", part)
		}
	}
	for _, size := range []uint32{0, 1, MaxFrameBytes + 1, ^uint32(0)} {
		header := make([]byte, 4)
		binary.BigEndian.PutUint32(header, size)
		if _, e := ReadFrame(bytes.NewReader(header)); !errors.Is(e, ErrLimit) {
			t.Fatal(size, e)
		}
	}
	if e := NewSession(k, true).Send(io.Discard, map[string]any{"huge": strings.Repeat("x", MaxPlainBytes)}); !errors.Is(e, ErrLimit) {
		t.Fatal(e)
	}
	sender := NewSession(k, true)
	sender.sent = maxSequence
	if e := sender.Send(io.Discard, payload("c2s")); !errors.Is(e, ErrLimit) {
		t.Fatal(e)
	}
	if _, e := object([]byte(`{"v":1,"v":1}`)); !errors.Is(e, ErrProtocol) {
		t.Fatal("重复键未拒绝", e)
	}
	if _, e := object([]byte(strings.Repeat("[", 14) + "0" + strings.Repeat("]", 14))); !errors.Is(e, ErrLimit) {
		t.Fatal("深度未拒绝", e)
	}
}
func TestCoalescedAndFragmentedFrameReader(t *testing.T) {
	one := frame(t, map[string]any{"a": 1})
	two := frame(t, map[string]any{"b": 2})
	reader := bytes.NewReader(append(one, two...))
	if _, e := ReadFrame(reader); e != nil {
		t.Fatal(e)
	}
	if _, e := ReadFrame(reader); e != nil {
		t.Fatal(e)
	}
	_, e := ReadFrame(&byteReader{reader: bytes.NewReader(one)})
	if e != nil {
		t.Fatal(e)
	}
}

type byteReader struct{ reader io.Reader }

func (r *byteReader) Read(p []byte) (int, error) {
	if len(p) > 1 {
		p = p[:1]
	}
	return r.reader.Read(p)
}
func TestFixtureDigestIsStable(t *testing.T) {
	raw, e := os.ReadFile("testdata/peer-v1.json")
	if e != nil {
		t.Fatal(e)
	}
	sum := sha256.Sum256(raw)
	t.Logf("fixture bytes=%d sha256=%x", len(raw), sum)
}

func TestRealLoopbackWrongPSKDoesNotAuthenticate(t *testing.T) {
	listener, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer listener.Close()
	result := make(chan error, 1)
	nc, ns := testNonces()
	go func() {
		conn, e := listener.Accept()
		if e != nil {
			result <- e
			return
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(5 * time.Second))
		session, e := AuthenticateServer(conn, testLink(), ns)
		if session != nil || e == nil {
			result <- errors.New("错误PSK仍产生已认证服务端session")
			return
		}
		result <- nil
	}()
	conn, e := net.DialTimeout("tcp", listener.Addr().String(), time.Second)
	if e != nil {
		t.Fatal(e)
	}
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	bad := testLink()
	bad.Secret[0] ^= 1
	session, e := AuthenticateClient(conn, bad, nc)
	conn.Close()
	if session != nil || !errors.Is(e, ErrAuthentication) {
		t.Fatalf("客户端不应获认证 session=%v error=%v", session, e)
	}
	if e = <-result; e != nil {
		t.Fatal(e)
	}
}
