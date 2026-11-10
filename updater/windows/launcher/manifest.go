package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const (
	launcherAPI           = 1
	seedVersionCode int64 = 2026111001
	seedSHA256            = "d9ec96f4c8b6fa14e95e5aec4dc8998c84072ec470f088bd6b84f481092835a1"
	seedSize        int64 = 28879872
	displayName           = "Bakım.TR Yardım"
	engineName            = "Bakım.TR Yardım.exe"
)

// Build-time values have no environment/command-line override in a released binary.
// Native CI can compile a disposable helper with a separate temporary public key.
var launcherVersion = "1.0.0"
var launcherBuildString = "2026111101"
var updateKeyID = "bakim-yardim-2026"
var updatePublicKey = "dS7jt4SMbs05q2Od0C5btJQbh9BjBhQWcS2d6gQwPt0="
var updateFeed = "https://xn--bakm-nza.tr/yardim-guncelle.php?platform=windows"
var packageOrigin = "https://xn--bakm-nza.tr"
var launcherUpdateFeed = "https://xn--bakm-nza.tr/yardim-guncelle.php?platform=windows-launcher"
var fixtureRootBase64 = ""
var fixtureCABase64 = ""

type Envelope struct {
	Payload   string `json:"payload"`
	Signature string `json:"signature"`
	KeyID     string `json:"keyId"`
}

type Manifest struct {
	Schema               int      `json:"schema"`
	Product              string   `json:"product"`
	Platform             string   `json:"platform"`
	Channel              string   `json:"channel"`
	Version              string   `json:"version"`
	VersionCode          int64    `json:"versionCode"`
	URL                  string   `json:"url"`
	SHA256               string   `json:"sha256"`
	Size                 int64    `json:"size"`
	PublishedAt          string   `json:"publishedAt"`
	IssuedAt             string   `json:"issuedAt"`
	ExpiresAt            string   `json:"expiresAt"`
	MinLauncher          int      `json:"minLauncher"`
	AuthenticodeRequired bool     `json:"authenticodeRequired"`
	SignerThumbprints    []string `json:"signerThumbprints"`
}

type Trust struct {
	Key                   ed25519.PublicKey
	KeyID, Feed, Origin   string
	Platform, URLPlatform string
	MinimumCode           int64
}

var errNewLauncherRequired = errors.New("a newer launcher is required")

func productionTrust() Trust {
	key, err := base64.StdEncoding.Strict().DecodeString(updatePublicKey)
	if err != nil || len(key) != ed25519.PublicKeySize {
		panic("invalid compiled update key")
	}
	return Trust{Key: key, KeyID: updateKeyID, Feed: updateFeed, Origin: packageOrigin}
}

func (t Trust) platform() string {
	if t.Platform != "" {
		return t.Platform
	}
	return "windows-x64"
}
func (t Trust) urlPlatform() string {
	if t.URLPlatform != "" {
		return t.URLPlatform
	}
	return "windows"
}
func (t Trust) floor() int64 {
	if t.MinimumCode > 0 {
		return t.MinimumCode
	}
	return seedVersionCode
}
func launcherBuildCode() int64 {
	n, e := strconv.ParseInt(launcherBuildString, 10, 64)
	if e != nil || n < 2026111101 {
		panic("invalid launcher build code")
	}
	return n
}
func launcherTrust() Trust {
	t := productionTrust()
	t.Platform = "windows-launcher"
	t.URLPlatform = "windows-launcher"
	t.Feed = launcherUpdateFeed
	t.MinimumCode = 2026111101
	return t
}

func (t Trust) allowedURL(raw string, code int64, feed bool) error {
	u, err := url.Parse(raw)
	if err != nil {
		return errors.New("invalid update URL")
	}
	origin, err := url.Parse(t.Origin)
	if err != nil {
		return err
	}
	if u.Scheme != "https" || u.User != nil || u.Fragment != "" || !strings.EqualFold(u.Host, origin.Host) {
		return errors.New("update origin rejected")
	}
	q := u.Query()
	if q.Get("platform") != t.urlPlatform() || len(q["platform"]) != 1 {
		return errors.New("update platform URL rejected")
	}
	if feed {
		if u.Path != "/yardim-guncelle.php" || len(q) != 1 {
			return errors.New("feed endpoint rejected")
		}
	} else {
		if u.Path != "/yardim-paket.php" || len(q) != 2 || len(q["versionCode"]) != 1 || q.Get("versionCode") != strconv.FormatInt(code, 10) {
			return errors.New("package endpoint rejected")
		}
	}
	return nil
}

