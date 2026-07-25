# PostgreSQL Sorgu Performansı ve Öneri Motoru

PDF v1.1'de tarif edilen ilk iterasyonun çalışan referans uygulamasıdır. Tek bir Docker/OrbStack hostu üzerinde **iki ayrı PostgreSQL sunucu süreci** çalışır: demo kaynak instance `5432`, PoWA repository instance `5433`. PoWA Collector istatistikleri kaynaktan repository'ye taşır; FastAPI yalnız repository'yi okur ve React arayüzü sonuçları gösterir. Aynı repository/collector, `scripts/register-source.sh` ile birden fazla gerçek PostgreSQL kaynağı izleyebilir.

> Bu sürüm önce hangi sorguya bakılması gerektiğini gösterir, gerçek CPU tüketimini ayrı gözlem sinyali olarak sunar ve dar kapsamlı WHERE adaylarını HypoPG ile doğrulayabilir. Yalnız doğrulanmış aday için kopyalanabilir `CREATE INDEX CONCURRENTLY` taslağı üretir; otomatik `CREATE/DROP INDEX`, SQL rewrite veya canlı veritabanına müdahale yapmaz.

## Hızlı başlangıç

Gerekenler:

- Çalışan Docker Engine + Docker Compose v2 veya macOS'ta OrbStack
- İlk image build'i için internet erişimi
- Kabul testi için `bash`, `curl` ve Python 3.10+ (`python3` veya `python`)

Proje kökünde:

```bash
cp .env.example .env
chmod 600 .env
```

`.env` içindeki admin, collector, API, evaluator ve iç servis token örneklerini değiştirin. Ardından:

```bash
docker info
docker compose version
docker compose config --quiet
docker compose up --build -d
docker compose ps
```

Bu komut demo PostgreSQL'ü ölçülebilir hedef olarak hazırlar ancak sürekli yük üreten `workload` servisini başlatmaz. `REGISTER_DEMO_SOURCE=false` yalnız **boş bir repository volume'ünün ilk kurulumu öncesinde** seçilirse demo kaydı oluşturulmaz; gerçek kaynak-only kurulumlarda bu seçenek kullanılabilir.

İlk build sırasında PostgreSQL 18 tabanı üzerinde PoWA Archivist 5.2.0, `pg_qualstats` 2.1.4, `pg_stat_kcache` 2.3.2 ve HypoPG 1.4.3 doğrulanmış kaynak arşivlerinden derlenir; bu nedenle sonraki başlatmalardan daha uzun sürer. PostgreSQL 17 named volume'leri yalnız image etiketi değiştirilerek açılamaz; PG18'in `/var/lib/postgresql/18/docker` veri dizini düzenine dump/restore veya `pg_upgrade` ile taşınmalıdır. Aşağıdaki scriptler aynı PostgreSQL major sürümündeki mevcut demo volume'lerini yeni extension/rol/grant düzenine geçirir; temiz volume init sırasında zaten hazırlanır.

```bash
bash scripts/enable-pg-qualstats.sh
bash scripts/enable-hypopg.sh
bash scripts/enable-pg-stat-kcache.sh
```

Servisler sağlıklı olduktan sonra:

```bash
bash scripts/verify.sh
```

Başarılı sonuç İterasyon 2.1-B predicate hattını, İterasyon 2.2 HypoPG doğrulamasını, puan kalibrasyon guard'larını ve İterasyon 2.3 CPU telemetrisini kabul eder.

## Erişim adresleri

| Bileşen | Yerel adres | Varsayılan erişim |
|---|---|---|
| Web arayüzü | <http://localhost:5173> | Host ağına açık (`0.0.0.0`) |
| Web üzerinden API | <http://localhost:5173/api/v1/health> | Nginx proxy üzerinden |
| FastAPI | <http://localhost:8000/api/v1/health> | Yalnız loopback (`127.0.0.1`) |
| OpenAPI | <http://localhost:8000/docs> | Yalnız loopback |
| Kaynak PostgreSQL | `127.0.0.1:15432/appdb` | Yalnız loopback; container içinde `5432` |
| PoWA repository | `127.0.0.1:15433/powa_repository` | Yalnız loopback; container içinde `5433` |

