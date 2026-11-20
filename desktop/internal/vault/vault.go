// Package vault 提供仅恢复者持钥的分块加密容器。
//
// 服务端只能保存密文。Context 不写入头部；所有字段以定长长度前缀绑定到
// KDF/AAD。完整性必须经 Verify 或 RestoreFile 检查，InspectHeader 不作认证。
package vault

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"runtime"
	"strings"
	"unicode/utf8"
)

const (
	ChunkBytes                 = 64 * 1024
	HeaderBytes                = 8 + 32 + 8 + 4
	frameBytes                 = 1 + 4 + 4
	footerBytes                = 8 + 4 + sha256.Size
	MinCiphertextBytes         = HeaderBytes + frameBytes + footerBytes + 16
	DefaultMaxPlaintext int64  = 64 << 30
	DefaultMaxChunks    uint32 = 1 << 20
	HardMaxPlaintext    int64  = 1 << 40
	HardMaxChunks       uint32 = 1 << 24
	dataFrame           byte   = 1
	finalFrame          byte   = 2
)

var (
	magic                    = []byte("WOVLT1\r\n")
	ErrInvalid               = errors.New("加密归档无效或完整性认证失败")
	ErrKey                   = errors.New("恢复密钥必须为32字节")
	ErrContext               = errors.New("归档上下文无效")
	ErrLimit                 = errors.New("归档超过资源限制")
	ErrDestination           = errors.New("恢复目的地必须是不存在的安全文件名")
	ErrCleanup               = errors.New("本地文件系统未能清理恢复暂存，请隔离接收目录")
	ErrPrivateACLUnavailable = errors.New("Windows 尚未实现并验证私有 ACL，禁止明文恢复")
)

type Context struct{ Family, Backup, Entry string }
type Limits struct {
	MaxPlaintext int64
	MaxChunks    uint32
}
type Summary struct {
	Bytes  int64
	Chunks uint32
	SHA256 [sha256.Size]byte
}

// Header 仅表示公开固定头结构可解析，不证明密文完整、密钥正确或来源可信。
// InspectHeader 只读取 HeaderBytes，MinCiphertextBytes 需调用者对实际文件大小另查。
type Header struct {
	Version            int
	ChunkSize          int
	HeaderBytes        int
	MinCiphertextBytes int
}

func normalize(l Limits) (Limits, error) {
	if l.MaxPlaintext == 0 {
		l.MaxPlaintext = DefaultMaxPlaintext
	}
	if l.MaxChunks == 0 {
		l.MaxChunks = DefaultMaxChunks
	}
	if l.MaxPlaintext < 0 || l.MaxPlaintext > HardMaxPlaintext || l.MaxChunks > HardMaxChunks {
		return Limits{}, ErrLimit
	}
	return l, nil
}

func contextHash(context Context) ([sha256.Size]byte, error) {
	h := sha256.New()
	h.Write([]byte("WoVault/context/v1\x00"))
	for _, value := range []string{context.Family, context.Backup, context.Entry} {
		if len(value) == 0 || len(value) > 4096 || !utf8.ValidString(value) || strings.IndexByte(value, 0) >= 0 {
			return [sha256.Size]byte{}, ErrContext
		}
		var size [4]byte
		binary.BigEndian.PutUint32(size[:], uint32(len(value)))
		h.Write(size[:])
		h.Write([]byte(value))
	}
	var result [sha256.Size]byte
	copy(result[:], h.Sum(nil))
	return result, nil
}

// RFC 5869 HKDF-SHA256，避免引入非标准库依赖。
func derive(key, salt []byte, context [sha256.Size]byte) []byte {
	extract := hmac.New(sha256.New, salt)
	extract.Write(key)
	prk := extract.Sum(nil)
	expand := hmac.New(sha256.New, prk)
	expand.Write([]byte("WoVault/AES256GCM/v1\x00"))
	expand.Write(context[:])
	expand.Write([]byte{1})
	result := expand.Sum(nil)
	clear(prk)
	return result
}

