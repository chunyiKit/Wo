package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// safePath rejects repository ancestors and every symlink component, including
// dangling links. Its final component may be absent; it never removes anything.
func safePath(path string) (string, error) {
	if path == "" {
		return "", errors.New("path required")
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	abs = filepath.Clean(abs)
	if filepath.Dir(abs) == abs {
		return "", errors.New("filesystem root is not an application directory")
	}
	for p := abs; ; p = filepath.Dir(p) {
		info, e := os.Lstat(p)
		if e == nil && info.Mode()&os.ModeSymlink != 0 {
			return "", errors.New("symlink path refused")
		}
		if e != nil && !errors.Is(e, os.ErrNotExist) {
			return "", e
		}
		if info != nil && info.IsDir() {
			if _, e = os.Lstat(filepath.Join(p, ".git")); e == nil {
				return "", errors.New("Git work tree is not a data destination")
			} else if !errors.Is(e, os.ErrNotExist) {
				return "", e
			}
		}
		if filepath.Dir(p) == p {
			break
		}
	}
	return abs, nil
}
func safeDir(path string, create bool, private bool) (string, error) {
	abs, e := safePath(path)
	if e != nil {
		return "", e
	}
	if create {
		if e = os.MkdirAll(abs, 0700); e != nil {
			return "", e
		}
	}
	abs, e = safePath(abs)
	if e != nil {
		return "", e
	}
	info, e := os.Lstat(abs)
	if e != nil {
		return "", e
	}
	if !info.IsDir() {
		return "", errors.New("real directory required")
	}
	if private && runtime.GOOS != "windows" && info.Mode().Perm()&0077 != 0 {
		return "", errors.New("private directory requires mode 0700")
	}
	return abs, nil
}
func defaultDataPath() (string, error) {
	home, e := os.UserHomeDir()
	if e != nil {
		return "", e
	}
	config := ""
	if runtime.GOOS != "darwin" && runtime.GOOS != "windows" {
		config, e = os.UserConfigDir()
		if e != nil {
			return "", e
		}
	}
	return platformDataPath(runtime.GOOS, home, config, os.Getenv("LOCALAPPDATA"))
}
func platformDataPath(goos, home, config, local string) (string, error) {
	var path string
	switch goos {
	case "darwin":
		path = filepath.Join(home, "Library", "Application Support", "Wo", "Backups")
	case "windows":
		if local == "" || !filepath.IsAbs(local) {
			return "", errors.New("absolute LOCALAPPDATA required")
		}
		path = filepath.Join(local, "Wo", "Backups")
	default:
		if config == "" || !filepath.IsAbs(config) {
			return "", errors.New("absolute user config directory required")
		}
		path = filepath.Join(config, "Wo", "Backups")
	}
	for _, part := range strings.FieldsFunc(path, func(r rune) bool { return r == '/' || r == '\\' }) {
		if strings.EqualFold(part, "Desktop") || strings.EqualFold(part, "Documents") || strings.HasPrefix(strings.ToLower(part), "onedrive") {
			return "", errors.New("default data directory would be inside a synced folder; choose explicit private --data")
		}
	}
	return path, nil
}
func regular(path string, private bool) (*os.File, error) {
	abs, e := safePath(path)
	if e != nil {
		return nil, e
	}
	info, e := os.Lstat(abs)
	if e != nil {
		return nil, e
	}
	if !info.Mode().IsRegular() {
		return nil, errors.New("regular file required")
	}
	if private && runtime.GOOS != "windows" && info.Mode().Perm()&0077 != 0 {
		return nil, errors.New("credential file requires mode 0600")
	}
	f, e := os.Open(abs)
	if e != nil {
		return nil, e
	}
	current, e := f.Stat()
	if e != nil || !os.SameFile(info, current) {
		f.Close()
		return nil, errors.New("file changed while opening")
	}
	return f, nil
}
func newOutput(path, suffix string) (*os.File, error) {
	if !strings.HasSuffix(path, suffix) {
		return nil, fmt.Errorf("output must end in %s", suffix)
	}
	abs, e := safePath(path)
	if e != nil {
		return nil, e
	}
	if _, e = safeDir(filepath.Dir(abs), false, false); e != nil {
		return nil, e
	}
	return os.OpenFile(abs, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
}

// Include close failures in rollback; unlink only this command's original inode.
func finishOutput(file *os.File, err *error) {
	own, statErr := file.Stat()
	*err = errors.Join(*err, statErr, file.Close())
	if *err == nil {
		return
	}
	if own == nil {
		return
	}
	current, e := os.Lstat(file.Name())
	if errors.Is(e, os.ErrNotExist) {
		return
	}
	if e != nil {
		*err = errors.Join(*err, e)
		return
	}
	if !os.SameFile(own, current) {
		*err = errors.Join(*err, errors.New("output replaced; refusing cleanup"))
		return
	}
	*err = errors.Join(*err, os.Remove(file.Name()))
}

func removeOwnedDirectory(path string, own os.FileInfo) error {
	current, e := os.Lstat(path)
	if errors.Is(e, os.ErrNotExist) {
		return nil
	}
	if e != nil {
		return e
	}
	if !os.SameFile(own, current) {
		return errors.New("temporary directory replaced; refusing cleanup")
	}
	return os.RemoveAll(path)
}