Başka bir bilgisayardan yalnız `http://SUNUCU_IP:5173` adresini açın. API çağrıları arayüzün Nginx `/api` proxy'sinden geçer; `15432`, `15433` ve `8000` portlarını dış ağa açmayın.

Arayüzde şu analiz ekranları bulunur:

- Genel Bakış: yük özeti, en yüksek etkili sorgular ve trend
- Sorgular: arama, filtreleme, sıralama, dönem karşılaştırması, `pg_stat_kcache` gerçek CPU/OS I/O, pg_qualstats tabanlı WHERE gözlemleri ve isteğe bağlı HypoPG plan doğrulaması
- Sistem Sağlığı: son repository snapshot'ındaki seq scan, dead tuple, autovacuum ve uzun transaction sinyalleri; dönem seçici bu snapshot ekranında gösterilmez
- Operasyonlar: collector/retention görünürlüğü, repository kapasitesi, veritabanı ve cluster I/O, WAL/checkpoint ile güvenli index kullanım sinyalleri

## Kontrollü test yükü

Kaynak veritabanındaki `run_advisor_test_workload(iterations integer)` fonksiyonu dört tekrarlanabilir `SELECT` deseniyle birlikte kontrollü bir `INSERT` / `UPDATE` / `DELETE` döngüsü çalıştırır. DML döngüsü eklediği satırı aynı çağrı içinde sildiği için test tablosu sınırsız büyümez. Fonksiyonu sarmalayan komut:

```bash
bash scripts/run-test-workload.sh 20
```

`iterations` değeri `1–1000` arasında olmalıdır. Script yalnız bu test oturumunda `pg_qualstats.sample_rate=1` kullanır; global varsayılan `0.1` kalır. Collector frekansı demo için 5 saniyedir; iki snapshot oluşması ve fark metriklerinin görünmesi için komuttan sonra yaklaşık 10 saniye bekleyin.

Varsayılan kurulum **sürekli sentetik trafik üretmez**. Sürekli demo trafiğini özellikle açmak isterseniz:

```bash
docker compose --profile demo up -d workload
```

Durdurmak için:

```bash
docker compose stop workload
```

## İterasyon 2.1-B — `pg_qualstats` altyapı durumu

Altyapı ve ilk ürün adımı tamamlandı: PostgreSQL 18 image'ı sabitlenmiş `pg_qualstats 2.1.4` içeriyor; kaynakta preload, güvenli başlangıç ayarları, extension/grant'lar ve PoWA datasource kaydı hazır. Collector predicate geçmişini repository'ye taşır. `GET /api/v1/queries/{queryId}/predicates` endpoint'i ve sorgu detayındaki **WHERE filtreleri ve index adayı gözlemleri** paneli; kolonları, örneklenen predicate çalışma sayısını, işlenen/elenen satırı, eleme oranını ve veri kapsamını açıklar.

Çıktı yalnız gözlemdir: Impact Score'a katılmaz, otomatik `CREATE INDEX` üretmez veya çalıştırmaz ve kullanıcıyı HypoPG/EXPLAIN doğrulamasına yönlendirir. Düşük örnekli kayıtlar `INSUFFICIENT_DATA` olarak işaretlenir.

