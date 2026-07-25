# Kurulum ve işletim rehberi

Bu rehber PostgreSQL 18 üzerinde predicate, HypoPG, `pg_stat_kcache`, `pg_wait_sampling`, JOIN snapshotter ve composite aday hatlarını içeren stack'i macOS/OrbStack veya Docker Engine çalıştırabilen Linux üzerinde kurar. Disposable clone testi varsayılan kapalı `real-validation` profilidir. Ana yol container tabanlıdır; işletim sistemi yalnız Docker kurulum adımını değiştirir.

## 1. Kurulum modelini doğru okuyun

Bu repo varsayılan olarak tek bir fiziksel/virtual host üzerinde iki PostgreSQL 18 container'ı açar; mevcut kabul ortamında her ikisi de PostgreSQL 18.4 olarak doğrulanmıştır:

1. Kaynak PostgreSQL: host loopback `15432`, container `5432`
2. Repository PostgreSQL: host loopback `15433`, container `5433`

Bunlara collector, repository-only API, ayrı salt-okunur HypoPG evaluator ve web container'ları eklenir. Hacimli sentetik trafik üreten `workload` container'ı yalnız seed sonrasında ve isteğe bağlı `realistic-load` profiliyle açılır. Bu ayrım PDF'deki “tek test sunucusu, iki PostgreSQL instance” kararının çalıştırılabilir halidir.

DB, API ve web portları `.env.example` içinde varsayılan olarak `127.0.0.1`
adresine bağlıdır. Web container'ındaki Nginx, `/api` isteklerini Docker iç
ağındaki FastAPI'ye taşır. Uzak web erişimi ancak kimlik doğrulayan/TLS
sonlandıran reverse proxy sınırı kurulduktan sonra bilinçli opt-in'dir.

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

Aynı Docker hostunda birden fazla kurulum varsa her `.env` için benzersiz
`COMPOSE_PROJECT_NAME` seçin. Normal kurulumda Docker'ın çakışmayan subnet
atamasını kullanın; deterministik subnet gerçekten gerekiyorsa
`COMPOSE_FILE=compose.yaml:compose.networks.fixed.yaml` overlay'ini açıp subnet
değerlerini VPN/kurum ağına göre özelleştirin.

`.env` dosyasında en az şu değerleri güçlü ve birbirinden farklı parolalarla değiştirin:

```dotenv
POSTGRES_ADMIN_PASSWORD=GUCLU_ADMIN_PAROLASI
POWA_COLLECTOR_PASSWORD=GUCLU_COLLECTOR_PAROLASI
ADVISOR_API_PASSWORD=GUCLU_API_PAROLASI
ADVISOR_EVALUATOR_PASSWORD=GUCLU_EVALUATOR_PAROLASI
EVALUATOR_TOKEN=GUCLU_RASTGELE_IC_SERVIS_TOKENI
ADVISOR_JOIN_SOURCE_PASSWORD=GUCLU_JOIN_SOURCE_PAROLASI
ADVISOR_JOIN_REPOSITORY_PASSWORD=GUCLU_JOIN_REPOSITORY_PAROLASI
WORKLOAD_DB_PASSWORD=GUCLU_WORKLOAD_PAROLASI
CLONE_ADMIN_PASSWORD=GUCLU_CLONE_ADMIN_PAROLASI
CLONE_RUNNER_PASSWORD=GUCLU_CLONE_RUNNER_PAROLASI
CLONE_EVALUATOR_TOKEN=GUCLU_CLONE_IC_SERVIS_TOKENI
ADVISOR_AUTH_PRINCIPALS='[{"credential_id":"operator-cli","subject":"user:operator","token_sha256":"64_KARAKTER_LOWERCASE_SHA256","roles":["analyst","annotator","admin"]}]'
```

Kalıcı kaynak/repository ve opt-in workload parolalarının Compose fallback'i yoktur;
eksik veya boş bırakılırsa `docker compose config` container oluşturmadan hata
verir. Böylece `.env` dosyasının yanlışlıkla yüklenmemesi mevcut volume'ü genel
bir geliştirme parolasına geri döndüremez. Rol reconciler ayrıca eski
`advisor_dev_*` parolalarını ve `change-me-*` örneklerini PostgreSQL'e
bağlanmadan reddeder.

Compose `.env` içindeki `$` karakterini yorumlayabildiği için `$` içeren
secret'ları tek tırnakla yazın. TLS-doğrulamalı build ve mevcut-volume parola
rotasyonu ayrıntıları [portable deployment hardening belgesindedir](PORTABLE_DEPLOYMENT_HARDENING.md).

