package server

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"
)

// Certificate 将传输密钥只存于本机私有状态目录；它不是受限内容恢复密钥。
func Certificate(dir string) (tls.Certificate, string, error) {
	var zero tls.Certificate
	if info, e := os.Lstat(dir); e == nil && (!info.IsDir() || info.Mode()&os.ModeSymlink != 0) {
		return zero, "", errors.New("state directory invalid")
	}
	if e := os.MkdirAll(dir, 0700); e != nil {
		return zero, "", e
	}
	certPath, keyPath := filepath.Join(dir, "transport-cert.pem"), filepath.Join(dir, "transport-private.pem")
	certInfo, ce := os.Lstat(certPath)
	keyInfo, ke := os.Lstat(keyPath)
	if ce == nil || ke == nil {
		if ce != nil || ke != nil || !certInfo.Mode().IsRegular() || !keyInfo.Mode().IsRegular() {
			return zero, "", errors.New("incomplete TLS identity; refusing replacement")
		}
	} else {
		if !errors.Is(ce, os.ErrNotExist) || !errors.Is(ke, os.ErrNotExist) {
			return zero, "", errors.New("TLS identity unavailable")
		}
		pub, priv, e := ed25519.GenerateKey(rand.Reader)
		if e != nil {
			return zero, "", e
		}
		serial, e := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
		if e != nil {
			return zero, "", e
		}
		now := time.Now()
		template := x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: "Wo local backup"}, NotBefore: now.Add(-time.Hour), NotAfter: now.AddDate(3, 0, 0), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, DNSNames: []string{"localhost"}, IPAddresses: []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")}}
		der, e := x509.CreateCertificate(rand.Reader, &template, &template, pub, priv)
		if e != nil {
			return zero, "", e
		}
		key, e := x509.MarshalPKCS8PrivateKey(priv)
		if e != nil {
			return zero, "", e
		}
		write := func(path string, data []byte) error {
			f, e := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
			if e != nil {
				return e
			}
			if _, e = f.Write(data); e == nil {
				e = f.Sync()
			}
			if er := f.Close(); e == nil {
				e = er
			}
			return e
		}
		if e = write(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: key})); e != nil {
			return zero, "", e
		}
		if e = write(certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})); e != nil {
			return zero, "", e
		}
	}
	cert, e := tls.LoadX509KeyPair(certPath, keyPath)
	if e != nil {
		return zero, "", e
	}
	sum := sha256.Sum256(cert.Certificate[0])
	return cert, hex.EncodeToString(sum[:]), nil
}
