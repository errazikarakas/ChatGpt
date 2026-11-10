#!/usr/bin/env python3
"""Run only in a disposable Android emulator. Publish booleans, never credentials."""
from __future__ import annotations
import argparse,hashlib,json,os,pathlib,re,subprocess,time,unicodedata,xml.etree.ElementTree as ET
ap=argparse.ArgumentParser();ap.add_argument('--apk',type=pathlib.Path,required=True);ap.add_argument('--output',type=pathlib.Path,required=True);ap.add_argument('--timeout',type=int,default=180);a=ap.parse_args();a.output.mkdir(parents=True,exist_ok=True)
PACKAGE='tr.bakim.yardim';APP='Bakım.TR Yardım';EXPECTED={'custom-rendezvous-server':'xn--bakm-nza.tr:21116','relay-server':'xn--bakm-nza.tr:21117','key':'v15Oj1NdzRE32xyZRKLlk2sfrP8AOLxx5ZxEV3JqYvM=','enable-keyboard':'Y','enable-clipboard':'Y','enable-file-transfer':'N','enable-audio':'N','enable-camera':'N','enable-terminal':'N','enable-tunnel':'N','enable-remote-printer':'N'}

def adb(*args,timeout=35,check=True):
 p=subprocess.run(['adb',*map(str,args)],capture_output=True,timeout=timeout)
 if check and p.returncode:raise RuntimeError('ADB operation failed: '+str(args[0]))
 return p.stdout

