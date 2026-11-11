# Bakım.TR Yardım Windows başlatıcısı

Go1.27.4 standart kütüphanesiyle native x64 portable GUI. Doğrulanmış RustDesk motoru d9ec96f4c8b6fa14e95e5aec4dc8998c84072ec470f088bd6b84f481092835a1 değişmeden gömülüdür. Kurulum veya servis oluşturmaz.

Ed25519 update envelope, SHA256/boyut, exact HTTPS host/endpoint, platform/channel, monotonik versionCode, issuedAt/expiry ve minLauncher doğrulanır. Zone.Identifier korunur; IAttachmentExecute.Save ve ShellExecuteExW(open) normal Windows güvenlik yoludur. Üretim uygulaması SmartScreen/Defender/AV veya kullanıcı güvenlik ayarlarını değiştirmez. Mevcut Windows Authenticode sertifikası bulunmadığı için üretim EXE imzasızdır; güvenlik/reputation uyarılarının kalktığı iddia edilmez. Geçerli sertifika için sign_windows.ps1 hook'u hazırdır.

Motor ve başlatıcı ayrı imzalı kanallardan güncellenir. Immutable sürüm dizinleri, atomik current.json, önceki/seed sürüme dönüş, tek native mutex ve çalışan engine/remote süreçlerinin korunması vardır. Yeni sürüm imzalı metadata ile biliniyorsa bounded indirme tamamlanır ve aynı açılışta güncel sürüm açılır; gerçek ağ/paket hatasında mevcut doğrulanmış sürüme dönülür. Aktif oturumda motor yalnız stage edilir. Başlatıcı nonce, gerçek child PID/handle, imzalı path ve Core.OnReady sonrası GUI ACK eşleşince current olur; erken child çıkışı önceki başlatıcıya döner. Engine süreçleri sonlandırılmaz.

%LOCALAPPDATA%/BakimTRYardim/Launcher altında çalışır. Önceki RustDesk kimlik/parola ve kendi sunucu ayarlarının namespace'i korunur. Üretim raw EXE ve seed test imzasıyla değiştirilmez.

## Windows test koşulu

Asıl native lifecycle testi yalnız GitHub-hosted disposable Windows2022 VM'de, açık CI opt-in ile tek Application Reputation test profili kullanır: HKLM64\SOFTWARE\Policies\Microsoft\Windows\System\EnableSmartScreen geçici DWORD0 yapılır. Özgün değer/türü, eksik anahtar zinciri ve exact run/job/source/runner/SID snapshot'ı alınır. Sonuç ne olursa olsun finally ve ikinci always cleanup ile aynen geri yüklenir; typedSnapshotRestored=true yayın kapısının parçasıdır. Defender Antivirus, Attachment Manager/MotW ve başka güvenlik ayarları değiştirilmez. Bu helper uygulamaya gömülmez, kullanıcı cihazlarında çağrılmaz. CI farkı üretimde Windows uyarılarının çözüldüğü anlamına gelmez.

Bu koşulda exact raw motor/Go kodu ile gerçek GUI, Ed25519/SHA kontrolü, update/rollback, native mutex, aktif süreç koruma, gerçek sonraki Go helper, exact PID/ACK ve erken çıkış geri dönüşü test edilir. Tam raw deliverable aynı test koşulunda gerçek Unicode engine GUI'sini açmalıdır. Profil geri yüklendikten sonraki normal unsigned açılış ayrı 45sn gözlemdir; OS onayı beklemesi uygulama fonksiyon başarısı gibi gösterilmez.

Ek disposable publisher araçları yalnız test amaçlıdır: geçici nonexportable CurrentUser My anahtarı, LocalMachine Root/TrustedPublisher public trust, signed catalog ve embedded fixture karşılaştırmaları. Üretim paketi test sertifikası/PFX/özel anahtar içermez. Aktif native test koşulu ve gerçek kapsam final proof JSON'undadır.

Microsoft yürütme API: https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shellexecuteexw
Microsoft test policy mapping: https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-windowsexplorer#enablesmartscreen
Go Ed25519: https://pkg.go.dev/crypto/ed25519