Compose, veritabanı parolalarını bağlantı URI'sine eklemez; host, port,
database, kullanıcı ve parola alanlarını container'a ayrı geçirir ve servisler
libpq conninfo değerini güvenli biçimde üretir. Bu nedenle `@`, `:`, `/`, `?`,
`%` veya `5432` içeren parolalar URI kaçışına ihtiyaç duymadan kullanılabilir.
Referans dışı Compose topolojilerinde `ADVISOR_API_DATABASE_*`,
`ADVISOR_EVALUATOR_DATABASE_*`, `ADVISOR_JOIN_SOURCE_DATABASE_*`,
`ADVISOR_JOIN_REPOSITORY_DATABASE_*` ve `ADVISOR_CLONE_DATABASE_*`
host/port/name/user/sslmode alanları `.env` üzerinden ayrı ayrı
değiştirilebilir; repository'nin standart PostgreSQL portu `5432` olması
desteklenir. Bu stack-prefix'i, geliştirici makinesinde tesadüfen export edilmiş
genel bir `DATABASE_URL` değerinin Compose hedefini değiştirmesini önler.
Bu alanlar tek başına ağ veya migration sınırını genişletmez: referans
servisler yerel DB'lere `depends_on` uygular; evaluator, JOIN snapshotter ve
clone ayrıca yalnız `internal` Compose ağlarına bağlıdır. API repository dahil
harici bir hedef için kuruma özel bir Compose override ile yalnız gereken
egress ağı/allowlist, migration hedefi ve bağımlılık düzeni tanımlanmalıdır;
`.env` tek başına harici DB erişimi açmaz.
Eski `DATABASE_URL`, `EVALUATOR_DATABASE_URL`, `CLONE_DATABASE_URL` ve JOIN
`*_DATABASE_URL`/`*_DATABASE_URL_FILE` override'ları uyumluluk için korunur;
tam URL kullanılırsa URI özel karakterlerini encode etmek yine operatörün
sorumluluğundadır.

Varsayılan bind ayarlarını ilk iterasyon için koruyun:

```dotenv
SOURCE_DB_BIND=127.0.0.1
REPOSITORY_DB_BIND=127.0.0.1
API_BIND=127.0.0.1
WEB_BIND=127.0.0.1
```

Bu sayede DB, API ve web yalnız aynı hosttan erişilebilir. Registry girdisini
ve raw token'ı `scripts/generate-auth-credential.py` ile üretin. Raw token
frontend build/env değişkeni değildir; yalnız secret manager'da tutulur. API
ortamı yalnız SHA-256 hashini alır. `.env` dosyasını Git'e eklemeyin. Registry
boş bırakılırsa annotation/export/runtime endpoint'leri fail-closed kapalı
kalır. Ayrıntılar [AUTHENTICATION.md](AUTHENTICATION.md) içindedir.

İterasyon 2.1-B demo kaynağı için varsayılanlar:

```dotenv
PG_QUALSTATS_SAMPLE_RATE=0.1
PG_QUALSTATS_MAX=10000
SOURCE_DB_SHM_SIZE=256mb
```

Sampling oranını üretimde overhead ölçmeden yükseltmeyin. `PG_QUALSTATS_MAX` büyütülürse PostgreSQL shared-memory ihtiyacı ile container `/dev/shm` kapasitesi birlikte artırılmalıdır.

İterasyon 2.2 demo evaluator varsayılanları:

```dotenv
EVALUATOR_ALLOWED_SERVER_ALIAS=test-source
EVALUATOR_ALLOWED_DATABASE=appdb
EVALUATOR_STATEMENT_TIMEOUT_MS=2000
EVALUATOR_LOCK_TIMEOUT_MS=250
EVALUATOR_MIN_IMPROVEMENT_PERCENT=10
```

Bu izin listesi monitoring kaydından bağımsızdır. Değerleri başka bir alias'a çevirmek tek başına dış kaynağı hazır hale getirmez; source DSN'i, HypoPG/rol/grant'ları ve kısıtlı ağ yolu ayrıca kurulmalıdır.

Gerçek kaynaklarla temiz bir repository kuracaksanız ve demo kaydını istemiyorsanız **ilk `docker compose up` öncesinde** şunu da ayarlayın:

```dotenv
REGISTER_DEMO_SOURCE=false
```

Bu init ayarı yalnız boş `repository_data` volume'ü bootstrap edilirken okunur; mevcut volume'deki demo kaydını geriye dönük silmez.

### PostgreSQL 17'den 18'e major geçiş uyarısı

Compose artık PostgreSQL 18 image'ı ve `/var/lib/postgresql/18/docker` veri diziniyle çalışır. PostgreSQL 17 named volume'ünü doğrudan PostgreSQL 18 container'ına bağlamayın; major sürüm veri dizinleri binary uyumlu değildir. Kaynak ve repository için önce doğrulanmış logical dump ile rol yedeği alın, ayrı PG18 volume'lerini oluşturun, restore edin ve ancak satır/snapshot sayıları doğrulandıktan sonra eski volume'leri kaldırın. Alternatif olarak DBA kontrollü `pg_upgrade` akışı kullanın.

