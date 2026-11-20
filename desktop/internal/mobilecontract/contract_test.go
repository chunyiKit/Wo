// Package mobilecontract 验证独立合成向量，不代表 Dart 已执行或手机实际互通。
package mobilecontract

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/chunyiKit/Wo/desktop/internal/backup"
	"github.com/chunyiKit/Wo/desktop/internal/portable"
	"github.com/chunyiKit/Wo/desktop/internal/vault"
)

type vectorFrame struct {
	Nonce      string `json:"nonce"`
	AAD        string `json:"aad"`
	Plaintext  string `json:"plaintext"`
	Ciphertext string `json:"ciphertext"`
}
type vector struct {
	Family      string        `json:"family"`
	Backup      string        `json:"backup"`
	Entry       string        `json:"entry"`
	Key         string        `json:"key"`
	Random      string        `json:"random"`
	ContextHash string        `json:"context_hash"`
	DerivedKey  string        `json:"derived_key"`
	Portable    string        `json:"portable"`
	Vault       string        `json:"vault"`
	Frames      []vectorFrame `json:"frames"`
}

func hx(b []byte) string { return hex.EncodeToString(b) }
func unhex(t *testing.T, s string) []byte {
	t.Helper()
	b, e := hex.DecodeString(s)
	if e != nil {
		t.Fatal(e)
	}
	return b
}
func mac(key, data []byte) []byte { h := hmac.New(sha256.New, key); h.Write(data); return h.Sum(nil) }
func u32(n uint32) []byte         { b := make([]byte, 4); binary.BigEndian.PutUint32(b, n); return b }
func digest(b []byte) string      { h := sha256.Sum256(b); return hx(h[:]) }
func strOct(n, width int) string {
	const digits = "01234567"
	out := bytes.Repeat([]byte{'0'}, width)
	for i := width - 1; i >= 0; i-- {
		out[i] = digits[n&7]
		n >>= 3
	}
	return string(out)
}

