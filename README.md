# PostgreSQL Sorgu Performansı ve Öneri Motoru

PDF v1.1'de tarif edilen ilk iterasyonun çalışan referans uygulamasıdır. Tek bir Docker/OrbStack hostu üzerinde **iki ayrı PostgreSQL sunucu süreci** çalışır: demo kaynak instance `5432`, PoWA repository instance `5433`. PoWA Collector istatistikleri kaynaktan repository'ye taşır; FastAPI yalnız repository'yi okur ve React arayüzü sonuçları gösterir. Aynı repository/collector, `scripts/register-source.sh` ile birden fazla gerçek PostgreSQL kaynağı izleyebilir.

> Bu sürüm önce hangi sorguya bakılması gerektiğini gösterir; gerçek CPU ile sampled wait profilini ayırır, JOIN ilişkilerini düşük yetkili snapshotter ile taşır ve iki kolonlu adayları HypoPG ile doğrular. Gerçek `CREATE INDEX` yalnız isteğe bağlı disposable clone profilinde çalışır; izlenen kaynakta otomatik DDL, SQL rewrite veya müdahale yapılmaz.

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

`.env` içindeki admin, collector, API, evaluator, runtime operator ve iç servis token örneklerini değiştirin. `RUNTIME_ADMIN_TOKEN` değerini frontend build/env dosyasına koymayın. Ardından:

```bash
docker info
docker compose version
docker compose config --quiet
docker compose up --build -d
docker compose ps
```

Bu komut demo PostgreSQL'ü ölçülebilir hedef olarak hazırlar ancak sürekli yük üreten `workload` servisini başlatmaz. `REGISTER_DEMO_SOURCE=false` yalnız **boş bir repository volume'ünün ilk kurulumu öncesinde** seçilirse demo kaydı oluşturulmaz; gerçek kaynak-only kurulumlarda bu seçenek kullanılabilir.

İlk build sırasında PostgreSQL 18 tabanı üzerinde PoWA Archivist 5.2.0, `pg_qualstats` 2.1.4, `pg_stat_kcache` 2.3.2, `pg_wait_sampling` release 1.1.11 (extension version 1.1) ve HypoPG 1.4.3 doğrulanmış kaynak arşivlerinden derlenir; bu nedenle sonraki başlatmalardan daha uzun sürer. PostgreSQL 17 named volume'leri yalnız image etiketi değiştirilerek açılamaz; PG18'in `/var/lib/postgresql/18/docker` veri dizini düzenine dump/restore veya `pg_upgrade` ile taşınmalıdır. Aşağıdaki scriptler aynı PostgreSQL major sürümündeki mevcut demo volume'lerini yeni extension/rol/grant düzenine geçirir; temiz volume init sırasında zaten hazırlanır.

```bash
bash scripts/enable-pg-qualstats.sh
bash scripts/enable-hypopg.sh
bash scripts/enable-pg-stat-kcache.sh
bash scripts/enable-pg-wait-sampling.sh
bash scripts/enable-join-snapshotter.sh
```

Servisler sağlıklı olduktan sonra:

```bash
bash scripts/verify.sh
```

Başarılı sonuç predicate, HypoPG, CPU, sampled wait, JOIN snapshot ve composite aday hatlarını kabul eder. İzole gerçek çalışma testi ayrı ve isteğe bağlıdır:

```bash
docker compose --profile real-validation up -d --wait clone-db clone-evaluator
bash scripts/verify-real-validation.sh
```

İkinci script demo eşitlik sorgusu için audit metadatalı sentetik replay fixture'ı kaydeder; gerçek indexin yalnız disposable candidate clone'da kullanıldığını, kaynağın değişmediğini ve iki job database'in de temizlendiğini doğrular.

## Erişim adresleri

| Bileşen | Yerel adres | Varsayılan erişim |
|---|---|---|
| Web arayüzü | <http://localhost:5173> | Yalnız loopback (`127.0.0.1`) |
| Web üzerinden API | <http://localhost:5173/api/v1/health> | Nginx proxy üzerinden |
| FastAPI | <http://localhost:8000/api/v1/health> | Yalnız loopback (`127.0.0.1`) |
| OpenAPI | <http://localhost:8000/docs> | Yalnız loopback |
| Kaynak PostgreSQL | `127.0.0.1:15432/appdb` | Yalnız loopback; container içinde `5432` |
| PoWA repository | `127.0.0.1:15433/powa_repository` | Yalnız loopback; container içinde `5433` |

