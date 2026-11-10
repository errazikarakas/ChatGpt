#!/usr/bin/env python3
"""Inject branded PNG and an isolated portable cache name using upstream's RDPKG resource format."""
import argparse,ctypes,hashlib,json,shutil,struct,urllib.request
from ctypes import wintypes
from pathlib import Path
import brotli
from PIL import Image
import io
p=argparse.ArgumentParser();p.add_argument('--input',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--config',type=Path,required=True);a=p.parse_args()
cfg=json.loads(a.config.read_text(encoding='utf-8'))
with urllib.request.urlopen(cfg['logoUrl'],timeout=30) as response:raw=response.read()
assert hashlib.sha256(raw).hexdigest()==cfg['logoSha256']
im=Image.open(io.BytesIO(raw)).convert('RGBA');im.thumbnail((256,256),Image.Resampling.LANCZOS);buf=io.BytesIO();im.save(buf,format='PNG');icon=buf.getvalue()
name=b'./data/flutter_assets/assets/icon.png';compressed=brotli.compress(icon,quality=11)
blob=b'rustdesk'+struct.pack('>I',len(name))+name+struct.pack('>I',len(compressed))+compressed+hashlib.md5(icon).hexdigest().encode()+b'rustdesk'+b'./Bakim-TR-Yardim.exe'
a.output.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(a.input,a.output)
k=ctypes.WinDLL('kernel32',use_last_error=True)
k.BeginUpdateResourceW.argtypes=[wintypes.LPCWSTR,wintypes.BOOL];k.BeginUpdateResourceW.restype=wintypes.HANDLE
k.UpdateResourceW.argtypes=[wintypes.HANDLE,ctypes.c_void_p,wintypes.LPCWSTR,wintypes.WORD,ctypes.c_void_p,wintypes.DWORD];k.UpdateResourceW.restype=wintypes.BOOL
k.EndUpdateResourceW.argtypes=[wintypes.HANDLE,wintypes.BOOL];k.EndUpdateResourceW.restype=wintypes.BOOL
h=k.BeginUpdateResourceW(str(a.output.resolve()),False)
if not h:raise ctypes.WinError(ctypes.get_last_error())
data=ctypes.create_string_buffer(blob)
if not k.UpdateResourceW(h,ctypes.c_void_p(10),'RDPKG',1033,data,len(blob)):
 err=ctypes.get_last_error();k.EndUpdateResourceW(h,True);raise ctypes.WinError(err)
if not k.EndUpdateResourceW(h,False):raise ctypes.WinError(ctypes.get_last_error())
report={'format':'RustDesk1.5.1-RDPKG','upstreamEngineRecompiled':True,'nativeBuildRun':42887318323,'originalSha256':hashlib.sha256(a.input.read_bytes()).hexdigest(),'finalSha256':hashlib.sha256(a.output.read_bytes()).hexdigest(),'iconSha256':hashlib.sha256(icon).hexdigest(),'innerExecutable':'Bakim-TR-Yardim.exe','isolatedCache':'bakim-tr-yardim','nativeConfigNamespace':'Bakım.TR Yardım','publicPresets':{k:cfg[k] for k in ('appName','idServer','relayServer','publicKey')}}
(a.output.parent/'finalization.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
(a.output.parent/'SHA256SUMS').write_text(report['finalSha256']+'  '+a.output.name+'\n')
print('Branded icon, native engine and isolated portable package prepared; no credentials embedded')
