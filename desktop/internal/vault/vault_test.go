package vault

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"
)

var testKey = bytes.Repeat([]byte{0x51}, 32)
var testContext = Context{Family: "synthetic-family", Backup: "synthetic-backup", Entry: "synthetic-entry"}

func seal(t *testing.T, plain []byte) ([]byte, Summary) {
	t.Helper()
	var dst bytes.Buffer
	s, err := Encrypt(&dst, bytes.NewReader(plain), testKey, testContext, Limits{})
	if err != nil {
		t.Fatal(err)
	}
	return dst.Bytes(), s
}
func openRoot(t *testing.T) (*os.Root, string) {
	t.Helper()
	path := t.TempDir()
	root, err := os.OpenRoot(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { root.Close() })
	return root, path
}
func noScratch(t *testing.T, path string) {
	t.Helper()
	entries, err := os.ReadDir(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".wo-vault-") {
			t.Fatalf("留下暂存 %s", entry.Name())
		}
	}
}

func TestRoundTripAndRandomization(t *testing.T) {
	for _, size := range []int{0, 1, ChunkBytes - 1, ChunkBytes, ChunkBytes + 1, 5*1024*1024 + 39} {
		t.Run(strconv.Itoa(size), func(t *testing.T) {
			plain := make([]byte, size)
			for i := range plain {
				plain[i] = byte(i*17 + 31)
			}
			encoded, summary := seal(t, plain)
			if summary.Bytes != int64(size) || summary.SHA256 != sha256.Sum256(plain) {
				t.Fatalf("摘要不符 %+v", summary)
			}
			verified, err := Verify(bytes.NewReader(encoded), testKey, testContext, Limits{})
			if err != nil || verified != summary {
				t.Fatalf("认证 %v %+v", err, verified)
			}
			root, path := openRoot(t)
			if runtime.GOOS == "windows" {
				if _, err := RestoreFile(root, "restored.bin", bytes.NewReader(encoded), testKey, testContext, Limits{}); !errors.Is(err, ErrPrivateACLUnavailable) {
					t.Fatal(err)
				}
				entries, err := os.ReadDir(path)
				if err != nil || len(entries) != 0 {
					t.Fatal("Windows 拒绝前写入了文件", err)
				}
				return
			}
			restored, err := RestoreFile(root, "restored.bin", bytes.NewReader(encoded), testKey, testContext, Limits{})
			if err != nil || restored != summary {
				t.Fatalf("恢复 %v", err)
			}
			data, err := os.ReadFile(filepath.Join(path, "restored.bin"))
			if err != nil || !bytes.Equal(data, plain) {
				t.Fatal("恢复内容不同", err)
			}
			noScratch(t, path)
			second, _ := seal(t, plain)
			if bytes.Equal(encoded, second) {
				t.Fatal("每次归档必须随机化")
			}
		})
	}
}

func TestOpaqueHeaderAndInspectionIsNotAuthentication(t *testing.T) {
	plain := []byte("PRIVATE-MARKER-NOT-FOR-SHARED-COMPUTER")
	encoded, _ := seal(t, plain)
	for _, private := range []string{string(plain), testContext.Family, testContext.Backup, testContext.Entry} {
		if bytes.Contains(encoded, []byte(private)) {
			t.Fatal("密文泄露输入")
		}
	}
	reader := bytes.NewReader(encoded)
	header, err := InspectHeader(reader)
	if err != nil || header.Version != 1 || header.ChunkSize != ChunkBytes || header.HeaderBytes != 52 || header.MinCiphertextBytes != 121 {
		t.Fatalf("头 %v %+v", err, header)
	}
	if reader.Len() != len(encoded)-HeaderBytes {
		t.Fatal("检查头不得消费内容")
	}
	if _, err = InspectHeader(bytes.NewReader(encoded[:HeaderBytes])); err != nil {
		t.Fatal("单独头在结构上有效", err)
	}
	if _, err = Verify(bytes.NewReader(encoded[:HeaderBytes]), testKey, testContext, Limits{}); !errors.Is(err, ErrInvalid) {
		t.Fatal("结构检查不能替代认证", err)
	}
	for _, offset := range []int{0, 5, 48, 51} {
		bad := bytes.Clone(encoded)
		bad[offset] ^= 1
		if _, err := InspectHeader(bytes.NewReader(bad)); !errors.Is(err, ErrInvalid) {
			t.Fatalf("坏头 %d", offset)
		}
	}
}

