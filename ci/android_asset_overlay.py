#!/usr/bin/env python3
"""Reproducible final Flutter icon overlay; no executable/config/native changes."""
from __future__ import annotations
import argparse,hashlib,io,json,struct,zipfile
from pathlib import Path
from PIL import Image

# Flutter StandardMessageCodec subset used by the pinned AssetManifest.bin.
class Reader:
 def __init__(self,data):self.data=data;self.pos=0
 def take(self,n):v=self.data[self.pos:self.pos+n];self.pos+=n;return v
 def size(self):
  n=self.take(1)[0]
  return struct.unpack('<H' if n==254 else '<I',self.take(2 if n==254 else 4))[0] if n>=254 else n
 def value(self):
  tag=self.take(1)[0]
  if tag==0:return None
  if tag==1:return True
  if tag==2:return False
  if tag==7:return self.take(self.size()).decode('utf-8')
  if tag==12:return [self.value() for _ in range(self.size())]
  if tag==13:return {self.value():self.value() for _ in range(self.size())}
  raise ValueError('Unsupported pinned Flutter asset manifest type: '+str(tag))
def size(n):return bytes([n]) if n<254 else (b'\xfe'+struct.pack('<H',n) if n<=65535 else b'\xff'+struct.pack('<I',n))
def encode(v):
 if v is None:return b'\x00'
 if v is True:return b'\x01'
 if v is False:return b'\x02'
 if isinstance(v,str):d=v.encode();return b'\x07'+size(len(d))+d
 if isinstance(v,list):return b'\x0c'+size(len(v))+b''.join(encode(x) for x in v)
 if isinstance(v,dict):return b'\x0d'+size(len(v))+b''.join(encode(k)+encode(x) for k,x in v.items())
 raise ValueError('Unsupported asset manifest value')

ap=argparse.ArgumentParser();ap.add_argument('--input',type=Path,required=True);ap.add_argument('--output',type=Path,required=True);ap.add_argument('--logo',type=Path,required=True);a=ap.parse_args()
logo=Image.open(a.logo).convert('RGBA');logo.thumbnail((256,256),Image.Resampling.LANCZOS);buf=io.BytesIO();logo.save(buf,format='PNG');icon=buf.getvalue()
entry='assets/flutter_assets/assets/icon.png';binname='assets/flutter_assets/AssetManifest.bin';jsonname='assets/flutter_assets/AssetManifest.json'
with zipfile.ZipFile(a.input) as z:
 original=z.read(binname);reader=Reader(original);manifest=reader.value()
 if reader.pos!=len(original) or encode(manifest)!=original:raise ValueError('Asset manifest did not losslessly decode/re-encode')
 manifest['assets/icon.png']=[{'asset':'assets/icon.png'}]
 doc=json.loads(z.read(jsonname));doc['assets/icon.png']=['assets/icon.png']
 changes={entry:icon,binname:encode(manifest),jsonname:json.dumps(doc,separators=(',',':'),ensure_ascii=False).encode()}
 a.output.parent.mkdir(parents=True,exist_ok=True)
 with zipfile.ZipFile(a.output,'w') as out:
  written=set()
  for info in z.infolist():out.writestr(info,changes.get(info.filename,z.read(info.filename)));written.add(info.filename)
  for name,data in changes.items():
   if name not in written:out.writestr(name,data,compress_type=zipfile.ZIP_DEFLATED)
with zipfile.ZipFile(a.input) as before,zipfile.ZipFile(a.output) as after:
 for name in before.namelist():
  if name.endswith('.so') and before.read(name)!=after.read(name):raise RuntimeError('Executable/native library bytes changed')
 assert after.read(entry)==icon
report={'changedAssets':list(changes),'iconSha256':hashlib.sha256(icon).hexdigest(),'iconSize':list(logo.size),'nativeAndAotLibrariesUnchanged':True,'sourceTag':'1.5.1','requiresResigning':True}
a.output.with_suffix('.asset-overlay.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(report,ensure_ascii=False))
