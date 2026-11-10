package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type rejectedLaunch struct{ *fakePlatform }

func (p *rejectedLaunch) Launch(path string) error {
	p.fakePlatform.Launch(path)
	return errUserDeclined
}

type invalidAtomicState struct{ *fakePlatform }

func (p *invalidAtomicState) AtomicReplace(from, to string) error {
	if filepath.Base(to) == "current.json" {
		return errors.New("fixture state storage unavailable")
	}
	return p.fakePlatform.AtomicReplace(from, to)
}

func TestWindowsSecurityDeclineDoesNotRetryOrBlacklistVersion(t *testing.T) {
	f := newTestFeed(t)
	u, p := newTestUpdater(t, f)
	u.OS = &rejectedLaunch{p}
	err := u.Run()
	if !errors.Is(err, errUserDeclined) {
		t.Fatal("Windows user decision was not propagated")
	}
	s := u.state()
	if len(p.launched) != 1 || s.Current != seedVersionCode || s.Staged != seedVersionCode+1 || s.Failed != 0 {
		t.Fatal("security decline retried another executor/version or permanently blacklisted a declined update")
	}
}
func TestExistingGuiCannotAckBeforeCoreStateValidation(t *testing.T) {
	f := newTestFeed(t)
	u, p := newTestUpdater(t, f)
	p.busy.Store(true)
	u.OS = &invalidAtomicState{p}
	acknowledgements := 0
	u.OnReady = func() { acknowledgements++ }
	if err := u.Run(); err == nil {
		t.Fatal("startup storage failure was silently accepted")
	}
	if acknowledgements != 0 {
		t.Fatal("existing GUI was used as an ACK before child core startup validated its state")
	}
}

func signedManifest(t *testing.T, key ed25519.PrivateKey, m Manifest) []byte {
	t.Helper()
	p, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	e := Envelope{base64.StdEncoding.EncodeToString(p), base64.StdEncoding.EncodeToString(ed25519.Sign(key, p)), "test-key"}
	b, _ := json.Marshal(e)
	return b
}
func manifestFor(code int64, origin string, data []byte) Manifest {
	now := time.Now().UTC()
	sum := sha256.Sum256(data)
	return Manifest{Schema: 1, Product: "Bakim.TR Yardim", Platform: "windows-x64", Channel: "stable", Version: "1.5.1-test", VersionCode: code, URL: origin + "/yardim-paket.php?platform=windows&versionCode=" + intString(code), SHA256: hex.EncodeToString(sum[:]), Size: int64(len(data)), PublishedAt: now.Add(-time.Hour).Format(time.RFC3339), IssuedAt: now.Format(time.RFC3339), ExpiresAt: now.Add(30 * 24 * time.Hour).Format(time.RFC3339), MinLauncher: 1}
}
func intString(code int64) string { b, _ := json.Marshal(code); return string(b) }

type fakePlatform struct {
	updaterLock sync.Mutex
	dataLock    sync.Mutex
	busy        atomic.Bool
	failures    atomic.Int32
	launched    []string
	foreground  atomic.Int32
	prepared    atomic.Int32
}

func (p *fakePlatform) Lock(_ string) (func(), bool, error) {
	if !p.updaterLock.TryLock() {
		return func() {}, false, nil
	}
	return p.updaterLock.Unlock, true, nil
}
func (p *fakePlatform) Busy() bool                              { return p.busy.Load() }
func (p *fakePlatform) Foreground()                             { p.foreground.Add(1) }
func (p *fakePlatform) Prepare(_, _ string) error               { p.prepared.Add(1); return nil }
func (p *fakePlatform) Authenticode(_ string, _ Manifest) error { return nil }
func (p *fakePlatform) Launch(path string) error {
	p.dataLock.Lock()
	defer p.dataLock.Unlock()
	p.launched = append(p.launched, path)
	return nil
}
func (p *fakePlatform) Healthy(_ time.Duration) bool {
	if p.failures.Load() > 0 {
		p.failures.Add(-1)
		return false
	}
	p.busy.Store(true)
	return true
}
func (p *fakePlatform) AtomicReplace(from, to string) error { return os.Rename(from, to) }

type testFeed struct {
	server         *httptest.Server
	trust          Trust
	key            ed25519.PrivateKey
	manifest       []byte
	engineManifest []byte
	packages       map[string][]byte
	data           []byte
	requests       atomic.Int32
	delay          time.Duration
}