Önemli veri sınırı şudur: kaynak `pg_qualstats()` hem `WHERE` hem kolon-kolon `JOIN` predicate'lerini yakalar. PoWA 5.2'nin standart remote datasource'u ise repository geçmişine yalnız tek tarafında kolon bulunan `WHERE`/filter predicate'lerini taşır. JOIN görünürlüğünün ürünleştirilmesi sonraki adımda ayrı, düşük yetkili bir `source-snapshotter` gerektirir. Uygulama ve işletim ayrıntıları [İterasyon 2.1-B runbook'unda](docs/ITERATION_2_1_B_PG_QUALSTATS.md) yer alır.

## İterasyon 2.2 — HypoPG doğrulaması

HypoPG 1.4.3 kaynak PostgreSQL 18 image'ına sabitlendi ve ayrı, salt-okunur `evaluator` servisine bağlandı. Sorgu detayındaki uygun WHERE adayı için kullanıcı **HypoPG ile doğrula** dediğinde sistem aynı kaynak oturumunda önce normal, sonra sanal tek kolonlu B-tree index ile plain `EXPLAIN` planı alır. Sanal index gerçekten seçilir ve yapılandırılmış planner-cost eşiği aşılırsa maliyet farkı, tahmini index boyutu, güven seviyesi ve kopyalanabilir `CREATE INDEX CONCURRENTLY` taslağı gösterilir.

İlk kapsam yalnız tek statement `SELECT`/`WITH`, tek kolonlu B-tree uyumlu predicate ve yapılandırılmış `test-source/appdb` hedefidir. `EXPLAIN ANALYZE`, gerçek DDL, DML replay, SQL rewrite ve otomatik uygulama yoktur; bütün cevaplarda `ddlExecuted=false` kalır. Collector'a dış kaynak eklemek o kaynağı otomatik evaluator kapsamına almaz. Güvenlik modeli, sonuç durumları, mevcut-volume adımı ve dış kaynak runbook'u [İterasyon 2.2 belgesindedir](docs/ITERATION_2_2_HYPOPG.md).

## İterasyon 2.3 — `pg_stat_kcache` gerçek CPU telemetrisi

`pg_stat_kcache 2.3.2` PostgreSQL 18 image'ına sabitlendi ve PoWA 5.2 remote hattına bağlandı. Sorgu listesi ve detay ekranı execution user/system/total CPU süresini, CPU'nun DB süresindeki oranını ve OS filesystem read/write byte değerlerini gösterir. Extension kapalı, history yetersiz ve veri kullanılabilir durumları ayrı capability sonucu taşır; eksik veri sahte `0 CPU` olarak sunulmaz.

CPU bu iterasyonda gözlem modundadır: `scoreIncluded=false` kalır ve mevcut Impact Score ağırlıkları değişmez. Paralel worker CPU toplamı duvar saatini aşabileceği için oran `%100` üstünde olabilir. Kurulum, mevcut-volume migration'ı, sayaç semantiği, overhead komutu ve kabul ayrıntıları [İterasyon 2.3 runbook'undadır](docs/ITERATION_2_3_PG_STAT_KCACHE.md).

## İterasyon 1 kapanış notu — 24 Temmuz 2026

İlk iterasyonun mimarisi ve veri akışı çalışır durumdadır: kaynak PostgreSQL, remote PoWA collector, ayrı repository, repository-only API ve dört ana UI ekranı canlı verilerle doğrulanmıştır. Backend unit testleri, frontend unit testleri ve production build başarılıdır. Bununla birlikte puanlama ve bazı sunum kuralları üretim kararı vermeden önce yeniden kalibre edilmelidir.

Denetim sırasında agresif demo yükü 6 worker ile yaklaşık 1.164 statement yürütmesi/sn üretti. Bir saatlik pencerede 17 sorgunun 13'ü süre hacmi, 16'sı çağrı hacmi için tam katsayıya ulaştı. Bu nedenle mevcut hacim eşikleri sorguları ayırmakta yetersiz kalıyor. Özellikle şu konular İterasyon 2 öncesi zorunlu doğruluk işi olarak kaydedildi:

