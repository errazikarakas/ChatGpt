#!/usr/bin/env python3
"""Apply only after the pinned Bakim branding and Android native overlay."""
from pathlib import Path
import argparse,json,re,shutil

p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True);p.add_argument('--assets',type=Path,default=Path(__file__).parent)
p.add_argument('--version-code',type=int,default=2026113002);p.add_argument('--version-name',default='1.5.1-bakim.2');a=p.parse_args()
assert 2026113001<a.version_code<=2147483647
root=a.source;flutter=root/'flutter';app=flutter/'android/app';assets=a.assets
def replace(path,old,new):
 s=path.read_text();assert s.count(old)==1,(str(path),old,s.count(old));path.write_text(s.replace(old,new,1))

pubspec=flutter/'pubspec.yaml'
s=pubspec.read_text();assert 'cryptography:' not in s
s=s.replace('  ffi: ^2.1.0','  cryptography: 2.7.0\n  crypto: 3.0.6\n  ffi: ^2.1.0',1)
s=re.sub(r'^version: .*$',f'version: {a.version_name}+{a.version_code}',s,flags=re.M);pubspec.write_text(s)
# Force a monotonic Android code even if an old workflow supplies build-number.
replace(app/'build.gradle','versionCode flutterVersionCode.toInteger()',f'versionCode {a.version_code}')
replace(app/'build.gradle','versionName flutterVersionName',f'versionName {json.dumps(a.version_name)}')

dart=flutter/'lib/bakim';dart.mkdir(exist_ok=True)
for name in ['bakim_android_updater.dart','bakim_update_feed.dart']:shutil.copyfile(assets/name,dart/name)
kotlin=app/'src/main/kotlin/com/carriez/flutter_hbb'
for name in ['BakimUpdater.kt','BakimUpdateActivity.kt']:shutil.copyfile(assets/name,kotlin/name)
replace(kotlin/'MainActivity.kt','        super.configureFlutterEngine(flutterEngine)','        super.configureFlutterEngine(flutterEngine)\n        BakimUpdater.register(this, flutterEngine)')
manifest=app/'src/main/AndroidManifest.xml'
replace(manifest,'    <uses-permission android:name="android.permission.INTERNET" />','    <uses-permission android:name="android.permission.INTERNET" />\n    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />')
replace(manifest,'        <activity\n            android:name=".PermissionRequestTransparentActivity"','        <activity\n            android:name=".BakimUpdateActivity"\n            android:exported="false"\n            android:launchMode="singleTop"\n            android:configChanges="orientation|screenSize|keyboardHidden"\n            android:theme="@android:style/Theme.Material.Light.NoActionBar" />\n\n        <activity\n            android:name=".PermissionRequestTransparentActivity"')
main=flutter/'lib/main.dart'
replace(main,"import 'dart:io';","import 'dart:io';\nimport 'bakim/bakim_android_updater.dart';")
s=main.read_text();start=s.index('void runMobileApp() async {');anchor='  runApp(App());';pos=s.index(anchor,start)+len(anchor)
s=s[:pos]+"\n  if (isAndroid) { unawaited(BakimAndroidUpdater.checkAtStartup()); }"+s[pos:];main.write_text(s)
manifest_path=root/'bakim-android-build-manifest.json'
m=json.loads(manifest_path.read_text());m.update({'versionName':a.version_name,'versionCode':a.version_code,'signedFeedAutoCheck':True,'updateFeed':'https://xn--bakm-nza.tr/yardim-guncelle.php?platform=android','mandatorySystemInstallApproval':True,'publisherCertificateSha256':'8965892c1419f7bcdead4dc152c8b2916d43e3a8e71521cd7e0ac4d6333e7341'});manifest_path.write_text(json.dumps(m,ensure_ascii=False,indent=2)+'\n')
print('Signed own-server Android updater installed; system approval and monotonic same-publisher update required')
