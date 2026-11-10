package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"
)

// Launcher and engine have separate signed feeds and independent immutable stores.
// A managed child never waits for its parent's launcher-controller mutex.
type helperPlatform interface {
	Platform
	ProcessMatches(int, string) bool
	LaunchHelper(string) (*launchedHelper, error)
}
type launchedHelper struct {
	PID   int
	Alive func() bool
	Stop  func()
	Close func()
}
type handover struct {
	Nonce       string `json:"nonce"`
	VersionCode int64  `json:"versionCode"`
	SHA256      string `json:"sha256"`
	ParentPID   int    `json:"parentPid"`
	Deadline    string `json:"deadline"`
}
type readyAck struct {
	Nonce       string `json:"nonce"`
	VersionCode int64  `json:"versionCode"`
	PID         int    `json:"pid"`
	EngineReady bool   `json:"engineReady"`
	Error       string `json:"error,omitempty"`
}
type Delegator struct {
	Core      *Updater
	Store     *Updater
	OS        helperPlatform
	BuildCode int64
	AckWait   time.Duration
}

func newDelegator(core *Updater, platform helperPlatform) *Delegator {
	trust := launcherTrust()
	return &Delegator{Core: core, Store: &Updater{Root: filepath.Join(core.Root, "launchers"), FileName: "launcher.exe", Trust: trust, OS: platform, FeedClient: trust.client(2500 * time.Millisecond), DownloadClient: trust.client(60 * time.Second)}, OS: platform, BuildCode: launcherBuildCode(), AckWait: 90 * time.Second}
}
func (d *Delegator) state() State {
	var s State
	raw, err := os.ReadFile(filepath.Join(d.Store.Root, "current.json"))
	if err == nil {
		_ = json.Unmarshal(raw, &s)
	}
	if s.Current < d.BuildCode {
		s.Current = d.BuildCode
	}
	if s.HighWater < s.Current {
		s.HighWater = s.Current
	}
	return s
}
func (d *Delegator) requestPath() string { return filepath.Join(d.Store.Root, "handover.json") }
func (d *Delegator) ackPath(nonce string) string {
	return filepath.Join(d.Store.Root, "acks", nonce+".json")
}
func (d *Delegator) receiptPath(nonce string) string {
	return filepath.Join(d.Store.Root, "receipts", nonce+".json")
}

func (d *Delegator) managedRequest() (*handover, error) {
	raw, err := os.ReadFile(d.requestPath())
	if err != nil {
		return nil, err
	}
	var req handover
	if json.Unmarshal(raw, &req) != nil || len(req.Nonce) != 64 || req.VersionCode != d.BuildCode || req.ParentPID <= 0 {
		return nil, errors.New("managed handover identity rejected")
	}
	if _, err = hex.DecodeString(req.Nonce); err != nil {
		return nil, err
	}
	until, err := time.Parse(time.RFC3339Nano, req.Deadline)
	if err != nil || time.Now().After(until) || until.After(time.Now().Add(2*time.Minute)) {
		return nil, errors.New("managed handover expired")
	}
	if !d.OS.ProcessMatches(os.Getpid(), d.Store.path(d.BuildCode)) {
		return nil, errors.New("managed image location rejected")
	}
	m, err := d.Store.valid(d.BuildCode)
	if err != nil || m.SHA256 != req.SHA256 {
		return nil, errors.New("managed signed image rejected")
	}
	return &req, nil
}