1. Regresyon puanı yalnız pozitif değişime göre verilmemeli. Denetimde yaklaşık `%0,8–%1,8` değişimler bile `4,71–10` puan aldı ve dashboard tarafından “yavaşlayan sorgu” sayıldı. Anlamlı değişim eşiği, yeterli örnek sayısı ve değişim büyüklüğü katsayısı eklenmeli.
2. Demo kaynağındaki `pg_stat_statements.track=all` nedeniyle `run_advisor_test_workload` dış çağrısı ile fonksiyon içi sorgular aynı toplamda çift atfediliyor. Wrapper listede kalmalı; ancak dashboard toplamları top-level statementlardan hesaplanmalı, inner statementlar ayrı analiz edilmelidir. WAL için query-attributed toplam ile sunucu düzeyi gerçek WAL açıkça ayrılmalıdır.
3. Süre, çağrı, fiziksel okuma, temp ve WAL tam-puan eşikleri sabit ve düşük değerler yerine gözlem süresi, sunucu toplamındaki pay ve ortam profiliyle kalibre edilmelidir. Çağrı sayısı toplam sürenin içinde zaten etkili olduğundan ayrıca verilen ağırlık çift ödüllendirme açısından yeniden değerlendirilmelidir.
4. API seçili pencerenin gerçek veri kapsamını (`observedFrom`, `observedTo`, `coveragePercent`) ve önceki dönem karşılaştırmasının kullanılabilirliğini dönmelidir. Yeterli geçmiş yokken `0 regresyon`, “regresyon yok” anlamında gösterilmemelidir.
5. Bir saatlik rolling index penceresinde ölçülen aralık pratikte `1 saat`ten birkaç saniye kısa kaldığı için `observed_hours < 1` kontrolü indexleri sürekli `INSUFFICIENT_DATA` durumunda bırakabilir. Snapshot frekansını tolere eden kapsam kontrolü kullanılmalıdır.
6. Bir saatlik grafik etiketleri dakika içermeli; sıfır hareketli `pg_stat_io` bağlamları varsayılan görünümden çıkarılmalı; Genel Bakış sorgu önizlemesi Sorgular ekranındaki eski filtrelerden etkilenmemelidir.
7. Sistem Sağlığı sinyalleri kümülatif sayaç ve küçük demo tabloları nedeniyle fazla hassastır. `stats_reset`, gözlem süresi, tablo boyutu ve zaman penceresi sinyal açıklamasına dahil edilmelidir.
8. Sürekli workload için `normal` ve `stress` profilleri ayrılmalıdır. Kabul testi normal profille, doygunluk ve kapasite testi stress profiliyle çalışmalıdır.

**25 Temmuz 2026 kısa kalibrasyon kapanışı:** En yüksek doğruluk etkili iki madde kapatıldı. Ana dashboard/trend yalnız top-level statement toplamını kullanıyor; regresyon puanı ve “yavaşlayan sorgu” sayısı için her iki dönemde en az 20 çağrı ve en az `%20` artış gerekiyor, büyüklük katsayısı `%50`de tam değere ulaşıyor. Observation-hour hacim modeli ve 85/70/40 priority sınırları korundu. Ortam profili, coverage ve uzun süreli production dağılım kalibrasyonu ayrı ürün işi olarak kalır; 2.3 CPU sinyali ölçüm görmeden skora eklenmedi.

## İterasyon 2 araç stratejisi

İterasyon 2 tek büyük paket olarak uygulanmayacaktır. Her araçlı alt iterasyon yalnız **bir** yeni PostgreSQL aracı/extension ekleyecek; kurulum, collector kaydı, repository şeması, API sözleşmesi, UI açıklaması, overhead ölçümü, capability fallback'i ve kabul testi aynı alt iterasyonda tamamlanacaktır. Bir araç kararlı hâle gelmeden sonraki araca geçilmeyecektir.