func TestKeyContextAndLimits(t *testing.T) {
	encoded, _ := seal(t, bytes.Repeat([]byte{3}, ChunkBytes+1))
	contexts := []Context{{Family: "other", Backup: testContext.Backup, Entry: testContext.Entry}, {Family: testContext.Family, Backup: "other", Entry: testContext.Entry}, {Family: testContext.Family, Backup: testContext.Backup, Entry: "other"}, {Family: "ab", Backup: "c", Entry: "d"}}
	for _, ctx := range contexts {
		if _, err := Verify(bytes.NewReader(encoded), testKey, ctx, Limits{}); !errors.Is(err, ErrInvalid) {
			t.Fatal("上下文未认证", err)
		}
	}
	wrong := bytes.Clone(testKey)
	wrong[0] ^= 1
	if _, err := Verify(bytes.NewReader(encoded), wrong, testContext, Limits{}); !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
	for _, key := range [][]byte{nil, make([]byte, 31), make([]byte, 33)} {
		if _, err := Verify(bytes.NewReader(encoded), key, testContext, Limits{}); !errors.Is(err, ErrKey) {
			t.Fatal(err)
		}
	}
	for _, ctx := range []Context{{}, {Family: "a", Backup: "b", Entry: "\x00"}, {Family: "a", Backup: "b", Entry: strings.Repeat("a", 4097)}} {
		if _, err := Encrypt(io.Discard, strings.NewReader(""), testKey, ctx, Limits{}); !errors.Is(err, ErrContext) {
			t.Fatal(err)
		}
	}
	for _, limit := range []Limits{{MaxPlaintext: -1}, {MaxPlaintext: HardMaxPlaintext + 1}, {MaxChunks: HardMaxChunks + 1}, {MaxPlaintext: ChunkBytes}, {MaxChunks: 1}} {
		if _, err := Verify(bytes.NewReader(encoded), testKey, testContext, limit); !errors.Is(err, ErrLimit) {
			t.Fatalf("应拒绝限制 %+v: %v", limit, err)
		}
		if _, err := Encrypt(io.Discard, bytes.NewReader(make([]byte, ChunkBytes+1)), testKey, testContext, limit); !errors.Is(err, ErrLimit) {
			t.Fatalf("写入限制 %+v: %v", limit, err)
		}
	}
	// 长度前缀区分连接后一样的上下文。
	a, _ := contextHash(Context{Family: "ab", Backup: "c", Entry: "d"})
	b, _ := contextHash(Context{Family: "a", Backup: "bc", Entry: "d"})
	if a == b {
		t.Fatal("上下文边界碰撞")
	}
}

func TestAllTruncationAndMutationReject(t *testing.T) {
	encoded, _ := seal(t, []byte("synthetic-secret"))
	for cut := 0; cut < len(encoded); cut++ {
		if _, err := Verify(bytes.NewReader(encoded[:cut]), testKey, testContext, Limits{}); err == nil {
			t.Fatalf("接受截断 %d", cut)
		}
	}
	for pos := range encoded {
		bad := bytes.Clone(encoded)
		bad[pos] ^= 0x80
		if _, err := Verify(bytes.NewReader(bad), testKey, testContext, Limits{}); err == nil {
			t.Fatalf("接受篡改 %d", pos)
		}
	}
	for _, suffix := range [][]byte{{0}, encoded} {
		bad := append(bytes.Clone(encoded), suffix...)
		if _, err := Verify(bytes.NewReader(bad), testKey, testContext, Limits{}); err == nil {
			t.Fatal("接受尾部附加")
		}
	}
}