`scripts/enable-pg-qualstats.sh` yalnız extension/datasource/grant geçişini yapar; PostgreSQL major upgrade'i yapmaz. Major geçiş öncesinde repository geçmişi ve kaynak uygulama verisi ayrıca yedeklenmelidir.

### Adım 3 — Portları kontrol edin

Varsayılan host portları `15432`, `15433`, `8000` ve `5173`'tür. Kullanımdaysa yalnız host tarafını `.env` içinde değiştirin; container içi portlar `5432` ve `5433` olarak sabittir.

macOS/Linux örneği:

```bash
lsof -nP -iTCP:15432 -sTCP:LISTEN || true
lsof -nP -iTCP:15433 -sTCP:LISTEN || true
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

Bu komut yedi ana servisi (`source-db`, `repository-db`, `collector`, `join-snapshotter`, `evaluator`, `api`, `web`) başlatır; `realistic-load` ve `real-validation` profilleri seçilmediği için workload ile disposable clone başlamaz. İlk build şu kontrolleri içerir:

- `postgres:18-trixie` tabanı indirilir.
- PoWA Archivist `REL_5_2_0` kaynak arşivi indirilir ve SHA-256 doğrulanır.
- PoWA 5.2.0'ın `pg_qualstats` retention purge fonksiyonundaki eski iki-parametreli kilit çağrısı, sürüme özel tek satırlık patch ile doğru tek-parametreli imzaya çevrilir.
- `pg_qualstats 2.1.4` kaynak arşivi indirilir, SHA-256 doğrulanır ve sabit sürüme yerel shared-memory düzeltmesi uygulanır.
- `pg_stat_kcache 2.3.2` ve `pg_wait_sampling 1.1.11` kaynak arşivleri SHA-256 ve extension sürümüyle doğrulanır.
- HypoPG `1.4.3`, tam upstream commit arşivinden indirilir; SHA-256 ve extension sürümü doğrulanarak PostgreSQL 18 için derlenir.
- PoWA Collector 1.3.2 wheel'i hash sabitlenmiş biçimde kurulur.
- Backend ve frontend dependency'leri kurulur.

İlerlemeyi izleyin:

```bash
docker compose ps
docker compose logs --tail=100 source-db repository-db collector join-snapshotter evaluator api web
```

Beklenen sonuç: iki PostgreSQL, collector, JOIN snapshotter, evaluator, API ve web servisleri çalışır/`healthy` görünür. `workload`, `clone-db` ve `clone-evaluator` listede olmamalıdır. İlk database bootstrap'ı birkaç dakika sürebilir.

### Adım 6 — Sağlık uçlarını kontrol edin

Aynı hostta:

```bash
curl -fsS http://localhost:8000/api/v1/health
curl -fsS http://localhost:5173/healthz
curl -fsS http://localhost:5173/api/v1/health
docker compose exec -T evaluator python -c \
  "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8010/health', timeout=3).read().decode())"