| Aday alt iterasyon | Tek araç | Kazandırdığı veri | Mevcut mimariye uyum | Temel dikkat noktası |
|---|---|---|---|---|
| `2.1-B` | `pg_qualstats` | Kaynakta `WHERE`/`JOIN`, standart repository hattında `WHERE`/filter predicate istatistikleri | Altyapı tamamlandı; JOIN tarihçesi için özel snapshotter gerekir | Sampling overhead'i ve entry büyümesi ölçülmeli; agresif demoda constants takibi sınırlanmalı |
| `2.2` | `HypoPG` | Gerçek index oluşturmadan sanal index kullanımı, plan maliyeti ve tahmini boyut karşılaştırması | Tamamlandı; ayrı salt-okunur evaluator aynı kaynak oturumunu kullanır | İlk kapsam SELECT + tek kolonlu B-tree + yapılandırılmış `appdb`; dış kaynaklar ayrıca hazırlanmalı |
| `2.3` | `pg_stat_kcache` | Sorgu bazında CPU user/system süresi ve işletim sistemi fiziksel I/O'su | Tamamlandı; PoWA remote history + API/UI capability | Skor dışında gözlem modunda; gerçek yükte dağılım izlenmeli |
| `2.4` | `pg_wait_sampling` | CPU dışı bekleme nedenleri, lock/I/O/client wait dağılımı | Sıradaki; PoWA remote mode destekler | Sampling frekansı ve ek yük ölçülmeli |
| `2.5` | JOIN snapshotter | PoWA'nın taşımadığı kolon-kolon JOIN ilişkileri | Ayrı düşük yetkili servis gerekir | Secret, read-only transaction, timeout ve audit sınırı |
| `2.6` | Composite öneri | JOIN + WHERE kanıtından kolon sırası | 2.5 sonrasında | Eşitlik/range sırası ve mevcut index örtüşmesi doğrulanmalı |
| `2.7` | İzole gerçek test | Disposable clone üzerinde gerçek index + `EXPLAIN ANALYZE` | Opsiyonel, kaynak dışı | Clone yaşam döngüsü, veri güvenliği ve maliyet |
| Alternatif plan yakalama | `auto_explain` | Yavaş sorguların gerçek planlarını loga yazar | Düşük; PoWA repository hattına doğal olarak akmaz | Log ingestion, hassas veri, örnekleme ve planlama/çalıştırma overhead'i gerektirir |

**Seçilen rota:** `pg_qualstats`, HypoPG ve `pg_stat_kcache` alt iterasyonları tamamlandı. Sıradaki araç `2.4 pg_wait_sampling`; ardından PoWA'nın taşımadığı JOIN'ler için `2.5` düşük yetkili snapshotter, yeterli JOIN/WHERE kanıtından sonra `2.6` composite kolon sırası ve opsiyonel `2.7` disposable clone doğrulaması gelir. HypoPG gerçek index oluşturmaz; gösterilen SQL'i çalıştırma kararı DBA'ya aittir.

PoWA'nın taşıdığı tarihsel veriler repository üzerinden sunulmaya ve ana API repository-only kalmaya devam eder. İterasyon 2.2'de HypoPG için ayrı, düşük yetkili `evaluator` servisi yalnız açıkça yapılandırılmış tek kaynak/database hedefine bağlanır. Kaynak erişimi veya HypoPG hazırlığı olmayan kurulumlarda doğrulama `UNAVAILABLE` döner; çoklu dış kaynak evaluator routing'i henüz yoktur. PoWA'nın taşımadığı JOIN snapshotları da ileride ayrı, audit edilen `source-snapshotter` gerektirir.

## Gerçek bir PostgreSQL kaynağı ekleme

Bu entegrasyon yalnız PostgreSQL içindir. Kaynak cluster'a uygun PoWA Archivist, `pg_stat_statements`, `pg_qualstats 2.1.x` ve `pg_stat_kcache 2.3.x` paketleri önceden kurulmuş; `pg_stat_statements,pg_qualstats,pg_stat_kcache` `shared_preload_libraries` içinde etkin olmalıdır. Script extension binary'si veya PostgreSQL ayarı kurmaz; preload değişikliği ve gerekli restart kaynak DBA'ya aittir.

1. Örneği Git dışındaki güvenli bir konuma kopyalayın:

   ```bash
   cp config/source.env.example /secure/prod-source.env
   chmod 600 /secure/prod-source.env
   printf '%s\n' 'GUCLU_COLLECTOR_PAROLASI' > /secure/powa-collector.password
   chmod 600 /secure/powa-collector.password
   ```

2. `/secure/prod-source.env` içindeki host, alias ve parola dosyası yolunu değiştirin.
3. Kaynak DBA hazırlığını da aynı komutla yapmak istiyorsanız `PREPARE_SOURCE=true` ve ayrı bir `SOURCE_ADMIN_PASSWORD_FILE` tanımlayın. Hazırlık daha önce yapıldıysa `false` bırakın.
4. Kaydedin ve ilk snapshot'ı doğrulayın:

   ```bash
   bash scripts/register-source.sh --env-file /secure/prod-source.env
   bash scripts/verify-source.sh production-main
   ```