func newTestFeed(t *testing.T) *testFeed {
	t.Helper()
	pub, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	f := &testFeed{key: key, data: []byte(strings.Repeat("verified-updater-test", 256))}
	f.server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/yardim-guncelle.php" {
			f.requests.Add(1)
			w.Header().Set("Content-Type", "application/json")
			if r.URL.Query().Get("platform") == "windows" && f.engineManifest != nil {
				_, _ = w.Write(f.engineManifest)
			} else {
				_, _ = w.Write(f.manifest)
			}
			return
		}
		if r.URL.Path == "/yardim-paket.php" {
			if f.delay > 0 {
				time.Sleep(f.delay)
			}
			key := r.URL.Query().Get("platform") + "/" + r.URL.Query().Get("versionCode")
			if data, ok := f.packages[key]; ok {
				_, _ = w.Write(data)
			} else {
				_, _ = w.Write(f.data)
			}
			return
		}
		http.NotFound(w, r)
	}))
	f.trust = Trust{Key: pub, KeyID: "test-key", Feed: f.server.URL + "/yardim-guncelle.php?platform=windows", Origin: f.server.URL}
	f.manifest = signedManifest(t, key, manifestFor(seedVersionCode+1, f.server.URL, f.data))
	t.Cleanup(f.server.Close)
	return f
}
func newTestUpdater(t *testing.T, f *testFeed) (*Updater, *fakePlatform) {
	t.Helper()
	p := &fakePlatform{}
	u := &Updater{Root: t.TempDir(), Trust: f.trust, OS: p, FeedClient: f.server.Client(), DownloadClient: f.server.Client(), HealthWait: time.Millisecond}
	return u, p
}

func TestManifestSecurityBoundaries(t *testing.T) {
	f := newTestFeed(t)
	base := manifestFor(seedVersionCode+1, f.server.URL, f.data)
	if _, err := f.trust.verify(signedManifest(t, f.key, base), true, time.Now()); err != nil {
		t.Fatal(err)
	}
	cases := map[string]func(*Manifest){
		"wrong_product": func(m *Manifest) { m.Product = "other" }, "wrong_platform": func(m *Manifest) { m.Platform = "android-arm64" },
		"wrong_channel": func(m *Manifest) { m.Channel = "beta" }, "schema": func(m *Manifest) { m.Schema = 2 },
		"rollback_floor": func(m *Manifest) { m.VersionCode = seedVersionCode - 1 }, "new_launcher_required": func(m *Manifest) { m.MinLauncher = 2 },
		"http": func(m *Manifest) { m.URL = strings.Replace(m.URL, "https:", "http:", 1) },
		"origin": func(m *Manifest) {
			m.URL = "https://evil.invalid/yardim-paket.php?platform=windows&versionCode=" + intString(m.VersionCode)
		},
		"endpoint":        func(m *Manifest) { m.URL = strings.Replace(m.URL, "yardim-paket.php", "other.exe", 1) },
		"fixture_query":   func(m *Manifest) { m.URL += "&fixture=00000000000000000000000000000000" },
		"url_wrong_build": func(m *Manifest) { m.URL = strings.Replace(m.URL, intString(m.VersionCode), "1", 1) },
		"size_limit":      func(m *Manifest) { m.Size = 300 * 1024 * 1024 }, "hash": func(m *Manifest) { m.SHA256 = strings.Repeat("g", 64) },
		"expired": func(m *Manifest) {
			m.IssuedAt = time.Now().Add(-48 * time.Hour).UTC().Format(time.RFC3339)
			m.ExpiresAt = time.Now().Add(-time.Hour).UTC().Format(time.RFC3339)
		},
		"future_issue":       func(m *Manifest) { m.IssuedAt = time.Now().Add(time.Hour).UTC().Format(time.RFC3339) },
		"excessive_validity": func(m *Manifest) { m.ExpiresAt = time.Now().Add(40 * 24 * time.Hour).UTC().Format(time.RFC3339) },
		"publisher_missing":  func(m *Manifest) { m.AuthenticodeRequired = true },
	}
	for name, change := range cases {
		t.Run(name, func(t *testing.T) {
			m := base
			change(&m)
			if _, err := f.trust.verify(signedManifest(t, f.key, m), true, time.Now()); err == nil {
				t.Fatal("unsafe manifest accepted")
			}
		})
	}
	t.Run("bad_signature", func(t *testing.T) {
		raw := signedManifest(t, f.key, base)
		var e Envelope
		_ = json.Unmarshal(raw, &e)
		sig, _ := base64.StdEncoding.DecodeString(e.Signature)
		sig[0] ^= 0xff
		e.Signature = base64.StdEncoding.EncodeToString(sig)
		raw, _ = json.Marshal(e)
		if _, err := f.trust.verify(raw, true, time.Now()); err == nil {
			t.Fatal("bad signature accepted")
		}
	})
	t.Run("fixture_payload", func(t *testing.T) {
		raw, _ := json.Marshal(base)
		var fields map[string]any
		_ = json.Unmarshal(raw, &fields)
		fields["fixture"] = nil
		raw, _ = json.Marshal(fields)
		e := Envelope{base64.StdEncoding.EncodeToString(raw), base64.StdEncoding.EncodeToString(ed25519.Sign(f.key, raw)), "test-key"}
		raw, _ = json.Marshal(e)
		if _, err := f.trust.verify(raw, true, time.Now()); err == nil {
			t.Fatal("fixture payload accepted")
		}
	})
	t.Run("cached_expiry_keeps_working", func(t *testing.T) {
		m := base
		m.PublishedAt = time.Now().Add(-61 * 24 * time.Hour).UTC().Format(time.RFC3339)
		m.IssuedAt = time.Now().Add(-60 * 24 * time.Hour).UTC().Format(time.RFC3339)
		m.ExpiresAt = time.Now().Add(-30 * 24 * time.Hour).UTC().Format(time.RFC3339)
		if _, err := f.trust.verify(signedManifest(t, f.key, m), false, time.Now()); err != nil {
			t.Fatal(err)
		}
	})
}