```

İlk API yanıtında `repository: healthy`, `collector: healthy`, `postgresVersion: 18.4` ve `powaVersion: 5.2.0` beklenir. Evaluator yanıtında `database_name=appdb`, `role_name=advisor_evaluator`, `hypopg_version=1.4.3`, `default_read_only=on` ve `ddlExecuted=false` bulunmalıdır.

Kimlik doğrulayan/TLS sonlandıran bir reverse proxy sınırı kurduktan sonra
uzak web erişimini özellikle açmak isterseniz `.env` içinde
`WEB_BIND=0.0.0.0` seçin. Sonra başka bir bilgisayardan yalnız web/proxy
kontrolü yapın:

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

Collector 5 saniyede bir snapshot alır. İki ölçüm farkı için yaklaşık 10 saniye bekleyin. Komut deterministik predicate kabulü için yalnız kendi oturumunda `pg_qualstats.sample_rate=1` kullanır; cluster varsayılanı `0.1` olarak kalır.

Bu komut tek seferlik kontrollü trafik üretir. Sürekli sentetik trafik varsayılan
olarak kapalıdır. Hacimli ve süreli karma trafik için önce
`scripts/run-realistic-workload.sh` kullanılmalıdır; fresh fixture üzerinde
`workload` servisini doğrudan açmak desteklenmez.

### Adım 8 — Uçtan uca kabul testini çalıştırın

```bash
bash scripts/verify.sh
```

Host portlarını değiştirdiyseniz test URL'lerini de verin:

```bash
API_URL=http://localhost:18000 WEB_URL=http://localhost:15173 bash scripts/verify.sh
```

Beklenen sonuç, bütün kontrollerin `[OK]` ile tamamlanması ve scriptin sıfır koduyla çıkmasıdır. Kabul artık temel stack'e ek olarak wait sampling, JOIN outbox/snapshotter ve composite aday hattını da doğrular; gerçek clone testi profil dışında ayrıca çalıştırılır.

Test ayrıca iki database'in PostgreSQL 18 kullandığını, veri dizininin `/var/lib/postgresql/18/docker` olduğunu, gerçek predicate kayıtları üzerinden WHERE+JOIN capability sözleşmesini, CPU/wait history alanlarını, composite candidate eşiklerini ve HypoPG evaluator'ın gerçek index oluşturmadan aynı oturumda plan doğrulaması yaptığını kontrol eder.

İsteğe bağlı İterasyon 2.7 kabulü için `.env` içindeki
`ADVISOR_AUTH_PRINCIPALS` registry'sinde `admin` rolü ve çağıran shell'de aynı
credential'ın raw `ADVISOR_API_TOKEN` değeri bulunmalıdır. Önceki kabul testi
demo composite adayını hazırladıktan sonra:

```bash
docker compose --profile real-validation up -d --wait clone-db clone-evaluator
bash scripts/verify-real-validation.sh
```

Script exact normalize eşitlik sorgusuna audit metadatalı `["paid"]` sentetik fixture'ı operator kayıt yoluyla bağlar; admin Bearer API çağrısını, gerçek index kullanımını, kaynak index fingerprint'inin değişmediğini ve disposable baseline/candidate database'lerin temizlendiğini doğrular. Genel/manual fixture ve endpoint akışı [2.5–2.7 runbook'undadır](ITERATIONS_2_5_TO_2_7.md#27-disposable-clone-profili). Profil varsayılan stack için zorunlu değildir.

### Adım 9 — Analiz arayüzünü açın

Yerel:

```text
http://localhost:5173
```

Uzak Linux sunucusu (yalnız bilinçli `WEB_BIND=0.0.0.0` opt-in'i ve güvenilir
reverse proxy sonrasında):

```text
http://SUNUCU_IP:5173
```

Kurulum adımları dashboard'da yer almaz; bu belge işletim sistemi kurulumunun tek kaynağıdır. Kabul için Genel Bakış'ta veri, Sorgular ekranında en az bir sorgu detayı ile CPU/wait ve WHERE/JOIN panelleri, Operasyonlar'da da ilgili collector kaynağının healthy görünmesi beklenir.

Predicate endpoint'ini bağımsız kontrol etmek için gerçek sorgu, server ve database kimliklerini kullanın:

```bash
curl -fsS -H 'X-Advisor-Role: analyst' \
  'http://localhost:8000/api/v1/queries/QUERY_ID/predicates?window=24h&serverId=SERVER_ID&databaseId=DATABASE_OID'
```

Sağlıklı demo snapshotter sonrasında `capability.coverage=WHERE_AND_JOIN_SNAPSHOT` ve `joinsAvailable=true` beklenir. Seçilen sorgu/eşikler iki kolonlu persisted aday ürettiyse `ddlGenerated=true` olabilir; bu alan DDL'in çalıştırıldığı anlamına gelmez. `occurrences` örneklenen predicate çalışmasıdır ve sorgunun statement çağrı sayısı değildir. `rowsProcessed`, PoWA/pg_qualstats `execution_count`; `rowsFiltered`, `nbfiltered` sayacından gelir. `filterRatio`, `rowsFiltered / rowsProcessed` oranıdır. Snapshotter hazır değilse güvenli fallback `WHERE_FILTER_ONLY` olur ve bu, sorguda JOIN bulunmadığını kanıtlamaz.

Uygun predicate için UI'daki **HypoPG ile doğrula** butonunu kullanın veya aynı kimliklerle endpoint'i çağırın:

```bash
curl -fsS -H 'X-Advisor-Role: analyst' \
  -H 'Content-Type: application/json' \
  -X POST \
  'http://localhost:8000/api/v1/queries/QUERY_ID/index-evaluations?window=24h' \
  -d '{"serverId":1,"databaseId":16384,"qualId":"QUAL_ID","relationId":RELATION_OID}'