// 独立 GNU 物理头实现对应 Dart _tarHeader，不使用 portable.Pack 作为自身 oracle。
func mobileHeader(name string, size int) []byte {
	b := make([]byte, 512)
	copy(b, name)
	oct := func(offset, length, value int) { copy(b[offset:offset+length-1], strOct(value, length-1)) }
	oct(100, 8, 0600)
	oct(108, 8, 0)
	oct(116, 8, 0)
	oct(124, 12, size)
	oct(136, 12, 0)
	for i := 148; i < 156; i++ {
		b[i] = ' '
	}
	b[156] = '0'
	copy(b[257:265], []byte("ustar  \x00"))
	sum := 0
	for _, v := range b {
		sum += int(v)
	}
	copy(b[148:154], strOct(sum, 6))
	b[154] = 0
	b[155] = ' '
	return b
}
func mobilePortable() []byte {
	data := []byte(`{"schema":1,"notes":[{"id":"note-1","text":"synthetic-only"}]}`)
	m := portable.Manifest{Version: 1, FamilyID: "family", Entries: []portable.Entry{
		{ID: "records", Kind: portable.Records, Size: int64(len(data)), SHA256: digest(data)},
		{ID: "missing-photo", Kind: portable.Photo, MissingReason: portable.SourceUnavailable},
	}}
	raw, _ := json.Marshal(m)
	var out bytes.Buffer
	for _, part := range []struct {
		name string
		data []byte
	}{{"manifest.json", raw}, {"entries/records", data}} {
		out.Write(mobileHeader(part.name, len(part.data)))
		out.Write(part.data)
		out.Write(make([]byte, (512-len(part.data)%512)%512))
	}
	out.Write(make([]byte, 1024))
	return out.Bytes()
}
func generate() vector {
	v := vector{Family: "family", Backup: "backup", Entry: "sealed"}
	key := bytes.Repeat([]byte{0x42}, 32)
	random := make([]byte, 40)
	for i := range random {
		random[i] = byte(i)
	}
	ctx := []byte("WoVault/context/v1\x00")
	for _, s := range []string{v.Family, v.Backup, v.Entry} {
		ctx = append(ctx, u32(uint32(len(s)))...)
		ctx = append(ctx, []byte(s)...)
	}
	ch := sha256.Sum256(ctx)
	prk := mac(random[:32], key)
	info := append([]byte("WoVault/AES256GCM/v1\x00"), ch[:]...)
	info = append(info, 1)
	derived := mac(prk, info)
	block, _ := aes.NewCipher(derived)
	gcm, _ := cipher.NewGCM(block)
	header := append([]byte("WOVLT1\r\n"), random...)
	header = append(header, u32(vault.ChunkBytes)...)
	plain := mobilePortable()
	var wire bytes.Buffer
	wire.Write(header)
	appendFrame := func(kind byte, seq uint32, data []byte) {
		desc := append([]byte{kind}, u32(seq)...)
		desc = append(desc, u32(uint32(len(data)))...)
		nonce := append(bytes.Clone(random[32:]), u32(seq)...)
		aad := append([]byte("WoVault/frame/v1\x00"), header...)
		aad = append(aad, ch[:]...)
		aad = append(aad, desc...)
		ciphertext := gcm.Seal(nil, nonce, data, aad)
		v.Frames = append(v.Frames, vectorFrame{Nonce: hx(nonce), AAD: hx(aad), Plaintext: hx(data), Ciphertext: hx(ciphertext)})
		wire.Write(desc)
		wire.Write(ciphertext)
	}
	appendFrame(1, 0, plain)
	footer := make([]byte, 44)
	binary.BigEndian.PutUint64(footer[:8], uint64(len(plain)))
	binary.BigEndian.PutUint32(footer[8:12], 1)
	sum := sha256.Sum256(plain)
	copy(footer[12:], sum[:])
	appendFrame(2, 1, footer)
	v.Key = hx(key)
	v.Random = hx(random)
	v.ContextHash = hx(ch[:])
	v.DerivedKey = hx(derived)
	v.Portable = hx(plain)
	v.Vault = hx(wire.Bytes())
	return v
}
func fixture(t *testing.T) vector {
	t.Helper()
	v := generate()
	raw, e := json.MarshalIndent(v, "", "  ")
	if e != nil {
		t.Fatal(e)
	}
	raw = append(raw, '\n')
	if os.Getenv("WO_WRITE_SYNTHETIC_FIXTURES") == "1" {
		for _, path := range []string{"testdata/v1.json", "../../../test/local/backup/fixtures/v1.json"} {
			if e = os.MkdirAll(filepath.Dir(path), 0700); e != nil {
				t.Fatal(e)
			}
			if e = os.WriteFile(path, raw, 0600); e != nil {
				t.Fatal(e)
			}
		}
	}
	stored, e := os.ReadFile("testdata/v1.json")
	if e != nil {
		t.Fatal(e)
	}
	if !bytes.Equal(raw, stored) {
		t.Fatal("合成向量与固定fixture不同")
	}
	return v
}
func TestMobileWireOracle(t *testing.T) {
	v := fixture(t)
	key := unhex(t, v.Key)
	encoded := unhex(t, v.Vault)
	ctx := vault.Context{Family: v.Family, Backup: v.Backup, Entry: v.Entry}
	summary, e := vault.Verify(bytes.NewReader(encoded), key, ctx, vault.Limits{})
	if e != nil || summary.Bytes != int64(len(unhex(t, v.Portable))) {
		t.Fatal(summary, e)
	}
	root, e := os.OpenRoot(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	defer root.Close()
	if runtime.GOOS == "windows" {
		if _, e = vault.RestoreFile(root, "plain", bytes.NewReader(encoded), key, ctx, vault.Limits{}); !errors.Is(e, vault.ErrPrivateACLUnavailable) {
			t.Fatal(e)
		}
		return // Windows没有私有ACL实现，不运行明文恢复部分。
	}
	if _, e = vault.RestoreFile(root, "plain", bytes.NewReader(encoded), key, ctx, vault.Limits{}); e != nil {
		t.Fatal(e)
	}
	data, e := root.ReadFile("plain")
	if e != nil || !bytes.Equal(data, unhex(t, v.Portable)) {
		t.Fatal(e)
	}
	tr := tar.NewReader(bytes.NewReader(data))
	h, e := tr.Next()
	if e != nil || h.Format != tar.FormatGNU {
		t.Fatal(h, e)
	}
	result, e := portable.Restore(context.Background(), bytes.NewReader(data), portable.RestoreOptions{ExpectedFamilyID: "family", Destination: filepath.Join(t.TempDir(), "new"), RequirePrivateACL: true})
	if e != nil {
		t.Fatal(e)
	}
	if result.NewFamilyID == v.Family || result.NewDeviceID == "" || result.RecordsApplied || result.Complete || result.Missing["missing-photo"] != "source_unavailable" {
		t.Fatalf("恢复语义 %+v", result)
	}
	for _, handle := range []string{"content://", "ph://", "file://", "bookmark", "old-device", "old-photo-id"} {
		if bytes.Contains(data, []byte(handle)) {
			t.Fatal("合成向量含源句柄")
		}
	}
}
func TestWrongKeyFamilyAndBoundaryReject(t *testing.T) {
	v := fixture(t)
	data, key := unhex(t, v.Vault), unhex(t, v.Key)
	ctx := vault.Context{Family: v.Family, Backup: v.Backup, Entry: v.Entry}
	wrong := bytes.Clone(key)
	wrong[0] ^= 1
	if _, e := vault.Verify(bytes.NewReader(data), wrong, ctx, vault.Limits{}); !errors.Is(e, vault.ErrInvalid) {
		t.Fatal(e)
	}
	ctx.Family = "other"
	if _, e := vault.Verify(bytes.NewReader(data), key, ctx, vault.Limits{}); !errors.Is(e, vault.ErrInvalid) {
		t.Fatal(e)
	}
	for _, cut := range []int{0, 51, 52, 53, len(data) - 1} {
		ctx.Family = v.Family
		if _, e := vault.Verify(bytes.NewReader(data[:cut]), key, ctx, vault.Limits{}); e == nil {
			t.Fatalf("接受断线边界 %d", cut)
		}
	}
	_, e := portable.Restore(context.Background(), bytes.NewReader(unhex(t, v.Portable)), portable.RestoreOptions{ExpectedFamilyID: "other", Destination: filepath.Join(t.TempDir(), "new")})
	if !errors.Is(e, portable.ErrFamily) {
		t.Fatal(e)
	}
}
func TestUploadLostAckAndFinalDigestOracle(t *testing.T) {
	data := bytes.Repeat([]byte{0x61}, int(backup.ChunkSize)+17)
	entry := backup.Entry{ID: "video", Kind: "video", Size: int64(len(data)), SHA256: digest(data), SourceExact: true}
	m := backup.Manifest{Version: 1, FamilyID: "family", BackupID: "backup", Entries: []backup.Entry{entry}}
	store, e := backup.New(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	defer store.Close()
	if e = store.Create(m); e != nil {
		t.Fatal(e)
	}
	first := data[:backup.ChunkSize]
	if _, e = store.Append("family", "backup", "video", 0, int64(len(first)), digest(first), bytes.NewReader(first)); e != nil {
		t.Fatal(e)
	}
	next, e := store.Append("family", "backup", "video", 0, int64(len(first)), digest(first), bytes.NewReader(first))
	if e != nil || next != backup.ChunkSize {
		t.Fatal(next, e)
	}
	partial := data[backup.ChunkSize:]
	if _, e = store.Append("family", "backup", "video", next, int64(len(partial)), digest(partial), io.LimitReader(bytes.NewReader(partial), 5)); e == nil {
		t.Fatal("接受断线半块")
	}
	status, e := store.Status("family", "backup")
	if e != nil || status.Entries[0].Offset != backup.ChunkSize {
		t.Fatal(status, e)
	}
	if _, e = store.Append("family", "backup", "video", next, int64(len(partial)), digest(partial), bytes.NewReader(partial)); e != nil {
		t.Fatal(e)
	}
	result, e := store.Finalize("family", "backup")
	if e != nil || !result.Complete || result.FullDeviceComplete {
		t.Fatal(result, e)
	}
}
