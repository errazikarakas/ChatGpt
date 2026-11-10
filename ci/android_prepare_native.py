#!/usr/bin/env python3
"""Download only checksum-pinned public dependencies; never fetch/sign with secrets."""
import argparse, hashlib, io, shutil, tarfile, urllib.request
from pathlib import Path
ap=argparse.ArgumentParser();ap.add_argument('--source',type=Path,required=True);ap.add_argument('--output',type=Path,required=True);a=ap.parse_args();a.output.mkdir(parents=True,exist_ok=True)
url='https://github.com/rustdesk/rustdesk/releases/download/1.5.1/rustdesk-1.5.1-aarch64-signed.apk'
apk=a.output/'upstream-1.5.1-aarch64.apk'
if not apk.exists():
 with urllib.request.urlopen(url) as r,apk.open('wb') as f:shutil.copyfileobj(r,f)
if hashlib.sha256(apk.read_bytes()).hexdigest()!='cfc44193ef96dd601d25c9a29f1aa5385effdbaae33d2abbb1d88495797f6b84':raise RuntimeError('Official native APK checksum mismatch')
crate_url='https://static.crates.io/crates/rustls-platform-verifier-android/rustls-platform-verifier-android-0.1.1.crate'
with urllib.request.urlopen(crate_url) as r:data=r.read()
if hashlib.sha256(data).hexdigest()!='f87165f0995f63a9fbeea62b64d10b4d9d8e78ec6d7d51fb2125fda7bb36788f':raise RuntimeError('Cargo.lock-pinned Maven crate checksum mismatch')
with tarfile.open(fileobj=io.BytesIO(data),mode='r:gz') as tar:
 prefix='rustls-platform-verifier-android-0.1.1/maven/'
 for item in tar:
  if item.isfile() and item.name.startswith(prefix):
   relative=Path(item.name[len(prefix):])
   if '..' in relative.parts:raise RuntimeError('Invalid Maven path')
   out=a.source/'flutter/android/native-maven'/relative;out.parent.mkdir(parents=True,exist_ok=True);out.write_bytes(tar.extractfile(item).read())
print('Exact official 1.5.1 native APK and Cargo.lock-pinned Rustls Android Maven package verified')