func TestChunkReorderReplayAndSpliceReject(t *testing.T) {
	data := bytes.Repeat([]byte{42}, 2*ChunkBytes+3)
	encoded, _ := seal(t, data)
	other, _ := seal(t, data)
	block := frameBytes + ChunkBytes + 16
	first := HeaderBytes
	second := first + block
	third := second + block
	variants := [][]byte{}
	swapped := bytes.Clone(encoded)
	copy(swapped[first:second], encoded[second:third])
	copy(swapped[second:third], encoded[first:second])
	variants = append(variants, swapped)
	replay := bytes.Clone(encoded)
	copy(replay[second:third], encoded[first:second])
	variants = append(variants, replay)
	spliced := bytes.Clone(encoded)
	copy(spliced[second:third], other[second:third])
	variants = append(variants, spliced)
	oversized := bytes.Clone(encoded)
	binary.BigEndian.PutUint32(oversized[first+5:first+9], ^uint32(0))
	variants = append(variants, oversized)
	for i, bad := range variants {
		if _, err := Verify(bytes.NewReader(bad), testKey, testContext, Limits{}); err == nil {
			t.Fatalf("接受重排/重放/拼接/超大长度 %d", i)
		}
	}
}

type observingReader struct {
	reader io.Reader
	before func()
	once   sync.Once
}

func (r *observingReader) Read(p []byte) (int, error) { r.once.Do(r.before); return r.reader.Read(p) }

func TestFailureLeavesNoPlaintextAndPublicationWaits(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 明文恢复因缺已验证私有 ACL 而关闭")
	}
	encoded, _ := seal(t, bytes.Repeat([]byte{0x63}, ChunkBytes+1))
	for _, mode := range []string{"key", "corrupt", "context", "truncated", "limit"} {
		t.Run(mode, func(t *testing.T) {
			root, path := openRoot(t)
			key := bytes.Clone(testKey)
			ctx := testContext
			bad := bytes.Clone(encoded)
			limits := Limits{}
			switch mode {
			case "key":
				key[0] ^= 1
			case "corrupt":
				bad[len(bad)-1] ^= 1
			case "context":
				ctx.Entry = "other"
			case "truncated":
				bad = bad[:len(bad)-1]
			case "limit":
				limits.MaxPlaintext = 1
			}
			reader := &observingReader{reader: bytes.NewReader(bad), before: func() {
				if _, err := root.Lstat("restore.bin"); !errors.Is(err, os.ErrNotExist) {
					t.Fatal("验证前发布")
				}
				entries, _ := os.ReadDir(path)
				for _, e := range entries {
					if strings.Contains(e.Name(), "-plain-") {
						t.Fatal("首遍认证前出现明文暂存")
					}
				}
			}}
			if s, err := RestoreFile(root, "restore.bin", reader, key, ctx, limits); err == nil || s != (Summary{}) {
				t.Fatal("必须失败且无成功摘要", err)
			}
			entries, err := os.ReadDir(path)
			if err != nil || len(entries) != 0 {
				t.Fatalf("失败留下文件: %+v %v", entries, err)
			}
		})
	}
	root, _ := openRoot(t)
	if _, err := RestoreFile(root, "nil.bin", nil, testKey, testContext, Limits{}); !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
}

func TestDestinationSafetyAndRace(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 明文恢复因缺已验证私有 ACL 而关闭")
	}
	encoded, _ := seal(t, []byte("new"))
	root, path := openRoot(t)
	if err := os.WriteFile(filepath.Join(path, "existing"), []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := RestoreFile(root, "existing", bytes.NewReader(encoded), testKey, testContext, Limits{}); !errors.Is(err, ErrDestination) {
		t.Fatal(err)
	}
	if err := os.Symlink("existing", filepath.Join(path, "link")); err != nil {
		t.Skip("平台无法创建符号链接", err)
	}
	if _, err := RestoreFile(root, "link", bytes.NewReader(encoded), testKey, testContext, Limits{}); !errors.Is(err, ErrDestination) {
		t.Fatal(err)
	}
	for _, name := range []string{"", ".", "..", "../escape", "a/b", "a\\b", "C:stream", "CON", "nul.txt", "COM1.bin", "LPT9", "a.", " leading", "a\n", "a\x00"} {
		if _, err := RestoreFile(root, name, bytes.NewReader(encoded), testKey, testContext, Limits{}); !errors.Is(err, ErrDestination) {
			t.Fatalf("非法文件名 %q: %v", name, err)
		}
	}
	for _, kind := range []string{"file", "symlink"} {
		name := "race-" + kind
		reader := &observingReader{reader: bytes.NewReader(encoded), before: func() {
			var err error
			if kind == "file" {
				err = os.WriteFile(filepath.Join(path, name), []byte("winner"), 0600)
			} else {
				err = os.Symlink("existing", filepath.Join(path, name))
			}
			if err != nil {
				t.Fatal(err)
			}
		}}
		if _, err := RestoreFile(root, name, reader, testKey, testContext, Limits{}); !errors.Is(err, ErrDestination) {
			t.Fatal("不得覆盖并发目的地", err)
		}
	}
	keep, _ := os.ReadFile(filepath.Join(path, "existing"))
	if string(keep) != "keep" {
		t.Fatal("改动已有文件")
	}
	winner, _ := os.ReadFile(filepath.Join(path, "race-file"))
	if string(winner) != "winner" {
		t.Fatal("覆盖并发文件")
	}
	noScratch(t, path)
}

