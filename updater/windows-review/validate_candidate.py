import os,json,hashlib,struct,pathlib,shutil
root=pathlib.Path(__file__).resolve().parents[1]/'windows'
exe=root/'release/Bakim-TR-Yardim.exe'
seed=root/'launcher/seed/engine.exe'
h=lambda x:hashlib.sha256(x).hexdigest()
s=seed.read_bytes();b=exe.read_bytes()
expected='d9ec96f4c8b6fa14e95e5aec4dc8998c84072ec470f088bd6b84f481092835a1'
assert h(s)==expected and len(s)==28879872,'Original engine seed changed'
assert b[:2]==b'MZ'
pe=struct.unpack_from('<I',b,0x3c)[0]
assert b[pe:pe+4]==b'PE\0\0'
assert struct.unpack_from('<H',b,pe+4)[0]==0x8664
opt=pe+24
assert struct.unpack_from('<H',b,opt)[0]==0x20b
cert_offset,cert_size=struct.unpack_from('<II',b,opt+112+4*8)
assert cert_offset==0 and cert_size==0,'Candidate unexpectedly embedded-signed'
seed_offset=b.find(s)
assert seed_offset>=0,'Exact original seed missing from candidate'
for value in [b'dS7jt4SMbs05q2Od0C5btJQbh9BjBhQWcS2d6gQwPt0=',b'https://xn--bakm-nza.tr/yardim-guncelle.php?platform=windows-launcher']:
    assert value in b,'Compiled public update trust/config missing'
out=root.parent/'windows-review/release'
out.mkdir(parents=True,exist_ok=True)
name='Bakim-TR-Yardim-Review.exe'
shutil.copyfile(exe,out/name)
for license in ['AGPL-3.0.txt','LICENSE-GO.txt']:shutil.copyfile(root/license,out/license)
production=[p for p in (root/'launcher').glob('*.go') if not p.name.endswith('_test.go')]
meta={'status':'compiled_review_candidate_unverified_on_physical_windows','nativeRuntimeVerified':False,'productionActivationApproved':False,'sourceCommit':os.environ['GITHUB_SHA'],'buildRunId':int(os.environ['GITHUB_RUN_ID']),'launcherVersion':'1.0.0','launcherBuildCode':2026111101,'sha256':h(b),'size':len(b),'fileName':name,'embeddedOriginalSeedSha256':expected,'embeddedOriginalSeedSize':len(s),'embeddedOriginalSeedExactBytes':True,'embeddedSeedOffset':seed_offset,'peMachine':'amd64','embeddedAuthenticodeSignaturePresent':False,'compiledUpdatePublicKeyAndFeedVerified':True,'productionSourceSha256':{p.name:h(p.read_bytes()) for p in sorted(production)},'lastNativeGuiAttemptRunId':42930863428,'nativeTestBlock':'Normal Open File Security Warning awaited Run; CI consent helper UInt32-to-Object binder exception','warning':'Not a stable release. Native update/rollback/GUI validation has not passed. Windows security prompts are retained.'}
(out/'review.json').write_text(json.dumps(meta,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
(out/'SHA256SUMS').write_text(h(b)+'  '+name+'\n',encoding='ascii')
(out/'OKU.txt').write_text('BAKIM.TR YARDIM - INCELEME ADAYI\n\nBu dosya derlenmis inceleme adayidir. Gercek Windows ortaminda otomatik guncelleme/GUI testi henuz onaylanmamistir. Stabil uygulama yerine otomatik yayinlanmamistir. Windows guvenlik uyarilari korunur.\n',encoding='utf-8')
print(json.dumps({'reviewCandidate':True,'sha256':h(b),'size':len(b),'sourceCommit':meta['sourceCommit'],'originalSeedPreserved':True,'nativeRuntimeVerified':False}))
