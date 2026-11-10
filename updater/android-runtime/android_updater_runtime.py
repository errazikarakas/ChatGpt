#!/usr/bin/env python3
"""Disposable AVD only. Secrets and production-signed test APKs never become artifacts."""
import argparse,hashlib,json,os,pathlib,re,subprocess,tempfile,time,urllib.request,urllib.parse,xml.etree.ElementTree as ET
p=argparse.ArgumentParser();p.add_argument('--bootstrap-url',required=True);p.add_argument('--private-key',type=pathlib.Path,required=True)
p.add_argument('--fixture-sha256',required=True);p.add_argument('--initial-sha256',required=True);p.add_argument('--output',type=pathlib.Path,required=True)
p.add_argument('--initial-version',type=int,default=2026113002);p.add_argument('--target-version',type=int,default=2026113003);p.add_argument('--timeout',type=int,default=300)
a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True);PACKAGE='tr.bakim.yardim';MAIN=PACKAGE+'/com.carriez.flutter_hbb.MainActivity'
report={'ok':False,'productionFeedModified':False,'productionPrivateKeyUploaded':False,'productionApkPublished':False,'signedTestApkPublishedAsArtifact':False,'fixtureTokenPublished':False,'physicalPhoneTested':False,'initialVersionCode':a.initial_version,'targetVersionCode':a.target_version,'testKind':'real Android PackageInstaller self-update with actual user UI approval'}
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
 for label in labels:
  for n in items:
   if n.get('enabled')=='true' and n.get('text','').strip().casefold()==label.casefold():
    return tap(n)
 return False
def launch():adb('shell','am','start','-W','-n',MAIN)
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
  adb('wait-for-device',timeout=60);adb('install','-r','-t',apk,timeout=120)
  if version()!=a.initial_version:raise RuntimeError('Initial version incorrect')
  report['initialVersionConfirmed']=True
  adb('shell','run-as',PACKAGE,'mkdir','-p','cache/bakim-updates')
  adb('shell','run-as',PACKAGE,'sh','-c','cat > cache/bakim-updates/fixture.token',input=token.encode())
  launch();phase='decline_app';phase_started=time.monotonic();last_action=0;grant_return=False
  while time.monotonic()-phase_started<a.timeout:
   if time.monotonic()-last_action<2:time.sleep(1);continue
   items=nodes();last_action=time.monotonic();texts=[n.get('text','').strip().casefold() for n in items]
   if phase=='decline_app':
    if button(items,['Şimdi değil']):
     report['applicationDeclineUsed']=True;time.sleep(2)
     report['applicationDeclinePreservedVersion']=version()==a.initial_version
     report['applicationDeclineReturnedToCurrentApp']=resumed()
     reset_defer();phase='decline_os';phase_started=time.monotonic()
   else:
    if button(items,['İzni aç']):report['normalUnknownSourcesExplanationShown']=True;grant_return=True;continue
    if grant_return:
     switches=[n for n in items if n.get('checkable')=='true' and ('switch' in n.get('class','').lower() or 'switch' in n.get('resource-id','').lower())]
     if switches:
      if switches[0].get('checked')!='true':tap(switches[0]);report['unknownSourcesGrantedThroughSystemUi']=True;time.sleep(1)
      adb('shell','input','keyevent','KEYCODE_BACK');grant_return=False;continue
    is_installer=any('packageinstaller' in n.get('package','') or 'permissioncontroller' in n.get('package','') for n in items)
    has_update=any(t in ('update','güncelle','install','yükle') for t in texts)
    if is_installer and has_update:
     report['normalAndroidInstallerShown']=True
     if phase=='decline_os' and button(items,['Cancel','İptal']):
      report['systemInstallerDeclineUsed']=True;time.sleep(2)
      report['systemDeclinePreservedVersion']=version()==a.initial_version
      report['systemDeclineReturnedToCurrentApp']=resumed()
      reset_defer();phase='accept_os';phase_started=time.monotonic();continue
     if phase=='accept_os' and button(items,['Update','Güncelle','Install','Yükle']):
      report['actualSystemInstallConfirmed']=True;phase='installed';phase_started=time.monotonic();continue
    if phase=='installed' and version()==a.target_version:
     report['targetVersionInstalled']=True
     # No adb launch is allowed here: this verifies the actual callback restart.
     report['automaticRelaunchObserved']=resumed()
     prefs=adb('shell','run-as',PACKAGE,'cat','shared_prefs/bakim-yardim-updater.xml',check=False)
     report['nativeSuccessCallbackVerifiedVersion']=f'name="lastInstalledVersion" value="{a.target_version}"' in prefs
     if report['automaticRelaunchObserved'] and report['nativeSuccessCallbackVerifiedVersion']:break
   time.sleep(1)
  else:raise RuntimeError('Normal Android update flow did not finish before the bounded deadline')
  report['publisherSignatureAcceptedByAndroidUpdate']=report.get('targetVersionInstalled',False)
except Exception as exc:error=type(exc).__name__
finally:
 try:adb('shell','am','force-stop',PACKAGE,check=False)
 except Exception:pass
 try:a.private_key.unlink(missing_ok=True)
 except Exception:pass
 token=None
 report['errorType']=error;report['elapsedSeconds']=round(time.monotonic()-started,1)
 required=['initialApkSha256Matched','initialVersionConfirmed','applicationDeclinePreservedVersion','applicationDeclineReturnedToCurrentApp','normalUnknownSourcesExplanationShown','unknownSourcesGrantedThroughSystemUi','normalAndroidInstallerShown','systemDeclinePreservedVersion','systemDeclineReturnedToCurrentApp','actualSystemInstallConfirmed','targetVersionInstalled','automaticRelaunchObserved','nativeSuccessCallbackVerifiedVersion','publisherSignatureAcceptedByAndroidUpdate']
 report['ok']=error is None and all(report.get(k) for k in required)
 (a.output/'android-updater-proof.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
 print(json.dumps(report,ensure_ascii=False))
raise SystemExit(0 if report['ok'] else 1)
