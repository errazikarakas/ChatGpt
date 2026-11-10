#!/usr/bin/env python3
"""Root-only test handoff: encrypt the fixture token to the verified ephemeral CI public key."""
import argparse,hashlib,json,os,pathlib,re,subprocess
p=argparse.ArgumentParser();p.add_argument('--public-key',type=pathlib.Path,required=True);p.add_argument('--run-id',required=True);a=p.parse_args()
assert os.geteuid()==0 and re.fullmatch(r'[0-9]{8,16}',a.run_id)
config=json.loads(pathlib.Path('/home/errazi/bakim-yardim-updater-20261111/android-fixture-private.json').read_text());token=config['fixture']
assert re.fullmatch(r'[0-9a-f]{32}',token)
result=subprocess.run(['openssl','pkeyutl','-encrypt','-pubin','-inkey',str(a.public_key),'-pkeyopt','rsa_padding_mode:oaep','-pkeyopt','rsa_oaep_md:sha256','-pkeyopt','rsa_mgf1_md:sha256'],input=token.encode(),check=True,capture_output=True)
assert 256<=len(result.stdout)<=1024
out=pathlib.Path('/var/www/html/bakim/assets/support')/('android-update-bootstrap-'+a.run_id+'.bin')
out.write_bytes(result.stdout);out.chmod(0o644)
print(json.dumps({'bootstrapReady':True,'runId':a.run_id,'publicKeySha256':hashlib.sha256(a.public_key.read_bytes()).hexdigest(),'encryptedBytes':len(result.stdout),'fixtureTokenPrinted':False}))