def norm(s):return unicodedata.normalize('NFKD',s).casefold().replace('\u0307','')
def tap_bounds(bounds):
 m=re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',bounds or '')
 if not m:return False
 x1,y1,x2,y2=map(int,m.groups())
 if x2<=x1 or y2<=y1:return False
 adb('shell','input','tap',(x1+x2)//2,(y1+y2)//2);return True

def ui_nodes():
 adb('shell','uiautomator','dump','/sdcard/bakim-ui.xml',timeout=20,check=False)
 raw=adb('shell','cat','/sdcard/bakim-ui.xml',check=False).decode(errors='replace')
 try:return list(ET.fromstring(raw).iter('node'))
 except ET.ParseError:return []

def auto_os_and_screen(nodes):
 # Only our disposable emulator is touched; production app still requires user OS approval.
 # Dialog confirmations must win over the navigation tab underneath them.
 # RustDesk's first host startup also has a deliberate twelve-second warning.
 for node in nodes:
  rid=node.get('resource-id','')
  if rid.endswith(('/permission_allow_button','/permission_allow_foreground_only_button','/start_button')) and node.get('enabled')=='true' and tap_bounds(node.get('bounds')):return 'os_permission'
 choices=('i agree','kabul ediyorum','start now','start recording','şimdi başlat','kaydı başlat','ok','tamam','allow','while using the app','izin ver','uygulamayı kullanırken','start service','hizmeti başlat','servisi başlat','screen capture','ekran görüntüsü','share screen','ekranı paylaş','ekran paylaşımı')
 for choice in choices:
  key=norm(choice)
  for node in nodes:
   text=norm(node.get('text','')+' '+node.get('content-desc','')).strip()
   if node.get('enabled')!='true':continue
   if node.get('selected')=='true' and choice in ('share screen','ekranı paylaş','ekran paylaşımı'):continue
   if node.get('checked')=='true' and choice in ('screen capture','ekran görüntüsü'):continue
   if text==key or text.startswith(key+'\n') or text.startswith(key+' tab '):
    if tap_bounds(node.get('bounds')):return choice
 return None

def read_heartbeat():
 raw=adb('shell','run-as',PACKAGE,'cat','app_flutter/bakim-smoke.json',check=False).decode(errors='replace')
 try:return json.loads(raw)
 except Exception:return {}

report={'app':'Bakım.TR Yardım','testPackage':PACKAGE,'testApkSha256':hashlib.sha256(a.apk.read_bytes()).hexdigest(),'realNativeApplicationLaunch':False,'labelMatched':False,'nativeDiagnosticReady':False,'idPresent':False,'online':False,'ownServerConfigMatched':False,'disabledFeaturesMatched':False,'noPublicServerInLogs':None,'physicalPhoneTested':False,'smokeRuntimeOnly':True,'uiActions':[]}
started=time.time();heartbeat={};error=None
try:
 sdk=pathlib.Path(os.environ.get('ANDROID_HOME',os.environ.get('ANDROID_SDK_ROOT','/usr/local/lib/android/sdk')))
 aapts=sorted(sdk.glob('build-tools/*/aapt2'))
 if aapts:
  badging=subprocess.check_output([str(aapts[-1]),'dump','badging',str(a.apk)],text=True)
  report['labelMatched']=APP in badging and "package: name='tr.bakim.yardim'" in badging
 adb('wait-for-device',timeout=60);adb('logcat','-c');adb('install','-r','-t',a.apk,timeout=90)
 # Stateless protocol check from inside the AVD, separate from app/service UI.
 # Unknown RegisterPeer asks for a public key and does not create a device row.
 try:
  probe_id=b'bakim-avd-network-probe';inner=b'\x0a'+bytes([len(probe_id)])+probe_id;packet=b'\x32'+bytes([len(inner)])+inner
  probe=subprocess.run(['adb','shell','toybox','nc','-u','-w','5','xn--bakm-nza.tr','21116'],input=packet,capture_output=True,timeout=12)
  report['avdUdpProbeSupported']=probe.returncode==0
  report['avdUdpOwnServerResponded']=b'\x3a\x02\x10\x01' in probe.stdout
 except Exception:
  report['avdUdpProbeSupported']=False;report['avdUdpOwnServerResponded']=False
 # Test fixture grants only to this app on this disposable emulator. These are
 # the same permissions a person must approve on a physical phone; the release
 # app does not contain ADB or any permission bypass.
 adb('shell','settings','put','secure','enabled_accessibility_services',PACKAGE+'/com.carriez.flutter_hbb.InputService')
 adb('shell','settings','put','secure','accessibility_enabled','1')
 adb('shell','appops','set',PACKAGE,'SYSTEM_ALERT_WINDOW','allow',check=False)
 adb('shell','pm','grant',PACKAGE,'android.permission.POST_NOTIFICATIONS',check=False)
 report['testOnlyAccessibilityPermissionGranted']=True
 adb('shell','settings','put','global','window_animation_scale','0');adb('shell','settings','put','global','transition_animation_scale','0')
 adb('shell','am','start','-W','-n',PACKAGE+'/com.carriez.flutter_hbb.MainActivity',timeout=45)
 initial_fallback=False;last_ui=0
 while time.time()-started<a.timeout:
  time.sleep(2);heartbeat=read_heartbeat()
  pid=adb('shell','pidof',PACKAGE,check=False).decode().strip();report['realNativeApplicationLaunch']=bool(pid)
  if heartbeat.get('marker')=='bakim-android-smoke-v1':
   report['nativeDiagnosticReady']=True;opts=heartbeat.get('options') or {}
   report['ownServerConfigMatched']=all(opts.get(k)==EXPECTED[k] for k in ('custom-rendezvous-server','relay-server','key'))
   report['disabledFeaturesMatched']=all(opts.get(k)==v for k,v in EXPECTED.items() if k.startswith('enable-') and v=='N')
   report['keyboardAndClipboardEnabled']=all(k in opts and opts[k]!='N' for k in ('enable-keyboard','enable-clipboard'))
   report['idPresent']=bool(re.fullmatch(r'[0-9]{6,14}',str(heartbeat.get('id','')).replace(' ','')))
   report['online']=int((heartbeat.get('connectStatus') or {}).get('status_num',0))>0
  if time.time()-last_ui>8:
   nodes=ui_nodes();texts=[n.get('text','')+' '+n.get('content-desc','') for n in nodes]
   report['labelMatched']=report['labelMatched'] or any(APP in t for t in texts)
   acted=auto_os_and_screen(nodes);last_ui=time.time()
   if acted and len(report['uiActions'])<40:report['uiActions'].append(acted)
   # Flutter semantics may be absent before Android accessibility is enabled.
   if not acted and not initial_fallback and time.time()-started>15:
    size=adb('shell','wm','size').decode();m=re.search(r'(\d+)x(\d+)',size)
    if m:
     w,h=map(int,m.groups());adb('shell','input','tap',int(w*0.625),h-28);initial_fallback=True;report['uiActions'].append('share_tab_coordinate_fallback')
  if report['nativeDiagnosticReady'] and report['ownServerConfigMatched'] and report['disabledFeaturesMatched'] and report['online'] and report['idPresent']:break
 logs=adb('logcat','-d',check=False).decode(errors='replace')
 report['normalHostCallbackStarted']='BAKIM_SMOKE_NORMAL_HOST_CALLBACK_START' in logs
 report['normalHostCallbackReturned']='BAKIM_SMOKE_NORMAL_HOST_CALLBACK_RETURNED' in logs
 report['noPublicServerInLogs']=not any(host in logs.lower() for host in ('rs-ny.rustdesk.com','rs-sg.rustdesk.com','rs-cn.rustdesk.com'))
 report['nativeCrashObserved']=bool(re.search(r'AndroidRuntime.*Process: '+re.escape(PACKAGE)+r'[,\s]',logs)) or ('signal 11 (SIGSEGV)' in logs and PACKAGE in logs)
 activities=adb('shell','dumpsys','activity','activities',check=False).decode(errors='replace')
 report['labelMatched']=report['labelMatched'] or APP in activities
 resumed=re.search(r'mResumedActivity:.*? ([A-Za-z0-9_.]+/[A-Za-z0-9_.$]+)',activities)
 report['lastActivityComponent']=resumed.group(1) if resumed else None
 services=adb('shell','dumpsys','activity','services',PACKAGE,check=False).decode(errors='replace')
 report['androidHostServiceRunning']='MainService' in services
 projection=adb('shell','dumpsys','media_projection',check=False).decode(errors='replace')
 report['mediaProjectionActive']=PACKAGE in projection
 # Private config is inspected only for non-secret public presets, never exported.
 raw=adb('shell','run-as',PACKAGE,'cat','app_flutter/RustDesk2.toml',check=False).decode(errors='replace')
 report['persistedOwnServerMatched']=all(v in raw for v in (EXPECTED['custom-rendezvous-server'],EXPECTED['relay-server'],EXPECTED['key']))
 # Do not publish full-screen images: an upstream sharing widget can display a
 # temporary password. AAPT label + native telemetry prove brand/runtime state
 # without exporting any device password, ID, private configuration or pixels.
 report['screenshotPublished']=False
except Exception as exc:error=type(exc).__name__+': '+str(exc)
finally:
 adb('shell','am','force-stop',PACKAGE,check=False)
 report['elapsedSeconds']=round(time.time()-started,1)
 report['error']=error
 required=['realNativeApplicationLaunch','labelMatched','nativeDiagnosticReady','ownServerConfigMatched','disabledFeaturesMatched','keyboardAndClipboardEnabled','idPresent','online','persistedOwnServerMatched','noPublicServerInLogs']
 report['ok']=error is None and all(report.get(k) for k in required) and not report.get('nativeCrashObserved',False)
 (a.output/'android-smoke.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
 print(json.dumps(report,ensure_ascii=False))
raise SystemExit(0 if report['ok'] else 1)