Uzak erişim varsayılan olarak kapalıdır. Bilinçli bir sunucu kurulumunda kimlik doğrulayan/TLS sonlandıran reverse proxy kullanın; yalnız bu sınır hazırsa `WEB_BIND=0.0.0.0` ile web portunu açın. API çağrıları arayüzün Nginx `/api` proxy'sinden geçer; `15432`, `15433` ve `8000` portlarını dış ağa açmayın.

Arayüzde şu analiz ekranları bulunur:

- Genel Bakış: yük özeti, en yüksek etkili sorgular ve trend
- Sorgular: arama, filtreleme, dönem karşılaştırması, gerçek CPU/OS I/O, sampled wait dağılımı, WHERE/JOIN kanıtı, composite kolon sırası, HypoPG ve isteğe bağlı clone runtime doğrulaması
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

Önemli veri sınırı şudur: kaynak `pg_qualstats()` hem `WHERE` hem kolon-kolon `JOIN` predicate'lerini yakalar. PoWA 5.2'nin standart remote datasource'u yalnız `WHERE`/filter predicate'lerini taşır; JOIN kapsamı artık reset ile aynı transaction'daki outbox ve düşük yetkili `join-snapshotter` üzerinden tamamlanır. Ayrıntılar [İterasyon 2.1-B](docs/ITERATION_2_1_B_PG_QUALSTATS.md) ve [2.5–2.7](docs/ITERATIONS_2_5_TO_2_7.md) runbook'larındadır.

## İterasyon 2.2 — HypoPG doğrulaması

HypoPG 1.4.3 kaynak PostgreSQL 18 image'ına sabitlendi ve ayrı, salt-okunur `evaluator` servisine bağlandı. Uygun tek kolonlu WHERE veya persisted iki kolonlu composite aday için aynı kaynak oturumunda önce normal, sonra sanal B-tree index ile plain `EXPLAIN` planı alınır. Sanal index seçilir ve planner-cost eşiği aşılırsa maliyet farkı, tahmini boyut, güven seviyesi ve kopyalanabilir `CREATE INDEX CONCURRENTLY` taslağı gösterilir.

Kapsam tek statement `SELECT`/`WITH`, en fazla iki kolonlu B-tree adayı ve yapılandırılmış `test-source/appdb` hedefidir. HypoPG tarafında `EXPLAIN ANALYZE` veya gerçek DDL yoktur ve `ddlExecuted=false` kalır. Gerçek çalışma yalnız ayrı clone profilindedir. Collector'a dış kaynak eklemek o kaynağı otomatik evaluator kapsamına almaz. Temel güvenlik modeli [İterasyon 2.2](docs/ITERATION_2_2_HYPOPG.md), composite/clone uzantısı [2.5–2.7 belgesindedir](docs/ITERATIONS_2_5_TO_2_7.md).

## İterasyon 2.3 — `pg_stat_kcache` gerçek CPU telemetrisi

`pg_stat_kcache 2.3.2` PostgreSQL 18 image'ına sabitlendi ve PoWA 5.2 remote hattına bağlandı. Sorgu listesi ve detay ekranı execution user/system/total CPU süresini, CPU'nun DB süresindeki oranını ve OS filesystem read/write byte değerlerini gösterir. Extension kapalı, history yetersiz ve veri kullanılabilir durumları ayrı capability sonucu taşır; eksik veri sahte `0 CPU` olarak sunulmaz.

CPU bu iterasyonda gözlem modundadır: `scoreIncluded=false` kalır ve mevcut Impact Score ağırlıkları değişmez. Paralel worker CPU toplamı duvar saatini aşabileceği için oran `%100` üstünde olabilir. Kurulum, mevcut-volume migration'ı, sayaç semantiği, overhead komutu ve kabul ayrıntıları [İterasyon 2.3 runbook'undadır](docs/ITERATION_2_3_PG_STAT_KCACHE.md).

## İterasyon 2.4–2.7 — wait, JOIN, composite ve izole gerçek test

`pg_wait_sampling` release 1.1.11 sorgu bazındaki bekleme örneklerini I/O, lock, LWLock, client, IPC, timeout, activity, extension ve other sınıflarına ayırır. Değerler örnek sayısıdır; duvar saati veya CPU yüzdesi değildir ve `scoreIncluded=false` kalır. Sürüm, overhead ve mevcut-volume runbook'u [pg_wait_sampling belgesindedir](docs/PG_WAIT_SAMPLING.md).

