#!/usr/bin/env python3
"""Normalize unpublished ABI version metadata, or create a newer emulator fixture; native/AOT bytes stay unchanged."""
import argparse,hashlib,json,pathlib,struct,zipfile
p=argparse.ArgumentParser();p.add_argument('--input',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--from-version',type=int,required=True);p.add_argument('--to-version',type=int,required=True);p.add_argument('--normalize-unpublished',action='store_true');a=p.parse_args()
assert 0<a.from_version<=2147483647 and 2026113001<a.to_version<=2147483647
assert a.normalize_unpublished or a.from_version<a.to_version
def length8(data,pos):
 value=data[pos];return (((value&127)<<8)|data[pos+1],pos+2) if value&128 else (value,pos+1)
def length16(data,pos):
 value=struct.unpack_from('<H',data,pos)[0];return (((value&32767)<<16)|struct.unpack_from('<H',data,pos+2)[0],pos+4) if value&32768 else (value,pos+2)
with zipfile.ZipFile(a.input) as original:
 data=bytearray(original.read('AndroidManifest.xml'));assert struct.unpack_from('<HH',data)==(3,8)
 cursor=8;strings=[];patches=0;package=None
 while cursor<len(data):
  kind,header,size=struct.unpack_from('<HHI',data,cursor);assert size>=header>=8
  if kind==1:
   count,_,flags,start,_=struct.unpack_from('<IIIII',data,cursor+8)
   for i in range(count):
    pos=cursor+start+struct.unpack_from('<I',data,cursor+header+i*4)[0]
    if flags&256:
     _,pos=length8(data,pos);n,pos=length8(data,pos);strings.append(bytes(data[pos:pos+n]).decode())
    else:n,pos=length16(data,pos);strings.append(bytes(data[pos:pos+n*2]).decode('utf-16le'))
  elif kind==258:
   ext=cursor+header;name=struct.unpack_from('<I',data,ext+4)[0]
   start,attrsize,count=struct.unpack_from('<HHH',data,ext+8)
   if strings[name]=='manifest':
    for i in range(count):
     attr=ext+start+i*attrsize;nameindex=struct.unpack_from('<I',data,attr+4)[0]
     if strings[nameindex]=='package':
      assert data[attr+15]==3;package=strings[struct.unpack_from('<I',data,attr+16)[0]]
     if strings[nameindex]=='versionCode':
      assert data[attr+15] in (16,17) and struct.unpack_from('<I',data,attr+16)[0]==a.from_version
      struct.pack_into('<I',data,attr+8,0xffffffff);struct.pack_into('<I',data,attr+16,a.to_version);patches+=1
  cursor+=size
 assert patches==1 and package=='tr.bakim.yardim'
 a.output.parent.mkdir(parents=True,exist_ok=True)
 with zipfile.ZipFile(a.output,'w') as out:
  for info in original.infolist():
   if info.filename.upper().startswith('META-INF/') and info.filename.upper().endswith(('.RSA','.DSA','.EC','.SF','.MF')):continue
   out.writestr(info,bytes(data) if info.filename=='AndroidManifest.xml' else original.read(info.filename))
with zipfile.ZipFile(a.input) as before,zipfile.ZipFile(a.output) as after:
 for name in before.namelist():
  if name.startswith('lib/') or name.endswith('kernel_blob.bin'):assert before.read(name)==after.read(name),name
print(json.dumps({'unpublishedAbiMetadataNormalization':a.normalize_unpublished,'testOnly':not a.normalize_unpublished,'oldVersionCode':a.from_version,'newVersionCode':a.to_version,'nativeAndAotUnchanged':True,'outputSha256':hashlib.sha256(a.output.read_bytes()).hexdigest()}))
