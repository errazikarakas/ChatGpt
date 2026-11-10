#!/usr/bin/env python3
"""Apply auditable Bakım.TR support branding to the exact upstream RustDesk 1.5.1 source."""
import argparse,base64,json,re,shutil,urllib.request,hashlib
from pathlib import Path
from PIL import Image

p=argparse.ArgumentParser();p.add_argument('--source',default='rustdesk');p.add_argument('--overlay',default='.');p.add_argument('--native',action='store_true');a=p.parse_args()
root=Path(a.source).resolve();overlay=Path(a.overlay).resolve();cfg=json.loads((overlay/'branding/client-public.json').read_text(encoding='utf-8'))
assert len(base64.b64decode(cfg['publicKey'],validate=True))==32
assert re.fullmatch(r'[a-z0-9.-]+:21116',cfg['idServer'])
logo_path=overlay/'branding/logo.png'
if not logo_path.exists():
 with urllib.request.urlopen(cfg['logoUrl'],timeout=30) as response:logo_path.write_bytes(response.read())
assert hashlib.sha256(logo_path.read_bytes()).hexdigest()==cfg['logoSha256'],'Branding logo digest mismatch'

def patch(path,old,new):
 f=root/path;s=f.read_text(encoding='utf-8');assert old in s,(path,old[:100]);f.write_text(s.replace(old,new),encoding='utf-8')
def rs(v):return json.dumps(v,ensure_ascii=False)

def rust_map(settings):
 return 'RwLock::new(HashMap::from(['+', '.join('('+rs(k)+'.to_owned(), '+rs(v)+'.to_owned())' for k,v in settings.items())+']))'
settings={'custom-rendezvous-server':cfg['idServer'],'relay-server':cfg['relayServer'],'key':cfg['publicKey'],'api-server':'','enable-keyboard':'Y','enable-clipboard':'Y','enable-file-transfer':'N','enable-audio':'N','enable-camera':'N','enable-terminal':'N','enable-remote-printer':'N','enable-tunnel':'N','approve-mode':'password-click'}
if a.native:
 path='libs/hbb_common/src/config.rs'
 patch(path,'RwLock::new("RustDesk".to_owned())','RwLock::new('+rs(cfg['appName'])+'.to_owned())')
 patch(path,'pub const RENDEZVOUS_SERVERS: &[&str] = &["rs-ny.rustdesk.com"];','pub const RENDEZVOUS_SERVERS: &[&str] = &['+rs(cfg['idServer'])+'];')
 patch(path,'pub const RS_PUB_KEY: &str = "OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=";','pub const RS_PUB_KEY: &str = '+rs(cfg['publicKey'])+';')
 for name,values in [('OVERWRITE_SETTINGS',settings),('HARD_SETTINGS',{'disable-installation':'Y','disable-account':'Y','disable-ab':'Y'}),('DEFAULT_LOCAL_SETTINGS',{'lang':'tr'})]:
  patch(path,'pub static ref '+name+': RwLock<HashMap<String, String>> = Default::default();','pub static ref '+name+': RwLock<HashMap<String, String>> = '+rust_map(values)+';')
 # Public diagnostic endpoint for release smoke tests; no IDs, passwords or private keys are emitted.
 diagnostic = """if args[0] == "--bakim-public-config" {
            let value = serde_json::json!({
                "appName": crate::get_app_name(),
                "version": crate::VERSION,
                "idServer": config::Config::get_option("custom-rendezvous-server"),
                "relayServer": config::Config::get_option("relay-server"),
                "publicKey": config::Config::get_option("key"),
                "fileTransfer": config::Config::get_option("enable-file-transfer"),
                "clipboard": config::Config::get_option("enable-clipboard"),
                "installationDisabled": config::is_disable_installation(),
                "keyConfirmed": config::Config::get_key_confirmed()
            });
            if let Some(path) = args.get(1) {
                let _ = std::fs::write(path, value.to_string());
            } else { println!("{}", value); }
            return None;
        } else if args[0] == "--version" {"""
 patch('src/core_main.rs','if args[0] == "--version" {',diagnostic)
 # Suppress update checks to upstream public RustDesk. These builds are updated from the support page.
 patch('flutter/lib/main.dart','  checkUpdate();','  // Bakim.TR Yardim updates are distributed from the help page.')
else:
 # Android reuses the exact released engine; configure its public settings before any service starts.
 lines='\n'.join('  await bind.mainSetOption(key: '+rs(k)+', value: '+rs(v)+');' for k,v in settings.items())
 patch('flutter/lib/main.dart','  await initGlobalFFI();','  await initGlobalFFI();\n'+lines)
 patch('flutter/lib/main.dart','  checkUpdate();','  // Bakim.TR Yardim updates are distributed from the help page.')
 patch('flutter/lib/common.dart','  final name = bind.mainGetAppNameSync();','  final name = '+rs(cfg['appName'])+';')
 patch('flutter/lib/common.dart',"String _appName = '';",'String _appName = '+rs(cfg['appName'])+';')
# Keep all license/copyright notices; only brand-facing product metadata changes.
for path in ['flutter/windows/runner/Runner.rc','libs/portable/Cargo.toml']:
 patch(path,'RustDesk Remote Desktop',cfg['appName'])
 patch(path,'ProductName = "RustDesk"','ProductName = '+rs(cfg['appName'])) if path.endswith('toml') else patch(path,'VALUE "ProductName", "RustDesk"','VALUE "ProductName", '+rs(cfg['appName']))
logo=Image.open(overlay/'branding/logo.png').convert('RGBA')
for name in ['logo.png','logo_light.png','logo_dark.png']:
 logo.save(root/'flutter/assets'/name)
for path in ['res/icon.ico','flutter/windows/runner/resources/app_icon.ico']:
 logo.save(root/path,format='ICO',sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])
# Portable container metadata has its own icon and app identity.
(root/'branding').mkdir(exist_ok=True)
shutil.copy2(overlay/'branding/client-public.json',root/'branding/client-public.json')
shutil.copy2(root/'LICENCE',root/'branding/AGPL-3.0.txt')
(root/'branding/NOTICE.txt').write_text('Bakım.TR Yardım\nRustDesk 1.5.1 tabanlıdır. RustDesk ve bağımlılıklarının telif/lisans bildirimleri korunmuştur.\nKaynak: '+cfg['sourceUrl']+'\n',encoding='utf-8')
print('Bakım.TR Yardım brand, public server binding and permission policy applied; no private credentials used.')