```

`candidate.createIndexSql` yalnız `status=VALIDATED` olduğunda bulunur ve `CREATE INDEX CONCURRENTLY` taslağıdır. `validation.costReductionPercent` planner cost farkıdır, süre kazancı değildir. Sonuç ne olursa olsun `ddlExecuted=false` beklenir; uygulama SQL'i yürütmez.

## Gerçek bir PostgreSQL kaynağını ekleme

### Nelerin otomatik, nelerin DBA sorumluluğunda olduğunu ayırın

`scripts/register-source.sh` birden fazla uzak PostgreSQL kaynağını aynı collector/repository'ye idempotent biçimde ekler. Ancak “herhangi bir DB” burada **ağdan erişilebilen ve yönetim erişiminiz olan PostgreSQL cluster** anlamına gelir; MySQL/MariaDB/SQL Server desteklenmez.

Script şunları yapar:

1. Collector parolasıyla uzak bağlantıyı, PoWA/stats extension sürümlerini, datasource çağrılarını ve atomik JOIN-capture/reset yetki sınırını kontrol eder.
2. İstenirse `--prepare` ile monitoring DB, collector ve ayrı JOIN reader rollerini, extension'ları, outbox wrapper'ını ve grant'ları oluşturur/günceller.
3. PoWA repository kaydını alias üzerinden ekler veya günceller.
4. `powa_servers.password` değerini daima `NULL` tutar.
5. Alias'a ait parolayı Git dışında `runtime/collector/sources/<alias>.pgpass` dosyasına `0600` izinle yazar.
6. Collector'ı yeniden başlatır, force-snapshot ister ve sonucu bekler.

Script şunları otomatik yapmaz:

- Kaynak işletim sistemine PoWA, `pg_stat_kcache` veya `pg_wait_sampling` binary/paketi kurmak
- `postgresql.conf` değiştirmek veya PostgreSQL'ü yeniden başlatmak
- `pg_hba.conf`, firewall, DNS, VPN ya da TLS sertifikası değiştirmek
- HypoPG binary/extension'ı, `advisor_evaluator` rolünü veya dış kaynak evaluator DSN/ağ yolunu hazırlamak
- Dış kaynağa ait JOIN reader secret'ını çalışan `join-snapshotter` deployment'ına bağlamak veya source/repository ağ yolunu otomatik açmak

Bu değişiklikler canlı veritabanında bakım ve güvenlik kararı gerektirir.

### 1 — Kaynak PostgreSQL ön koşulları

Kaynak cluster'ın PostgreSQL major sürümüne uygun `powa`/PoWA Archivist, `pg_stat_statements`, `pg_qualstats 2.1.x`, `pg_stat_kcache 2.3.x`, `pg_wait_sampling 1.1.x` ve `btree_gist` extension dosyalarını işletim sistemi paket yöneticisiyle kurun. `--prepare` bu binary/control dosyalarını işletim sistemine kurmaz. Yalnız telemetry toplamak için HypoPG gerekmez; bu kaynakta İterasyon 2.2 plan doğrulaması isteniyorsa HypoPG 1.4.3 ayrıca hedef uygulama database'ine kurulmalıdır.

`postgresql.conf` için minimum:

```conf
shared_preload_libraries = 'pg_stat_statements,pg_qualstats,pg_stat_kcache,pg_wait_sampling'
compute_query_id = on
track_io_timing = on
pg_qualstats.track_constants = off
pg_qualstats.track_pg_catalog = off
pg_qualstats.resolve_oids = off
pg_qualstats.sample_rate = 0.1
pg_stat_kcache.track = top
pg_stat_kcache.track_planning = off
pg_wait_sampling.profile_period = 10
pg_wait_sampling.profile_pid = off
pg_wait_sampling.profile_queries = top
pg_wait_sampling.sample_cpu = off
```

Mevcut `shared_preload_libraries` listesinde başka modüller varsa onları silmeyin; gerekli dört stats extension'ını ekleyin. Preload değişikliği cluster restart gerektirir. `track_io_timing`, qualstats/wait sampling ve kcache ölçümü maliyet taşıyabildiği için canlı değerler DBA kararı ve overhead ölçümüyle seçilmelidir.

Kontrol:

```sql
SHOW shared_preload_libraries;
SHOW compute_query_id;
SHOW track_io_timing;
SHOW pg_qualstats.sample_rate;
SHOW pg_stat_kcache.track;
SHOW pg_wait_sampling.profile_period;
SHOW pg_wait_sampling.profile_pid;
SHOW pg_wait_sampling.profile_queries;
SHOW pg_wait_sampling.sample_cpu;
```

Collector container'ından kaynak host/portuna ağ erişimi, kaynak `pg_hba.conf` içinde collector hostu için TLS/SCRAM kuralı ve firewall izni olmalıdır. Aynı Docker hostundaki host PostgreSQL için `localhost` yazmayın; container açısından bu kendi container'ıdır. `host.docker.internal` veya yönlendirilebilir DNS/IP kullanın.

### 2 — Secret ve kaynak config dosyalarını hazırlayın

```bash
install -d -m 700 /secure/advisor
cp config/source.env.example /secure/advisor/prod-source.env
chmod 600 /secure/advisor/prod-source.env
```

Collector, JOIN reader ve opsiyonel DBA parolalarını birbirinden ayrı dosyalara, sonunda tek newline olacak şekilde yazın:

```bash
printf '%s\n' 'GUCLU_COLLECTOR_PAROLASI' | sudo tee /secure/advisor/prod-collector.pass >/dev/null
printf '%s\n' 'FARKLI_GUCLU_JOIN_READER_PAROLASI' | sudo tee /secure/advisor/prod-join-reader.pass >/dev/null
sudo chmod 600 /secure/advisor/prod-collector.pass
sudo chmod 600 /secure/advisor/prod-join-reader.pass
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
SOURCE_JOIN_PASSWORD_FILE=/secure/advisor/prod-join-reader.pass
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
SOURCE_JOIN_PASSWORD_FILE=/secure/advisor/prod-join-reader.pass
```

Sonra aynı komutu çalıştırın:

```bash
bash scripts/register-source.sh --env-file /secure/advisor/prod-source.env
```

Uygulanan SQL şablonu [sql/002_prepare_remote_source.sql](../sql/002_prepare_remote_source.sql) dosyasındadır. Tekrar çalıştırılabilir; mevcut monitoring DB/extension/roller korunur, collector ve JOIN reader parolaları kontrollü olarak güncellenir. Parolalar SQL dosyasına ya da komut argümanına yazılmaz.

Kaynakta extension binary'si veya preload eksikse script açıklayıcı hatayla durur. Önce DBA adımını tamamlayıp tekrar çalıştırın.

### 4 — Sonucu bağımsız doğrulayın

```bash
bash scripts/verify-source.sh production-main
docker compose logs --tail=100 collector join-snapshotter
curl -fsS http://localhost:8000/api/v1/servers
```

Beklenenler:

- Aynı alias için tam bir repository satırı
- `password IS NULL`
- `frequency >= 5`
- `snapts > -infinity`
- Collector hata dizisi boş; qualstats, kcache ve wait datasource/fonksiyonları etkin
- Collector yalnız `advisor_join.capture_and_reset()` çağırabiliyor ve doğrudan `pg_qualstats_reset()` yetkisi taşımıyor
- Secret dosya izni `0600`
- Kaynak `/api/v1/servers` listesinde

Aynı register komutunu ikinci kez çalıştırmak yeni server id üretmez; mevcut id üzerinde bağlantı, frekans, coalesce ve retention güncellenir. Alias mantıksal kaynak kimliğidir. Bir alias'ı bambaşka bir cluster'a yöneltmek eski ve yeni geçmişi aynı server id altında birleştireceğinden önerilmez; yeni fiziksel/mantıksal kaynak için yeni alias kullanın.

Her kayıt/parola rotasyonu collector container'ını yeniden oluşturur. Mevcut kaynak worker'ları birkaç saniyeliğine yeniden bağlanır; repository geçmişi kaybolmaz. Çok sayıda canlı kaynakta bu kısa kesintiyi operasyon penceresinde planlayın.

PoWA 5.2'nin standart remote qualstats hattında repository'ye WHERE/filter predicate geçmişi gelir. Raw kaynak `pg_qualstats()` JOIN predicate'lerini de yakalar; wrapper bunları source outbox'a resetten önce yazar. Ancak `register-source.sh` çalışan snapshotter deployment'ının DSN/secret/ağ ayarını otomatik değiştirmez. Referans Compose snapshotter'ı yalnız `test-source/source-db` içindir; her dış kaynak için ayrı düşük yetkili source DSN'i, ayrı repository login'i ve ağ allowlist'i olan snapshotter deployment'ı hazırlanmadan endpoint `WHERE_FILTER_ONLY` kalabilir. Repository DBA her login'i ilgili alias'a `SELECT advisor_ingest.bind_join_source_role('rol_adi', 'source-alias');` ile bağlamalıdır; bu işlem rolün tablo/global-purge erişimini kaldırıp yalnız source-scoped wrapper yetkilerini verir.

Bu noktada kaynak yalnız monitoring kapsamındadır. HypoPG doğrulaması için collector secret'ından ayrı read-only rol, sabit alias/database allowlist'i, kaynak portuna kısıtlı evaluator network yolu ve ayrı DSN gerekir. Referans stack tek evaluator hedefi destekler; çoklu kaynak otomatik yönlendirilmez. Uygulanacak kontrollü adımlar [İterasyon 2.2 dış kaynak runbook'unda](ITERATION_2_2_HYPOPG.md#dış-kaynak-sınırı-ve-runbook) yer alır.

### 5 — TLS ve çoklu kaynak sınırı

Collector bütün uzak kaynaklar için ortak libpq `PGSSLMODE` kullanır. `.env` içindeki değeri kurum politikanıza göre ayarlayın:

```dotenv
POWA_SOURCE_SSLMODE=require
```

`verify-ca`/`verify-full` için CA/certificate dosyalarının hem collector'a hem de register/prepare kontrolünü çalıştıran repository container'ına salt-okunur mount edilmesi ayrıca gerekir. İlk iterasyon alias başına farklı `sslmode` veya farklı client certificate profili üretmez; bu ihtiyacı olan kaynak grupları ayrı collector deployment'larına ayrılmalıdır. Repository iç Docker bağlantısı DSN üzerinde `sslmode=disable` ile ayrıca belirlenmiştir.

## 5. Linux ağ ve SELinux kontrolü

### Dış erişim

Varsayılan durumda hiçbir host portu dış ağa açılmaz. Kimlik doğrulayan/TLS
sonlandıran reverse proxy sınırı hazırlandıktan sonra bilinçli olarak
`WEB_BIND=0.0.0.0` seçildiyse RHEL ailesinde yalnız TCP `5173` için:

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

Varsayılan beklenti: web dahil dört published port `127.0.0.1` adresindedir.
Uzak web opt-in'inde yalnız web `0.0.0.0:5173` olur. Üretimde `DOCKER-USER`,
cloud security group veya kurumun network policy katmanında da aynı kısıtı
uygulayın.

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
export ADVISOR_API_TOKEN='SECRET_MANAGERDAN_ALINAN_RAW_TOKEN'
curl -fsS \
  -H "Authorization: Bearer ${ADVISOR_API_TOKEN:?api token gerekli}" \
  'http://localhost:8000/api/v1/export/queries.csv?window=24h&priority=CRITICAL&minCalls=20' \
  -o queries-24h.csv
```

