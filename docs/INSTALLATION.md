# Kurulum ve işletim rehberi

Bu rehber ilk iterasyonu macOS/OrbStack veya Docker Engine çalıştırabilen Linux üzerinde kurar. Ana yol container tabanlıdır; işletim sistemi yalnız Docker kurulum adımını değiştirir. Uygulama stack'i ve kabul komutları bütün platformlarda aynıdır.

## 1. Kurulum modelini doğru okuyun

Bu repo varsayılan olarak tek bir fiziksel/virtual host üzerinde iki PostgreSQL container'ı açar:

1. Kaynak PostgreSQL: host loopback `5432`, container `5432`
2. Repository PostgreSQL: host loopback `5433`, container `5433`

Bunlara collector, API ve web container'ları eklenir. Sürekli sentetik trafik üreten `workload` container'ı yalnız isteğe bağlı `demo` profiliyle açılır. Bu ayrım PDF'deki “tek test sunucusu, iki PostgreSQL instance” kararının çalıştırılabilir halidir.

Üretim benzeri dış erişimde yalnız web portu `5173` açılır. DB ve API portları `.env.example` içinde `127.0.0.1` adresine bağlıdır. Web container'ındaki Nginx, `/api` isteklerini Docker iç ağındaki FastAPI'ye taşır.

## 2. Ön koşullar

Minimum geliştirme/test önerisi:

- 4 CPU
- 8 GiB RAM
- Image'lar ve volume'ler için en az 15 GiB boş disk
- Docker Engine + Compose v2 veya OrbStack
- İlk build için GitHub, PyPI ve container registry erişimi
- `bash`, `curl`, `python3`

Kontrol:

```bash
docker info
docker compose version
```

Her iki komut da hatasız dönmelidir. Linux'ta `permission denied` alırsanız Docker komutlarını `sudo` ile çalıştırın veya yalnız güvenilen operasyon kullanıcısını `docker` grubuna ekleyin. `docker` grubu pratikte root seviyesinde yetki verir.

## 3. Platforma göre Docker kurulumu

### 3.1 macOS + OrbStack

1. OrbStack'i açın ve durumunun running olmasını bekleyin.
2. Terminalde context'i doğrulayın:

   ```bash
   docker context show
   docker info
   docker compose version
   ```

3. İsteğe bağlı basit runtime testi:

   ```bash
   docker run --rm hello-world
   ```

OrbStack, Docker CLI ve Compose API'sini sağlar; uygulama için ayrıca Ubuntu VM hazırlamanız gerekmez. Resmî başlangıç rehberi: [OrbStack Quick Start](https://docs.orbstack.dev/quick-start).

### 3.2 Ubuntu

Aşağıdaki komutlar Docker'ın resmî APT deposu yoludur:

```bash
sudo apt update
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo docker run --rm hello-world
```

