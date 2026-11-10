# Bakım.TR Yardım bakım notları

Windows ana kullanıcı akışı, uygulamanın ID kutusuna karşı bilgisayarın kimliğini yazıp Bağlan düğmesini veya Enter tuşunu kullanmaktır. Üretim indirme bağlantısı doğrudan taşınabilir EXE dosyasını sunar.

1.5.1 tabanındaki bu özelleştirmede uygulama adı Türkçe ve boşluk içerir. Upstream `get_uri_prefix()` uygulama adından URI şeması ürettiği için CLI `--connect` ve özel derin bağlantı URI akışları bilinen sınırlamadır; bunlar dağıtılan web akışında kullanılmaz. Sonraki native kaynak güncellemesinde URI prefixi `bakimtryardim://` gibi sabit ASCII şemaya ayrılmalı, kayıt ve yönlendirme noktaları birlikte test edilmelidir. Mevcut asıl ID kutusu / Bağlan akışı doğrudan Flutter pencere yöneticisini kullanır.

Üretim Windows paketi içindeki çalıştırılabilir dosyanın adı `Bakım.TR Yardım.exe` ve ayrı portable önbellek klasörü `bakım.tr yardım` olmalıdır. Bu, native portable hizmetinin uygulama adı ile süreç adını eşleştirmesini korur.