func TestConcurrentRestoreHasOneWinner(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 明文恢复因缺已验证私有 ACL 而关闭")
	}
	encoded, _ := seal(t, make([]byte, ChunkBytes*3))
	root, path := openRoot(t)
	results := make(chan error, 8)
	var start sync.WaitGroup
	start.Add(1)
	for i := 0; i < 8; i++ {
		go func() {
			start.Wait()
			_, err := RestoreFile(root, "one.bin", bytes.NewReader(encoded), testKey, testContext, Limits{})
			results <- err
		}()
	}
	start.Done()
	success := 0
	for i := 0; i < 8; i++ {
		err := <-results
		if err == nil {
			success++
		} else if !errors.Is(err, ErrDestination) {
			t.Fatal(err)
		}
	}
	if success != 1 {
		t.Fatalf("获胜数 %d", success)
	}
	noScratch(t, path)
}

type shortReader struct{ reader io.Reader }

func (s shortReader) Read(p []byte) (int, error) { return s.reader.Read(p[:min(7, len(p))]) }

type shortWriter struct{ bytes.Buffer }

func (s *shortWriter) Write(p []byte) (int, error) { return s.Buffer.Write(p[:min(5, len(p))]) }

type emptyReader struct{}

func (emptyReader) Read([]byte) (int, error) { return 0, nil }

type failingReader struct{}

func (failingReader) Read([]byte) (int, error) { return 0, errors.New("synthetic IO failure") }

type failingWriter struct{}

func (failingWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }

func TestShortIOAndNoProgress(t *testing.T) {
	plain := bytes.Repeat([]byte{2}, ChunkBytes+4)
	var dst shortWriter
	summary, err := Encrypt(&dst, shortReader{bytes.NewReader(plain)}, testKey, testContext, Limits{})
	if err != nil {
		t.Fatal(err)
	}
	s, err := Verify(shortReader{bytes.NewReader(dst.Bytes())}, testKey, testContext, Limits{})
	if err != nil || s != summary {
		t.Fatal(err)
	}
	if _, err := Encrypt(io.Discard, emptyReader{}, testKey, testContext, Limits{}); !errors.Is(err, io.ErrNoProgress) {
		t.Fatal("无进度必须有界退出", err)
	}
	if _, err := Encrypt(io.Discard, failingReader{}, testKey, testContext, Limits{}); err == nil {
		t.Fatal("忽略读取错误")
	}
	if _, err := Encrypt(failingWriter{}, bytes.NewReader(plain), testKey, testContext, Limits{}); !errors.Is(err, io.ErrClosedPipe) {
		t.Fatal(err)
	}
	if _, err := Verify(emptyReader{}, testKey, testContext, Limits{}); err == nil {
		t.Fatal("无进度读取不能通过")
	}
}