// The callback is called by the new launcher only after its real engine GUI is
// visible. Parent receipt keeps the exact child PID alive for identity validation.
func (d *Delegator) ready(req *handover, cancelled <-chan struct{}) {
	deadline, _ := time.Parse(time.RFC3339Nano, req.Deadline)
	for time.Now().Before(deadline) {
		select {
		case <-cancelled:
			return
		default:
		}
		if d.OS.Healthy(200 * time.Millisecond) {
			ack := readyAck{Nonce: req.Nonce, VersionCode: d.BuildCode, PID: os.Getpid(), EngineReady: true}
			_ = os.MkdirAll(filepath.Dir(d.ackPath(req.Nonce)), 0700)
			if d.Store.writeJSON(d.ackPath(req.Nonce), ack) != nil {
				return
			}
			for time.Now().Before(deadline) {
				select {
				case <-cancelled:
					return
				default:
				}
				if _, err := os.Stat(d.receiptPath(req.Nonce)); err == nil {
					return
				}
				time.Sleep(75 * time.Millisecond)
			}
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func (d *Delegator) failed(req *handover, err error) {
	code := "startup_failed"
	if errors.Is(err, errUserDeclined) {
		code = "security_declined"
	}
	_ = os.MkdirAll(filepath.Dir(d.ackPath(req.Nonce)), 0700)
	_ = d.Store.writeJSON(d.ackPath(req.Nonce), readyAck{Nonce: req.Nonce, VersionCode: d.BuildCode, PID: os.Getpid(), Error: code})
	until := time.Now().Add(2 * time.Second)
	for time.Now().Before(until) {
		if _, err := os.Stat(d.receiptPath(req.Nonce)); err == nil {
			return
		}
		time.Sleep(40 * time.Millisecond)
	}
}

func (d *Delegator) delegate(code int64) (bool, error) {
	m, err := d.Store.valid(code)
	if err != nil {
		return false, err
	}
	nonce := make([]byte, 32)
	if _, err = rand.Read(nonce); err != nil {
		return false, err
	}
	req := handover{hex.EncodeToString(nonce), code, m.SHA256, os.Getpid(), time.Now().Add(d.AckWait).UTC().Format(time.RFC3339Nano)}
	if err = d.Store.writeJSON(d.requestPath(), req); err != nil {
		return false, err
	}
	child, launchErr := d.OS.LaunchHelper(d.Store.path(code))
	if launchErr != nil {
		return false, launchErr
	}
	defer child.Close()
	if child.PID <= 0 {
		return false, errors.New("managed helper process identity unavailable")
	}
	if err != nil {
		return false, err
	}
	until := time.Now().Add(d.AckWait)
	for time.Now().Before(until) {
		if !child.Alive() {
			return false, errors.New("new launcher exited before its readiness acknowledgement")
		}
		raw, err := os.ReadFile(d.ackPath(req.Nonce))
		if err == nil {
			var ack readyAck
			validIdentity := json.Unmarshal(raw, &ack) == nil && ack.Nonce == req.Nonce && ack.VersionCode == code && ack.PID == child.PID && d.OS.ProcessMatches(ack.PID, d.Store.path(code))
			if validIdentity && ack.Error != "" {
				_ = os.MkdirAll(filepath.Dir(d.receiptPath(req.Nonce)), 0700)
				_ = d.Store.writeJSON(d.receiptPath(req.Nonce), map[string]bool{"accepted": false})
				if ack.Error == "security_declined" {
					return false, errUserDeclined
				}
				return false, errors.New("managed launcher reported startup failure")
			}
			if validIdentity && ack.EngineReady && d.OS.Healthy(200*time.Millisecond) {
				_ = os.MkdirAll(filepath.Dir(d.receiptPath(req.Nonce)), 0700)
				_ = d.Store.writeJSON(d.receiptPath(req.Nonce), map[string]bool{"accepted": true})
				_ = os.Remove(d.requestPath())
				_ = os.Remove(d.ackPath(req.Nonce))
				return true, nil
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	// Only our newly launched updater helper may be stopped. RustDesk processes,
	// active desktop sessions, and the verified engine are never terminated.
	child.Stop()
	return false, errors.New("new launcher did not acknowledge actual GUI readiness")
}

func (d *Delegator) Run() (bool, error) {
	if err := os.MkdirAll(d.Store.Root, 0700); err != nil {
		return false, err
	}
	release, locked, err := d.OS.Lock(filepath.Join(d.Core.Root, "launcher-controller"))
	if err != nil {
		return false, err
	}
	if !locked {
		d.OS.Foreground()
		return true, nil
	}
	defer release()
	s := d.state()
	candidate := s.Current
	m, raw, feedErr := fetchManifest(d.Store.FeedClient, d.Store.Trust)
	if feedErr == nil && m.VersionCode >= s.HighWater && m.VersionCode > d.BuildCode && m.VersionCode != s.Failed {
		cached, cachedErr := d.Store.valid(m.VersionCode)
		if cachedErr == nil && cached.SHA256 != m.SHA256 {
			d.Core.event("launcher_immutable_metadata_conflict", m.VersionCode)
		} else if cachedErr == nil {
			candidate = m.VersionCode
		} else {
			d.Core.status("Uygulama güncellemesi indiriliyor…")
			err = d.Store.download(m, raw)
			if err == nil {
				candidate = m.VersionCode
				s.HighWater = m.VersionCode
				s.Staged = m.VersionCode
				_ = d.Store.save(s)
				d.Core.event("verified_launcher_staged", candidate)
			} else {
				d.Core.event("launcher_download_rejected", m.VersionCode)
			}
		}
	}
	if candidate <= d.BuildCode || candidate == s.Failed {
		return false, nil
	}
	if _, err = d.Store.valid(candidate); err != nil {
		return false, nil
	}
	engineRelease, engineFree, lockErr := d.OS.Lock(d.Core.Root)
	if lockErr != nil {
		return false, lockErr
	}
	if !engineFree {
		d.Core.event("launcher_waits_for_existing_updater", candidate)
		d.OS.Foreground()
		return false, nil
	}
	engineRelease()
	d.Core.status("Güncel uygulama açılıyor…")
	success, err := d.delegate(candidate)
	if success {
		if s.Current != candidate {
			s.Previous = s.Current
		}
		s.Current = candidate
		s.Staged = 0
		if s.HighWater < candidate {
			s.HighWater = candidate
		}
		_ = d.Store.save(s)
		d.Core.event("launcher_delegation_ready", candidate)
		d.Core.hide()
		return true, nil
	}
	if errors.Is(err, errUserDeclined) {
		s.Staged = candidate
		_ = d.Store.save(s)
		return true, err
	}
	s.Failed = candidate
	s.Staged = 0
	_ = d.Store.save(s)
	d.Core.event("launcher_failed_rollback", candidate)
	if s.Current > d.BuildCode && s.Current != candidate {
		if ok, _ := d.delegate(s.Current); ok {
			d.Core.event("previous_launcher_restored", s.Current)
			return true, nil
		}
	}
	return false, nil
}
