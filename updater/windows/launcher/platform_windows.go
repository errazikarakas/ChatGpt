//go:build windows

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

var (
	kernel           = syscall.NewLazyDLL("kernel32.dll")
	user             = syscall.NewLazyDLL("user32.dll")
	ole              = syscall.NewLazyDLL("ole32.dll")
	createMutex      = kernel.NewProc("CreateMutexW")
	releaseMutex     = kernel.NewProc("ReleaseMutex")
	closeHandle      = kernel.NewProc("CloseHandle")
	snapshot         = kernel.NewProc("CreateToolhelp32Snapshot")
	processFirst     = kernel.NewProc("Process32FirstW")
	processNext      = kernel.NewProc("Process32NextW")
	openProcess      = kernel.NewProc("OpenProcess")
	queryImage       = kernel.NewProc("QueryFullProcessImageNameW")
	moveFile         = kernel.NewProc("MoveFileExW")
	enumWindows      = user.NewProc("EnumWindows")
	windowPID        = user.NewProc("GetWindowThreadProcessId")
	windowVisible    = user.NewProc("IsWindowVisible")
	windowText       = user.NewProc("GetWindowTextW")
	showWindow       = user.NewProc("ShowWindow")
	foregroundWindow = user.NewProc("SetForegroundWindow")
	coInitialize     = ole.NewProc("CoInitializeEx")
	coUninitialize   = ole.NewProc("CoUninitialize")
	coCreate         = ole.NewProc("CoCreateInstance")
)

func utf16(s string) *uint16 {
	p, err := syscall.UTF16PtrFromString(s)
	if err != nil {
		panic("invalid native string")
	}
	return p
}
func nativeError(op string, e error) error { return fmt.Errorf("%s failed: %w", op, e) }
func hrError(hr uintptr) error {
	if int32(hr) < 0 {
		return fmt.Errorf("Windows trust service rejected operation (0x%08x)", uint32(hr))
	}
	return nil
}

type windowsPlatform struct{ root string }

func newWindowsPlatform(root string) *windowsPlatform { return &windowsPlatform{root: root} }
func (p *windowsPlatform) Lock(root string) (func(), bool, error) {
	runtime.LockOSThread()
	sum, _, _ := fileDigest(strings.NewReader(strings.ToLower(root)))
	name := utf16("Local\\BakimTRYardimUpdater." + sum[:24])
	h, _, err := createMutex.Call(0, 1, uintptr(unsafe.Pointer(name)))
	if h == 0 {
		runtime.UnlockOSThread()
		return nil, false, nativeError("CreateMutex", err)
	}
	if err == syscall.Errno(183) {
		closeHandle.Call(h)
		runtime.UnlockOSThread()
		return func() {}, false, nil
	}
	return func() { releaseMutex.Call(h); closeHandle.Call(h); runtime.UnlockOSThread() }, true, nil
}
func (p *windowsPlatform) AtomicReplace(from, to string) error {
	ok, _, err := moveFile.Call(uintptr(unsafe.Pointer(utf16(from))), uintptr(unsafe.Pointer(utf16(to))), 0x1|0x8)
	if ok == 0 {
		return nativeError("Atomic state replacement", err)
	}
	return nil
}

type processEntry struct {
	Size, Usage, PID          uint32
	Heap                      uintptr
	ModuleID, Threads, Parent uint32
	Priority                  int32
	Flags                     uint32
	File                      [260]uint16
}

