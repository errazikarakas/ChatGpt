#!/usr/bin/env python3
"""CI test APK only: invoke the normal Android host callback; keep OS consent."""
import argparse
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True);a=p.parse_args()
f=a.source/'flutter/lib/main.dart';s=f.read_text()
old='  runApp(App());\n  await initUniLinks();'
new="""  runApp(App());
  // CI-only: run the standard Share Screen start callback after fixture consent.
  // The same callback still presents the normal Android MediaProjection dialog.
  if (isAndroid && const bool.fromEnvironment('BAKIM_ANDROID_SMOKE')) {
    Timer(const Duration(seconds: 6), () async {
      debugPrint('BAKIM_SMOKE_NORMAL_HOST_CALLBACK_START');
      try {
        await gFFI.serverModel.startService();
        debugPrint('BAKIM_SMOKE_NORMAL_HOST_CALLBACK_RETURNED');
      } catch (error) {
        debugPrint('BAKIM_SMOKE_NORMAL_HOST_CALLBACK_FAILED:${error.runtimeType}');
      }
    });
  }
  await initUniLinks();"""
if old not in s:raise RuntimeError('Pinned mobile startup anchor missing')
f.write_text(s.replace(old,new,1));print('CI-only Android host callback scheduled; OS capture approval remains required')
