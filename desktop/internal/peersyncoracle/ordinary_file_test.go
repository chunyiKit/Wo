package peersyncoracle

// 独立Go协议/文件receiver模型：真实loopback TCP+现有PSK握手和AES-GCM帧。
// 不执行Dart，不证明家庭/父记录权限、SQLite接线、NSD或手机原生行为。
import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"testing"
	"time"
)

const ordinaryChunk = 256 << 10
const ordinaryMaxFile = 20 << 20
const ordinaryRounds = 16

var errOrdinary = errors.New("ordinary oracle: rejected")

type ordinaryDescriptor struct {
	ID, Plugin, SHA string
	Size            int64
}
type ordinarySource struct {
	Descriptor ordinaryDescriptor
	Bytes      []byte
}
type ordinaryJournal struct {
	Family      string                        `json:"family"`
	Descriptors map[string]ordinaryDescriptor `json:"descriptors"`
	Offsets     map[string]int64              `json:"offsets"`
}
type ordinaryReceiver struct {
	root, family string
	descriptors  map[string]ordinaryDescriptor
	offsets      map[string]int64
	requested    map[string]int64
	accepted     int
}

func ordinaryDigest(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
func ordinaryInt(m map[string]any, key string) (int64, bool) {
	n, ok := m[key].(json.Number)
	if !ok {
		return 0, false
	}
	v, e := strconv.ParseInt(string(n), 10, 64)
	return v, e == nil
}
func ordinaryVersion(m map[string]any) bool { v, ok := ordinaryInt(m, "version"); return ok && v == 1 }
func ordinaryOffer(enabled bool) map[string]any {
	m := map[string]any{"t": "offer", "couple": false}
	if enabled {
		m["ordinary_attachments"] = 1
	}
	return m
}
func ordinaryCapability(m map[string]any) (bool, error) {
	if m["t"] != "offer" {
		return false, errOrdinary
	}
	if _, ok := m["couple"].(bool); !ok {
		return false, errOrdinary
	}
	if len(m) == 2 && fields(m, "t", "couple") {
		return false, nil
	}
	if !fields(m, "t", "couple", "ordinary_attachments") {
		return false, errOrdinary
	}
	v, ok := ordinaryInt(m, "ordinary_attachments")
	if !ok || v != 1 {
		return false, errOrdinary
	}
	return true, nil
}
func ordinaryOpen(root, family string, ds map[string]ordinaryDescriptor) (*ordinaryReceiver, error) {
	if err := os.MkdirAll(root, 0700); err != nil {
		return nil, err
	}
	r := &ordinaryReceiver{root: root, family: family, descriptors: ds, offsets: map[string]int64{}, requested: map[string]int64{}}
	raw, err := os.ReadFile(filepath.Join(root, "offsets.json"))
	if err == nil {
		var saved ordinaryJournal
		if json.Unmarshal(raw, &saved) != nil || saved.Family != family || saved.Offsets == nil || len(saved.Descriptors) != len(ds) {
			return nil, errOrdinary
		}
		for id, d := range ds {
			if saved.Descriptors[id] != d {
				return nil, errOrdinary
			}
		}
		r.offsets = saved.Offsets
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	for id, d := range ds {
		if id != d.ID || (d.Plugin != "chat" && d.Plugin != "pet") || d.Size < 1 || d.Size > ordinaryMaxFile {
			return nil, errOrdinary
		}
		offset := r.offsets[id]
		if offset < 0 || offset > d.Size {
			return nil, errOrdinary
		}
		f, err := os.OpenFile(r.path(id), os.O_CREATE|os.O_RDWR, 0600)
		if err != nil {
			return nil, err
		}
		st, err := f.Stat()
		f.Close()
		if err != nil || st.Size() != offset {
			return nil, errOrdinary
		}
	}
	return r, nil
}
func (r *ordinaryReceiver) path(id string) string {
	return filepath.Join(r.root, ordinaryDigest([]byte(id))+".blob")
}
func (r *ordinaryReceiver) save() error {
	raw, err := json.Marshal(ordinaryJournal{r.family, r.descriptors, r.offsets})
	if err != nil {
		return err
	}
	name := filepath.Join(r.root, "offsets.tmp")
	f, err := os.OpenFile(name, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	if _, err = f.Write(raw); err == nil {
		err = f.Sync()
	}
	err = errors.Join(err, f.Close())
	if err != nil {
		return err
	}
	return os.Rename(name, filepath.Join(r.root, "offsets.json"))
}
func (r *ordinaryReceiver) request() map[string]any {
	ids := make([]string, 0, len(r.descriptors))
	for id := range r.descriptors {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	list := []any{}
	r.requested = map[string]int64{}
	for _, id := range ids {
		d := r.descriptors[id]
		offset := r.offsets[id]
		if offset >= d.Size {
			continue
		}
		length := min(d.Size-offset, int64(ordinaryChunk))
		list = append(list, map[string]any{"plugin": d.Plugin, "id": id, "sha256": d.SHA, "offset": offset, "length": length})
		r.requested[id] = offset
		if len(list) == 2 {
			break
		}
	}
	return map[string]any{"t": "ordinary_request", "version": 1, "family_id": r.family, "requests": list}
}
func ordinaryReply(family string, sources map[string]ordinarySource, request map[string]any) (map[string]any, error) {
	if !fields(request, "t", "version", "family_id", "requests") || request["t"] != "ordinary_request" || !ordinaryVersion(request) || request["family_id"] != family {
		return nil, errOrdinary
	}
	items, ok := request["requests"].([]any)
	if !ok || len(items) > 2 {
		return nil, errOrdinary
	}
	chunks := []any{}
	seen := map[string]bool{}
	more := false
	for _, raw := range items {
		item, ok := raw.(map[string]any)
		if !ok || !fields(item, "plugin", "id", "sha256", "offset", "length") {
			return nil, errOrdinary
		}
		id, ok := item["id"].(string)
		if !ok || !idPattern.MatchString(id) || seen[id] || (item["plugin"] != "chat" && item["plugin"] != "pet") {
			return nil, errOrdinary
		}
		seen[id] = true
		offset, ok := ordinaryInt(item, "offset")
		length, ok2 := ordinaryInt(item, "length")
		if !ok || !ok2 {
			return nil, errOrdinary
		}
		source, exists := sources[id]
		if !exists {
			continue
		}
		d := source.Descriptor
		if item["plugin"] != d.Plugin || item["sha256"] != d.SHA || offset < 0 || length < 1 || length > ordinaryChunk || offset > d.Size-length || int64(len(source.Bytes)) != d.Size {
			return nil, errOrdinary
		}
		chunks = append(chunks, map[string]any{"plugin": d.Plugin, "id": id, "sha256": d.SHA, "offset": offset, "bytes": b64(source.Bytes[offset : offset+length])})
		more = more || offset+length < d.Size
	}
	return map[string]any{"t": "ordinary_chunks", "version": 1, "family_id": family, "chunks": chunks, "more": more}, nil
}
func (r *ordinaryReceiver) receive(reply map[string]any) error {
	if !fields(reply, "t", "version", "family_id", "chunks", "more") || reply["t"] != "ordinary_chunks" || !ordinaryVersion(reply) || reply["family_id"] != r.family {
		return errOrdinary
	}
	if _, ok := reply["more"].(bool); !ok {
		return errOrdinary
	}
	items, ok := reply["chunks"].([]any)
	if !ok || len(items) > 2 {
		return errOrdinary
	}
	expected := r.requested
	r.requested = map[string]int64{}
	seen := map[string]bool{}
	for _, raw := range items {
		item, ok := raw.(map[string]any)
		if !ok || !fields(item, "plugin", "id", "sha256", "offset", "bytes") {
			return errOrdinary
		}
		id, ok := item["id"].(string)
		if !ok || seen[id] {
			return errOrdinary
		}
		seen[id] = true
		wanted, ok := expected[id]
		if !ok {
			return errOrdinary
		}
		d := r.descriptors[id]
		offset, ok := ordinaryInt(item, "offset")
		if !ok || offset != wanted || offset != r.offsets[id] || item["plugin"] != d.Plugin || item["sha256"] != d.SHA {
			return errOrdinary
		}
		encoded, ok := item["bytes"].(string)
		if !ok || len(encoded) > 350000 {
			return errOrdinary
		}
		chunk, err := un64(encoded)
		if err != nil || len(chunk) != int(min(d.Size-wanted, int64(ordinaryChunk))) || len(chunk) > ordinaryChunk {
			return errOrdinary
		}
		f, err := os.OpenFile(r.path(id), os.O_WRONLY|os.O_APPEND, 0600)
		if err != nil {
			return err
		}
		st, err := f.Stat()
		if err != nil || st.Size() != wanted {
			f.Close()
			return errOrdinary
		}
		_, err = f.Write(chunk)
		if err == nil {
			err = f.Sync()
		}
		err = errors.Join(err, f.Close())
		if err != nil {
			return err
		}
		next := wanted + int64(len(chunk))
		if next == d.Size {
			file, err := os.Open(r.path(id))
			if err != nil {
				return err
			}
			h := sha256.New()
			n, err := io.Copy(h, file)
			file.Close()
			if err != nil || n != d.Size || hex.EncodeToString(h.Sum(nil)) != d.SHA {
				return errOrdinary
			}
		}
		r.offsets[id] = next
		if err := r.save(); err != nil {
			return err
		}
		r.accepted++
	}
	return nil
}
func ordinaryEmptyRequest(family string) map[string]any {
	return map[string]any{"t": "ordinary_request", "version": 1, "family_id": family, "requests": []any{}}
}
func ordinaryDecoded(t *testing.T, m map[string]any) map[string]any {
	t.Helper()
	raw, e := Canonical(m)
	if e != nil {
		t.Fatal(e)
	}
	out, e := object(raw)
	if e != nil {
		t.Fatal(e)
	}
	return out
}

// 每连接新随机nonce与新AES会话；断线帧从未送入receiver，只有已持久化offset可恢复。
func ordinaryTCP(t *testing.T, r *ordinaryReceiver, sources map[string]ordinarySource, rounds, cutAt int, mutate func(map[string]any)) (string, error, error) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	done := make(chan error, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			done <- err
			return
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(45 * time.Second))
		serverNonce := make([]byte, 32)
		if _, err = rand.Read(serverNonce); err != nil {
			done <- err
			return
		}
		server, err := AuthenticateServer(conn, testLink(), serverNonce)
		if err != nil {
			done <- err
			return
		}
		offer, err := server.Receive(conn)
		if err != nil {
			done <- err
			return
		}
		supported, err := ordinaryCapability(offer)
		if err != nil || !supported {
			done <- errOrdinary
			return
		}
		if err = server.Send(conn, ordinaryOffer(true)); err != nil {
			done <- err
			return
		}
		for i := 1; i <= rounds; i++ {
			req, err := server.Receive(conn)
			if err != nil {
				done <- err
				return
			}
			reply, err := ordinaryReply(r.family, sources, req)
			if err != nil {
				done <- err
				return
			}
			if mutate != nil {
				mutate(reply)
			}
			if i == cutAt {
				var wire bytes.Buffer
				if err = server.Send(&wire, reply); err == nil {
					_, err = conn.Write(wire.Bytes()[:wire.Len()/2])
				}
				done <- err
				return
			}
			if err = server.Send(conn, reply); err != nil {
				done <- err
				return
			}
			if mutate != nil {
				done <- nil
				return
			} // 负例只测已认证单回复，免将拒绝误当后续轮次。
			if err = server.Send(conn, ordinaryEmptyRequest(r.family)); err != nil {
				done <- err
				return
			}
			empty, err := server.Receive(conn)
			if err != nil {
				done <- err
				return
			}
			if !fields(empty, "t", "version", "family_id", "chunks", "more") || empty["t"] != "ordinary_chunks" || !ordinaryVersion(empty) || empty["family_id"] != r.family || empty["more"] != false {
				done <- errOrdinary
				return
			}
			chunks, ok := empty["chunks"].([]any)
			if !ok || len(chunks) != 0 {
				done <- errOrdinary
				return
			}
		}
		done <- nil
	}()
	conn, err := net.DialTimeout("tcp", listener.Addr().String(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(45 * time.Second))
	clientNonce := make([]byte, 32)
	if _, err = rand.Read(clientNonce); err != nil {
		t.Fatal(err)
	}
	client, err := AuthenticateClient(conn, testLink(), clientNonce)
	if err != nil {
		t.Fatal(err)
	}
	if err = client.Send(conn, ordinaryOffer(true)); err == nil {
		var offer map[string]any
		offer, err = client.Receive(conn)
		if err == nil {
			var enabled bool
			enabled, err = ordinaryCapability(offer)
			if !enabled && err == nil {
				err = errOrdinary
			}
		}
	}
	for i := 1; err == nil && i <= rounds; i++ {
		err = client.Send(conn, r.request())
		if err != nil {
			break
		}
		var reply map[string]any
		reply, err = client.Receive(conn)
		if err != nil {
			break
		}
		err = r.receive(reply)
		if err != nil {
			break
		}
		if mutate != nil {
			break
		}
		var reverse map[string]any
		reverse, err = client.Receive(conn)
		if err != nil {
			break
		}
		var empty map[string]any
		empty, err = ordinaryReply(r.family, map[string]ordinarySource{}, reverse)
		if err != nil {
			break
		}
		err = client.Send(conn, empty)
	}
	conn.Close()
	return client.keys.SessionID, err, <-done
}

func TestOrdinaryFileTwentyMiBRealTCPEncryptedResume(t *testing.T) {
	data := make([]byte, ordinaryMaxFile)
	for i := range data {
		data[i] = byte((i*31 + 7) % 251)
	}
	copy(data, []byte("%PDF-1.7\nsynthetic ordinary transfer oracle\n"))
	copy(data[len(data)-7:], []byte("\n%%EOF\n"))
	d := ordinaryDescriptor{"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "chat", ordinaryDigest(data), int64(len(data))}
	ds := map[string]ordinaryDescriptor{d.ID: d}
	sources := map[string]ordinarySource{d.ID: {d, data}}
	root := filepath.Join(t.TempDir(), "private-model")
	r, err := ordinaryOpen(root, "family_synthetic", ds)
	if err != nil {
		t.Fatal(err)
	}
	sid, clientErr, serverErr := ordinaryTCP(t, r, sources, ordinaryRounds, 7, nil)
	if clientErr == nil || serverErr != nil || r.offsets[d.ID] != 6*ordinaryChunk || r.accepted != 6 {
		t.Fatal("partial encrypted frame acknowledged", r.offsets, clientErr, serverErr)
	}
	sessions := map[string]bool{sid: true}
	accepted := r.accepted
	attempted := 7
	for r.offsets[d.ID] < d.Size {
		previous := r.offsets[d.ID]
		r, err = ordinaryOpen(root, "family_synthetic", ds)
		if err != nil || r.offsets[d.ID] != previous {
			t.Fatal("offset journal restart", err)
		}
		rounds := min(ordinaryRounds, int((d.Size-previous)/ordinaryChunk))
		sid, clientErr, serverErr = ordinaryTCP(t, r, sources, rounds, 0, nil)
		if clientErr != nil || serverErr != nil || sessions[sid] {
			t.Fatal("fresh session/resume", clientErr, serverErr)
		}
		sessions[sid] = true
		accepted += r.accepted
		attempted += rounds
	}
	reopened, err := ordinaryOpen(root, "family_synthetic", ds)
	if err != nil || reopened.offsets[d.ID] != d.Size || accepted != 80 || len(sessions) != 6 || attempted != 81 {
		t.Fatal("resume totals", accepted, len(sessions), attempted, err)
	}
	got, err := os.ReadFile(reopened.path(d.ID))
	if err != nil || ordinaryDigest(got) != d.SHA || !bytes.Equal(got, data) {
		t.Fatal("final SHA changed", err)
	}
	t.Logf("独立Go模型：20MiB/80块256KiB，6个真实TCP+新AEAD session（每session<=16轮）；第7帧中途断流后持久offset=%d继续，尝试81帧，最终SHA=%s；非Dart/NSD/家庭权限证明", 6*ordinaryChunk, d.SHA)
}

func TestOrdinaryTwoDistinctChunksAndAuthenticatedReceiverRejects(t *testing.T) {
	pdf := []byte("%PDF-1.7\nsynthetic document\n%%EOF\n")
	d := ordinaryDescriptor{"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "pet", ordinaryDigest(pdf), int64(len(pdf))}
	d2 := d
	d2.ID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
	d2.Plugin = "chat"
	// 两个不同ID均用最大256KiB，以验证实际加密JSON帧可容纳最大合法回复。
	large := make([]byte, ordinaryChunk)
	copy(large, pdf)
	p1, p2 := d, d2
	p1.Size, p2.Size = ordinaryChunk, ordinaryChunk
	p1.SHA, p2.SHA = ordinaryDigest(large), ordinaryDigest(large)
	ds := map[string]ordinaryDescriptor{p1.ID: p1, p2.ID: p2}
	positiveSources := map[string]ordinarySource{p1.ID: {p1, large}, p2.ID: {p2, large}}
	sources := map[string]ordinarySource{d.ID: {d, pdf}, d2.ID: {d2, pdf}}
	r, err := ordinaryOpen(filepath.Join(t.TempDir(), "private-model"), "family_synthetic", ds)
	if err != nil {
		t.Fatal(err)
	}
	_, ce, se := ordinaryTCP(t, r, positiveSources, 1, 0, nil)
	if ce != nil || se != nil || r.accepted != 2 {
		t.Fatal("valid two-file chunk reply", ce, se)
	}
	cases := map[string]func(map[string]any){
		"wrong_offset": func(m map[string]any) { m["chunks"].([]any)[0].(map[string]any)["offset"] = 1 },
		"wrong_sha_descriptor": func(m map[string]any) {
			m["chunks"].([]any)[0].(map[string]any)["sha256"] = ordinaryDigest([]byte("wrong"))
		},
		"wrong_family":   func(m map[string]any) { m["family_id"] = "another_family" },
		"unrequested_id": func(m map[string]any) { m["chunks"].([]any)[0].(map[string]any)["id"] = "not_requested" },
		"three_chunks":   func(m map[string]any) { item := m["chunks"].([]any)[0]; m["chunks"] = []any{item, item, item} },
		"chunk_over_256KiB": func(m map[string]any) {
			m["chunks"].([]any)[0].(map[string]any)["bytes"] = b64(make([]byte, ordinaryChunk+1))
		},
		"wrong_final_bytes_sha": func(m map[string]any) {
			bad := bytes.Clone(pdf)
			bad[0] ^= 1
			m["chunks"].([]any)[0].(map[string]any)["bytes"] = b64(bad)
		},
		"noncanonical_base64": func(m map[string]any) {
			item := m["chunks"].([]any)[0].(map[string]any)
			item["bytes"] = item["bytes"].(string) + "="
		},
		"unknown_version": func(m map[string]any) { m["version"] = 2 },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			r, err := ordinaryOpen(filepath.Join(t.TempDir(), "private-model"), "family_synthetic", map[string]ordinaryDescriptor{d.ID: d})
			if err != nil {
				t.Fatal(err)
			}
			_, ce, se := ordinaryTCP(t, r, sources, 1, 0, mutate)
			if ce == nil || se != nil || r.offsets[d.ID] != 0 {
				t.Fatal("invalid encrypted reply accepted", ce, se, r.offsets)
			}
		})
	}
}

func TestOrdinaryCapabilityAndRequestLimits(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		got, err := ordinaryCapability(ordinaryDecoded(t, ordinaryOffer(enabled)))
		if err != nil || got != enabled {
			t.Fatal("capability negotiation", got, err)
		}
	}
	for name, cap := range map[string]any{"bool": true, "unknown": 2, "float": 1.0, "string": "1"} {
		t.Run("capability_"+name, func(t *testing.T) {
			m := ordinaryOffer(true)
			m["ordinary_attachments"] = cap
			if name == "float" {
				m = map[string]any{"t": "offer", "couple": false, "ordinary_attachments": json.Number("1.0")}
			}
			if _, err := ordinaryCapability(ordinaryDecoded(t, m)); err == nil {
				t.Fatal("invalid capability accepted")
			}
		})
	}
	extra := ordinaryOffer(true)
	extra["extra"] = true
	if _, err := ordinaryCapability(ordinaryDecoded(t, extra)); err == nil {
		t.Fatal("unknown offer key")
	}
	data := []byte("synthetic PDF document")
	d := ordinaryDescriptor{"dddddddd-dddd-4ddd-8ddd-dddddddddddd", "chat", ordinaryDigest(data), int64(len(data))}
	sources := map[string]ordinarySource{d.ID: {d, data}}
	base := map[string]any{"plugin": "chat", "id": d.ID, "sha256": d.SHA, "offset": 0, "length": len(data)}
	cases := map[string]func(map[string]any){
		"three_requests":   func(m map[string]any) { m["requests"] = []any{base, base, base} },
		"duplicate_id":     func(m map[string]any) { m["requests"] = []any{base, base} },
		"oversize_request": func(m map[string]any) { m["requests"].([]any)[0].(map[string]any)["length"] = ordinaryChunk + 1 },
		"wrong_family":     func(m map[string]any) { m["family_id"] = "another_family" },
		"wrong_sha":        func(m map[string]any) { m["requests"].([]any)[0].(map[string]any)["sha256"] = "wrong" },
		"negative_offset":  func(m map[string]any) { m["requests"].([]any)[0].(map[string]any)["offset"] = -1 },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			m := ordinaryDecoded(t, map[string]any{"t": "ordinary_request", "version": 1, "family_id": "family_synthetic", "requests": []any{base}})
			mutate(m)
			if _, err := ordinaryReply("family_synthetic", sources, ordinaryDecoded(t, m)); err == nil {
				t.Fatalf("invalid request %s accepted", name)
			}
		})
	}
}