Komut tekrar çalıştırılabilir: aynı alias yeni satır açmaz; bağlantı/frequency/retention değerlerini günceller. Kaynak parolası repository'de tutulmaz. Alias başına `runtime/collector/sources/*.pgpass` altında `0600` bir secret oluşur, collector yeniden başlar ve ilk snapshot beklenir. Ayrıntılar ve kaynak tarafı kurulum adımları [kurulum rehberindedir](docs/INSTALLATION.md#gerçek-bir-postgresql-kaynağını-ekleme).

## Servisler ve veri akışı

| Compose servisi | Görev | Kalıcı veri |
|---|---|---|
| `source-db` | PostgreSQL 18, `appdb`, `pg_stat_statements`, `pg_qualstats`, `pg_stat_kcache`, HypoPG ve remote PoWA fonksiyonları | `source_data` |
| `repository-db` | PostgreSQL 18, PoWA geçmişi ve `advisor` şeması | `repository_data` |
| `collector` | PoWA Collector 1.3.2; kaynaktan snapshot alır | Yok |
| `api` | Repository-only FastAPI okuma/annotation katmanı | Repository'de |
| `evaluator` | Yapılandırılmış kaynakta salt-okunur HypoPG/plain-EXPLAIN doğrulaması | Yok |
| `workload` | Yalnız `demo` profili açıldığında sürekli sentetik sorgu yükü | Yok |
| `web` | React + TypeScript arayüzü ve Nginx API proxy | Yok |

```text
source-db:5432 ───────┐
external PG #1 ──────┼──okuma──> collector ──yazma──> repository-db:5433
external PG #N ──────┘                                      │
                                                            v
                                                   api:8000 ──> web:5173

configured source/appdb ──salt-okunur──> evaluator:8010 ──iç API──> api:8000
```

Mimari sınırlar ve rol matrisi için [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) dosyasına bakın.

## Güvenlik sınırları

- Repository'deki kaynak kayıtlarında parola tutulmaz (`password = NULL`); collector Git dışında tutulan alias-bazlı `0600` pgpass secret'larını açılışta geçici `.pgpass` dosyasında birleştirir.
- `powa_collector`, PostgreSQL'ün hazır PoWA rollerini ve kaynakta `pg_read_all_stats` yetkisini kullanır.
- `advisor_api` yalnız repository DSN'i alır. Yapılandırma doğrulaması `source-db`, `5432` veya `appdb` içeren API DSN'ini reddeder.
- Kaynak DSN'i yalnız ayrı `evaluator` servisindedir. Bu servis `advisor_evaluator` rolü, read-only transaction, kısa timeout, connection limit, internal network ve token korumalı iç endpoint ile sınırlandırılır; ana API'ye kaynak parolası verilmez.
- HypoPG fonksiyonlarının PUBLIC yetkileri kaldırılmıştır. Evaluator yalnız sanal index oluşturur ve plain `EXPLAIN` çalıştırır; kopyalanabilir SQL'in kullanıcıya dönmesi gerçek DDL çalıştığı anlamına gelmez.
- Header gönderilmeyen API isteği `viewer` sayılır ve tam SQL maskelenir. `X-Advisor-Role: analyst` ve `admin` SQL'i görür; CSV export yalnız `admin` içindir. Referans web istemcisi analiz ekranlarını gösterebilmek için şu anda `analyst` header'ı gönderir.
- Bu header tabanlı rol seçimi ilk iterasyon demonstrasyonudur, kimlik doğrulama değildir. İnternet erişimi verilen bir kurulumda OIDC/SSO veya kimlik doğrulayan reverse proxy eklenmeden üretim güvenliği sağlanmış sayılmaz.
- `.env` yalnız yerel geliştirme içindir; canlı ortamda secret manager ve parola rotasyonu kullanın.
- Docker port publish kuralları bazı firewall araçlarından önce uygulanabilir. Linux sunucuda `DOCKER-USER` zinciri veya kurumun network policy katmanıyla yalnız web portuna izin verildiğini ayrıca doğrulayın.

## Testler

Tüm çalışma zamanı kabul kontrolleri:

```bash
bash scripts/verify.sh
```

