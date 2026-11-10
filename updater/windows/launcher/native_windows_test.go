//go:build windows

package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func nativeOnly(t *testing.T) {
	t.Helper()
	if os.Getenv("BAKIM_NATIVE_TESTS") != "1" {
		t.Skip("disposable Windows integration runner only")
	}
}
func auditedWindowsPlatform(t *testing.T, root string) *windowsPlatform {
	t.Helper()
	p := newWindowsPlatform(root)
	p.BeforeLaunch = func(path string) {
		audit := os.Getenv("BAKIM_CI_PENDING")
		if audit == "" {
			t.Fatal("CI pending launch audit missing")
		}
		file, err := os.Open(path)
		if err != nil {
			t.Fatal(err)
		}
		sum, _, err := fileDigest(file)
		_ = file.Close()
		if err != nil {
			t.Fatal(err)
		}
		data, _ := json.Marshal(map[string]any{"path": path, "sha256": sum, "callerPid": os.Getpid(), "utc": time.Now().UTC().Format(time.RFC3339Nano)})
		if err = os.WriteFile(audit, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	return p
}
func stopFixtureProcesses(t *testing.T, p *windowsPlatform) {
	t.Helper()
	prefix := strings.ToLower(p.root) + string(os.PathSeparator)
	for pid, path := range p.ours() {
		if strings.HasPrefix(strings.ToLower(path), prefix) {
			_ = exec.Command("taskkill.exe", "/PID", intString(int64(pid)), "/T", "/F").Run()
		}
	}
	time.Sleep(300 * time.Millisecond)
}
func TestWindowsNativeMutexAndAtomicState(t *testing.T) {
	nativeOnly(t)
	root := t.TempDir()
	p := auditedWindowsPlatform(t, root)
	release, ok, err := p.Lock(root)
	if err != nil || !ok {
		t.Fatal("first Windows mutex failed")
	}
	_, second, err := p.Lock(root)
	if err != nil || second {
		t.Fatal("second native updater obtained the same mutex")
	}
	release()
	u := &Updater{Root: root, OS: p}
	for i := int64(0); i < 100; i++ {
		if err := u.save(State{Current: seedVersionCode + i, HighWater: seedVersionCode + i}); err != nil {
			t.Fatal(err)
		}
		b, err := os.ReadFile(filepath.Join(root, "current.json"))
		var s State
		if err != nil || json.Unmarshal(b, &s) != nil || s.Current != seedVersionCode+i {
			t.Fatal("atomic Windows state was damaged")
		}
	}
}
func TestWindowsRealSignedUpdateBusyDeferralAndRollback(t *testing.T) {
	nativeOnly(t)
	f := newTestFeed(t)
	good := os.Getenv("BAKIM_FIXTURE_GOOD")
	bad := os.Getenv("BAKIM_FIXTURE_BAD")
	var err error
	f.data, err = os.ReadFile(good)
	if err != nil {
		t.Fatal(err)
	}
	f.manifest = signedManifest(t, f.key, manifestFor(seedVersionCode+1, f.server.URL, f.data))
	u, _ := newTestUpdater(t, f)
	p := auditedWindowsPlatform(t, u.Root)
	u.OS = p
	u.HealthWait = 3 * time.Second
	t.Cleanup(func() { stopFixtureProcesses(t, p) })
	if err = u.Run(); err != nil {
		t.Fatal(err)
	}
	if u.state().Current != seedVersionCode+1 || !p.Busy() {
		t.Fatal("actual Windows updated GUI did not start")
	}
	before := p.ours()
	if len(before) == 0 {
		t.Fatal("real fixture process missing")
	}
	zone, err := os.ReadFile(u.path(seedVersionCode+1) + ":Zone.Identifier")
	if err != nil || !strings.Contains(string(zone), "ZoneId=3") {
		t.Fatal("download origin evidence was lost")
	}
	f.data, err = os.ReadFile(bad)
	if err != nil {
		t.Fatal(err)
	}
	f.manifest = signedManifest(t, f.key, manifestFor(seedVersionCode+2, f.server.URL, f.data))
	if err = u.Run(); err != nil {
		t.Fatal(err)
	}
	after := p.ours()
	for pid := range before {
		if _, ok := after[pid]; !ok {
			t.Fatal("running session process was terminated")
		}
	}
	if u.state().Current != seedVersionCode+1 || u.state().Staged != seedVersionCode+2 {
		t.Fatal("busy app was replaced instead of staging update")
	}
	stopFixtureProcesses(t, p)
	if err = u.Run(); err != nil {
		t.Fatal(err)
	}
	if u.state().Current != seedVersionCode+1 || u.state().Failed != seedVersionCode+2 || !p.Busy() {
		t.Fatal("failed real EXE did not roll back to the previous working GUI")
	}
	t.Log("Real Windows verified download + SHA256/Ed25519 + native GUI + live-process deferral + failed EXE rollback passed; MOTW retained")
}

func TestWindowsExactProductionEngineChildGUI(t *testing.T) {
	nativeOnly(t)
	root := t.TempDir()
	p := auditedWindowsPlatform(t, root)
	trust := productionTrust()
	u := &Updater{Root: root, Trust: trust, OS: p, FeedClient: trust.client(2500 * time.Millisecond), DownloadClient: trust.client(60 * time.Second), HealthWait: 25 * time.Second}
	defer func() {
		// This test runs only in a disposable CI VM. Never used by the production launcher.
		for pid, path := range p.ours() {
			if strings.HasPrefix(strings.ToLower(path), strings.ToLower(root)+string(os.PathSeparator)) || strings.EqualFold(filepath.Base(path), engineName) {
				_ = exec.Command("taskkill.exe", "/PID", intString(int64(pid)), "/T", "/F").Run()
			}
		}
	}()
	if err := u.Run(); err != nil {
		t.Fatal(err)
	}
	if !p.Busy() {
		t.Fatal("portable inner process missing after outer launcher returned")
	}
	found := false
	for _, path := range p.ours() {
		if strings.EqualFold(filepath.Base(path), engineName) {
			found = true
		}
	}
	if !found {
		t.Fatal("exact Unicode-named RustDesk GUI child not observed")
	}
	if err := checkedFile(u.path(seedVersionCode), seedSHA256, seedSize); err != nil {
		t.Fatal("original proven engine bytes changed")
	}
	zone, err := os.ReadFile(u.path(seedVersionCode) + ":Zone.Identifier")
	if err != nil || !strings.Contains(string(zone), "ZoneId=3") {
		t.Fatal("production seed origin evidence missing")
	}
	t.Log("Original exact engine + actual Unicode child GUI + current server feed signature + retained internet-zone metadata passed")
}