func cryptor(key, header []byte, context [sha256.Size]byte) (cipher.AEAD, error) {
	if len(key) != 32 {
		return nil, ErrKey
	}
	derived := derive(key, header[8:40], context)
	defer clear(derived)
	block, err := aes.NewCipher(derived)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

func readFull(reader io.Reader, p []byte) (int, error) {
	total, empty := 0, 0
	for total < len(p) {
		n, err := reader.Read(p[total:])
		if n < 0 || n > len(p)-total {
			return total, ErrInvalid
		}
		total += n
		if total == len(p) {
			return total, nil
		}
		if err != nil {
			if err == io.EOF && total > 0 {
				err = io.ErrUnexpectedEOF
			}
			return total, err
		}
		if n == 0 {
			empty++
			if empty >= 100 {
				return total, io.ErrNoProgress
			}
		} else {
			empty = 0
		}
	}
	return total, nil
}

func writeFull(writer io.Writer, p []byte) error {
	for len(p) > 0 {
		n, err := writer.Write(p)
		if n < 0 || n > len(p) {
			return io.ErrShortWrite
		}
		p = p[n:]
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
	}
	return nil
}

func readHeader(reader io.Reader) ([]byte, error) {
	raw := make([]byte, HeaderBytes)
	if _, err := readFull(reader, raw); err != nil {
		return nil, ErrInvalid
	}
	if !bytes.Equal(raw[:8], magic) || binary.BigEndian.Uint32(raw[48:52]) != ChunkBytes {
		return nil, ErrInvalid
	}
	return raw, nil
}

func InspectHeader(reader io.Reader) (Header, error) {
	if reader == nil {
		return Header{}, ErrInvalid
	}
	if _, err := readHeader(reader); err != nil {
		return Header{}, err
	}
	return Header{Version: 1, ChunkSize: ChunkBytes, HeaderBytes: HeaderBytes, MinCiphertextBytes: MinCiphertextBytes}, nil
}

func frame(kind byte, sequence uint32, size int) []byte {
	raw := make([]byte, frameBytes)
	raw[0] = kind
	binary.BigEndian.PutUint32(raw[1:5], sequence)
	binary.BigEndian.PutUint32(raw[5:9], uint32(size))
	return raw
}
func nonce(header []byte, sequence uint32) []byte {
	raw := make([]byte, 12)
	copy(raw[:8], header[40:48])
	binary.BigEndian.PutUint32(raw[8:], sequence)
	return raw
}
func aad(header []byte, context [sha256.Size]byte, frame []byte) []byte {
	raw := make([]byte, 0, len(header)+len(context)+len(frame)+20)
	raw = append(raw, []byte("WoVault/frame/v1\x00")...)
	raw = append(raw, header...)
	raw = append(raw, context[:]...)
	return append(raw, frame...)
}

// Encrypt 以固定内存流式写密文。失败可留下不可用的密文前缀，调用者须先暂存，
// 不得把错误返回前的输出发布成完整归档；本函数从不更改调用者密钥。
func Encrypt(dst io.Writer, src io.Reader, key []byte, context Context, limits Limits) (Summary, error) {
	var result Summary
	if len(key) != 32 {
		return result, ErrKey
	}
	if src == nil || dst == nil {
		return result, ErrInvalid
	}
	ctx, err := contextHash(context)
	if err != nil {
		return result, err
	}
	limits, err = normalize(limits)
	if err != nil {
		return result, err
	}
	header := make([]byte, HeaderBytes)
	copy(header, magic)
	if _, err = rand.Read(header[8:48]); err != nil {
		return result, err
	}
	binary.BigEndian.PutUint32(header[48:], ChunkBytes)
	aead, err := cryptor(key, header, ctx)
	if err != nil {
		return result, err
	}
	if err = writeFull(dst, header); err != nil {
		return Summary{}, err
	}
	plain := make([]byte, ChunkBytes)
	defer clear(plain)
	encrypted := make([]byte, 0, ChunkBytes+aead.Overhead())
	defer func() { clear(encrypted[:cap(encrypted)]) }()
	digest := sha256.New()
	for {
		n, readErr := readFull(src, plain)
		if readErr != nil && readErr != io.EOF && readErr != io.ErrUnexpectedEOF {
			return Summary{}, readErr
		}
		if n > 0 {
			if result.Chunks >= limits.MaxChunks || int64(n) > limits.MaxPlaintext-result.Bytes {
				return Summary{}, ErrLimit
			}
			descriptor := frame(dataFrame, result.Chunks, n)
			encrypted = aead.Seal(encrypted[:0], nonce(header, result.Chunks), plain[:n], aad(header, ctx, descriptor))
			if err = writeFull(dst, descriptor); err != nil {
				return Summary{}, err
			}
			if err = writeFull(dst, encrypted); err != nil {
				return Summary{}, err
			}
			digest.Write(plain[:n])
			result.Bytes += int64(n)
			result.Chunks++
			clear(plain[:n])
		}
		if readErr != nil {
			break
		}
	}
	copy(result.SHA256[:], digest.Sum(nil))
	footer := make([]byte, footerBytes)
	defer clear(footer)
	binary.BigEndian.PutUint64(footer[:8], uint64(result.Bytes))
	binary.BigEndian.PutUint32(footer[8:12], result.Chunks)
	copy(footer[12:], result.SHA256[:])
	descriptor := frame(finalFrame, result.Chunks, len(footer))
	encrypted = aead.Seal(encrypted[:0], nonce(header, result.Chunks), footer, aad(header, ctx, descriptor))
	if err = writeFull(dst, descriptor); err != nil {
		return Summary{}, err
	}
	if err = writeFull(dst, encrypted); err != nil {
		return Summary{}, err
	}
	return result, nil
}

func eof(reader io.Reader) error {
	var b [1]byte
	for attempt := 0; attempt < 100; attempt++ {
		n, err := reader.Read(b[:])
		if n != 0 {
			return ErrInvalid
		}
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return ErrInvalid
		}
	}
	return io.ErrNoProgress
}

