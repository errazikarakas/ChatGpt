//go:build windows

package main

import (
	"fmt"
	"os"
	"runtime"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

var createWindow = user.NewProc("CreateWindowExW")
var defWindow = user.NewProc("DefWindowProcW")
var registerClass = user.NewProc("RegisterClassExW")
var getMessage = user.NewProc("GetMessageW")
var translateMessage = user.NewProc("TranslateMessage")
var dispatchMessage = user.NewProc("DispatchMessageW")
var postMessage = user.NewProc("PostMessageW")
var destroyWindow = user.NewProc("DestroyWindow")
var quitMessage = user.NewProc("PostQuitMessage")
var setText = user.NewProc("SetWindowTextW")
var messageBox = user.NewProc("MessageBoxW")
var loadImage = user.NewProc("LoadImageW")
var getModule = kernel.NewProc("GetModuleHandleW")
var getMetrics = user.NewProc("GetSystemMetrics")
var openShell = syscall.NewLazyDLL("shell32.dll").NewProc("ShellExecuteW")

type windowClass struct {
	Size, Style                        uint32
	Proc                               uintptr
	ClassExtra, WindowExtra            int32
	Instance, Icon, Cursor, Background uintptr
	Menu, Class                        *uint16
	SmallIcon                          uintptr
}
type winMessage struct {
	Window         uintptr
	Message        uint32
	WParam, LParam uintptr
	Time           uint32
	X, Y           int32
	Private        uint32
}

func main() {
	runtime.LockOSThread()
	root, err := defaultRoot()
	if err != nil {
		return
	}
	instance, _, _ := getModule.Call(0)
	className := utf16("BakimTRYardimLauncherWindow")
	wndproc := syscall.NewCallback(func(h uintptr, msg uint32, w, l uintptr) uintptr {
		switch msg {
		case 0x8001:
			showWindow.Call(h, 0)
			return 0
		case 0x8002:
			destroyWindow.Call(h)
			return 0
		case 0x10:
			showWindow.Call(h, 0)
			return 0
		case 2:
			quitMessage.Call(0)
			return 0
		}
		result, _, _ := defWindow.Call(h, uintptr(msg), w, l)
		return result
	})
	icon, _, _ := loadImage.Call(instance, 101, 1, 64, 64, 0)
	wc := windowClass{Size: uint32(unsafe.Sizeof(windowClass{})), Proc: wndproc, Instance: instance, Icon: icon, SmallIcon: icon, Background: 6, Class: className}
	registerClass.Call(uintptr(unsafe.Pointer(&wc)))
	width, height := uintptr(420), uintptr(160)
	sx, _, _ := getMetrics.Call(0)
	sy, _, _ := getMetrics.Call(1)
	window, _, _ := createWindow.Call(0, uintptr(unsafe.Pointer(className)), uintptr(unsafe.Pointer(utf16(displayName))), 0x00C80000, (sx-width)/2, (sy-height)/2, width, height, 0, 0, instance, 0)
	if window == 0 {
		return
	}
	label, _, _ := createWindow.Call(0, uintptr(unsafe.Pointer(utf16("STATIC"))), uintptr(unsafe.Pointer(utf16("Yardım uygulaması hazırlanıyor…"))), 0x50000000, 30, 34, 355, 45, window, 0, instance, 0)
	createWindow.Call(0, uintptr(unsafe.Pointer(utf16("STATIC"))), uintptr(unsafe.Pointer(utf16("Bakım.TR"))), 0x50000000, 30, 91, 355, 20, window, 0, instance, 0)
	showWindow.Call(window, 5)
	osPlatform := newWindowsPlatform(root)
	osPlatform.Owner = window
	updater := &Updater{Root: root, Trust: productionTrust(), OS: osPlatform, FeedClient: productionTrust().client(2500 * time.Millisecond), DownloadClient: productionTrust().client(60 * time.Second), Status: func(text string) { setText.Call(label, uintptr(unsafe.Pointer(utf16(text)))) }, Hide: func() { postMessage.Call(window, 0x8001, 0, 0) }}
	updater.RequireLauncher = func() {
		text := "Uygulama güncellemesi şu anda tamamlanamadı. Mevcut sürümünüz açık kalacak; sonraki açılışta güncelleme otomatik yeniden denenecek."
		messageBox.Call(0, uintptr(unsafe.Pointer(utf16(text))), uintptr(unsafe.Pointer(utf16(displayName))), 0x40)
	}
	go func() {
		prefetch := make(chan manifestResult, 1)
		go func() {
			m, raw, e := fetchManifest(updater.FeedClient, updater.Trust)
			prefetch <- manifestResult{m, raw, e}
		}()
		updater.Prefetched = prefetch
		delegator := newDelegator(updater, osPlatform)
		var runErr error
		if req, managedErr := delegator.managedRequest(); managedErr == nil {
			ackDone := make(chan struct{})
			cancelled := make(chan struct{})
			coreReady := make(chan struct{})
			var readyOnce sync.Once
			updater.OnReady = func() { readyOnce.Do(func() { close(coreReady) }) }
			go func() {
				defer close(ackDone)
				deadline, _ := time.Parse(time.RFC3339Nano, req.Deadline)
				select {
				case <-coreReady:
					delegator.ready(req, cancelled)
				case <-cancelled:
				case <-time.After(time.Until(deadline)):
				}
			}()
			runErr = updater.Run()
			if runErr == nil {
				select {
				case <-coreReady:
				default:
					runErr = fmt.Errorf("managed core did not confirm a ready application")
				}
			}
			if runErr != nil {
				close(cancelled)
				<-ackDone
				delegator.failed(req, runErr)
				postMessage.Call(window, 0x8002, 0, 0)
				return
			}
			<-ackDone
		} else {
			if osPlatform.Busy() {
				osPlatform.Foreground()
				updater.hide()
			}
			handled, delegateErr := delegator.Run()
			if delegateErr != nil {
				runErr = delegateErr
			} else if !handled {
				runErr = updater.Run()
			}
		}
		if err := runErr; err != nil {
			updater.event("launch_failed", 0)
			text := "Yardım uygulaması açılamadı. Mevcut sürüm korunuyor. Lütfen uygulamadan tam çıktıktan sonra yeniden deneyin."
			if err == errUserDeclined {
				text = "Windows güvenlik onayı verilmediği için uygulama açılmadı. Güvenlik ayarlarınız değiştirilmedi."
			}
			messageBox.Call(window, uintptr(unsafe.Pointer(utf16(text))), uintptr(unsafe.Pointer(utf16(displayName))), 0x10)
		}
		postMessage.Call(window, 0x8002, 0, 0)
	}()
	var msg winMessage
	for {
		ok, _, _ := getMessage.Call(uintptr(unsafe.Pointer(&msg)), 0, 0, 0)
		if int32(ok) <= 0 {
			break
		}
		translateMessage.Call(uintptr(unsafe.Pointer(&msg)))
		dispatchMessage.Call(uintptr(unsafe.Pointer(&msg)))
	}
	_ = os.Stdout
}