CSV endpoint'i sorgu listesindeki `search`, `priority`, `serverId`, `databaseId`,
`minCalls`, `minDurationMs` ve `sort` filtrelerini kabul eder. Eşleşen kayıtların
tamamı PostgreSQL server-side cursor üzerinden sabit boyutlu partilerle aktarılır;
UI'ın 200 satırlık sayfa sınırı export'a uygulanmaz ve dosyanın tamamı API
belleğinde oluşturulmaz.

CSV `admin` Bearer principal ister. Audit actor istemci header'ı değil,
registry'deki doğrulanmış subject'tir. Token'ı browser bundle'ına koymayın;
yerel PAT modeli SSO değildir.

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

Kaynak server kaydı `retention = interval '90 days'` ile oluşturulur.
`pg_wait_sampling` yüksek kardinaliteli geçmişi için ayrıca 30 günlük extension
override'ı vardır; fresh init, `enable-pg-wait-sampling.sh` ve
`register-source.sh` bunu aynı biçimde uygular. `.env` içindeki
`RETENTION_DAYS=90` API/operasyon ekranındaki genel ayardır; mevcut PoWA kaydını
sonradan tek başına değiştirmez. Retention değişikliği repository'de PoWA'nın
yönetim fonksiyonlarıyla ve kapasite planıyla birlikte yapılmalıdır.

