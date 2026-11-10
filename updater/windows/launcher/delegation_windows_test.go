//go:build windows

package main

import (
	"encoding/base64"
	"encoding/pem"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestWindowsActualLauncherDelegationAndExactChildRollback(t *testing.T) {
	nativeOnly(t)
	f := newTestFeed(t)
	root := t.TempDir()
	platform := newWindowsPlatform(root)
	core := &Updater{Root: root, Trust: f.trust, OS: platform, FeedClient: f.server.Client(), DownloadClient: f.server.Client(), HealthWait: 5 * time.Second}
	t.Cleanup(func() { stopFixtureProcesses(t, platform) })
	good, err := os.ReadFile(os.Getenv("BAKIM_FIXTURE_GOOD"))
	if err != nil {
		t.Fatal(err)
	}
	engineManifest := manifestFor(seedVersionCode+1, f.server.URL, good)
	f.engineManifest = signedManifest(t, f.key, engineManifest)
	f.packages = map[string][]byte{"windows/" + intString(engineManifest.VersionCode): good}
	if err = core.ensureSeed(); err != nil {
		t.Fatal(err)
	}
	if err = core.download(engineManifest, f.engineManifest); err != nil {
		t.Fatal(err)
	}
	if err = core.save(State{Current: engineManifest.VersionCode, Previous: seedVersionCode, HighWater: engineManifest.VersionCode}); err != nil {
		t.Fatal(err)
	}
	if err = core.launch(engineManifest.VersionCode); err != nil {
		t.Fatal(err)
	}
	engineProcesses := platform.ours()
	helperCode := int64(2026111102)
	output := filepath.Join(t.TempDir(), "next-launcher.exe")
	ca := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: f.server.Certificate().Raw})
	flags := []string{"-s", "-w", "-H=windowsgui", "-X", "main.launcherBuildString=" + intString(helperCode), "-X", "main.launcherVersion=1.0.1-ci", "-X", "main.updatePublicKey=" + base64.StdEncoding.EncodeToString(f.trust.Key), "-X", "main.updateKeyID=test-key", "-X", "main.packageOrigin=" + f.server.URL, "-X", "main.updateFeed=" + f.server.URL + "/yardim-guncelle.php?platform=windows", "-X", "main.launcherUpdateFeed=" + f.server.URL + "/yardim-guncelle.php?platform=windows-launcher", "-X", "main.fixtureRootBase64=" + base64.StdEncoding.EncodeToString([]byte(root)), "-X", "main.fixtureCABase64=" + base64.StdEncoding.EncodeToString(ca)}
	command := exec.Command("go", "build", "-trimpath", "-buildvcs=false", "-ldflags", strings.Join(flags, " "), "-o", output, ".")
	if result, err := command.CombinedOutput(); err != nil {
		t.Fatalf("disposable actual launcher compilation failed: %v\n%s", err, result)
	}
	next, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	helperTrust := f.trust
	helperTrust.Platform = "windows-launcher"
	helperTrust.URLPlatform = "windows-launcher"
	helperTrust.MinimumCode = 2026111101
	helperTrust.Feed = f.server.URL + "/yardim-guncelle.php?platform=windows-launcher"
	store := &Updater{Root: filepath.Join(root, "launchers"), FileName: "launcher.exe", Trust: helperTrust, OS: platform, FeedClient: f.server.Client(), DownloadClient: f.server.Client()}
	delegator := &Delegator{Core: core, Store: store, OS: platform, BuildCode: 2026111101, AckWait: 20 * time.Second}
	f.packages["windows-launcher/"+intString(helperCode)] = next
	f.manifest = signedManifest(t, f.key, helperManifest(helperCode, f.server.URL, next))
	if handled, err := delegator.Run(); err != nil || !handled {
		t.Fatalf("actual new launcher delegation failed: %v", err)
	}
	if delegator.state().Current != helperCode {
		t.Fatal("new launcher was not committed after exact-child ready ACK")
	}
	after := platform.ours()
	for pid := range engineProcesses {
		if _, alive := after[pid]; !alive {
			t.Fatal("self-update interrupted the original engine process")
		}
	}
	bad, err := os.ReadFile(os.Getenv("BAKIM_FIXTURE_BAD"))
	if err != nil {
		t.Fatal(err)
	}
	f.packages["windows-launcher/"+intString(helperCode+1)] = bad
	f.manifest = signedManifest(t, f.key, helperManifest(helperCode+1, f.server.URL, bad))
	start := time.Now()
	if handled, err := delegator.Run(); err != nil || !handled {
		t.Fatalf("previous actual helper was not restored: %v", err)
	}
	if time.Since(start) > 15*time.Second {
		t.Fatal("early helper exit waited the full ACK timeout instead of rolling back promptly")
	}
	s := delegator.state()
	if s.Current != helperCode || s.Failed != helperCode+1 {
		t.Fatal("broken helper corrupted the current launcher pointer")
	}
	for pid := range engineProcesses {
		if _, alive := platform.ours()[pid]; !alive {
			t.Fatal("launcher rollback interrupted the live engine")
		}
	}
	t.Log("Actual compiled next launcher + separate mutexes + signed cached delegation + exact child PID/handle readiness + early-exit rollback + uninterrupted engine passed")
}