func TestSuccessfulAtomicUpdate(t *testing.T) {
	f := newTestFeed(t)
	u, p := newTestUpdater(t, f)
	if err := u.Run(); err != nil {
		t.Fatal(err)
	}
	s := u.state()
	if s.Current != seedVersionCode+1 || s.Previous != seedVersionCode || s.Staged != 0 || s.HighWater != seedVersionCode+1 {
		t.Fatalf("bad committed state: %+v", s)
	}
	if len(p.launched) != 1 || p.launched[0] != u.path(seedVersionCode+1) {
		t.Fatal("updated version did not launch")
	}
	if _, err := u.valid(seedVersionCode); err != nil {
		t.Fatal("recovery image lost")
	}
	if _, err := u.valid(seedVersionCode + 1); err != nil {
		t.Fatal("new signed version invalid")
	}
}
func TestBadDownloadKeepsWorkingVersion(t *testing.T) {
	for _, kind := range []string{"hash", "truncated"} {
		t.Run(kind, func(t *testing.T) {
			f := newTestFeed(t)
			if kind == "hash" {
				f.data[0] ^= 1
			} else {
				f.data = f.data[:100]
			}
			u, p := newTestUpdater(t, f)
			if err := u.Run(); err != nil {
				t.Fatal(err)
			}
			if u.state().Current != seedVersionCode || len(p.launched) != 1 || p.launched[0] != u.path(seedVersionCode) {
				t.Fatal("failed update replaced working version")
			}
		})
	}
}
func TestStartupFailureRollsBack(t *testing.T) {
	f := newTestFeed(t)
	u, p := newTestUpdater(t, f)
	p.failures.Store(1)
	if err := u.Run(); err != nil {
		t.Fatal(err)
	}
	s := u.state()
	if s.Current != seedVersionCode || s.Failed != seedVersionCode+1 || len(p.launched) != 2 || p.launched[1] != u.path(seedVersionCode) {
		t.Fatal("rollback did not restore the working version")
	}
}
func TestActiveSessionIsNeverRestarted(t *testing.T) {
	f := newTestFeed(t)
	u, p := newTestUpdater(t, f)
	p.busy.Store(true)
	if err := u.Run(); err != nil {
		t.Fatal(err)
	}
	if len(p.launched) != 0 || u.state().Current != seedVersionCode || u.state().Staged != seedVersionCode+1 || p.foreground.Load() == 0 {
		t.Fatal("active session was interrupted or update lost")
	}
}
func TestKnownNewVersionCompletesBeforeFirstLaunch(t *testing.T) {
	f := newTestFeed(t)
	f.delay = 100 * time.Millisecond
	u, p := newTestUpdater(t, f)
	if err := u.Run(); err != nil {
		t.Fatal(err)
	}
	if len(p.launched) != 1 || p.launched[0] != u.path(seedVersionCode+1) || u.state().Staged != 0 || u.state().Current != seedVersionCode+1 {
		t.Fatal("known new version did not launch during the same opening")
	}
}
func TestOneUpdaterOwnsConcurrentLaunches(t *testing.T) {
	f := newTestFeed(t)
	f.delay = 150 * time.Millisecond
	u, p := newTestUpdater(t, f)
	done := make(chan error, 1)
	go func() { done <- u.Run() }()
	for f.requests.Load() == 0 {
		time.Sleep(time.Millisecond)
	}
	if err := u.Run(); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if f.requests.Load() != 1 || len(p.launched) != 1 || p.foreground.Load() == 0 {
		t.Fatal("parallel launches duplicated the updater")
	}
}
func TestSignedDowngradeIsRejected(t *testing.T) {
	f := newTestFeed(t)
	u, p := newTestUpdater(t, f)
	if err := os.MkdirAll(u.Root, 0700); err != nil {
		t.Fatal(err)
	}
	if err := u.save(State{Current: seedVersionCode, HighWater: seedVersionCode + 2}); err != nil {
		t.Fatal(err)
	}
	if err := u.Run(); err != nil {
		t.Fatal(err)
	}
	if u.state().Current != seedVersionCode || len(p.launched) != 1 {
		t.Fatal("signed downgrade was applied")
	}
	if _, err := os.Stat(u.dir(seedVersionCode + 1)); !os.IsNotExist(err) {
		t.Fatal("downgraded package was downloaded")
	}
}
func TestTamperedCachedVersionFallsBackToRecovery(t *testing.T) {
	f := newTestFeed(t)
	u, p := newTestUpdater(t, f)
	if err := u.Run(); err != nil {
		t.Fatal(err)
	}
	p.busy.Store(false)
	p.launched = nil
	if err := os.WriteFile(u.path(seedVersionCode+1), []byte("tampered"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := u.Run(); err != nil {
		t.Fatal(err)
	}
	if u.state().Current != seedVersionCode || len(p.launched) != 1 || p.launched[0] != u.path(seedVersionCode) {
		t.Fatal("tampered cached image executed")
	}
}
func TestOfflineCachedSignatureDoesNotExpireApplication(t *testing.T) {
	f := newTestFeed(t)
	u, p := newTestUpdater(t, f)
	if err := u.Run(); err != nil {
		t.Fatal(err)
	}
	p.busy.Store(false)
	p.launched = nil
	m := manifestFor(seedVersionCode+1, f.server.URL, f.data)
	m.PublishedAt = time.Now().Add(-61 * 24 * time.Hour).UTC().Format(time.RFC3339)
	m.IssuedAt = time.Now().Add(-60 * 24 * time.Hour).UTC().Format(time.RFC3339)
	m.ExpiresAt = time.Now().Add(-30 * 24 * time.Hour).UTC().Format(time.RFC3339)
	if err := os.WriteFile(filepath.Join(u.dir(m.VersionCode), "manifest.json"), signedManifest(t, f.key, m), 0600); err != nil {
		t.Fatal(err)
	}
	f.manifest = []byte("network unavailable")
	if err := u.Run(); err != nil {
		t.Fatal(err)
	}
	if len(p.launched) != 1 || p.launched[0] != u.path(m.VersionCode) {
		t.Fatal("expired online metadata stopped an offline working application")
	}
}
func TestRedirectCannotEscapePinnedOrigin(t *testing.T) {
	var escaped atomic.Bool
	evil := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		escaped.Store(true)
		_, _ = io.WriteString(w, "unexpected")
	}))
	defer evil.Close()
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, evil.URL+"/yardim-guncelle.php?platform=windows", http.StatusFound)
	}))
	defer server.Close()
	trust := Trust{Feed: server.URL + "/yardim-guncelle.php?platform=windows", Origin: server.URL}
	client := trust.client(time.Second)
	client.Transport = server.Client().Transport
	if _, _, err := fetchManifest(client, trust); err == nil || escaped.Load() {
		t.Fatal("cross-origin redirect followed")
	}
}