### İterasyon 2.1-B–2.6 mevcut-volume geçişi

Named volume daha eski image ile oluşturulduysa init scriptleri kendiliğinden
tekrar çalışmaz. `repository-migrate` bu nedenle her `docker compose up`
akışında repository sağlıklı olduktan sonra checksum doğrulamalı ve advisory
lock korumalı upgrade'i çalıştırır. Aynı adımı elle yürütmek için
`bash scripts/migrate-repository.sh` kullanılabilir; ayrıntılar
[REPOSITORY_MIGRATIONS.md](REPOSITORY_MIGRATIONS.md) içindedir. Demo stack'i
veri/geçmiş silmeden yükseltmek için:

```bash
docker compose build source-db
docker compose up -d --force-recreate source-db repository-db
bash scripts/migrate-repository.sh
bash scripts/enable-pg-qualstats.sh
bash scripts/enable-hypopg.sh
bash scripts/enable-pg-stat-kcache.sh
bash scripts/enable-pg-wait-sampling.sh
bash scripts/enable-join-snapshotter.sh
docker compose up -d --force-recreate evaluator api web
bash scripts/verify.sh
```

İlk script predicate datasource/grant koşullarını ve history akışını doğrular; ayrıca mevcut volume'de PoWA 5.2.0'ın `pg_qualstats` retention purge imza düzeltmesini idempotent uygular. İkinci script HypoPG 1.4.3'ü, `advisor_hypopg` şemasını ve salt-okunur evaluator rolünü hazırlar. Sonraki scriptler `pg_stat_kcache 2.3.2`, `pg_wait_sampling 1.1.11` ve düşük yetkili JOIN outbox/snapshotter hattını veri silmeden etkinleştirir; JOIN repository login'ini `test-source` kimliğine bağlar ve iki snapshot üzerinden composite aday oluşumunu da kabul eder. Scriptler `test-source` demo kaydına özeldir. Gerçek dış kaynakları izlemek için DBA binary/preload/restart işleminden sonra aynı alias ile `scripts/register-source.sh` çalıştırılır; dış kaynak HypoPG evaluator, ayrı bound repository login'i ve kaynak başına snapshotter routing hazırlığı bunun dışında ve ayrı runbook'lara tabidir.

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

