package main

import (
	"bytes"
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

// The original verified engine is a first-run/offline recovery image. It is never modified.
//
//go:embed seed/engine.exe
var seedEngine []byte

var errUserDeclined = errors.New("Windows execution approval declined")

type Platform interface {
	Lock(string) (func(), bool, error)
	Busy() bool
	Foreground()
	Prepare(string, string) error
	Authenticode(string, Manifest) error
	Launch(string) error
	Healthy(time.Duration) bool
	AtomicReplace(string, string) error
}
type State struct {
	Current   int64 `json:"current"`
	Previous  int64 `json:"previous,omitempty"`
	HighWater int64 `json:"highWater"`
	Staged    int64 `json:"staged,omitempty"`
	Failed    int64 `json:"failed,omitempty"`
}
type Updater struct {
	Root                       string
	FileName                   string
	Trust                      Trust
	OS                         Platform
	FeedClient, DownloadClient *http.Client
	Status                     func(string)
	Hide                       func()
	RequireLauncher            func()
	OnReady                    func()
	HealthWait                 time.Duration
	Prefetched                 <-chan manifestResult
}

type manifestResult struct {
	Manifest Manifest
	Raw      []byte
	Err      error
}

func (u *Updater) event(name string, code int64) {
	path := filepath.Join(u.Root, "launcher.log")
	if st, err := os.Stat(path); err == nil && st.Size() > 256*1024 {
		_ = os.Remove(path + ".1")
		_ = os.Rename(path, path+".1")
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		return
	}
	defer f.Close()
	_ = json.NewEncoder(f).Encode(map[string]any{"time": time.Now().UTC().Format(time.RFC3339), "event": name, "versionCode": code})
}
func (u *Updater) status(s string) {
	if u.Status != nil {
		u.Status(s)
	}
}
func (u *Updater) hide() {
	if u.Hide != nil {
		u.Hide()
	}
}
func (u *Updater) dir(code int64) string {
	return filepath.Join(u.Root, "versions", strconv.FormatInt(code, 10))
}
func (u *Updater) fileName() string {
	if u.FileName != "" {
		return u.FileName
	}
	return "engine.exe"
}
func (u *Updater) path(code int64) string { return filepath.Join(u.dir(code), u.fileName()) }

func checkedFile(path, digest string, size int64) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	sum, n, err := fileDigest(f)
	if err != nil {
		return err
	}
	if n != size || sum != digest {
		return errors.New("engine integrity rejected")
	}
	return nil
}

func (u *Updater) writeJSON(path string, value any) error {
	raw, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".state-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if _, err = f.Write(append(raw, '\n')); err == nil {
		err = f.Sync()
	}
	cerr := f.Close()
	if err != nil {
		return err
	}
	if cerr != nil {
		return cerr
	}
	return u.OS.AtomicReplace(tmp, path)
}
func (u *Updater) save(s State) error { return u.writeJSON(filepath.Join(u.Root, "current.json"), s) }
func (u *Updater) state() State {
	var s State
	b, err := os.ReadFile(filepath.Join(u.Root, "current.json"))
	if err == nil {
		_ = json.Unmarshal(b, &s)
	}
	if s.Current < seedVersionCode {
		s.Current = seedVersionCode
	}
	if s.HighWater < s.Current {
		s.HighWater = s.Current
	}
	return s
}
func (u *Updater) valid(code int64) (Manifest, error) {
	if code == seedVersionCode {
		m := Manifest{VersionCode: seedVersionCode, Version: "1.5.1", SHA256: seedSHA256, Size: seedSize, URL: packageOrigin + "/yardim-paket.php?platform=windows&versionCode=2026111001"}
		return m, checkedFile(u.path(code), m.SHA256, m.Size)
	}
	b, err := os.ReadFile(filepath.Join(u.dir(code), "manifest.json"))
	if err != nil {
		return Manifest{}, err
	}
	m, err := u.Trust.verify(b, false, time.Now())
	if err != nil || m.VersionCode != code {
		return m, errors.New("cached engine manifest rejected")
	}
	if err = checkedFile(u.path(code), m.SHA256, m.Size); err != nil {
		return m, err
	}
	return m, u.OS.Authenticode(u.path(code), m)
}

