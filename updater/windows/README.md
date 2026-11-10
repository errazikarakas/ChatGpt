# Bakım.TR Yardım Windows başlatıcısı

Go1.27.4 standart kütüphanesiyle native x64 GUI. Mevcut doğrulanmış RustDesk motorunun baytları korunur; ilk açılış/offline geri dönüş imajı olarak pakete gömülür. Kurulum, servis veya yönetici hakkı gerektirmez.

Ortak root Ed25519 update envelope imzası, SHA256/boyut, exact HTTPS host/endpoint, platform/channel, monotonik versionCode, issuedAt/expiry ve minLauncher kontrol edilir. Zone.Identifier korunur; Windows IAttachmentExecute Save/Execute antivirüs ve güvenlik onay akışını uygular. MotW/SmartScreen/Defender kapatılmaz. Geçerli Windows kod imzalama sertifikası henüz sağlanmadığı için uyarıların kalktığı iddia edilmez. sign_windows.ps1 yalnız geçerli codeSigning EKU ve Windows-trusted sertifika ile SHA256 zaman damgalı imzalama hook'udur.

%LOCALAPPDATA%/BakimTRYardim/Launcher/versions altında immutable sürümler, atomik current.json ve önceki/seed sürüm geri dönüşü vardır. Tek native mutex, Unicode isimli gerçek motor alt süreçleri ve GUI sağlığı takip edilir. Çalışan motor durdurulmaz. Yavaş download8sn sonra mevcut sürüm açılır ve indirme arkaplanda yalnız stage edilir; sonraki tam uygulamadan çıkış/açılışta etkinleşir. Güncelleme kontrolü2.5sn, indirme toplam60sn ile sınırlıdır.

Bu ara v1 kaynak checkpoint'i motor updater testini içerir. Başlatıcının kendi signed-cache delegation güncellemesi sonraki checkpoint'te eklenecektir; minLauncher uyumsuzluğu sessizce geçilmez.

Windows test yardımcıları yalnız disposable CI makinesinde sentetik dosyalara normal Windows güvenlik onayı verir; uygulamaya gömülmez ve dağıtılmaz. Gerçek seed motorun GUI alt süreci ayrıca başlatılır; outer process exit tek başına sağlık sayılmaz.

Microsoft: https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nn-shobjidl_core-iattachmentexecute
Go Ed25519: https://pkg.go.dev/crypto/ed25519