func processes() map[uint32]string {
	result := map[uint32]string{}
	h, _, _ := snapshot.Call(2, 0)
	if h == ^uintptr(0) {
		return result
	}
	defer closeHandle.Call(h)
	var e processEntry
	e.Size = uint32(unsafe.Sizeof(e))
	ok, _, _ := processFirst.Call(h, uintptr(unsafe.Pointer(&e)))
	for ok != 0 {
		name := syscall.UTF16ToString(e.File[:])
		if strings.EqualFold(name, engineName) || strings.EqualFold(name, "engine.exe") || strings.EqualFold(name, "Bakim-TR-Yardim.exe") {
			if e.PID != uint32(os.Getpid()) {
				ph, _, _ := openProcess.Call(0x1000, 0, uintptr(e.PID))
				if ph != 0 {
					var path [32768]uint16
					n := uint32(len(path))
					got, _, _ := queryImage.Call(ph, 0, uintptr(unsafe.Pointer(&path[0])), uintptr(unsafe.Pointer(&n)))
					closeHandle.Call(ph)
					if got != 0 {
						result[e.PID] = syscall.UTF16ToString(path[:n])
					}
				}
			}
		}
		ok, _, _ = processNext.Call(h, uintptr(unsafe.Pointer(&e)))
	}
	return result
}
func (p *windowsPlatform) ours() map[uint32]string {
	result := map[uint32]string{}
	local, _ := os.UserCacheDir()
	native := strings.ToLower(filepath.Join(local, "bakım.tr yardım")) + string(os.PathSeparator)
	prefix := strings.ToLower(p.root) + string(os.PathSeparator)
	for pid, path := range processes() {
		low := strings.ToLower(path)
		if strings.HasPrefix(low, prefix) || strings.HasPrefix(low, native) || strings.EqualFold(filepath.Base(path), "Bakim-TR-Yardim.exe") {
			result[pid] = path
		}
	}
	return result
}
func (p *windowsPlatform) Busy() bool { return len(p.ours()) > 0 }
func (p *windowsPlatform) windows(visible bool, visit func(uintptr, string) bool) {
	own := p.ours()
	callback := syscall.NewCallback(func(h, unused uintptr) uintptr {
		var pid uint32
		windowPID.Call(h, uintptr(unsafe.Pointer(&pid)))
		if _, ok := own[pid]; !ok {
			return 1
		}
		if visible {
			shown, _, _ := windowVisible.Call(h)
			if shown == 0 {
				return 1
			}
		}
		var text [512]uint16
		windowText.Call(h, uintptr(unsafe.Pointer(&text[0])), uintptr(len(text)))
		if visit(h, syscall.UTF16ToString(text[:])) {
			return 0
		}
		return 1
	})
	enumWindows.Call(callback, 0)
}
func (p *windowsPlatform) Foreground() {
	p.windows(false, func(h uintptr, title string) bool {
		if title == displayName || strings.Contains(title, "Remote Desktop - "+displayName) {
			showWindow.Call(h, 9)
			foregroundWindow.Call(h)
			return true
		}
		return false
	})
}
func (p *windowsPlatform) Healthy(timeout time.Duration) bool {
	until := time.Now().Add(timeout)
	for time.Now().Before(until) {
		ready := false
		p.windows(true, func(h uintptr, title string) bool {
			if title == displayName || strings.Contains(title, "Remote Desktop - "+displayName) {
				ready = true
				return true
			}
			return false
		})
		if ready {
			return true
		}
		time.Sleep(150 * time.Millisecond)
	}
	return false
}

// IAttachmentExecute is the documented Windows security/Attachment Manager path.
// Its Save/Execute methods retain MOTW and may show Windows security approval UI.
type guid struct {
	A    uint32
	B, C uint16
	D    [8]byte
}

var attachmentClass = guid{0x4125dd96, 0xe03a, 0x4103, [8]byte{0x8f, 0x70, 0xe0, 0x59, 0x7d, 0x80, 0x3b, 0x9c}}
var attachmentIID = guid{0x73db1241, 0x1e85, 0x4581, [8]byte{0x8e, 0x4f, 0xa8, 0x1e, 0x1d, 0x0f, 0x8c, 0x57}}
var attachmentClient = guid{0xa96776e2, 0x03af, 0x40b9, [8]byte{0x97, 0x8f, 0xb4, 0x6a, 0xcb, 0x7c, 0xaa, 0x96}}

