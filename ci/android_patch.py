#!/usr/bin/env python3
"""Bakım.TR Yardım Android shell overlay; upstream native ABI stays unchanged."""
from __future__ import annotations
import argparse, hashlib, json, re, shutil, zipfile
from pathlib import Path
from PIL import Image

APP_NAME='Bakım.TR Yardım'
OPTIONS={
 'custom-rendezvous-server':'xn--bakm-nza.tr:21116',
 'relay-server':'xn--bakm-nza.tr:21117',
 'key':'v15Oj1NdzRE32xyZRKLlk2sfrP8AOLxx5ZxEV3JqYvM=',
 'access-mode':'custom','approve-mode':'click',
 'enable-keyboard':'Y','enable-clipboard':'Y','enable-file-transfer':'N',
 'enable-audio':'N','enable-camera':'N','enable-terminal':'N',
 'enable-tunnel':'N','enable-remote-printer':'N',
}
UPSTREAM_SHA256={
 'arm64-v8a':'cfc44193ef96dd601d25c9a29f1aa5385effdbaae33d2abbb1d88495797f6b84',
 'x86_64':'75977356cee4a2dd0c1dd8e93d09ea7f712aa4ef25f190fdad27b9e9200dbb33',
}

def replace_one(path:Path,old:str,new:str):
    text=path.read_text()
    if old not in text: raise RuntimeError(f'Expected upstream anchor missing: {path.name}')
    path.write_text(text.replace(old,new,1))

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--source',type=Path,required=True);ap.add_argument('--logo',type=Path,required=True);ap.add_argument('--upstream-apk',type=Path,required=True);ap.add_argument('--abi',choices=UPSTREAM_SHA256,default='arm64-v8a');a=ap.parse_args()
    root=a.source; flutter=root/'flutter'; android=flutter/'android'; app=android/'app'
    apk_hash=hashlib.sha256(a.upstream_apk.read_bytes()).hexdigest()
    if apk_hash!=UPSTREAM_SHA256[a.abi]:raise RuntimeError('Official 1.5.1 native APK digest mismatch for selected ABI')
    gradle=app/'build.gradle'
    replace_one(gradle,'applicationId "com.carriez.flutter_hbb"','applicationId "tr.bakim.yardim"')
    # No Rust build is performed: Maven AAR is the exact Cargo.lock-pinned package.
    txt=gradle.read_text();start=txt.index('String findRustlsPlatformVerifierMavenDir() {');end=txt.index('\n\nrepositories {',start)
    txt=txt[:start]+'''String findRustlsPlatformVerifierMavenDir() {
    def mavenDir = rootProject.file('native-maven')
    if (!mavenDir.isDirectory()) throw new GradleException("Pinned native Maven package missing")
    return mavenDir.path
}
'''+txt[end:];gradle.write_text(txt)
    replace_one(gradle,'signingConfig signingConfigs.release','signingConfig signingConfigs.debug')
    # Flutter debug engine/asset compression exceeds upstream's 1 GiB Gradle
    # heap on current Android Gradle Plugin. Bound parallel workers and give
    # the compiler its own 4 GiB heap on the disposable CI runner.
    props=android/'gradle.properties';proptext=props.read_text()
    proptext=re.sub(r'^org\.gradle\.jvmargs=.*$', 'org.gradle.jvmargs=-Xmx4g -XX:MaxMetaspaceSize=1g -XX:+HeapDumpOnOutOfMemoryError',proptext,flags=re.M)
    if 'org.gradle.workers.max=' not in proptext:proptext+='\norg.gradle.workers.max=2\n'
    props.write_text(proptext)
    # CI debug signature is replaced with the private production certificate on our server.
    replace_one(app/'src/main/AndroidManifest.xml','android:label="RustDesk"','android:label="Bakım.TR Yardım"')
    replace_one(app/'src/main/AndroidManifest.xml','android:label="RustDesk Input"','android:label="Bakım.TR Yardım · Kontrol"')
    strings=app/'src/main/res/values/strings.xml';txt=strings.read_text().replace('>RustDesk<','>Bakım.TR Yardım<').replace('when RustDesk screen sharing is established','when Bakım.TR Yardım screen sharing is established').replace('Keeps the RustDesk remote desktop host','Keeps the Bakım.TR Yardım remote desktop host');strings.write_text(txt)
    # The reused upstream native core deliberately retains its JNI package/classes.
    # Its visible app-name comes through Flutter; do not change native package names.
    common=flutter/'lib/common.dart';replace_one(common,"String get appName {\n", "String get appName {\n  if (isAndroid) return 'Bakım.TR Yardım';\n")
    home=flutter/'lib/mobile/pages/home_page.dart';home.write_text(home.read_text().replace('bind.mainGetAppNameSync()', 'appName'))
    main_dart=flutter/'lib/main.dart';main_dart.write_text(main_dart.read_text().replace(': bind.mainGetAppNameSync(),', ': appName,'))
    # The upstream Android service flow asks for a file-workspace/log folder
    # even before screen sharing. Skip that optional setup when file transfer
    # is disabled, keeping this support build free of unrelated folder prompts.
    server_model=flutter/'lib/models/server_model.dart'
    replace_one(server_model, '      if (isAndroid) {\n        try {\n          await AndroidDocuments.requireLogFolder();', '      if (isAndroid && bind.mainGetOptionSync(key: kOptionEnableFileTransfer) != \'N\') {\n        try {\n          await AndroidDocuments.requireLogFolder();')
    # Pre-seed BEFORE native mainInit invokes any rendezvous tests on the first launch.
    # Public server address/key only; no shared/embedded unattended access password.
    toml='[options]\n'+''.join(json.dumps(k)+' = '+json.dumps(v)+'\n' for k,v in OPTIONS.items())
    native=flutter/'lib/models/native_model.dart'
    seed="""      if (isAndroid) {
        final bakimConfig = File('$_dir/RustDesk2.toml');
        if (!await bakimConfig.exists()) {
          await bakimConfig.writeAsString(%s, flush: true);
        }
      }
"""%json.dumps(toml,ensure_ascii=False)
    replace_one(native,'      _ffiBind = RustdeskImpl(dylib);',seed+'      _ffiBind = RustdeskImpl(dylib);')
    # CI-only read-only diagnostics. The production APK has this flag off and
    # tree-shakes this block; no temporary password/private key enters the proof.
    native.write_text(native.read_text().replace("import 'dart:convert';", "import 'dart:async';\nimport 'dart:convert';",1))
    diag="""      if (isAndroid && const bool.fromEnvironment('BAKIM_ANDROID_SMOKE')) {
        Timer.periodic(const Duration(seconds: 2), (timer) async {
          try {
            final status = jsonDecode(await _ffiBind.mainGetConnectStatus());
            final proof = <String, dynamic>{
              'marker': 'bakim-android-smoke-v1',
              'appName': 'Bakım.TR Yardım',
              'id': await _ffiBind.mainGetMyId(),
              'connectStatus': status,
              'options': <String, String>{
                for (final key in <String>['custom-rendezvous-server', 'relay-server', 'key', 'enable-keyboard', 'enable-clipboard', 'enable-file-transfer', 'enable-audio', 'enable-camera', 'enable-terminal', 'enable-tunnel', 'enable-remote-printer'])
                  key: _ffiBind.mainGetOptionSync(key: key),
              },
            };
            await File('$_dir/bakim-smoke.json').writeAsString(jsonEncode(proof), flush: true);
          } catch (_) { /* Retry on the next heartbeat while native startup completes. */ }
        });
      }
"""
    replace_one(native,"        customClientConfig: '',\n      );", "        customClientConfig: '',\n      );\n"+diag)
    # Optional microphone/file modules are denied by presets; native Android permission
    # flows are retained unchanged so screen capture and accessibility stay OS-approved.
    image=Image.open(a.logo).convert('RGBA');bbox=image.getbbox();image=image.crop(bbox) if bbox else image
    for density,px in [('mdpi',48),('hdpi',72),('xhdpi',96),('xxhdpi',144),('xxxhdpi',192)]:
        out=app/'src/main/res'/f'mipmap-{density}';out.mkdir(parents=True,exist_ok=True)
        for name in ['ic_launcher.png','ic_launcher_round.png']:
            image.resize((px,px),Image.Resampling.LANCZOS).save(out/name)
        size=int(px*108/48);foreground=Image.new('RGBA',(size,size));n=int(size*0.66);foreground.alpha_composite(image.resize((n,n),Image.Resampling.LANCZOS),((size-n)//2,(size-n)//2));foreground.save(out/'ic_launcher_foreground.png')
    with zipfile.ZipFile(a.upstream_apk) as z:
        for name in ['librustdesk.so','libc++_shared.so']:
            data=z.read('lib/'+a.abi+'/'+name);out=app/'src/main/jniLibs'/a.abi/name;out.parent.mkdir(parents=True,exist_ok=True);out.write_bytes(data)
    report={'appName':APP_NAME,'applicationId':'tr.bakim.yardim','abi':a.abi,'upstreamTag':'1.5.1','upstreamApkSha256':apk_hash,'nativeCoreReused':True,'nativeCoreRecompiled':False,'firstRunServerPreset':True,'presets':OPTIONS,'requiredOsApprovals':['Android package installation','MediaProjection screen capture','Accessibility input control when needed']}
    (root/'bakim-android-build-manifest.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print('Android overlay applied: label, icon, isolated application ID, first-run server presets and exact upstream native core')

if __name__=='__main__':main()
