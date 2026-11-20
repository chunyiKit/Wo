package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"time"

	"github.com/chunyiKit/Wo/desktop/internal/backup"
	"github.com/chunyiKit/Wo/desktop/internal/server"
)

func parseFlags(name string, args []string, stderr io.Writer, setup func(*flag.FlagSet)) error {
	flags := flag.NewFlagSet(name, flag.ContinueOnError)
	flags.SetOutput(stderr)
	setup(flags)
	if e := flags.Parse(args); e != nil {
		return e
	}
	if flags.NArg() != 0 {
		return errors.New("unexpected positional arguments")
	}
	return nil
}
func serve(ctx context.Context, args []string, stdout, stderr io.Writer) error {
	var data, listen string
	e := parseFlags("serve", args, stderr, func(f *flag.FlagSet) {
		f.StringVar(&data, "data", "", "private backup directory")
		f.StringVar(&listen, "listen", "127.0.0.1:8787", "explicit bind address; non-loopback opts into LAN")
	})
	if e != nil {
		return e
	}
	bindHost, _, e := net.SplitHostPort(listen)
	if e != nil {
		return errors.New("listen requires host:port")
	}
	if bindHost != "localhost" && bindHost != "127.0.0.1" && bindHost != "::1" && bindHost != "0.0.0.0" && bindHost != "::" {
		return errors.New("listen must be loopback or explicit 0.0.0.0/[::] wildcard so local management remains reachable")
	}
	if data == "" {
		data, e = defaultDataPath()
		if e != nil {
			return e
		}
	}
	data, e = safeDir(data, true, true)
	if e != nil {
		return e
	}
	state, e := safeDir(filepath.Join(data, ".state"), true, true)
	if e != nil {
		return e
	}
	lock := filepath.Join(state, "serve.lock")
	if e = os.Mkdir(lock, 0700); e != nil {
		return errors.New("serve lock exists or unavailable; inspect stale lock manually, never auto-delete")
	}
	own, e := os.Lstat(lock)
	if e != nil {
		return e
	}
	defer func() {
		if current, er := os.Lstat(lock); er == nil && os.SameFile(own, current) {
			_ = os.Remove(lock)
		}
	}()
	auth := filepath.Join(state, "devices.json")
	if info, er := os.Lstat(auth); er == nil {
		if !info.Mode().IsRegular() || runtime.GOOS != "windows" && info.Mode().Perm()&0077 != 0 {
			return errors.New("private regular auth state required")
		}
	} else if !errors.Is(er, os.ErrNotExist) {
		return er
	}
	cert, pin, e := server.Certificate(state)
	if e != nil {
		return e
	}
	store, e := backup.New(data)
	if e != nil {
		return e
	}
	defer store.Close()
	secret := server.NewAdminSecret()
	handler, e := server.New(store, secret, auth)
	if e != nil {
		return e
	}
	listener, e := net.Listen("tcp", listen)
	if e != nil {
		return e
	}
	defer listener.Close()
	srv := &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 2 * time.Minute, WriteTimeout: 15 * time.Minute, MaxHeaderBytes: 16 << 10, TLSConfig: &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{cert}}}
	host, port, e := net.SplitHostPort(listener.Addr().String())
	if e != nil {
		return e
	}
	// Management is local even when the explicit listen address accepts phones.
	adminHost := "127.0.0.1"
	if ip := net.ParseIP(host); ip != nil && ip.To4() == nil {
		adminHost = "::1"
	}
	startup := map[string]string{"event": "listening", "url": "https://" + net.JoinHostPort(adminHost, port), "listen": listener.Addr().String(), "pin": pin, "admin_code": secret}
	if e = output(stdout, startup); e != nil {
		return e
	}
	result := make(chan error, 1)
	go func() { result <- srv.Serve(tls.NewListener(listener, srv.TLSConfig)) }()
	select {
	case e = <-result:
		if errors.Is(e, http.ErrServerClosed) {
			return nil
		}
		return e
	case <-ctx.Done():
		stop, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		e = srv.Shutdown(stop)
		if e != nil {
			_ = srv.Close()
			return e
		}
		e = <-result
		if errors.Is(e, http.ErrServerClosed) {
			return nil
		}
		return e
	}
}