Sürüm/dağıtım desteğini kurulum gününde [Docker Ubuntu kurulum sayfasından](https://docs.docker.com/engine/install/ubuntu/) doğrulayın.

### 3.3 Debian

Ubuntu komutlarını Debian repository adresiyle karıştırmayın. Debian için:

```bash
sudo apt update
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo docker run --rm hello-world
```

Debian türevi bir dağıtım kendi codename'ini döndürüyorsa upstream Debian codename'ini açıkça seçmeniz gerekebilir. Resmî kaynak: [Docker Debian kurulumu](https://docs.docker.com/engine/install/debian/).

### 3.4 RHEL

Docker'ın resmî RHEL RPM deposu:

```bash
sudo dnf -y install dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo docker run --rm hello-world
```

GPG anahtar parmak izini kurulum isteminde Docker'ın [RHEL kurulum sayfasındaki](https://docs.docker.com/engine/install/rhel/) güncel değerle karşılaştırın.

### 3.5 Rocky Linux / AlmaLinux

Uygulama Docker API'si ve Compose v2 üzerinde çalıştığı için dağıtım bağımlılığı yoktur. Ancak Docker'ın doğrudan destek matrisi ile Rocky/Alma kurum desteği aynı şey değildir. Öncelik sırası:

1. Kurumunuzun onayladığı Docker/Moby paketini ve repository'sini kullanın.
2. Docker CE tercih edilecekse OS ana sürümünüzle uyumluluğu doğrulayın; EL uyumlu sistemlerde çoğunlukla Docker'ın CentOS repository yolu kullanılır.
3. `docker info`, `docker compose version` ve `hello-world` başarılı olmadan uygulama kurulumuna geçmeyin.

Politikanız izin veriyorsa yaygın Docker CE yolu:

```bash
sudo dnf -y install dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo docker run --rm hello-world
```

Kaynak: [Docker CentOS kurulumu](https://docs.docker.com/engine/install/centos/). Rocky/Alma üzerinde bu repo kullanımı için dağıtım ve kurum destek politikanızı ayrıca kontrol edin.

### 3.6 Linux'ta operasyon kullanıcısı

Docker komutlarını `sudo` olmadan çalıştırmak isterseniz:

```bash
sudo usermod -aG docker "$USER"
newgrp docker
docker run --rm hello-world
```

Bu üyelik root seviyesine yakın yetki verir; ortak veya güvenilmeyen hesaba vermeyin. Alternatif olarak bütün `docker`/`docker compose` komutlarını `sudo` ile çalıştırın. Ayrıntı: [Docker Linux post-install](https://docs.docker.com/engine/install/linux-postinstall/).

## 4. Ortak uygulama kurulumu

### Adım 1 — Proje köküne geçin

```bash
cd "/uygun/yol/sql dashboard"
test -f compose.yaml
```

Beklenen sonuç: `test` komutu sessizce `0` koduyla biter.

### Adım 2 — Ortam dosyasını oluşturun

```bash
cp .env.example .env
chmod 600 .env
```

`.env` dosyasında en az şu değerleri güçlü ve birbirinden farklı parolalarla değiştirin:

```dotenv
POSTGRES_ADMIN_PASSWORD=GUCLU_ADMIN_PAROLASI
POWA_COLLECTOR_PASSWORD=GUCLU_COLLECTOR_PAROLASI
ADVISOR_API_PASSWORD=GUCLU_API_PAROLASI
```

Varsayılan bind ayarlarını ilk iterasyon için koruyun:

```dotenv
SOURCE_DB_BIND=127.0.0.1
REPOSITORY_DB_BIND=127.0.0.1
API_BIND=127.0.0.1
WEB_BIND=0.0.0.0
```

Bu sayede yalnız web dış ağdan erişilebilir. `.env` dosyasını Git'e eklemeyin.

Gerçek kaynaklarla temiz bir repository kuracaksanız ve demo kaydını istemiyorsanız **ilk `docker compose up` öncesinde** şunu da ayarlayın:

```dotenv
REGISTER_DEMO_SOURCE=false
```

Bu init ayarı yalnız boş `repository_data` volume'ü bootstrap edilirken okunur; mevcut volume'deki demo kaydını geriye dönük silmez.

### Adım 3 — Portları kontrol edin

Varsayılan host portları `5432`, `5433`, `8000` ve `5173`'tür. Kullanımdaysa yalnız host tarafını `.env` içinde değiştirin; container içi portlar sabittir.

macOS/Linux örneği:

```bash
lsof -nP -iTCP:5432 -sTCP:LISTEN || true
lsof -nP -iTCP:5433 -sTCP:LISTEN || true
lsof -nP -iTCP:8000 -sTCP:LISTEN || true
lsof -nP -iTCP:5173 -sTCP:LISTEN || true
```

`lsof` yoksa `ss -ltn` kullanın.

### Adım 4 — Compose modelini doğrulayın

```bash
docker compose config --quiet
```

Beklenen sonuç: çıktı ve hata olmadan tamamlanmasıdır. Bir environment değişkeni eksikse burada düzeltin.

### Adım 5 — Image'ları oluşturup bütün stack'i başlatın

```bash
docker compose up --build -d
```

Bu komut beş ana servisi başlatır; `demo` profili seçilmediği için sürekli workload başlamaz. İlk build şu kontrolleri içerir:

- `postgres:17-trixie` tabanı indirilir.
- PoWA Archivist `REL_5_2_0` kaynak arşivi indirilir ve SHA-256 doğrulanır.
- PoWA Collector 1.3.2 wheel'i hash sabitlenmiş biçimde kurulur.
- Backend ve frontend dependency'leri kurulur.

İlerlemeyi izleyin:

```bash
docker compose ps
docker compose logs --tail=100 source-db repository-db collector api web
```

Beklenen sonuç: iki PostgreSQL, collector, API ve web servisleri `healthy` görünür. `workload` listede olmamalıdır. İlk database bootstrap'ı birkaç dakika sürebilir.

### Adım 6 — Sağlık uçlarını kontrol edin

Aynı hostta:

```bash
curl -fsS http://localhost:8000/api/v1/health
curl -fsS http://localhost:5173/healthz
curl -fsS http://localhost:5173/api/v1/health
```

İlk API yanıtında `repository: healthy`, `collector: healthy` ve `powaVersion: 5.2.0` beklenir.

Başka bir bilgisayardan yalnız web/proxy kontrolü yapın:

```bash
curl -fsS http://SUNUCU_IP:5173/healthz
curl -fsS http://SUNUCU_IP:5173/api/v1/health
```

### Adım 7 — Kontrollü fonksiyonu çalıştırın

```bash
bash scripts/run-test-workload.sh 20
```

Örnek başarılı sonuç:

```json
{"ok": true, "iterations": 20, "statementsExecuted": 80, "durationMs": 123.45}
```

Collector 5 saniyede bir snapshot alır. İki ölçüm farkı için yaklaşık 10 saniye bekleyin.

Bu komut tek seferlik kontrollü trafik üretir. Sürekli sentetik trafik varsayılan olarak kapalıdır. Yalnız demo ihtiyacında:

```bash
docker compose --profile demo up -d workload
docker compose stop workload
```

### Adım 8 — Uçtan uca kabul testini çalıştırın

```bash
bash scripts/verify.sh
```

Host portlarını değiştirdiyseniz test URL'lerini de verin:

```bash
API_URL=http://localhost:18000 WEB_URL=http://localhost:15173 bash scripts/verify.sh
```

Beklenen son satır:

```text
İlk iterasyon çalışma zamanı kabul kontrolleri tamamlandı.
```

### Adım 9 — Analiz arayüzünü açın

Yerel:

```text
http://localhost:5173
```

Uzak Linux sunucusu:

```text
http://SUNUCU_IP:5173
```

Kurulum adımları dashboard'da yer almaz; bu belge işletim sistemi kurulumunun tek kaynağıdır. İlk iterasyon kabulü için Genel Bakış'ta veri, Sorgular ekranında en az bir sorgu detayı ve Operasyonlar'da ilgili collector kaynağının healthy görünmesi yeterlidir.

## Gerçek bir PostgreSQL kaynağını ekleme

### Nelerin otomatik, nelerin DBA sorumluluğunda olduğunu ayırın

`scripts/register-source.sh` birden fazla uzak PostgreSQL kaynağını aynı collector/repository'ye idempotent biçimde ekler. Ancak “herhangi bir DB” burada **ağdan erişilebilen ve yönetim erişiminiz olan PostgreSQL cluster** anlamına gelir; MySQL/MariaDB/SQL Server desteklenmez.

Script şunları yapar:

1. Collector parolasıyla uzak bağlantıyı ve PoWA yetkilerini kontrol eder.
2. İstenirse `--prepare` ile monitoring DB, collector rolü, extension ve grant'ları oluşturur/günceller.
3. PoWA repository kaydını alias üzerinden ekler veya günceller.
4. `powa_servers.password` değerini daima `NULL` tutar.
5. Alias'a ait parolayı Git dışında `runtime/collector/sources/<alias>.pgpass` dosyasına `0600` izinle yazar.
6. Collector'ı yeniden başlatır, force-snapshot ister ve sonucu bekler.

Script şunları otomatik yapmaz:

- Kaynak işletim sistemine PoWA binary/paketi kurmak
- `postgresql.conf` değiştirmek veya PostgreSQL'ü yeniden başlatmak
- `pg_hba.conf`, firewall, DNS, VPN ya da TLS sertifikası değiştirmek

Bu değişiklikler canlı veritabanında bakım ve güvenlik kararı gerektirir.

### 1 — Kaynak PostgreSQL ön koşulları

Kaynak cluster'ın PostgreSQL major sürümüne uygun `powa`/PoWA Archivist, `pg_stat_statements` ve `btree_gist` extension dosyalarını işletim sistemi paket yöneticisiyle kurun. PoWA'nın remote-mode belgeleri `pg_stat_statements` veri kaynağını zorunlu kabul eder.

`postgresql.conf` için minimum:

```conf
shared_preload_libraries = 'pg_stat_statements'
compute_query_id = on
track_io_timing = on
```

Mevcut `shared_preload_libraries` listesinde başka modüller varsa onları silmeyin; virgülle `pg_stat_statements` ekleyin. Bu değişiklik cluster restart gerektirir. `track_io_timing` ölçüm maliyeti taşıyabildiği için canlıda DBA kararıyla açılmalıdır.

Kontrol:

```sql
SHOW shared_preload_libraries;
SHOW compute_query_id;
SHOW track_io_timing;
```

Collector container'ından kaynak host/portuna ağ erişimi, kaynak `pg_hba.conf` içinde collector hostu için TLS/SCRAM kuralı ve firewall izni olmalıdır. Aynı Docker hostundaki host PostgreSQL için `localhost` yazmayın; container açısından bu kendi container'ıdır. `host.docker.internal` veya yönlendirilebilir DNS/IP kullanın.

### 2 — Secret ve kaynak config dosyalarını hazırlayın

```bash
install -d -m 700 /secure/advisor
cp config/source.env.example /secure/advisor/prod-source.env
chmod 600 /secure/advisor/prod-source.env
```

Collector ve opsiyonel DBA parolalarını ayrı dosyalara, sonunda tek newline olacak şekilde yazın:

```bash
printf '%s\n' 'GUCLU_COLLECTOR_PAROLASI' | sudo tee /secure/advisor/prod-collector.pass >/dev/null
sudo chmod 600 /secure/advisor/prod-collector.pass
```

`prod-source.env` örneği:

```dotenv
SOURCE_ALIAS=production-main
SOURCE_HOST=db.example.internal
SOURCE_PORT=5432
SOURCE_MONITORING_DB=powa
SOURCE_COLLECTOR_USER=powa_collector
SOURCE_PASSWORD_FILE=/secure/advisor/prod-collector.pass
SOURCE_FREQUENCY=60
SOURCE_COALESCE=100
SOURCE_RETENTION=90 days
PREPARE_SOURCE=false
```

Dosya shell olarak `source` edilmez; yalnız izin verilen `KEY=value` anahtarları okunur. CLI bayrakları environment'ı, environment config dosyasını ezer.

### 3A — DBA hazırlığı zaten yapıldıysa kaydedin

Kaynakta dedicated monitoring DB (`powa`), extension'lar, collector login rolü, `pg_read_all_stats`, `powa_snapshot` ve uygulama veritabanlarına `CONNECT` grant'ları hazırsa:

```bash
bash scripts/register-source.sh --env-file /secure/advisor/prod-source.env
```

### 3B — Hazırlığı script ile uygulayacaksanız

Önce DBA secret dosyasını oluşturun ve config'e ekleyin:

```dotenv
PREPARE_SOURCE=true
SOURCE_ADMIN_USER=postgres
SOURCE_ADMIN_DB=postgres
SOURCE_ADMIN_PASSWORD_FILE=/secure/advisor/prod-admin.pass
```

Sonra aynı komutu çalıştırın:

```bash
bash scripts/register-source.sh --env-file /secure/advisor/prod-source.env
```

Uygulanan SQL şablonu [sql/002_prepare_remote_source.sql](../sql/002_prepare_remote_source.sql) dosyasındadır. Tekrar çalıştırılabilir; mevcut monitoring DB/extension/rol korunur, collector parolası kontrollü olarak güncellenir. Parola SQL dosyasına ya da komut argümanına yazılmaz.

Kaynakta extension binary'si veya preload eksikse script açıklayıcı hatayla durur. Önce DBA adımını tamamlayıp tekrar çalıştırın.

### 4 — Sonucu bağımsız doğrulayın

```bash
bash scripts/verify-source.sh production-main
docker compose logs --tail=100 collector
curl -fsS http://localhost:8000/api/v1/servers
```

Beklenenler:

- Aynı alias için tam bir repository satırı
- `password IS NULL`
- `frequency >= 5`
- `snapts > -infinity`
- Collector hata dizisi boş
- Secret dosya izni `0600`
- Kaynak `/api/v1/servers` listesinde

Aynı register komutunu ikinci kez çalıştırmak yeni server id üretmez; mevcut id üzerinde bağlantı, frekans, coalesce ve retention güncellenir. Alias mantıksal kaynak kimliğidir. Bir alias'ı bambaşka bir cluster'a yöneltmek eski ve yeni geçmişi aynı server id altında birleştireceğinden önerilmez; yeni fiziksel/mantıksal kaynak için yeni alias kullanın.

Her kayıt/parola rotasyonu collector container'ını yeniden oluşturur. Mevcut kaynak worker'ları birkaç saniyeliğine yeniden bağlanır; repository geçmişi kaybolmaz. Çok sayıda canlı kaynakta bu kısa kesintiyi operasyon penceresinde planlayın.

### 5 — TLS ve çoklu kaynak sınırı

Collector bütün uzak kaynaklar için ortak libpq `PGSSLMODE` kullanır. `.env` içindeki değeri kurum politikanıza göre ayarlayın:

```dotenv
POWA_SOURCE_SSLMODE=require
```

`verify-ca`/`verify-full` için CA/certificate dosyalarının hem collector'a hem de register/prepare kontrolünü çalıştıran repository container'ına salt-okunur mount edilmesi ayrıca gerekir. İlk iterasyon alias başına farklı `sslmode` veya farklı client certificate profili üretmez; bu ihtiyacı olan kaynak grupları ayrı collector deployment'larına ayrılmalıdır. Repository iç Docker bağlantısı DSN üzerinde `sslmode=disable` ile ayrıca belirlenmiştir.

## 5. Linux ağ ve SELinux kontrolü

### Dış erişim

Varsayılan durumda yalnız TCP `5173` dışarı açılmalıdır. RHEL ailesinde firewalld kullanılıyorsa:

```bash
sudo firewall-cmd --permanent --add-port=5173/tcp
sudo firewall-cmd --reload
sudo firewall-cmd --list-ports
```

Docker published port'ları bazı firewall kurallarını farklı zincirlerden geçirebilir. Aşağıdakileri de doğrulayın:

```bash
docker compose port web 80
docker compose port api 8000
docker compose port source-db 5432
docker compose port repository-db 5433
```

Beklenti: web `0.0.0.0:5173`; diğer üçü `127.0.0.1` adresindedir. Üretimde `DOCKER-USER`, cloud security group veya kurumun network policy katmanında da aynı kısıtı uygulayın.

### SELinux

SELinux'u kapatmayın. Stack veri için named volume kullanır; bootstrap SQL/shell dosyaları read-only bind mount edilir ve Compose bunları SELinux için private label ile bağlar. `permission denied` görürseniz:

```bash
getenforce
docker compose logs source-db repository-db
ls -lZ deployment/source deployment/repository sql
```

Önce projenin desteklenen yerel filesystem üzerinde bulunduğunu ve güncel Compose/Docker kullandığınızı doğrulayın; kalıcı etiket veya SELinux policy değişikliğini sistem yöneticinizle uygulayın.

## 6. Sorgu metni görünürlüğünü kontrol etme

Varsayılan istek `viewer` sayılır ve SQL maskelenir:

```bash
curl -fsS 'http://localhost:8000/api/v1/queries?window=1h&pageSize=5'
```

Analist demonstrasyonu:

```bash
curl -fsS -H 'X-Advisor-Role: analyst' \
  'http://localhost:8000/api/v1/queries?window=1h&pageSize=5'
```

Admin CSV export:

```bash
curl -fsS \
  -H 'X-Advisor-Role: admin' \
  -H 'X-Advisor-Actor: kurulum-kontrolu' \
  'http://localhost:8000/api/v1/export/queries.csv?window=24h' \
  -o queries-24h.csv
```

Bu header'lar gerçek kullanıcı kimliği kanıtlamaz; sadece ilk iterasyon rol davranışını gösterir.

## 7. Günlük işletim

### Başlatma ve durdurma

```bash
docker compose start
docker compose stop
docker compose restart collector api web
```

Container'ları kaldırıp veriyi korumak:

```bash
docker compose down
```

### Loglar

```bash
docker compose logs -f --tail=100 collector
docker compose logs -f --tail=100 api
docker compose logs -f --tail=100 web
```

### Repository yedeği

```bash
bash scripts/backup-repository.sh
ls -lh backups/
```

Script custom-format `pg_dump` üretir. Yedeği aynı hostta bırakmak tek başına felaket kurtarma değildir; ayrı ve erişim kontrollü depoya kopyalayın, restore testini periyodik yapın.

Örnek geri yükleme hedefi kurum prosedürüne göre hazırlanmalıdır. Mevcut çalışan repository üzerine doğrudan restore etmeyin; önce ayrı bir test veritabanında doğrulayın.

### Retention

Kaynak server kaydı `retention = interval '90 days'` ile oluşturulur. `.env` içindeki `RETENTION_DAYS=90` API/operasyon ekranındaki ayardır; mevcut PoWA kaydını sonradan tek başına değiştirmez. Retention değişikliği repository'de PoWA'nın yönetim fonksiyonlarıyla ve kapasite planıyla birlikte yapılmalıdır.

## 8. Temizleme ve yeniden kurulum

Normal kaldırma, veriyi saklar:

```bash
docker compose down
```

Sadece image'ları yeniden oluşturmak:

```bash
docker compose build --pull
docker compose up -d
```

Tam sıfırlama:

```bash
docker compose down -v
docker compose up --build -d
```

> **Dikkat:** `down -v`, `source_data` ve `repository_data` volume'lerini; örnek uygulama verisini, PoWA geçmişini, kullanıcı notlarını ve audit kayıtlarını kalıcı olarak siler. Bu komutu yalnız hedefin test stack'i olduğunu doğruladıktan ve gerekli repository yedeğini aldıktan sonra çalıştırın.

Init scriptleri yalnız boş volume ilk oluşturulurken çalışır. Bootstrap SQL'ini değiştirdiğiniz halde sonuç görünmüyorsa bu davranışı göz önünde bulundurun; sırf yeniden denemek için üretim volume'ünü silmeyin.

## 9. Hata giderme

### API `starting` veya collector `degraded`

```bash
docker compose ps
docker compose logs --tail=200 repository-db collector api
```

Repository önce sağlıklı olmalı; ardından collector ilk snapshot'ı yazar. Authentication hatasında `.env` değerleriyle volume'lerin oluşturulduğu anda kullanılan parolaların farklı olup olmadığını kontrol edin.

### Queries boş

```bash
bash scripts/run-test-workload.sh 20
sleep 10
curl -fsS -H 'X-Advisor-Role: analyst' \
  'http://localhost:8000/api/v1/queries?window=1h&pageSize=10'
```

PoWA fark metriği için en az iki snapshot gerekir.

### Port kullanımda

`.env` içindeki host portunu değiştirin; örneğin:

```dotenv
WEB_PORT=15173
API_PORT=18000
```

Ardından:

```bash
docker compose up -d --force-recreate web api
API_URL=http://localhost:18000 WEB_URL=http://localhost:15173 bash scripts/verify.sh
```

### İlk build PoWA indirmesinde duruyor

GitHub erişimini ve proxy/CA ayarlarını kontrol edin. Hash uyuşmazlığında doğrulamayı kapatmayın; download kaynağını ve sabitlenen release'i inceleyin.

### Linux'ta web dışarıdan açılmıyor

1. `.env` içinde `WEB_BIND=0.0.0.0` olduğunu doğrulayın.
2. `docker compose port web 80` çıktısını kontrol edin.
3. Host firewall/security group üzerinde TCP 5173'e izin verin.
4. DB/API portlarını dışarı açmadan `http://SUNUCU_IP:5173/api/v1/health` çağrısını deneyin.

## 10. Neden bu iterasyonda native kurulum önerilmiyor?

PDF, Ubuntu/Debian ve RHEL ailesi için PGDG paketleri, ayrı cluster yönetimi, Python virtualenv ve systemd yolunu ayrıntılı anlatır. Bu mimari mümkündür; ancak ilk iterasyonda varsayılan değildir:

- PostgreSQL/PoWA paket adları ve filesystem yolları dağıtım ile major sürüme göre değişir.
- İkinci cluster'ın init/systemd adımları Ubuntu, Debian ve EL ailesinde farklıdır.
- PoWA extension ABI'si kurulu PostgreSQL major sürümüyle eşleşmelidir.
- Collector virtualenv, systemd kullanıcı/izinleri, `.pgpass`, SELinux/AppArmor ve log rotation ayrı ayrı yönetilmelidir.
- Bu çeşitlilik kurulum testinin kendisini ürün davranışından daha riskli hale getirir.

Container yolu PoWA sürümünü ve checksum'ları sabitler, aynı iki-instance topolojisini bütün hostlarda tekrarlar ve volume silmeden geri alınabilir. Native üretim kurulumu ancak kurum PostgreSQL standardı, hedef OS/major sürüm, TLS/secret yönetimi ve servis sahipliği netleştiğinde ayrı bir deployment paketi olarak hazırlanmalıdır. PDF'deki native runbook tasarım referansı olmaya devam eder; bu repodaki doğrulanmış kabul yolu Docker Compose'tur.
