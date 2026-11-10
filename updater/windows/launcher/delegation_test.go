package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type helperFake struct {
	fakePlatform
	storeRoot      string
	failCode       int64
	badPID         bool
	stopped        []string
	helperLaunches []string
	locksMu        sync.Mutex
	locks          map[string]*sync.Mutex
}

func (p *helperFake) Lock(root string) (func(), bool, error) {
	p.locksMu.Lock()
	if p.locks == nil {
		p.locks = map[string]*sync.Mutex{}
	}
	m := p.locks[root]
	if m == nil {
		m = &sync.Mutex{}
		p.locks[root] = m
	}
	p.locksMu.Unlock()
	if !m.TryLock() {
		return func() {}, false, nil
	}
	return m.Unlock, true, nil
}

func (p *helperFake) Launch(path string) error {
	p.helperLaunches = append(p.helperLaunches, path)
	raw, err := os.ReadFile(filepath.Join(p.storeRoot, "handover.json"))
	if err != nil {
		return err
	}
	var req handover
	if err = json.Unmarshal(raw, &req); err != nil {
		return err
	}
	if req.VersionCode == p.failCode {
		return nil
	}
	ack := readyAck{Nonce: req.Nonce, VersionCode: req.VersionCode, PID: 42, EngineReady: true}
	if p.badPID {
		ack.PID = 99
	}
	dir := filepath.Join(p.storeRoot, "acks")
	_ = os.MkdirAll(dir, 0700)
	raw, _ = json.Marshal(ack)
	return os.WriteFile(filepath.Join(dir, req.Nonce+".json"), raw, 0600)
}
func (p *helperFake) ProcessMatches(pid int, path string) bool {
	return pid == 42 && len(p.helperLaunches) > 0 && p.helperLaunches[len(p.helperLaunches)-1] == path
}
func (p *helperFake) StopHelper(path string) { p.stopped = append(p.stopped, path) }
func (p *helperFake) LaunchHelper(path string) (*launchedHelper, error) {
	err := p.Launch(path)
	if err != nil {
		return nil, err
	}
	var request handover
	raw, _ := os.ReadFile(filepath.Join(p.storeRoot, "handover.json"))
	_ = json.Unmarshal(raw, &request)
	alive := request.VersionCode != p.failCode
	return &launchedHelper{PID: 42, Alive: func() bool { return alive }, Stop: func() { p.StopHelper(path); alive = false }, Close: func() {}}, nil
}
func helperManifest(code int64, origin string, data []byte) Manifest {
	m := manifestFor(code, origin, data)
	m.Platform = "windows-launcher"
	m.URL = strings.Replace(m.URL, "platform=windows&", "platform=windows-launcher&", 1)
	return m
}
func newTestDelegator(t *testing.T) (*Delegator, *testFeed, *helperFake) {
	f := newTestFeed(t)
	trust := f.trust
	trust.Platform = "windows-launcher"
	trust.URLPlatform = "windows-launcher"
	trust.MinimumCode = 2026111101
	trust.Feed = strings.Replace(trust.Feed, "platform=windows", "platform=windows-launcher", 1)
	root := t.TempDir()
	p := &helperFake{storeRoot: filepath.Join(root, "launchers")}
	p.busy.Store(true)
	core := &Updater{Root: root, OS: p}
	store := &Updater{Root: p.storeRoot, FileName: "launcher.exe", Trust: trust, OS: p, FeedClient: f.server.Client(), DownloadClient: f.server.Client()}
	d := &Delegator{Core: core, Store: store, OS: p, BuildCode: 2026111101, AckWait: 35 * time.Millisecond}
	f.manifest = signedManifest(t, f.key, helperManifest(d.BuildCode+1, f.server.URL, f.data))
	return d, f, p
}
func TestLauncherDelegationVerifiesAndPromotesWithIdentityAck(t *testing.T) {
	d, _, p := newTestDelegator(t)
	handled, err := d.Run()
	if err != nil || !handled {
		t.Fatalf("verified delegation not handled: %v", err)
	}
	if d.state().Current != d.BuildCode+1 || len(p.helperLaunches) != 1 || len(p.stopped) != 0 {
		t.Fatal("launcher did not promote only after matching readiness ACK")
	}
	if !p.busy.Load() {
		t.Fatal("engine session was interrupted")
	}
}
func TestEarlyLauncherExitRollsBackToVerifiedPreviousHelper(t *testing.T) {
	d, f, p := newTestDelegator(t)
	if handled, err := d.Run(); err != nil || !handled {
		t.Fatal(err)
	}
	f.data = []byte(strings.Repeat("next-broken-helper", 256))
	f.manifest = signedManifest(t, f.key, helperManifest(d.BuildCode+2, f.server.URL, f.data))
	p.failCode = d.BuildCode + 2
	if handled, err := d.Run(); err != nil || !handled {
		t.Fatalf("previous verified helper was not restored: %v", err)
	}
	s := d.state()
	if s.Current != d.BuildCode+1 || s.Failed != d.BuildCode+2 || len(p.stopped) != 0 || p.helperLaunches[len(p.helperLaunches)-1] != d.Store.path(d.BuildCode+1) {
		t.Fatal("launcher early-exit rollback failed")
	}
	if !p.busy.Load() {
		t.Fatal("rollback stopped the live engine")
	}
}
func TestLauncherCannotForgeReadinessWithWrongPID(t *testing.T) {
	d, _, p := newTestDelegator(t)
	p.badPID = true
	handled, err := d.Run()
	if err != nil || handled {
		t.Fatal("unverified readiness identity accepted")
	}
	if d.state().Current != d.BuildCode || d.state().Failed != d.BuildCode+1 || len(p.stopped) != 1 {
		t.Fatal("forged readiness did not roll back")
	}
}
func TestExpiredCachedLauncherCanDelegateOffline(t *testing.T) {
	d, f, p := newTestDelegator(t)
	if handled, err := d.Run(); err != nil || !handled {
		t.Fatal(err)
	}
	f.manifest = []byte("offline")
	p.helperLaunches = nil
	handled, err := d.Run()
	if err != nil || !handled || len(p.helperLaunches) != 1 {
		t.Fatal("working cached helper was unavailable offline")
	}
}
func TestLauncherSignedDowngradeDoesNotReplaceNewerCache(t *testing.T) {
	d, f, p := newTestDelegator(t)
	if handled, err := d.Run(); err != nil || !handled {
		t.Fatal(err)
	}
	f.manifest = signedManifest(t, f.key, helperManifest(d.BuildCode, f.server.URL, f.data))
	p.helperLaunches = nil
	if handled, err := d.Run(); err != nil || !handled || d.state().Current != d.BuildCode+1 || p.helperLaunches[0] != d.Store.path(d.BuildCode+1) {
		t.Fatal("signed launcher downgrade replaced the newer helper")
	}
}
