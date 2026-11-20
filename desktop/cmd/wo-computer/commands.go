package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/chunyiKit/Wo/desktop/internal/backup"
	"github.com/chunyiKit/Wo/desktop/internal/client"
	"github.com/chunyiKit/Wo/desktop/internal/portable"
	"github.com/chunyiKit/Wo/desktop/internal/vault"
)

type pairing struct {
	Server string `json:"server"`
	Pin    string `json:"pin"`
	Code   string `json:"code"`
	Family string `json:"family"`
	Device string `json:"device"`
}
type connection struct {
	Server string `json:"server"`
	Pin    string `json:"pin"`
	Token  string `json:"token"`
	Family string `json:"family"`
	Device string `json:"device"`
}

func readJSON(path string, private bool, out any) error {
	f, e := regular(path, private)
	if e != nil {
		return e
	}
	defer f.Close()
	raw, e := io.ReadAll(io.LimitReader(f, 8<<20+1))
	if e != nil {
		return e
	}
	if len(raw) > 8<<20 {
		return errors.New("JSON input too large")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if e = decoder.Decode(out); e != nil {
		return errors.New("invalid JSON file")
	}
	if decoder.Decode(new(any)) != io.EOF {
		return errors.New("trailing JSON data")
	}
	return nil
}
func validSecret(value string) bool {
	raw, e := hex.DecodeString(value)
	return e == nil && len(raw) == 32
}
func loadConnection(path string) (connection, *client.Client, error) {
	var v connection
	if e := readJSON(path, true, &v); e != nil {
		return v, nil, e
	}
	if !backup.ValidID(v.Family) || !backup.ValidID(v.Device) || !validSecret(v.Token) {
		return v, nil, errors.New("invalid connection identity")
	}
	c, e := client.New(v.Server, v.Pin, v.Token)
	return v, c, e
}
func sourceDirectory(path string) (*os.Root, error) {
	dir, e := safeDir(path, false, false)
	if e != nil {
		return nil, e
	}
	return os.OpenRoot(dir)
}
func openSource(root *os.Root, id string) (*os.File, error) {
	if !backup.ValidID(id) {
		return nil, errors.New("invalid source ID")
	}
	name := id + ".bin"
	info, e := root.Lstat(name)
	if e != nil {
		return nil, e
	}
	if !info.Mode().IsRegular() {
		return nil, errors.New("source must be a regular file, never a symlink")
	}
	f, e := root.Open(name)
	if e != nil {
		return nil, e
	}
	current, e := f.Stat()
	if e != nil || !os.SameFile(info, current) {
		f.Close()
		return nil, errors.New("source changed while opening")
	}
	return f, nil
}
func required(values ...string) error {
	for _, v := range values {
		if v == "" {
			return errors.New("required flag missing")
		}
	}
	return nil
}
func clientCommand(ctx context.Context, args []string, stdout, stderr io.Writer) error {
	switch args[0] {
	case "pair":
		return pairCommand(ctx, args[1:], stdout, stderr)
	case "upload", "fetch":
		return transferCommand(ctx, args[0], args[1:], stdout, stderr)
	case "pack-public", "pack-sealed":
		return packCommand(ctx, args[0], args[1:], stdout, stderr)
	case "restore-public", "restore-sealed":
		return restoreCommand(ctx, args[0], args[1:], stdout, stderr)
	default:
		return errors.New("unknown command")
	}
}
func pairCommand(ctx context.Context, args []string, stdout, stderr io.Writer) (err error) {
	var input, destination string
	err = parseFlags("pair", args, stderr, func(f *flag.FlagSet) {
		f.StringVar(&input, "pairing-file", "", "private pairing JSON")
		f.StringVar(&destination, "out", "", "new private connection JSON")
	})
	if err != nil {
		return err
	}
	if err = required(input, destination); err != nil {
		return err
	}
	var p pairing
	if err = readJSON(input, true, &p); err != nil {
		return err
	}
	if !backup.ValidID(p.Family) || !backup.ValidID(p.Device) || !validSecret(p.Code) {
		return errors.New("invalid pairing identity or code")
	}
	c, err := client.New(p.Server, p.Pin, "")
	if err != nil {
		return err
	}
	defer c.Close()
	file, err := newOutput(destination, "")
	if err != nil {
		return err
	}
	defer finishOutput(file, &err)
	token, err := c.Pair(ctx, p.Code, p.Family, p.Device)
	if err != nil {
		return err
	}
	err = json.NewEncoder(file).Encode(connection{p.Server, p.Pin, token, p.Family, p.Device})
	if err != nil {
		return err
	}
	if err = file.Sync(); err != nil {
		return err
	}
	// Never echo bearer token or pairing code.
	return output(stdout, map[string]any{"paired": true, "family": p.Family, "device": p.Device})
}
func transferCommand(ctx context.Context, command string, args []string, stdout, stderr io.Writer) error {
	var connPath, manifest, files, bid, cache string
	err := parseFlags(command, args, stderr, func(f *flag.FlagSet) {
		f.StringVar(&connPath, "connection", "", "private connection JSON")
		if command == "upload" {
			f.StringVar(&manifest, "manifest", "", "backup manifest JSON")
			f.StringVar(&files, "files", "", "read-only ID.bin source directory")
		} else {
			f.StringVar(&bid, "backup", "", "backup ID")
			f.StringVar(&cache, "cache", "", "dedicated non-Git byte cache")
		}
	})
	if err != nil {
		return err
	}
	if err = required(connPath); err != nil {
		return err
	}
	config, c, err := loadConnection(connPath)
	if err != nil {
		return err
	}
	defer c.Close()
	if command == "upload" {
		if err = required(manifest, files); err != nil {
			return err
		}
		var m backup.Manifest
		if err = readJSON(manifest, false, &m); err != nil {
			return err
		}
		if m.FamilyID != config.Family {
			return errors.New("connection family mismatch")
		}
		root, err := sourceDirectory(files)
		if err != nil {
			return err
		}
		defer root.Close()
		status, err := c.Upload(ctx, m, func(id string) (*os.File, error) { return openSource(root, id) })
		if err != nil {
			return err
		}
		return output(stdout, status)
	}
	if err = required(bid, cache); err != nil {
		return err
	}
	m, err := c.Manifest(ctx, bid)
	if err != nil {
		return err
	}
	if m.FamilyID != config.Family {
		return errors.New("connection family mismatch")
	}
	cache, err = safeDir(cache, true, true)
	if err != nil {
		return err
	}
	store, err := backup.New(cache)
	if err != nil {
		return err
	}
	defer store.Close()
	status, err := c.Fetch(ctx, m, store)
	if err != nil {
		return err
	}
	return output(stdout, status)
}
func loadKey(path string) ([]byte, error) {
	file, e := regular(path, true)
	if e != nil {
		return nil, e
	}
	defer file.Close()
	raw, e := io.ReadAll(io.LimitReader(file, 129))
	if e != nil {
		return nil, e
	}
	defer clear(raw)
	if len(raw) == 32 {
		return bytes.Clone(raw), nil
	}
	text := strings.TrimSpace(string(raw))
	if len(text) != 64 {
		return nil, vault.ErrKey
	}
	key, e := hex.DecodeString(text)
	if e != nil || len(key) != 32 {
		return nil, vault.ErrKey
	}
	return key, nil
}
func packCommand(ctx context.Context, command string, args []string, stdout, stderr io.Writer) (err error) {
	var manifest, files, destination, keyFile, bid, entry string
	err = parseFlags(command, args, stderr, func(f *flag.FlagSet) {
		f.StringVar(&manifest, "manifest", "", "portable inner manifest JSON")
		f.StringVar(&files, "files", "", "read-only ID.bin source directory")
		f.StringVar(&destination, "out", "", "new archive output")
		if command == "pack-sealed" {
			f.StringVar(&keyFile, "key-file", "", "private 32-byte or 64-hex key file")
			f.StringVar(&bid, "backup", "", "outer backup ID")
			f.StringVar(&entry, "entry", "", "outer sealed entry ID")
		}
	})
	if err != nil {
		return err
	}
	if err = required(manifest, files, destination); err != nil {
		return err
	}
	var m portable.Manifest
	if err = readJSON(manifest, false, &m); err != nil {
		return err
	}
	root, err := sourceDirectory(files)
	if err != nil {
		return err
	}
	defer root.Close()
	opener := func(id string) (io.ReadCloser, error) { return openSource(root, id) }
	suffix := ".wotar"
	var key []byte
	if command == "pack-sealed" {
		if err = required(keyFile, bid, entry); err != nil {
			return err
		}
		if !backup.ValidID(bid) || !backup.ValidID(entry) {
			return errors.New("invalid vault context")
		}
		key, err = loadKey(keyFile)
		if err != nil {
			return err
		}
		defer clear(key)
		suffix = ".woseal"
	}
	file, err := newOutput(destination, suffix)
	if err != nil {
		return err
	}
	defer finishOutput(file, &err)
	hash := sha256.New()
	counter := &countWriter{writer: io.MultiWriter(file, hash)}
	if command == "pack-public" {
		err = portable.Pack(ctx, counter, m, opener)
	} else {
		// No plaintext tar file: producer writes straight into the encryptor.
		reader, writer := io.Pipe()
		done := make(chan error, 1)
		go func() { e := portable.Pack(ctx, writer, m, opener); _ = writer.CloseWithError(e); done <- e }()
		_, err = vault.Encrypt(counter, reader, key, vault.Context{Family: m.FamilyID, Backup: bid, Entry: entry}, vault.Limits{})
		_ = reader.CloseWithError(err)
		err = errors.Join(err, <-done)
	}
	if err != nil {
		return err
	}
	if err = file.Sync(); err != nil {
		return err
	}
	// This digest always describes ciphertext for sealed archives, never inner bytes.
	return output(stdout, map[string]any{"size": counter.size, "sha256": hex.EncodeToString(hash.Sum(nil))})
}

type countWriter struct {
	writer io.Writer
	size   int64
}

func (c *countWriter) Write(p []byte) (int, error) {
	n, e := c.writer.Write(p)
	c.size += int64(n)
	return n, e
}
func restoreCommand(ctx context.Context, command string, args []string, stdout, stderr io.Writer) (err error) {
	var input, family, destination, keyFile, bid, entry string
	err = parseFlags(command, args, stderr, func(f *flag.FlagSet) {
		f.StringVar(&input, "file", "", "archive file")
		f.StringVar(&family, "family", "", "expected source family")
		f.StringVar(&destination, "out", "", "entirely new destination directory")
		if command == "restore-sealed" {
			f.StringVar(&keyFile, "key-file", "", "private recovery key file")
			f.StringVar(&bid, "backup", "", "bound backup ID")
			f.StringVar(&entry, "entry", "", "bound sealed entry ID")
		}
	})
	if err != nil {
		return err
	}
	if err = required(input, family, destination); err != nil {
		return err
	}
	if !backup.ValidID(family) {
		return errors.New("invalid expected family")
	}
	destination, err = safePath(destination)
	if err != nil {
		return err
	}
	if _, err = os.Lstat(destination); err == nil {
		return errors.New("restore destination exists")
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	parent, err := safeDir(filepath.Dir(destination), false, command == "restore-sealed")
	if err != nil {
		return err
	}
	source, err := regular(input, false)
	if err != nil {
		return err
	}
	defer source.Close()
	opts := portable.RestoreOptions{ExpectedFamilyID: family, Destination: destination}
	if command == "restore-public" {
		result, err := portable.Restore(ctx, source, opts)
		if err != nil {
			return err
		}
		return output(stdout, result)
	}
	if err = required(keyFile, bid, entry); err != nil {
		return err
	}
	if !backup.ValidID(bid) || !backup.ValidID(entry) {
		return errors.New("invalid vault context")
	}
	// Explicitly preserve the library's fail-closed Windows ACL boundary before staging.
	if runtime.GOOS == "windows" {
		return vault.ErrPrivateACLUnavailable
	}
	key, err := loadKey(keyFile)
	if err != nil {
		return err
	}
	defer clear(key)
	temp, err := os.MkdirTemp(parent, ".wo-private-")
	if err != nil {
		return err
	}
	own, err := os.Lstat(temp)
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, removeOwnedDirectory(temp, own)) }()
	root, err := os.OpenRoot(temp)
	if err != nil {
		return err
	}
	defer root.Close()
	_, err = vault.RestoreFile(root, "authenticated.wotar", source, key, vault.Context{Family: family, Backup: bid, Entry: entry}, vault.Limits{})
	if err != nil {
		return err
	}
	plain, err := root.Open("authenticated.wotar")
	if err != nil {
		return err
	}
	defer plain.Close()
	opts.RequirePrivateACL = true
	result, err := portable.Restore(ctx, plain, opts)
	if err != nil {
		return err
	}
	return output(stdout, result)
}