PoWA'nın taşımadığı kolon-kolon JOIN kayıtları, `pg_qualstats` reset'iyle aynı source transaction'ında durable outbox'a alınır. Ayrı `join-snapshotter` yalnız source `fetch/ack` ve repository `ingest/status/purge` fonksiyonlarını çağırabilir. Repository commit edilmeden source batch ack edilmez; tekrar teslim candidate/evidence anahtarlarında idempotenttir.

JOIN eşitliği ile aynı tablodaki WHERE equality/range kanıtı en az iki snapshot ve asgari occurrence eşiklerini geçtiğinde iki kolonlu B-tree adayı oluşur. Equality/range kuralı kolon sırasını açıklar; mevcut index prefix'i ve planner faydası canlı kaynakta salt-okunur HypoPG evaluator tarafından doğrulanır. Bu kanıt da ana inceleme skoruna katılmaz.

Gerçek çalışma testi varsayılan olarak kapalıdır. `real-validation` profili tmpfs üzerinde clone template'ten ayrı baseline/candidate veritabanları üretir, gerçek indexi yalnız candidate clone'da kurar ve dönüşümlü `EXPLAIN ANALYZE` medianlarını karşılaştırır. Parametreli replay yalnız exact query/candidate kimliğine bağlı, süresi ve audit metadatası olan server-side sentetik/anonim fixture ile açılır; browser serbest SQL veya bind değeri gönderemez. Her cevap `sourceDdlExecuted=false` ve clone cleanup durumunu taşır. Kurulum ve güvenlik sınırları [2.5–2.7 runbook'undadır](docs/ITERATIONS_2_5_TO_2_7.md).

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
| `2.1-B` | `pg_qualstats` | Kaynakta `WHERE`/`JOIN`, standart repository hattında `WHERE`/filter predicate istatistikleri | Tamamlandı; JOIN tarihçesi 2.5 outbox hattında | Sampling overhead'i ve entry büyümesi ölçülmeli; agresif demoda constants takibi sınırlanmalı |
| `2.2` | `HypoPG` | Gerçek index oluşturmadan sanal index kullanımı, plan maliyeti ve tahmini boyut karşılaştırması | Tamamlandı; ayrı salt-okunur evaluator aynı kaynak oturumunu kullanır | İlk kapsam SELECT + tek kolonlu B-tree + yapılandırılmış `appdb`; dış kaynaklar ayrıca hazırlanmalı |
| `2.3` | `pg_stat_kcache` | Sorgu bazında CPU user/system süresi ve işletim sistemi fiziksel I/O'su | Tamamlandı; PoWA remote history + API/UI capability | Skor dışında gözlem modunda; gerçek yükte dağılım izlenmeli |
| `2.4` | `pg_wait_sampling` | CPU dışı bekleme nedenleri, lock/I/O/client wait dağılımı | Tamamlandı; PoWA remote history + API/UI capability | Örnek sayısı süre değildir; overhead scripti ayrı container kullanır |
| `2.5` | JOIN snapshotter | PoWA'nın taşımadığı kolon-kolon JOIN ilişkileri | Tamamlandı; atomik source outbox + düşük yetkili aktarım | At-least-once teslim, idempotent ingest ve ayrı parolalar |
| `2.6` | Composite öneri | JOIN + WHERE kanıtından kolon sırası | Tamamlandı; persisted 2 kolonlu aday + HypoPG | Eşitlik/range sırası ve mevcut index prefix'i evaluator'da doğrulanır |
| `2.7` | İzole gerçek test | Disposable clone üzerinde gerçek index + `EXPLAIN ANALYZE` | Tamamlandı; varsayılan kapalı `real-validation` profili | Onaylı scalar replay fixture, clone marker/rol guard'ı ve zorunlu cleanup |
| Alternatif plan yakalama | `auto_explain` | Yavaş sorguların gerçek planlarını loga yazar | Düşük; PoWA repository hattına doğal olarak akmaz | Log ingestion, hassas veri, örnekleme ve planlama/çalıştırma overhead'i gerektirir |

**Seçilen rota tamamlandı:** `pg_qualstats`, HypoPG, `pg_stat_kcache`, `pg_wait_sampling`, düşük yetkili JOIN snapshotter, composite kolon sırası ve opsiyonel disposable clone doğrulaması birlikte çalışır. HypoPG kaynakta gerçek index oluşturmaz; gerçek DDL yalnız açıkça başlatılan clone profilinde yürür.

PoWA'nın taşıdığı tarihsel veriler repository üzerinden sunulmaya ve ana API repository-only kalmaya devam eder. HypoPG evaluator yalnız açıkça yapılandırılmış kaynak/database hedefine bağlanır; JOIN snapshotter farklı source/repository rolleriyle yalnız kontrollü fonksiyon çağırır. Ana API ne source ne clone DB credential'ı alır. Hazırlığı olmayan capability `UNAVAILABLE` döner.

## Gerçek bir PostgreSQL kaynağı ekleme

Bu entegrasyon yalnız PostgreSQL içindir. Kaynak cluster'a uygun PoWA Archivist, `pg_stat_statements`, `pg_qualstats 2.1.x`, `pg_stat_kcache 2.3.x` ve `pg_wait_sampling 1.1.11` paketleri önceden kurulmuş; dördü de `shared_preload_libraries` içinde etkin olmalıdır. Script extension binary'si veya PostgreSQL ayarı kurmaz; preload değişikliği ve gerekli restart kaynak DBA'ya aittir. JOIN reader secret/routing'i kaynak başına ayrıca yapılandırılır; referans Compose snapshotter'ı yalnız `test-source` içindir.

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
| `source-db` | PostgreSQL 18, `appdb`, stats/kcache/wait extension'ları, HypoPG ve JOIN outbox | `source_data` |
| `repository-db` | PostgreSQL 18, PoWA geçmişi ve `advisor` şeması | `repository_data` |
| `collector` | PoWA Collector 1.3.2; kaynaktan snapshot alır | Yok |
| `join-snapshotter` | JOIN outbox batch'lerini düşük yetkili rollerle repository'ye taşır | Yok |
| `api` | Repository-only FastAPI okuma/annotation katmanı | Repository'de |
| `evaluator` | Yapılandırılmış kaynakta salt-okunur HypoPG/plain-EXPLAIN doğrulaması | Yok |
| `clone-db`, `clone-evaluator` | Yalnız `real-validation` profilinde tmpfs disposable clone + gerçek test | Tmpfs; kalıcı değil |
| `workload` | Yalnız `demo` profili açıldığında sürekli sentetik sorgu yükü | Yok |
| `web` | React + TypeScript arayüzü ve Nginx API proxy | Yok |

```text
source-db:5432 ───────┐
external PG #1 ──────┼──okuma──> collector ──yazma──> repository-db:5433
external PG #N ──────┘                                      │
                                                            v
                                                   api:8000 ──> web:5173

configured source/appdb ──salt-okunur──> evaluator:8010 ──iç API──> api:8000

source JOIN outbox ──fetch/ack──> join-snapshotter ──ingest──> repository-db
api ──iç token──> clone-evaluator:8020 ──gerçek DDL──> disposable clone-db
```

Mimari sınırlar ve rol matrisi için [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) dosyasına bakın.

## Güvenlik sınırları

- Repository'deki kaynak kayıtlarında parola tutulmaz (`password = NULL`); collector Git dışında tutulan alias-bazlı `0600` pgpass secret'larını açılışta geçici `.pgpass` dosyasında birleştirir.
- `powa_collector`, PostgreSQL'ün hazır PoWA rollerini ve kaynakta `pg_read_all_stats` yetkisini kullanır.
- `advisor_api` yalnız repository DSN'i alır. Yapılandırma doğrulaması `source-db`, `5432` veya `appdb` içeren API DSN'ini reddeder.
- Kaynak DSN'i yalnız ayrı `evaluator` servisindedir. Bu servis `advisor_evaluator` rolü, read-only transaction, kısa timeout, connection limit, internal network ve token korumalı iç endpoint ile sınırlandırılır; ana API'ye kaynak parolası verilmez.
- HypoPG fonksiyonlarının PUBLIC yetkileri kaldırılmıştır. Evaluator yalnız sanal index oluşturur ve plain `EXPLAIN` çalıştırır; kopyalanabilir SQL'in kullanıcıya dönmesi gerçek DDL çalıştığı anlamına gelmez.
- Header gönderilmeyen API isteği `viewer` sayılır ve tam SQL maskelenir. Referans web istemcisi analiz ekranları için demonstrasyon amaçlı `analyst` header'ı gönderir; bu gerçek kullanıcı kimliği değildir.
- `admin` iddiası tek başına kabul edilmez. `RUNTIME_ADMIN_TOKEN` boşken admin işlemleri fail-closed kapalıdır; CSV export ve disposable-clone runtime testi için ayrıca bu server-side secret ile `X-Advisor-Admin-Token` gerekir. Secret browser bundle'ına verilmez; yalnız güvenilir yerel/operator istemcisi kullanır.
- Runtime bind değerleri public API requestinden alınmaz. DBA yalnız sentetik/anonim scalar fixture'ı exact persisted aday ve normalize SQL hash'ine bağlar; UI yalnız fixture'ın hazır olup olmadığını görür.
- Statik operator token'ı tam kullanıcı kimlik doğrulamasının yerini tutmaz. İnternet erişimi verilen bir kurulumda OIDC/SSO veya kimlik doğrulayan reverse proxy eklenmeden üretim güvenliği sağlanmış sayılmaz.
- `.env` yalnız yerel geliştirme içindir; canlı ortamda secret manager ve parola rotasyonu kullanın.
- Docker port publish kuralları bazı firewall araçlarından önce uygulanabilir. Uzak web erişimini özellikle açtıysanız Linux sunucuda `DOCKER-USER` zinciri veya kurumun network policy katmanıyla yalnız web portuna izin verildiğini ayrıca doğrulayın.

## Testler

Temel stack çalışma zamanı kabul kontrolleri:

```bash
bash scripts/verify.sh
```

Bu script Compose geçerliliğini, iki PostgreSQL 18 instance'ını ve data directory düzenini, extension sürümlerini, 90/30 günlük retention'ları, CPU/wait history'sini, raw JOIN/WHERE yakalamayı, atomik snapshot ve multi-user composite kanıtını, güvenli predicate endpoint'ini, HypoPG izolasyonunu, collector sağlığını, SQL maskelemesini, 2 saniyelik API hedefini, audit kaydını ve ana API'nin kaynak/clone DSN taşımadığını kontrol eder.

İsteğe bağlı gerçek clone kabulü:

```bash
docker compose --profile real-validation up -d --wait clone-db clone-evaluator
bash scripts/verify-real-validation.sh
```

Bu ikinci script operator fixture kaydını, admin-token sınırını, güvenli bind adaptasyonuyla gerçek index kullanımını ve zorunlu clone cleanup'ını doğrular.

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
- [İterasyon 2.4 `pg_wait_sampling` telemetrisi](docs/PG_WAIT_SAMPLING.md)
- [İterasyon 2.5–2.7 JOIN, composite ve disposable clone](docs/ITERATIONS_2_5_TO_2_7.md)

## Sabitlenen temel sürümler

- PostgreSQL `18` (`postgres:18-trixie`; doğrulanan patch sürümü `18.4`)
- PoWA Archivist `5.2.0` / `REL_5_2_0` — kaynak arşiv SHA-256 ile doğrulanır
- `pg_qualstats 2.1.4` — kaynak arşiv SHA-256 ile doğrulanır; sabit sürüme hedefli shared-memory düzeltmesi uygulanır
- `pg_stat_kcache 2.3.2` — PostgreSQL 18 uyumlu kaynak arşiv SHA-256 ile doğrulanır
- `pg_wait_sampling 1.1.11` / SQL extension `1.1` — kaynak arşiv SHA-256 ile doğrulanır
- HypoPG `1.4.3` — tam upstream commit ve kaynak arşiv SHA-256 ile doğrulanır
- PoWA Collector `1.3.2` — wheel SHA-256 ile sabitlenir
- Python `3.12`, Node `22`, Nginx `1.27`

Güncel tasarım dayanakları: [PoWA remote setup](https://powa.readthedocs.io/en/latest/remote_setup.html), [PoWA destekli stats extension'ları](https://powa.readthedocs.io/en/latest/components/stats_extensions/), [pg_qualstats](https://powa.readthedocs.io/en/latest/components/stats_extensions/pg_qualstats.html), [pg_stat_kcache](https://powa.readthedocs.io/en/latest/components/stats_extensions/pg_stat_kcache.html), [pg_wait_sampling](https://github.com/postgrespro/pg_wait_sampling), [HypoPG](https://github.com/HypoPG/hypopg), [PoWA güvenlik](https://powa.readthedocs.io/en/latest/security.html), [Docker Engine kurulumu](https://docs.docker.com/engine/install/).
