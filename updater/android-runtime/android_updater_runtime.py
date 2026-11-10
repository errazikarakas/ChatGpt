#!/usr/bin/env python3
"""Disposable AVD only. Secrets and production-signed test APKs never become artifacts."""
import argparse,hashlib,json,os,pathlib,re,subprocess,tempfile,time,unicodedata,urllib.request,urllib.parse,xml.etree.ElementTree as ET
p=argparse.ArgumentParser();p.add_argument('--bootstrap-url',required=True);p.add_argument('--private-key',type=pathlib.Path,required=True)
p.add_argument('--fixture-sha256',required=True);p.add_argument('--initial-sha256',required=True);p.add_argument('--output',type=pathlib.Path,required=True)
p.add_argument('--initial-version',type=int,default=2026113002);p.add_argument('--target-version',type=int,default=2026113003);p.add_argument('--timeout',type=int,default=300)
p.add_argument('--observe-only',action='store_true')
a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True);PACKAGE='tr.bakim.yardim';MAIN=PACKAGE+'/com.carriez.flutter_hbb.MainActivity'
report={'ok':False,'productionFeedModified':False,'productionPrivateKeyUploaded':False,'productionApkPublished':False,'signedTestApkPublishedAsArtifact':False,'fixtureTokenPublished':False,'physicalPhoneTested':False,'initialVersionCode':a.initial_version,'targetVersionCode':a.target_version,'testKind':'documented same-publisher Android self-update with source consent and system-controlled confirmation fallback'}
started=time.monotonic();token=None;error=None
def adb(*args,check=True,timeout=40,input=None):
 r=subprocess.run(['adb',*map(str,args)],input=input,capture_output=True,timeout=timeout)
 if check and r.returncode:raise RuntimeError('ADB operation failed')
 return r.stdout.decode(errors='replace')
def version():
 raw=adb('shell','dumpsys','package',PACKAGE,check=False);m=re.search(r'\bversionCode=(\d+)',raw);return int(m[1]) if m else 0
def resumed():
 raw=adb('shell','dumpsys','activity','activities',check=False)+'\n'+adb('shell','dumpsys','window','windows',check=False)
 return any(MAIN in line and any(marker in line for marker in ('mResumedActivity','topResumedActivity','mCurrentFocus','mFocusedApp')) for line in raw.splitlines())
def nodes():
 adb('shell','uiautomator','dump','/sdcard/bakim-updater-ui.xml',check=False,timeout=20)
 raw=adb('shell','cat','/sdcard/bakim-updater-ui.xml',check=False)
 try:return list(ET.fromstring(raw).iter('node'))
 except ET.ParseError:return []