Bu script Compose geçerliliğini, iki PostgreSQL 18 instance'ını ve data directory düzenini, extension sürümlerini, 90 gün retention'ı, raw JOIN/WHERE predicate yakalamayı, repository filter geçmişi/katalog eşlemesini, güvenli predicate endpoint'ini, HypoPG evaluator izolasyonunu ve gerçek DDL üretmeden plan doğrulamasını, iki snapshot'ı, collector sağlığını, gerçek API metriklerini, SQL maskelemesini, 2 saniyelik API hedefini, annotation audit kaydını ve ana API'nin kaynak DSN taşımadığını kontrol eder.

Backend unit testleri:

```bash
docker build -f backend/Dockerfile.test -t postgresql-advisor/backend-tests backend
docker run --rm postgresql-advisor/backend-tests
```

Frontend unit testleri:

```bash
docker run --rm -v "$PWD/frontend:/app" -w /app node:22-alpine sh -c 'npm ci && npm test'
```

## İşletim

Durum ve loglar:

```bash
docker compose ps
docker compose logs --tail=100 collector evaluator api web
```

Repository yedeği:

```bash
bash scripts/backup-repository.sh
```

Yedek `backups/powa_repository-<UTC-zaman>.dump` olarak oluşturulur. Normal durdurma veriyi korur:

```bash
docker compose down
```

`docker compose down -v` ise **hem kaynak hem repository volume'lerini ve bütün geçmişi kalıcı olarak siler**. Yalnız yeniden üretilebilir test verisi için ve gerekli yedek alındıktan sonra kullanın.

## Belgeler

- [Kurulum ve işletim rehberi](docs/INSTALLATION.md)
- [Mimari ve güvenlik sınırları](docs/ARCHITECTURE.md)
- [PDF v1.1 uygunluk ve düzeltme incelemesi](docs/PDF_REVIEW.md)
- [Güncel veri kullanımı ve İterasyon 1.1 raporu](docs/postgresql_dashboard_veri_kullanimi_raporu.pdf)
- [İterasyon 1.1 belge boşluk analizi](docs/ITERATION_1_1_GAP_ANALYSIS.md)
- [İterasyon 2.1-B `pg_qualstats` durum ve işletim notu](docs/ITERATION_2_1_B_PG_QUALSTATS.md)
- [İterasyon 2.2 HypoPG plan doğrulaması ve dış kaynak runbook'u](docs/ITERATION_2_2_HYPOPG.md)
- [İterasyon 2.3 `pg_stat_kcache` CPU telemetrisi](docs/ITERATION_2_3_PG_STAT_KCACHE.md)

## Sabitlenen temel sürümler

- PostgreSQL `18` (`postgres:18-trixie`; doğrulanan patch sürümü `18.4`)
- PoWA Archivist `5.2.0` / `REL_5_2_0` — kaynak arşiv SHA-256 ile doğrulanır
- `pg_qualstats 2.1.4` — kaynak arşiv SHA-256 ile doğrulanır; sabit sürüme hedefli shared-memory düzeltmesi uygulanır
- `pg_stat_kcache 2.3.2` — PostgreSQL 18 uyumlu kaynak arşiv SHA-256 ile doğrulanır
- HypoPG `1.4.3` — tam upstream commit ve kaynak arşiv SHA-256 ile doğrulanır
- PoWA Collector `1.3.2` — wheel SHA-256 ile sabitlenir
- Python `3.12`, Node `22`, Nginx `1.27`

Güncel tasarım dayanakları: [PoWA remote setup](https://powa.readthedocs.io/en/latest/remote_setup.html), [PoWA destekli stats extension'ları](https://powa.readthedocs.io/en/latest/components/stats_extensions/), [pg_qualstats](https://powa.readthedocs.io/en/latest/components/stats_extensions/pg_qualstats.html), [pg_stat_kcache](https://powa.readthedocs.io/en/latest/components/stats_extensions/pg_stat_kcache.html), [HypoPG](https://github.com/HypoPG/hypopg), [PoWA güvenlik](https://powa.readthedocs.io/en/latest/security.html), [Docker Engine kurulumu](https://docs.docker.com/engine/install/).