func (u *Updater) ensureSeed() error {
	if checkedFile(u.path(seedVersionCode), seedSHA256, seedSize) == nil {
		return nil
	}
	if sum, n, err := fileDigest(bytes.NewReader(seedEngine)); err != nil || sum != seedSHA256 || n != seedSize {
		return errors.New("compiled recovery image rejected")
	}
	if err := os.MkdirAll(u.dir(seedVersionCode), 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(u.dir(seedVersionCode), ".seed-*.exe")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if _, err = f.Write(seedEngine); err == nil {
		err = f.Sync()
	}
	cerr := f.Close()
	if err != nil {
		return err
	}
	if cerr != nil {
		return cerr
	}
	source := packageOrigin + "/yardim-paket.php?platform=windows&versionCode=2026111001"
	if err = u.OS.Prepare(tmp, source); err != nil {
		return err
	}
	if err = checkedFile(tmp, seedSHA256, seedSize); err != nil {
		return err
	}
	return u.OS.AtomicReplace(tmp, u.path(seedVersionCode))
}

func (u *Updater) download(m Manifest, raw []byte) error {
	if _, err := u.valid(m.VersionCode); err == nil {
		return nil
	}
	base := filepath.Join(u.Root, "versions")
	if err := os.MkdirAll(base, 0700); err != nil {
		return err
	}
	temp, err := os.MkdirTemp(base, ".download-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temp)
	path := filepath.Join(temp, u.fileName())
	req, err := http.NewRequest("GET", m.URL, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "BakimTRYardimLauncher/"+launcherVersion)
	resp, err := u.DownloadClient.Do(req)
	if err != nil {
		return errors.New("engine download unavailable")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK || (resp.ContentLength >= 0 && resp.ContentLength != m.Size) {
		return errors.New("engine download size rejected")
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	n, err := io.Copy(f, io.LimitReader(resp.Body, m.Size+1))
	if err == nil {
		err = f.Sync()
	}
	cerr := f.Close()
	if err != nil {
		return err
	}
	if cerr != nil {
		return cerr
	}
	if n != m.Size {
		return errors.New("engine download incomplete")
	}
	if err = checkedFile(path, m.SHA256, m.Size); err != nil {
		return err
	}
	if err = u.OS.Authenticode(path, m); err != nil {
		return err
	}
	if err = u.OS.Prepare(path, m.URL); err != nil {
		return err
	}
	// Attachment Manager / antivirus may modify or delete a file: hash again after Save.
	if err = checkedFile(path, m.SHA256, m.Size); err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(temp, "manifest.json"), raw, 0600); err != nil {
		return err
	}
	dest := u.dir(m.VersionCode)
	if _, err = os.Stat(dest); err == nil {
		return errors.New("immutable release directory already exists")
	}
	return os.Rename(temp, dest)
}

func (u *Updater) launch(code int64) error {
	if _, err := u.valid(code); err != nil {
		return err
	}
	u.status("Yardım uygulaması açılıyor…")
	u.event("launch", code)
	if err := u.OS.Launch(u.path(code)); err != nil {
		return err
	}
	// The portable outer process may exit before its real Unicode-named GUI child.
	if !u.OS.Healthy(u.HealthWait) {
		return errors.New("engine GUI startup not confirmed")
	}
	u.event("gui_ready", code)
	if u.OnReady != nil {
		u.OnReady()
	}
	u.hide()
	return nil
}

func (u *Updater) activate(s *State, code int64) error {
	if u.OS.Busy() {
		s.Staged = code
		_ = u.save(*s)
		u.event("activation_deferred_busy", code)
		u.OS.Foreground()
		if _, err := u.valid(s.Current); err == nil && u.OS.Healthy(300*time.Millisecond) && u.OnReady != nil {
			u.OnReady()
		}
		return nil
	}
	previous := s.Current
	if err := u.launch(code); err != nil {
		if errors.Is(err, errUserDeclined) {
			s.Staged = code
			_ = u.save(*s)
			return err
		}
		s.Failed = code
		s.Staged = 0
		_ = u.save(*s)
		u.event("candidate_failed_rollback", code)
		// Never terminate a possibly active child just because its outer launcher exited.
		if u.OS.Busy() {
			u.OS.Foreground()
			return errors.New("new engine remains active; recovery deferred safely")
		}
		if code != previous {
			return u.launch(previous)
		}
		return err
	}
	s.Previous = previous
	s.Current = code
	s.Staged = 0
	s.Failed = 0
	if s.HighWater < code {
		s.HighWater = code
	}
	return u.save(*s)
}

func (u *Updater) Run() error {
	if u.HealthWait == 0 {
		u.HealthWait = 20 * time.Second
	}
	if err := os.MkdirAll(u.Root, 0700); err != nil {
		return err
	}
	release, locked, err := u.OS.Lock(u.Root)
	if err != nil {
		return err
	}
	if !locked {
		u.OS.Foreground()
		return nil
	}
	defer release()
	u.event("launcher_start", 0)
	busy := u.OS.Busy()
	if busy {
		u.OS.Foreground()
		u.hide()
	}
	if err = u.ensureSeed(); err != nil {
		return err
	}
	s := u.state()
	if _, err = u.valid(s.Current); err != nil {
		u.event("current_invalid_recover", s.Current)
		if _, err = u.valid(s.Previous); err == nil {
			s.Current = s.Previous
		} else {
			s.Current = seedVersionCode
		}
	}
	if err = u.save(s); err != nil {
		return err
	}
	if busy && u.OS.Healthy(300*time.Millisecond) && u.OnReady != nil {
		u.OnReady()
	}
	u.status("Güncellemeler denetleniyor…")
	var m Manifest
	var raw []byte
	var feedErr error
	if u.Prefetched != nil {
		r := <-u.Prefetched
		u.Prefetched = nil
		m, raw, feedErr = r.Manifest, r.Raw, r.Err
	} else {
		m, raw, feedErr = fetchManifest(u.FeedClient, u.Trust)
	}
	if feedErr != nil {
		if errors.Is(feedErr, errNewLauncherRequired) {
			u.event("new_launcher_required_user_notified", m.VersionCode)
			if !busy {
				if err = u.launch(s.Current); err != nil {
					return err
				}
			}
			if u.RequireLauncher != nil {
				u.RequireLauncher()
			}
			return nil
		}
		u.event("update_check_unavailable_using_current", s.Current)
		if busy {
			return nil
		}
		if s.Staged > s.Current && s.Staged != s.Failed {
			if _, err = u.valid(s.Staged); err == nil {
				return u.activate(&s, s.Staged)
			}
		}
		return u.launch(s.Current)
	}
	if m.VersionCode < s.HighWater || m.VersionCode == s.Failed {
		u.event("rollback_or_failed_update_rejected", m.VersionCode)
		if busy {
			return nil
		}
		return u.launch(s.Current)
	}
	if existing, err := u.valid(m.VersionCode); err == nil {
		if existing.SHA256 != m.SHA256 || existing.Size != m.Size {
			u.event("immutable_release_conflict_using_current", m.VersionCode)
			if busy {
				return nil
			}
			return u.launch(s.Current)
		}
		if m.VersionCode != seedVersionCode {
			_ = u.writeJSON(filepath.Join(u.dir(m.VersionCode), "manifest.json"), json.RawMessage(raw))
		}
		if m.VersionCode > s.Current {
			return u.activate(&s, m.VersionCode)
		}
		if busy {
			return nil
		}
		return u.launch(s.Current)
	}
	if m.VersionCode <= s.HighWater {
		u.event("non_monotonic_update_rejected", m.VersionCode)
		if busy {
			return nil
		}
		return u.launch(s.Current)
	}
	u.status("Yeni sürüm güvenle indiriliyor…")
	// Once a valid signed feed says a new version exists, finish its bounded
	// download before the first GUI launch. Existing sessions still stay untouched.
	startedOld := busy
	err = u.download(m, raw)
	if err != nil {
		u.event("update_download_rejected_using_current", m.VersionCode)
		if startedOld {
			return nil
		}
		return u.launch(s.Current)
	}
	s.Staged = m.VersionCode
	s.HighWater = m.VersionCode
	if err = u.save(s); err != nil {
		return err
	}
	u.event("verified_update_staged", m.VersionCode)
	if startedOld || u.OS.Busy() {
		u.event("update_waits_for_full_exit", m.VersionCode)
		return nil
	}
	return u.activate(&s, m.VersionCode)
}

func defaultRoot() (string, error) {
	if fixtureRootBase64 != "" {
		b, err := base64.StdEncoding.Strict().DecodeString(fixtureRootBase64)
		if err != nil {
			return "", err
		}
		return string(b), nil
	}
	base, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(base, "BakimTRYardim", "Launcher"), nil
}
func (s State) String() string {
	return fmt.Sprintf("current=%d previous=%d staged=%d", s.Current, s.Previous, s.Staged)
}