// decrypt 仅供内部 Verify 和私有暂存使用；不会将部分认证明文交给外部调用者。
func decrypt(dst io.Writer, src io.Reader, key []byte, context Context, limits Limits) (Summary, error) {
	var result Summary
	if len(key) != 32 {
		return result, ErrKey
	}
	if src == nil || dst == nil {
		return result, ErrInvalid
	}
	ctx, err := contextHash(context)
	if err != nil {
		return result, err
	}
	limits, err = normalize(limits)
	if err != nil {
		return result, err
	}
	header, err := readHeader(src)
	if err != nil {
		return result, err
	}
	aead, err := cryptor(key, header, ctx)
	if err != nil {
		return result, err
	}
	buffer := make([]byte, ChunkBytes+aead.Overhead())
	defer clear(buffer)
	digest := sha256.New()
	partial := false
	for {
		descriptor := make([]byte, frameBytes)
		if _, err = readFull(src, descriptor); err != nil {
			return Summary{}, ErrInvalid
		}
		kind, sequence, size := descriptor[0], binary.BigEndian.Uint32(descriptor[1:5]), binary.BigEndian.Uint32(descriptor[5:9])
		if sequence != result.Chunks {
			return Summary{}, ErrInvalid
		}
		if kind == dataFrame {
			if partial || size == 0 || size > ChunkBytes {
				return Summary{}, ErrInvalid
			}
			if result.Chunks >= limits.MaxChunks || int64(size) > limits.MaxPlaintext-result.Bytes {
				return Summary{}, ErrLimit
			}
		} else if kind != finalFrame || size != footerBytes {
			return Summary{}, ErrInvalid
		}
		encrypted := buffer[:int(size)+aead.Overhead()]
		if _, err = readFull(src, encrypted); err != nil {
			return Summary{}, ErrInvalid
		}
		plaintext, err := aead.Open(encrypted[:0], nonce(header, sequence), encrypted, aad(header, ctx, descriptor))
		if err != nil {
			return Summary{}, ErrInvalid
		}
		if kind == finalFrame {
			copy(result.SHA256[:], digest.Sum(nil))
			valid := binary.BigEndian.Uint64(plaintext[:8]) == uint64(result.Bytes) && binary.BigEndian.Uint32(plaintext[8:12]) == result.Chunks && subtle.ConstantTimeCompare(plaintext[12:], result.SHA256[:]) == 1
			clear(plaintext)
			if !valid {
				return Summary{}, ErrInvalid
			}
			if err = eof(src); err != nil {
				return Summary{}, err
			}
			return result, nil
		}
		digest.Write(plaintext)
		if err = writeFull(dst, plaintext); err != nil {
			clear(plaintext)
			return Summary{}, err
		}
		result.Bytes += int64(size)
		result.Chunks++
		partial = size < ChunkBytes
		clear(plaintext)
	}
}