func (t Trust) verify(raw []byte, online bool, now time.Time) (Manifest, error) {
	var e Envelope
	var m Manifest
	if len(raw) > 128*1024 || json.Unmarshal(raw, &e) != nil || e.KeyID != t.KeyID {
		return m, errors.New("update envelope rejected")
	}
	p, err := base64.StdEncoding.Strict().DecodeString(e.Payload)
	if err != nil || len(p) > 64*1024 {
		return m, errors.New("update payload rejected")
	}
	sig, err := base64.StdEncoding.Strict().DecodeString(e.Signature)
	if err != nil || len(sig) != ed25519.SignatureSize || !ed25519.Verify(t.Key, p, sig) {
		return m, errors.New("update signature rejected")
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(p, &fields) != nil {
		return m, errors.New("signed update JSON rejected")
	}
	if _, fixture := fields["fixture"]; fixture {
		return m, errors.New("fixture manifest forbidden in production launcher")
	}
	if json.Unmarshal(p, &m) != nil {
		return m, errors.New("signed update JSON rejected")
	}
	if m.Schema != 1 || m.Product != "Bakim.TR Yardim" || m.Platform != t.platform() || m.Channel != "stable" || m.VersionCode < t.floor() || m.MinLauncher < 1 {
		return m, errors.New("signed update identity rejected")
	}
	if m.MinLauncher > launcherAPI {
		return m, errNewLauncherRequired
	}
	if len(m.Version) == 0 || len(m.Version) > 80 || m.Size < 1024 || m.Size > 256*1024*1024 || len(m.SHA256) != 64 || strings.ToLower(m.SHA256) != m.SHA256 {
		return m, errors.New("signed update bounds rejected")
	}
	if b, err := hex.DecodeString(m.SHA256); err != nil || len(b) != 32 {
		return m, errors.New("signed update SHA256 rejected")
	}
	if err = t.allowedURL(m.URL, m.VersionCode, false); err != nil {
		return m, err
	}
	published, err := time.Parse(time.RFC3339, m.PublishedAt)
	if err != nil {
		return m, errors.New("update publication time rejected")
	}
	expires, err := time.Parse(time.RFC3339, m.ExpiresAt)
	if err != nil || !expires.After(published) {
		return m, errors.New("update validity rejected")
	}
	issued, err := time.Parse(time.RFC3339, m.IssuedAt)
	if err != nil || !expires.After(issued) || expires.Sub(issued) > 32*24*time.Hour {
		return m, errors.New("update issue window rejected")
	}
	if online && (published.After(now.Add(10*time.Minute)) || issued.After(now.Add(10*time.Minute)) || !expires.After(now)) {
		return m, errors.New("update expired or clock rejected")
	}
	if m.AuthenticodeRequired && len(m.SignerThumbprints) == 0 {
		return m, errors.New("required Authenticode publisher missing")
	}
	return m, nil
}

func (t Trust) client(timeout time.Duration) *http.Client {
	transport := &http.Transport{Proxy: http.ProxyFromEnvironment, TLSHandshakeTimeout: 1500 * time.Millisecond, ResponseHeaderTimeout: 2500 * time.Millisecond, IdleConnTimeout: 10 * time.Second}
	// Empty in every production build. Disposable CI helpers trust only their
	// compiled temporary TLS test CA; TLS validation is never disabled.
	if fixtureCABase64 != "" {
		raw, err := base64.StdEncoding.Strict().DecodeString(fixtureCABase64)
		if err != nil {
			panic("invalid compiled fixture CA")
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(raw) {
			panic("invalid fixture CA certificate")
		}
		transport.TLSClientConfig = &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}
	}
	return &http.Client{Timeout: timeout, Transport: transport, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) > 3 {
			return errors.New("too many update redirects")
		}
		code, _ := strconv.ParseInt(req.URL.Query().Get("versionCode"), 10, 64)
		return t.allowedURL(req.URL.String(), code, req.URL.Path == "/yardim-guncelle.php")
	}}
}

func fetchManifest(client *http.Client, t Trust) (Manifest, []byte, error) {
	var m Manifest
	if err := t.allowedURL(t.Feed, 0, true); err != nil {
		return m, nil, err
	}
	req, err := http.NewRequest("GET", t.Feed, nil)
	if err != nil {
		return m, nil, err
	}
	req.Header.Set("User-Agent", "BakimTRYardimLauncher/"+launcherVersion)
	req.Header.Set("Cache-Control", "no-cache")
	resp, err := client.Do(req)
	if err != nil {
		return m, nil, errors.New("update check unavailable")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return m, nil, fmt.Errorf("update HTTP status %d", resp.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 128*1024+1))
	if err != nil {
		return m, nil, errors.New("update check incomplete")
	}
	m, err = t.verify(raw, true, time.Now())
	return m, raw, err
}

func fileDigest(r io.Reader) (string, int64, error) {
	h := sha256.New()
	n, err := io.Copy(h, r)
	return hex.EncodeToString(h.Sum(nil)), n, err
}
