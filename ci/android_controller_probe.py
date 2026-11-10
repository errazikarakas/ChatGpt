#!/usr/bin/env python3
"""Android -> isolated Linux real desktop session using the ordinary deep link."""
import argparse,hashlib,json,pathlib,re,subprocess,time,urllib.request,urllib.parse
p=argparse.ArgumentParser();p.add_argument('--apk',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--target-url',default='https://xn--bakm-nza.tr/assets/support/test-target.json');p.add_argument('--timeout',type=int,default=180);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
PACKAGE='tr.bakim.yardim'
def adb(*args,timeout=40,check=True):
 q=subprocess.run(['adb',*map(str,args)],capture_output=True,timeout=timeout)
 if check and q.returncode:raise RuntimeError('ADB operation failed: '+str(args[0]))
 return q.stdout

def app_json(name):
 raw=adb('shell','run-as',PACKAGE,'cat','app_flutter/'+name,check=False).decode(errors='replace')
 try:return json.loads(raw)
 except Exception:return {}
report={'role':'Android controller -> isolated Linux target','productionApkChanged':False,'testApkSha256':hashlib.sha256(a.apk.read_bytes()).hexdigest(),'physicalPhoneTested':False,'realNativeAppStarted':False,'nativeHeartbeatReady':False,'ownServerConfigMatched':False,'controllerPreannounced':False,'normalDeepLinkUsed':False,'realVideoFrameReceived':False,'secureSession':False,'targetPeerInfoReceived':False,'relayUsed':None,'noPrivateIdOrPasswordPublished':True,'screenshotPublished':False}
start=time.time();error=None;frame={}
try:
 with urllib.request.urlopen(a.target_url,timeout=25) as r:target=json.load(r)
 target_id=str(target['targetId'])
 if not re.fullmatch(r'[A-Za-z0-9_-]{6,64}',target_id):raise RuntimeError('Isolated target identity invalid')
 adb('wait-for-device',timeout=60);adb('logcat','-c');adb('install','-r','-t',a.apk,timeout=90)
 adb('shell','pm','grant',PACKAGE,'android.permission.POST_NOTIFICATIONS',check=False)
 adb('shell','am','start','-W','-n',PACKAGE+'/com.carriez.flutter_hbb.MainActivity')
 hb={}
 for _ in range(25):
  time.sleep(2);hb=app_json('bakim-smoke.json')
  if hb.get('marker')=='bakim-android-smoke-v1':break
 report['realNativeAppStarted']=bool(adb('shell','pidof',PACKAGE,check=False).decode().strip())
 report['nativeHeartbeatReady']=hb.get('marker')=='bakim-android-smoke-v1'
 opts=hb.get('options') or {};report['ownServerConfigMatched']=opts.get('custom-rendezvous-server')=='xn--bakm-nza.tr:21116' and opts.get('relay-server')=='xn--bakm-nza.tr:21117' and opts.get('key')=='v15Oj1NdzRE32xyZRKLlk2sfrP8AOLxx5ZxEV3JqYvM='
 controller=str(hb.get('id','')).replace(' ','')
 if not re.fullmatch(r'[0-9]{6,14}',controller):raise RuntimeError('CI controller identity not ready')
 report['controllerIdSha256']=hashlib.sha256(controller.encode()).hexdigest()
 # GET is a harmless announcement logged by our isolated target observer, not
 # a password or an instruction to any production account/device.
 announce=a.target_url+('?' if '?' not in a.target_url else '&')+urllib.parse.urlencode({'controllerId':controller,'role':'android'})
 with urllib.request.urlopen(announce,timeout=20) as r:r.read()
 report['controllerPreannounced']=True
 time.sleep(8)
 # The normal /connect/<id> form preserves custom mixed-case IDs in the path;
 # URI authority normalization would lowercase a custom target ID.
 uri='rustdesk://connect/'+target_id+'?relay=1'
 adb('shell','am','start','-W','-a','android.intent.action.VIEW','-d',uri,'-n',PACKAGE+'/com.carriez.flutter_hbb.MainActivity')
 report['normalDeepLinkUsed']=True
 while time.time()-start<a.timeout:
  time.sleep(2);frame=app_json('bakim-controller-session.json')
  if frame.get('marker')=='bakim-android-controller-v1':
   report['realVideoFrameReceived']=frame.get('frameEventReceived') is True and int(frame.get('frameCount',0))>0
   report['frameCount']=int(frame.get('frameCount',0));report['targetPeerInfoReceived']=frame.get('peerInfoReceived') is True and int(frame.get('displayCount',0))>0
   report['secureSession']=frame.get('secure') is True;report['relayUsed']=frame.get('direct') is False
   if report['realVideoFrameReceived'] and report['targetPeerInfoReceived'] and report['secureSession']:break
 logs=adb('logcat','-d',check=False).decode(errors='replace')
 report['nativeCrashObserved']=bool(re.search(r'AndroidRuntime.*Process: '+re.escape(PACKAGE)+r'[,\s]',logs))
 report['noPublicServerInLogs']=not any(h in logs.lower() for h in ('rs-ny.rustdesk.com','rs-sg.rustdesk.com','rs-cn.rustdesk.com'))
except Exception as exc:error=type(exc).__name__ # Do not export URLs, IDs, configuration or password text.
finally:
 adb('shell','am','force-stop',PACKAGE,check=False)
 report['elapsedSeconds']=round(time.time()-start,1);report['errorType']=error
 required=['realNativeAppStarted','nativeHeartbeatReady','ownServerConfigMatched','controllerPreannounced','normalDeepLinkUsed','realVideoFrameReceived','secureSession','targetPeerInfoReceived','relayUsed','noPublicServerInLogs']
 report['ok']=error is None and all(report.get(k) for k in required) and not report.get('nativeCrashObserved',False)
 (a.output/'android-controller-proof.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
 print(json.dumps(report,ensure_ascii=False))
raise SystemExit(0 if report['ok'] else 1)
