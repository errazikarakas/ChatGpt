#!/usr/bin/env python3
"""CI-only native video receipt telemetry; never alters connection or permission logic."""
import argparse
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True);a=p.parse_args();f=a.source/'flutter/lib/models/model.dart';s=f.read_text()
s=s.replace("import 'dart:convert';", "import 'dart:convert';\nimport 'dart:io';\nimport 'package:path_provider/path_provider.dart';",1)
anchor='typedef HandleMsgBox = Function(Map<String, dynamic> evt, String id);'
assert anchor in s
s=s.replace(anchor,'int _bakimControllerFrameCount = 0;\n\n'+anchor,1)
anchor='  Future<void> onEvent2UIRgba() async {\n';assert anchor in s
probe="""    if (isAndroid && const bool.fromEnvironment('BAKIM_ANDROID_SMOKE')) {
      _bakimControllerFrameCount++;
      if (_bakimControllerFrameCount < 5 || _bakimControllerFrameCount % 15 == 0) {
        try {
          final appDir = (await getApplicationDocumentsDirectory()).path;
          final proof = <String, dynamic>{
            'marker': 'bakim-android-controller-v1',
            'frameEventReceived': true,
            'frameCount': _bakimControllerFrameCount,
            'peerInfoReceived': ffiModel.pi.displays.isNotEmpty,
            'displayCount': ffiModel.pi.displays.length,
            'secure': ffiModel.secure == true,
            'direct': ffiModel.direct == true,
          };
          await File('$appDir/bakim-controller-session.json').writeAsString(jsonEncode(proof), flush: true);
        } catch (error) {
          debugPrint('BAKIM_CONTROLLER_PROOF_WRITE_FAILED:${error.runtimeType}');
        }
      }
    }
"""
s=s.replace(anchor,anchor+probe,1);f.write_text(s)
print('CI-only outgoing decoded-video event telemetry installed; normal deep-link and connection path unchanged')