def tap(node):
 m=re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',node.get('bounds',''))
 if not m:return False
 x,y,xx,yy=map(int,m.groups());adb('shell','input','tap',(x+xx)//2,(y+yy)//2);return True
def button(items,labels):
 def norm(text):return ''.join(c for c in unicodedata.normalize('NFKD',text).casefold() if not unicodedata.combining(c)).strip()
 for label in labels:
  for n in items:
   if n.get('enabled')=='true' and norm(n.get('text',''))==norm(label):
    return tap(n)
 return False
def launch():
 # A person opens the app on an unlocked, awake phone. Keep the disposable
 # AVD in that same foreground state; never grant app/install permissions here.
 adb('shell','input','keyevent','KEYCODE_WAKEUP',check=False)
 adb('shell','wm','dismiss-keyguard',check=False)
 adb('shell','svc','power','stayon','true',check=False)
 adb('shell','am','start','-W','-n',MAIN)
def reset_defer():
 adb('shell','am','force-stop',PACKAGE)
 adb('shell','run-as',PACKAGE,'rm','-f','shared_prefs/bakim-yardim-updater.xml')
 launch()
class SameOrigin(urllib.request.HTTPRedirectHandler):
 def redirect_request(self,req,fp,code,msg,headers,newurl):
  old=urllib.parse.urlsplit(req.full_url);new=urllib.parse.urlsplit(newurl)
  if (old.scheme,old.netloc)!=(new.scheme,new.netloc):raise RuntimeError('Cross-origin test redirect rejected')
  return super().redirect_request(req,fp,code,msg,headers,newurl)
http=urllib.request.build_opener(SameOrigin)
try:
 bootstrap=urllib.parse.urlsplit(a.bootstrap_url)
 if bootstrap.scheme!='https' or bootstrap.netloc!='xn--bakm-nza.tr' or not bootstrap.path.startswith('/assets/support/android-update-bootstrap-'):raise RuntimeError('Invalid test bootstrap origin')
 with tempfile.TemporaryDirectory(prefix='bakim-private-update-') as scratch:
  scratch=pathlib.Path(scratch);enc=scratch/'bootstrap.enc'
  for attempt in range(60):
   try:
    with http.open(a.bootstrap_url,timeout=10) as r:data=r.read(2048)
    if len(data)>1024:raise RuntimeError('Invalid encrypted fixture')
    enc.write_bytes(data);break
   except urllib.error.HTTPError as exc:
    if exc.code!=404:raise
    time.sleep(5)
  else:raise RuntimeError('Fixture bootstrap was not supplied within five minutes')
  secret=subprocess.run(['openssl','pkeyutl','-decrypt','-inkey',str(a.private_key),'-in',str(enc),'-pkeyopt','rsa_padding_mode:oaep','-pkeyopt','rsa_oaep_md:sha256','-pkeyopt','rsa_mgf1_md:sha256'],check=True,capture_output=True).stdout.decode().strip()
  if not re.fullmatch(r'[0-9a-f]{32}',secret) or hashlib.sha256(secret.encode()).hexdigest()!=a.fixture_sha256:raise RuntimeError('Wrong private fixture identity')
  token=secret;print('::add-mask::'+token,flush=True);secret=None
  url='https://xn--bakm-nza.tr/yardim-paket.php?'+urllib.parse.urlencode({'platform':'android','versionCode':a.initial_version,'fixture':token})
  apk=scratch/'private-initial.apk';h=hashlib.sha256()
  with http.open(url,timeout=30) as r,apk.open('wb') as output:
   total=0
   while True:
    chunk=r.read(1024*1024)
    if not chunk:break
    total+=len(chunk)
    if total>160*1024*1024:raise RuntimeError('Unexpected test APK size')
    output.write(chunk);h.update(chunk)
  if h.hexdigest()!=a.initial_sha256:raise RuntimeError('Private initial APK checksum mismatch')
  report['initialApkSha256Matched']=True
  report['lastStep']='install_initial_apk'
  adb('wait-for-device',timeout=60);adb('logcat','-c');adb('install','-r','-t',apk,timeout=120)
  if version()!=a.initial_version:raise RuntimeError('Initial version incorrect')
  report['initialVersionConfirmed']=True
  # Negative test setup only: start with the same untrusted-source state as
  # a fresh app. Positive permission is granted later ONLY through Settings UI.
  adb('shell','appops','set',PACKAGE,'REQUEST_INSTALL_PACKAGES','deny')
  report['sourceInitiallyDeniedForNegativeFixture']=True
  report['lastStep']='create_private_fixture_cache'
  adb('shell','run-as',PACKAGE,'mkdir','-p','cache/bakim-updates')
  # tee receives bytes on stdin; no nested adb-shell redirection or token argv.
  # Its echo is captured privately by adb(), never written to the job log.
  report['lastStep']='seed_private_fixture_token'
  adb('shell','run-as',PACKAGE,'tee','cache/bakim-updates/fixture.token',input=token.encode())
  if hashlib.sha256(adb('shell','run-as',PACKAGE,'cat','cache/bakim-updates/fixture.token').strip().encode()).hexdigest()!=a.fixture_sha256:raise RuntimeError('Private fixture injection failed')
  report['privateFixtureInjected']=True;report['lastStep']='normal_system_permission_flow'
  launch();phase='decline_permission';phase_started=time.monotonic();last_action=0
  while time.monotonic()-phase_started<a.timeout:
   if version()==a.target_version:
    report['targetVersionInstalled']=True;report['automaticRelaunchObserved']=resumed()
    prefs=adb('shell','run-as',PACKAGE,'cat','shared_prefs/bakim-yardim-updater.xml',check=False)
    try:
     pref=ET.fromstring(prefs).find("long[@name='lastInstalledVersion']")
     report['nativeSuccessCallbackVerifiedVersion']=pref is not None and pref.get('value')==str(a.target_version)
    except ET.ParseError:report['nativeSuccessCallbackVerifiedVersion']=False
    report['selfUpdateCompletedWithoutInstallConfirmation']=not report.get('actualSystemInstallConfirmed',False)
    report['frameworkUpdateMode']='no_additional_user_action' if report['selfUpdateCompletedWithoutInstallConfirmation'] else 'pending_user_action_fallback'
    if report['automaticRelaunchObserved'] and report['nativeSuccessCallbackVerifiedVersion']:break
   if time.monotonic()-last_action<2:time.sleep(1);continue
   items=nodes();last_action=time.monotonic();texts=[n.get('text','').strip().casefold() for n in items]
   report['lastPhase']=phase
   report['lastUiPackages']=sorted({n.get('package','') for n in items if n.get('package','') in (PACKAGE,'com.android.settings','com.android.packageinstaller','com.google.android.packageinstaller','com.android.permissioncontroller','com.google.android.permissioncontroller','com.android.systemui')})
   switches=[n for n in items if n.get('enabled')=='true' and ('switch' in n.get('class','').lower() or 'switch' in n.get('resource-id','').lower())]
   if not switches:
    controls=[n for n in items if n.get('package')=='com.android.settings' and n.get('enabled')=='true' and n.get('checkable')=='true']
    if len(controls)==1:switches=controls
   report['lastSystemSwitchNodes']=[{key:n.get(key) for key in ('class','resource-id','checkable','checked','clickable')} for n in switches[:8]]
   in_settings=any(n.get('package')=='com.android.settings' for n in items)
   if in_settings and not (a.output/'system-source-permission.png').exists():
    # Only the opaque Android Settings page is shareable. Never capture the
    # RustDesk screen or installer overlay, which could expose a temporary ID.
    focus=adb('shell','dumpsys','window','windows',check=False)+'\n'+adb('shell','dumpsys','activity','activities',check=False)
    report['lastForegroundComponents']=sorted({m[1] for line in focus.splitlines() if any(marker in line for marker in ('mCurrentFocus','mFocusedApp','mResumedActivity','topResumedActivity')) for m in re.finditer(r'([A-Za-z0-9._]+/[A-Za-z0-9._$]+)',line)})
    if any(any(marker in line for marker in ('mCurrentFocus','mFocusedApp','mResumedActivity','topResumedActivity')) and 'com.android.settings/' in line for line in focus.splitlines()):
     snap=subprocess.run(['adb','exec-out','screencap','-p'],capture_output=True,timeout=20).stdout
     if snap.startswith(b'\x89PNG\r\n\x1a\n'):(a.output/'system-source-permission.png').write_bytes(snap)
    clean=ET.Element('native-settings')
    for node in items:
     if node.get('package')=='com.android.settings':
      attrs={key:node.get(key,'') for key in ('class','resource-id','bounds','enabled','checked','checkable','clickable')}
      attrs['text']=re.sub(r'https?://\S+|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+|\b[0-9a-f]{32}\b|\b[0-9]{6,}\b','[redacted]',node.get('text',''))
      ET.SubElement(clean,'node',attrs)
    ET.ElementTree(clean).write(a.output/'system-source-permission-sanitized.xml',encoding='utf-8',xml_declaration=True)
    if a.observe_only:report['diagnosticOnly']=True;report['systemSourcePermissionObserved']=True;break
   is_installer=any('packageinstaller' in n.get('package','') or 'permissioncontroller' in n.get('package','') for n in items)
   has_update=any(t in ('update','güncelle','install','yükle') for t in texts)
   if phase=='decline_permission':
    if in_settings:
     report['normalUnknownSourcesSettingsShown']=True
     adb('shell','input','keyevent','KEYCODE_BACK');time.sleep(2)
     report['sourcePermissionDeclinePreservedVersion']=version()==a.initial_version
     report['sourcePermissionDeclineReturnedToCurrentApp']=resumed()
     reset_defer();phase='update';phase_started=time.monotonic()
    elif is_installer and has_update and button(items,['Cancel','İptal']):
     # Some developer-installed AVD packages are already trusted sources.
     # Do not add an artificial permission step that the OS does not require.
     report['sourcePermissionInitiallyAlreadyAllowed']=True
     report['normalAndroidInstallerShown']=True;report['systemInstallerDeclineUsed']=True;time.sleep(2)
     report['systemDeclinePreservedVersion']=version()==a.initial_version;report['systemDeclineReturnedToCurrentApp']=resumed()
     reset_defer();phase='update';phase_started=time.monotonic()
   else:
    if in_settings and switches:
     if switches[0].get('checked')!='true':tap(switches[0]);report['unknownSourcesGrantedThroughSystemUi']=True;time.sleep(1)
     adb('shell','input','keyevent','KEYCODE_BACK');continue
    if is_installer and has_update:
     report['normalAndroidInstallerShown']=True
     if phase=='update' and button(items,['Update','Güncelle','Install','Yükle']):
      report['actualSystemInstallConfirmed']=True;phase='installed';phase_started=time.monotonic();continue
    if phase=='installed' and version()==a.target_version:
     report['targetVersionInstalled']=True
     # No adb launch is allowed here: this verifies the actual callback restart.
     report['automaticRelaunchObserved']=resumed()
     prefs=adb('shell','run-as',PACKAGE,'cat','shared_prefs/bakim-yardim-updater.xml',check=False)
     try:
      pref=ET.fromstring(prefs).find("long[@name='lastInstalledVersion']")
      report['nativeSuccessCallbackVerifiedVersion']=pref is not None and pref.get('value')==str(a.target_version)
     except ET.ParseError:report['nativeSuccessCallbackVerifiedVersion']=False
     if report['automaticRelaunchObserved'] and report['nativeSuccessCallbackVerifiedVersion']:break
   time.sleep(1)
  else:raise RuntimeError('Normal Android update flow did not finish before the bounded deadline')
  report['publisherSignatureAcceptedByAndroidUpdate']=report.get('targetVersionInstalled',False)
except Exception as exc:error=type(exc).__name__
finally:
 try:
  report['actualInstalledVersionCode']=version()
  for suffix,key in [('.apk','cachedTargetBytes'),('.apk.partial','partialTargetBytes')]:
   value=adb('shell','run-as',PACKAGE,'stat','-c','%s',f'cache/bakim-updates/bakim-{a.target_version}'+suffix,check=False).strip()
   report[key]=int(value) if value.isdigit() else 0
  pref=adb('shell','run-as',PACKAGE,'cat','shared_prefs/bakim-yardim-updater.xml',check=False)
  try:
   node=ET.fromstring(pref).find("long[@name='deferUntil']")
   report['nativeUpdateDeferredUntilFuture']=node is not None and int(node.get('value','0'))>int(time.time()*1000)
  except (ET.ParseError,ValueError):report['nativeUpdateDeferredUntilFuture']=False
 except Exception:pass
 try:
  logs=adb('logcat','-d',check=False)
  report['updaterActivityStartObserved']=any('START' in line and 'BakimUpdateActivity' in line for line in logs.splitlines())
  report['unknownSourcesSettingsStartObserved']='MANAGE_UNKNOWN_APP_SOURCES' in logs
  report['nativeAppCrashObserved']=bool(re.search(r'Process: '+re.escape(PACKAGE)+r'[,\s]',logs))
  report['backgroundActivityLaunchBlocked']=any(PACKAGE in line and 'background activity' in line.lower() and ('blocked' in line.lower() or 'denied' in line.lower()) for line in logs.splitlines())
 except Exception:pass
 try:adb('shell','am','force-stop',PACKAGE,check=False)
 except Exception:pass
 try:a.private_key.unlink(missing_ok=True)
 except Exception:pass
 token=None
 report['errorType']=error;report['elapsedSeconds']=round(time.monotonic()-started,1)
 required=['initialApkSha256Matched','initialVersionConfirmed','privateFixtureInjected','sourcePermissionDeclinePreservedVersion','sourcePermissionDeclineReturnedToCurrentApp','normalUnknownSourcesSettingsShown','unknownSourcesGrantedThroughSystemUi','targetVersionInstalled','automaticRelaunchObserved','nativeSuccessCallbackVerifiedVersion','publisherSignatureAcceptedByAndroidUpdate']
 report['ok']=error is None and all(report.get(k) for k in required)
 (a.output/'android-updater-proof.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
 print(json.dumps(report,ensure_ascii=False))
raise SystemExit(0 if report['ok'] or report.get('diagnosticOnly') and report.get('systemSourcePermissionObserved') else 1)