// Verify 认证全部分块、顺序、footer 和 EOF；不创建明文文件或修改输入。
func Verify(src io.Reader, key []byte, context Context, limits Limits) (Summary, error) {
	return decrypt(io.Discard, src, key, context, limits)
}

func safeLeaf(name string) bool {
	if name == "" || len(name) > 200 || name == "." || name == ".." || !utf8.ValidString(name) || strings.ContainsAny(name, "/\\:\x00<>\"|?*") || strings.TrimSpace(name) != name || strings.HasSuffix(name, ".") {
		return false
	}
	for _, r := range name {
		if r < 32 || r == 127 {
			return false
		}
	}
	base := strings.ToUpper(strings.TrimRight(strings.Split(name, ".")[0], " ."))
	if base == "CON" || base == "PRN" || base == "AUX" || base == "NUL" {
		return false
	}
	for _, prefix := range []string{"COM", "LPT"} {
		if len(base) == 4 && strings.HasPrefix(base, prefix) && base[3] >= '1' && base[3] <= '9' {
			return false
		}
	}
	return true
}

func temporary(root *os.Root, kind string) (*os.File, string, error) {
	for attempt := 0; attempt < 10; attempt++ {
		var random [16]byte
		if _, err := rand.Read(random[:]); err != nil {
			return nil, "", err
		}
		name := ".wo-vault-" + kind + "-" + hex.EncodeToString(random[:]) + ".tmp"
		file, err := root.OpenFile(name, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0600)
		if errors.Is(err, os.ErrExist) {
			continue
		}
		return file, name, err
	}
	return nil, "", errors.New("无法创建唯一恢复暂存")
}

// privateRestorePolicy 不把 Windows 的 mode 0600/0700 当作私有 ACL 证明。
func privateRestorePolicy(goos string) error {
	if goos == "windows" {
		return ErrPrivateACLUnavailable
	}
	return nil
}