Init scriptleri yalnız boş volume ilk oluşturulurken çalışır. Bootstrap
rollerindeki değişikliklerde bu davranışı göz önünde bulundurun; sırf yeniden
denemek için üretim volume'ünü silmeyin. Advisor şema değişiklikleri init
dosyalarına eklenmez, yeni manifest migration'ı olarak dağıtılır ve
`scripts/migrate-repository.sh` ile mevcut volume'e uygulanır.

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

### `pg_qualstats` eksik veya preload edilmemiş

```bash
docker compose exec -T source-db psql -U postgres -d powa -c \
  "SELECT extversion FROM pg_extension WHERE extname='pg_qualstats'; SHOW shared_preload_libraries;"
docker compose logs --tail=200 source-db collector
```

Extension dosyası image/host üzerinde bulunmalı, preload listesinde yer almalı ve preload değişikliğinden sonra PostgreSQL yeniden başlatılmış olmalıdır. Eski demo volume için yukarıdaki mevcut-volume geçişini uygulayın.

### Source startup shared-memory hatası

`PG_QUALSTATS_MAX` yükseltildiyse `SOURCE_DB_SHM_SIZE` değerini de kapasite ölçümüne göre artırın. Varsayılan kombinasyon `10000` ve `256mb` olarak kabul testinden geçer. Sabit `2.1.4` image'ı ayrıca belgelenen shared-memory hesap düzeltmesini içerir.

### HypoPG `UNAVAILABLE`, `UNSAFE` veya SQL göstermiyor

```bash
docker compose ps evaluator
docker compose logs --tail=200 evaluator api
docker compose exec -T source-db psql -U postgres -d appdb -c \
  "SELECT extversion FROM pg_extension WHERE extname='hypopg'; SELECT rolname, rolconfig FROM pg_roles WHERE rolname='advisor_evaluator';"
```

Mevcut demo volume'ünde extension/rol yoksa `bash scripts/enable-hypopg.sh` çalıştırıp `evaluator api web` servislerini yeniden oluşturun. `UNSAFE`, evaluator arızası demek değildir: DML, birden çok statement, RLS, çözümlenemeyen veya ikiden fazla kolonlu aday, B-tree uyumsuz operator ya da eski repository OID'i güvenli biçimde reddedilir. `NO_IMPROVEMENT` eşdeğer index bulunduğunu ya da varsayılan `%10` planner-cost eşiğinin aşılmadığını gösterebilir. SQL yalnız `VALIDATED` durumda açılır; HypoPG yolunda hiçbir durumda gerçek DDL çalıştırılmaz.

Dış alias yalnız collector'a kaydedildiyse `SOURCE_NOT_CONFIGURED` beklenir. Ana API'ye source DSN eklemeyin; [dış kaynak evaluator runbook'unu](ITERATION_2_2_HYPOPG.md#dış-kaynak-sınırı-ve-runbook) uygulayın.

### JOIN predicate kaynakta var, repository'de yok

Stock `powa_qualstats_src` yalnız tek taraflı WHERE/filter kayıtlarını taşır; JOIN için `join-snapshotter` ayrıca sağlıklı olmalıdır. Önce source wrapper/outbox'ı, iki ayrı düşük yetkili rolü ve servis logunu kontrol edin:

```bash
docker compose ps join-snapshotter
docker compose logs --tail=200 join-snapshotter collector
docker compose exec -T source-db psql -U postgres -d powa -c \
  "SELECT batch_id, captured_at, row_count FROM advisor_join.outbox_batches ORDER BY batch_id DESC LIMIT 10;"
docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -c \
  "SELECT * FROM advisor.join_snapshot_capability(1);"
```

Outbox doluyor fakat repository status ilerlemiyorsa source/repository DSN, ayrı parolalar ve internal `join_source`/`join_repository` ağlarını doğrulayın. Dış alias için referans Compose'un demo DSN'ini yeniden kullanmayın; kaynak başına ayrı snapshotter routing'i gerekir. `joinsAvailable=false` sorguda JOIN bulunmadığını kanıtlamaz.

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

Uzak erişimin varsayılan olarak kapalı olduğunu unutmayın. Kimlik doğrulayan/TLS
sonlandıran reverse proxy hazırsa ve riski bilinçli kabul ettiyseniz:

1. `.env` içinde özellikle `WEB_BIND=0.0.0.0` seçildiğini doğrulayın.
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
