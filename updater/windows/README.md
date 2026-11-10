# Bakım.TR Yardım Windows başlatıcısı

Go1.27.4 standart kütüphanesiyle native x64 GUI. Mevcut doğrulanmış RustDesk motorunun baytları korunur; ilk açılış/offline geri dönüş imajı olarak pakete gömülür. Kurulum, servis veya yönetici hakkı gerektirmez.

Ortak root Ed25519 update envelope imzası, SHA256/boyut, exact HTTPS host/endpoint, platform/channel, monotonik versionCode, issuedAt/expiry ve minLauncher kontrol edilir. Zone.Identifier korunur; Windows IAttachmentExecute Save + ShellExecuteExW(open) antivirüs ve güvenlik onay akışını uygular. MotW/SmartScreen/Defender kapatılmaz. Geçerli Windows kod imzalama sertifikası henüz sağlanmadığı için uyarıların kalktığı iddia edilmez. sign_windows.ps1 yalnız geçerli codeSigning EKU ve Windows-trusted sertifika ile SHA256 zaman damgalı imzalama hook'udur.

%LOCALAPPDATA%/BakimTRYardim/Launcher/versions altında immutable sürümler, atomik current.json ve önceki/seed sürüm geri dönüşü vardır. Tek native mutex, Unicode isimli gerçek motor alt süreçleri ve GUI sağlığı takip edilir. Çalışan motor durdurulmaz. Metadata denetimleri paralel ve2.5sn ile sınırlıdır. Yeni sürüm imzalı metadata ile biliniyorsa60sn toplam sınır içindeki indirme tamamlanır ve aynı açılışta yeni sürüm açılır. Gerçek ağ/paket hatası veya timeoutta doğrulanmış mevcut sürüme dönülür. Aktif motor oturumu varsa yeni motor yalnız stage edilir ve mevcut süreçlere dokunulmaz.

Başlatıcı da ayrı windows-launcher imzalı kanalından otomatik güncellenir. Kalıcı indirme giriş dosyası eski kalsa bile en yeni doğrulanmış cached başlatıcıya delege olur. Ebeveyn/çocuk ayrı mutex kapılarını kullanır. Nonce, tam child PID/handle, imzalı dosya yolu ve Core.OnReady sonrası GUI ACK eşleşmeden launcher current pointer ilerlemez. Erken child çıkışında önceki doğrulanmış başlatıcıya veya mevcut yerel çekirdeğe dönülür; yalnız ebeveynin açtığı updater helper handle'ı sonlandırılabilir, RustDesk motorları sonlandırılmaz. Managed startup hatası parent'a kısa hata ACK'i verir; child modal hata dialogunda rollback'i bekletmez.

Windows testleri yalnız disposable CI makinesinde oluşturulan geçici codeSigning test yayıncısı ile yürütülür. Geçici public sertifika yalnız bu yönetici CI VM’sinin LocalMachine Root/TrustedPublisher depolarına eklenir; dışa aktarılamayan özel anahtar yalnız CurrentUser My deposunda kalır; dosya SHA256’ları imzalı katalogla doğrulanır, PE baytları değişmez. Test sonunda yalnız oluşturulan katalog/sertifika kaldırılır; PFX veya özel anahtar artifact olmaz. SmartScreen/Defender politikası ve Internet ZoneId=3 korunur. Bu CI güven modeli üretim kullanıcılarının imzasız uygulama uyarısının çözüldüğü anlamına gelmez. Test yardımcıları uygulamaya gömülmez ve dağıtılmaz. Gerçek seed motorun GUI alt süreci ayrıca başlatılır; outer process exit tek başına sağlık sayılmaz.

Microsoft: https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nn-shobjidl_core-iattachmentexecute
Go Ed25519: https://pkg.go.dev/crypto/ed25519

Windows yürütme API: https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shellexecuteexw