// RestoreFile 在调用者打开的可信私有 root 内创建新文件。name 必须是安全叶名，
// 不接收路径。root 不能由未授权的共享目录/符号链接临时推断为可信目录。
// Windows 缺少已验证的私有 ACL 实现，先于任何输入读取或暂存返回 ErrPrivateACLUnavailable。
//
// 首遍只落密文并完整验证；错误密钥、上下文、损坏、截断不会创建明文暂存。
// 第二遍只在私有临时文件解密，完整复验和 fsync 后才用原子不覆盖的 hard link
// 发布。文件系统不支持 hard link 时返回错误，不退回覆盖式 rename。
// 普通失败清理自己创建的文件；若本地文件系统拒绝清理返回 ErrCleanup，调用者
// 必须隔离该目录，不得声称物理安全擦除。私有目录不可同时被不可信进程修改。
func RestoreFile(root *os.Root, name string, src io.Reader, key []byte, context Context, limits Limits) (result Summary, err error) {
	if err = privateRestorePolicy(runtime.GOOS); err != nil {
		return result, err
	}
	if root == nil || !safeLeaf(name) {
		return result, ErrDestination
	}
	if src == nil {
		return result, ErrInvalid
	}
	if _, statErr := root.Lstat(name); statErr == nil || !errors.Is(statErr, os.ErrNotExist) {
		return result, ErrDestination
	}
	// 在任何暂存前验证调用参数。
	if len(key) != 32 {
		return result, ErrKey
	}
	if _, err = contextHash(context); err != nil {
		return Summary{}, err
	}
	if _, err = normalize(limits); err != nil {
		return Summary{}, err
	}
	encrypted, cipherName, err := temporary(root, "cipher")
	if err != nil {
		return Summary{}, err
	}
	var plaintext *os.File
	var ownInfo os.FileInfo
	plainName := ""
	published := false
	defer func() {
		if plaintext != nil {
			if closeErr := plaintext.Close(); closeErr != nil && !errors.Is(closeErr, os.ErrClosed) {
				err = errors.Join(err, closeErr)
			}
		}
		if closeErr := encrypted.Close(); closeErr != nil {
			err = errors.Join(err, closeErr)
		}
		var cleanup error
		for _, path := range []string{plainName, cipherName} {
			if path != "" {
				if removeErr := root.Remove(path); removeErr != nil && !errors.Is(removeErr, os.ErrNotExist) {
					cleanup = errors.Join(cleanup, removeErr)
				}
			}
		}
		if cleanup != nil {
			err = errors.Join(err, ErrCleanup, cleanup)
		}
		if err != nil && published && ownInfo != nil {
			// 仅回滚自己独占发布的 inode，不能删除后来由其它进程放入的目的文件。
			if current, currentErr := root.Lstat(name); currentErr == nil && os.SameFile(ownInfo, current) {
				if removeErr := root.Remove(name); removeErr != nil && !errors.Is(removeErr, os.ErrNotExist) {
					err = errors.Join(err, ErrCleanup, removeErr)
				}
			}
		}
		if err != nil {
			result = Summary{}
		}
	}()
	first, err := Verify(io.TeeReader(src, encrypted), key, context, limits)
	if err != nil {
		return Summary{}, err
	}
	if err = encrypted.Sync(); err != nil {
		return Summary{}, err
	}
	if _, err = encrypted.Seek(0, io.SeekStart); err != nil {
		return Summary{}, err
	}
	plaintext, plainName, err = temporary(root, "plain")
	if err != nil {
		return Summary{}, err
	}
	second, err := decrypt(plaintext, encrypted, key, context, limits)
	if err != nil {
		return Summary{}, err
	}
	if first != second {
		return Summary{}, ErrInvalid
	}
	if err = plaintext.Sync(); err != nil {
		return Summary{}, err
	}
	ownInfo, err = plaintext.Stat()
	if err != nil {
		return Summary{}, err
	}
	if err = plaintext.Close(); err != nil {
		return Summary{}, err
	}
	// 即便攻击者在第一次 Lstat 后创建文件/符号链接，Link 也不会覆盖它。
	if err = root.Link(plainName, name); err != nil {
		if errors.Is(err, os.ErrExist) {
			return Summary{}, ErrDestination
		}
		return Summary{}, err
	}
	published = true
	finalInfo, err := root.Lstat(name)
	if err != nil {
		return Summary{}, err
	}
	if !finalInfo.Mode().IsRegular() || !os.SameFile(ownInfo, finalInfo) {
		return Summary{}, ErrDestination
	}
	return second, nil
}

// FormatDescription 只用于本地诊断，无密钥、Context 或明文摘要。
func FormatDescription() string {
	return fmt.Sprintf("WoVault v1: AES-256-GCM, %d-byte chunks, %d-byte header", ChunkBytes, HeaderBytes)
}