func TestAuthenticatedMalformedStructureReject(t *testing.T) {
	// 已持钥的坏写入器也不能省略全档摘要或制造非规范分块。
	empty, _ := seal(t, nil)
	header := empty[:HeaderBytes]
	ctx, _ := contextHash(testContext)
	aead, err := cryptor(testKey, header, ctx)
	if err != nil {
		t.Fatal(err)
	}
	type part struct {
		kind byte
		seq  uint32
		data []byte
	}
	footer := func(total uint64, chunks uint32, hash [32]byte) []byte {
		b := make([]byte, footerBytes)
		binary.BigEndian.PutUint64(b[:8], total)
		binary.BigEndian.PutUint32(b[8:12], chunks)
		copy(b[12:], hash[:])
		return b
	}
	small := []byte("partial")
	digest := sha256.Sum256(small)
	cases := [][]part{
		{{dataFrame, 0, small}, {finalFrame, 1, footer(uint64(len(small)+1), 1, digest)}},
		{{dataFrame, 0, small}, {finalFrame, 1, footer(uint64(len(small)), 2, digest)}},
		{{dataFrame, 0, small}, {finalFrame, 1, footer(uint64(len(small)), 1, [32]byte{})}},
		{{dataFrame, 0, small}, {dataFrame, 1, small}, {finalFrame, 2, footer(14, 2, sha256.Sum256(append(bytes.Clone(small), small...)))}},
		{{dataFrame, 1, small}},
		{{dataFrame, 0, nil}},
		{{3, 0, small}},
	}
	for i, parts := range cases {
		encoded := bytes.Clone(header)
		for _, p := range parts {
			desc := frame(p.kind, p.seq, len(p.data))
			encoded = append(encoded, desc...)
			encoded = append(encoded, aead.Seal(nil, nonce(header, p.seq), p.data, aad(header, ctx, desc))...)
		}
		if _, err := Verify(bytes.NewReader(encoded), testKey, testContext, Limits{}); err == nil {
			t.Fatalf("接受已认证但非规范结构 %d", i)
		}
	}
}

type checkingReader struct {
	reader io.Reader
	check  func()
}

func (r checkingReader) Read(p []byte) (int, error) { r.check(); return r.reader.Read(p) }

func TestEntireInputVerifiedBeforeAnyPlaintextStaging(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 明文恢复因缺已验证私有 ACL 而关闭")
	}
	encoded, _ := seal(t, make([]byte, 2*ChunkBytes+1))
	root, path := openRoot(t)
	calls := 0
	reader := checkingReader{reader: shortReader{bytes.NewReader(encoded)}, check: func() {
		calls++
		if _, err := root.Lstat("verified.bin"); !errors.Is(err, os.ErrNotExist) {
			t.Fatal("输入尚未读完即发布")
		}
		entries, err := os.ReadDir(path)
		if err != nil {
			t.Fatal(err)
		}
		for _, e := range entries {
			if strings.Contains(e.Name(), "-plain-") {
				t.Fatal("全归档认证前落盘明文")
			}
		}
	}}
	if _, err := RestoreFile(root, "verified.bin", reader, testKey, testContext, Limits{}); err != nil {
		t.Fatal(err)
	}
	if calls < 20 {
		t.Fatal("测试未覆盖分块输入")
	}
	noScratch(t, path)
}

func TestPrivateRestorePolicy(t *testing.T) {
	for _, goos := range []string{"windows", "linux", "darwin"} {
		err := privateRestorePolicy(goos)
		if goos == "windows" {
			if !errors.Is(err, ErrPrivateACLUnavailable) {
				t.Fatalf("Windows 必须拒绝: %v", err)
			}
		} else if err != nil {
			t.Fatalf("%s 调用者可信私有root策略应允许: %v", goos, err)
		}
	}
}

func TestWindowsRestoreRejectsBeforeInputOrStaging(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("需要 Windows 原生执行；Linux 已独立覆盖纯策略函数")
	}
	root, path := openRoot(t)
	reader := checkingReader{reader: strings.NewReader("unread"), check: func() { t.Fatal("Windows 拒绝前不应读取输入") }}
	if summary, err := RestoreFile(root, "private.bin", reader, testKey, testContext, Limits{}); !errors.Is(err, ErrPrivateACLUnavailable) || summary != (Summary{}) {
		t.Fatal("Windows 未在恢复入口关闭", err)
	}
	entries, err := os.ReadDir(path)
	if err != nil || len(entries) != 0 {
		t.Fatal("Windows 拒绝前不应创建任何暂存", err)
	}
}