func withAttachment(path, source string, execute bool) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	hr, _, _ := coInitialize.Call(0, 2)
	if err := hrError(hr); err != nil {
		return err
	}
	defer coUninitialize.Call()
	var object uintptr
	hr, _, _ = coCreate.Call(uintptr(unsafe.Pointer(&attachmentClass)), 0, 1, uintptr(unsafe.Pointer(&attachmentIID)), uintptr(unsafe.Pointer(&object)))
	if err := hrError(hr); err != nil {
		return err
	}
	table := *(*uintptr)(unsafe.Pointer(object))
	method := func(index uintptr, args ...uintptr) uintptr {
		fn := *(*uintptr)(unsafe.Pointer(table + index*unsafe.Sizeof(uintptr(0))))
		values := append([]uintptr{object}, args...)
		result, _, _ := syscall.SyscallN(fn, values...)
		return result
	}
	defer method(2)
	if err := hrError(method(3, uintptr(unsafe.Pointer(utf16(displayName))))); err != nil {
		return err
	}
	if err := hrError(method(4, uintptr(unsafe.Pointer(&attachmentClient)))); err != nil {
		return err
	}
	if err := hrError(method(5, uintptr(unsafe.Pointer(utf16(path))))); err != nil {
		return err
	}
	if source != "" {
		if err := hrError(method(7, uintptr(unsafe.Pointer(utf16(source))))); err != nil {
			return err
		}
	}
	if execute {
		var handle uintptr
		hr = method(12, 0, 0, uintptr(unsafe.Pointer(&handle)))
		if handle != 0 {
			closeHandle.Call(handle)
		}
		if uint32(hr) == 0x800704c7 || uint32(hr) == 0x80004004 {
			return errUserDeclined
		}
		return hrError(hr)
	}
	return hrError(method(11))
}
func (p *windowsPlatform) Prepare(path, source string) error {
	// Origin evidence is deliberately preserved, never cleared or downgraded.
	zone := []byte("[ZoneTransfer]\r\nZoneId=3\r\nReferrerUrl=" + updateFeed + "\r\nHostUrl=" + source + "\r\n")
	if err := os.WriteFile(path+":Zone.Identifier", zone, 0600); err != nil {
		return errors.New("Windows origin metadata could not be retained")
	}
	if err := withAttachment(path, source, false); err != nil {
		return err
	}
	return os.WriteFile(path+":Zone.Identifier", zone, 0600)
}
func (p *windowsPlatform) Launch(path string) error { return withAttachment(path, "", true) }
func (p *windowsPlatform) Authenticode(path string, m Manifest) error {
	if !m.AuthenticodeRequired {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	script := `$ErrorActionPreference='Stop';$s=Get-AuthenticodeSignature -LiteralPath $env:BAKIM_SIGNATURE_FILE;[pscustomobject]@{valid=($s.Status -eq 'Valid');sha1=$s.SignerCertificate.Thumbprint;sha256=([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($s.SignerCertificate.RawData)).Replace('-',''))}|ConvertTo-Json -Compress`
	cmd := exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script)
	cmd.Env = append(os.Environ(), "BAKIM_SIGNATURE_FILE="+path)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	raw, err := cmd.Output()
	if err != nil {
		return errors.New("Authenticode trust verification failed")
	}
	var result struct {
		Valid  bool   `json:"valid"`
		SHA1   string `json:"sha1"`
		SHA256 string `json:"sha256"`
	}
	if json.Unmarshal(raw, &result) != nil || !result.Valid {
		return errors.New("Authenticode publisher is not Windows trusted")
	}
	for _, pin := range m.SignerThumbprints {
		if strings.EqualFold(pin, result.SHA256) || strings.EqualFold(pin, result.SHA1) {
			return nil
		}
	}
	return errors.New("Authenticode publisher pin mismatch")
}
