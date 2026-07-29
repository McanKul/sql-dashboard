# PostgreSQL Sorgu Performansı ve Öneri Motoru

Güncel sürüm: `1.1.1`. Değişiklikler [CHANGELOG.md](CHANGELOG.md), güvenli
yükseltme ve geri dönüş adımları [upgrade/rollback runbook'unda](docs/UPGRADE_ROLLBACK.md).

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

`.env` içindeki PostgreSQL ve iç servis secret örneklerini değiştirin. Annotation,
CSV ve gerçek-index clone runtime endpoint'i için raw token'ı secret manager'da
tutup yalnız hash registry'sini `ADVISOR_AUTH_PRINCIPALS` olarak yapılandırın;
raw token'ı frontend build/env dosyasına koymayın. Dashboard source EXPLAIN yolu
tek-kullanıcılı loopback kurulumda açıktır; web/API portunu dışa açmadan önce
gerçek auth ve rate limit ekleyin. Credential üretimi ve rol modeli
[kimlik doğrulama belgesindedir](docs/AUTHENTICATION.md). Ardından:

```bash
docker info
docker compose version
docker compose config --quiet
docker compose up --build -d
docker compose ps
```

`repository-migrate` tek seferlik servisinin başarıyla tamamlanması beklenen
durumdur. Bu servis fresh ve mevcut named volume'lerde sürümlü SQL dosyalarının
checksum'ını doğrular; collector, JOIN snapshotter ve API ancak migration
başarısından sonra başlar. Elle upgrade/tekrar doğrulama için
`bash scripts/migrate-repository.sh` kullanılabilir. Ayrıntılı model
[docs/REPOSITORY_MIGRATIONS.md](docs/REPOSITORY_MIGRATIONS.md) içindedir.
Release yükseltmesini `docker compose up` ile doğrudan başlatmadan önce yedek,
writer-stop, explicit migrator ve cutover sırasını
[upgrade/rollback runbook'undan](docs/UPGRADE_ROLLBACK.md) uygulayın.
TLS-doğrulamalı image build'i, özel karakterli secret kullanımı ve mevcut
named volume parola/rol drift uzlaştırması
[portable deployment hardening belgesinde](docs/PORTABLE_DEPLOYMENT_HARDENING.md)
açıklanır.

Query/kcache/wait sayaç resetleri ile gerçek pencere kapsamının kabul testi:

```bash
bash scripts/verify-temporal-reliability.sh
```

`observedFrom`, `observedTo`, `coveragePercent`, `resetDetected`,
`comparisonReliable`, `warmingUp` ve eksik önceki dönem `null` semantiği
[temporal reliability belgesinde](docs/TEMPORAL_RELIABILITY.md) açıklanır.

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

`CLONE_SOURCE_ALIAS`, repository'deki kaynak alias'ıyla birebir aynı olmalıdır
(demo varsayılanı `test-source`). Evaluator hem request kimliğini hem clone
manifestindeki alias/database bağını doğrulamadan job database oluşturmaz.

İkinci script dashboard'ın fixture'sız tek-sorgu EXPLAIN ANALYZE yolunu gerçek source üzerinde çalıştırıp read-only/OID/rol/rollback sözleşmesini doğrular; ardından demo eşitlik sorgusu için audit metadatalı sentetik replay fixture'ı kaydeder, gerçek indexin yalnız disposable candidate clone'da kullanıldığını, kaynak DDL/index durumunun değişmediğini ve bütün job database'lerin temizlendiğini kanıtlar.

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

`iterations` değeri `1–1000` arasında olmalıdır. Script yalnız bu test oturumunda `pg_qualstats.sample_rate=1` kullanır; global varsayılan `0.1` kalır. Fresh demo collector frekansı üretim-temsili `60` saniyedir; script çalışan kaydın gerçek frekansını ve iki snapshot için yaklaşık bekleme süresini yazdırır. Çok kısa yerel kabul döngüsü gerekiyorsa yalnız yeni/boş volume kurulurken `DEMO_SOURCE_FREQUENCY=5` seçilebilir; ERP kapasite benchmark'ı varsayılan olarak en az `30` saniye ister.

Varsayılan kurulum **sürekli sentetik trafik üretmez**. Küçük fixture üzerinde
trafik gerektiğinde yukarıdaki komut tekrarlanabilir; sürekli ve hacimli karma
trafik ise aşağıdaki opt-in realistic profilinden önce mutlaka seed edilir.

### Gerçekçi toplu yük

Küçük acceptance fixture'ını büyütmeden, mevcut source volume'ünü hedef-count
bazlı büyüten ve wrapper üzerinden süreli karma trafik çalıştıran ayrı profil
vardır. Varsayılan `normal` koşu 100 bin müşteri, 1 milyon sipariş, 4 milyon
kalem ve 6 milyon event hedefler; ardından read/write, ağır JOIN, JSON filtre,
temp spill, CPU ve kontrollü row-lock trafiğini 24 worker ile 10 dakika birlikte
üretir:

```bash
bash scripts/run-realistic-workload.sh normal
```

Bu komut yalnız yerel/izole test source'u içindir: veriyi küçültmez, otomatik
rollback veya cleanup yapmaz ve makinenin CPU/disk I/O kapasitesini bilinçli
olarak doyurabilir. `stress` gerçek production kaynağında çalıştırılmamalıdır.
Wrapper süreyi sınırlar; `docker compose --profile realistic-load up workload`
komutu ise `WORKLOAD_DURATION_SECONDS=0` varsayılanıyla elle durdurulana kadar
çalışır.

Kısa makine kontrolü için `quick`, açık kapasite testi için `stress` seçilebilir.
Geniş katalog davranışı için `erp`, normal veri setine ek olarak 500 gerçek tablo,
tablo başına 2.000 satır ve sekiz salt-okunur sorgu ailesiyle 4.000 bounded
fingerprint hedefini deterministik olarak dolaşır:

```bash
bash scripts/run-realistic-workload.sh erp 600 32
```

Hazırlanmış aynı ERP manifesti üzerinde ölçümü yalnız steady-state trafiğe ayırmak
için `REALISTIC_SKIP_PREPARE=true` kullanılabilir; profil veya ERP hedefi
uyuşmazsa wrapper fail-closed kapanır.

Source ve repository maliyetini API trafiğiyle aynı sınırda ölçmek için kapasite
harness'ı kullanılır:

```bash
bash scripts/benchmark-erp-stack.sh run erp
```

Harness yük boyunca varsayılan `24h` penceresinde query-list → global overview →
listeden seçilmiş query-detail/trend batch'lerini round-robin çalıştırır. Varsayılan
concurrency list/detail için `2`, overview için `1`; p95 tavanları sırasıyla
`2s / 8s / 2s`'dir. Raporun legacy `api` root alanları query-list'i temsil etmeye
devam eder; endpoint kırılımı `api.byEndpoint`, toplam matris hatası
`api.matrixErrorCount`, gerçek rotation ve delay ise `api.probePlan` altındadır.
Additive `derivedMetrics`, source/repository container read-write-total byte/s
hızlarını ve pencerenin PoWA aggregate/purge sınırına denk gelip gelmediğini
`maintenanceInclusive` / `steadyStateEligible` olarak verir; eksik veya
uyumsuz sequence/config kanıtı steady-state iddiası üretmez.
Release kabulünde admin token'ı yalnız shell ortamında tutarak tam modu açın:

```bash
ERP_FULL_ACCEPTANCE=true ADVISOR_API_TOKEN="$ADVISOR_API_TOKEN" \
  bash scripts/benchmark-erp-stack.sh run erp 600 32
```

Tam mod ilk collector ilerlemesinden sonra web root + hashed asset + proxied
health'i okur; persisted ERP point-read için source EXPLAIN ile bütün CSV
stream'ini aynı anda tüketir. Token host benchmark process environment'ından
okunur; container argv/environment, rapor veya dosyaya yazılmadan `docker exec`
stdin'iyle aktarılır. Bu HTTP kontrolü browser render testi değildir.
Bu koşu 7d/30d veya dolu retention soak testi ve observer kapalı/açık A/B ölçümü
yerine geçmez. API p95 kapıları bounded warmup sonrası SWR yolunu ölçer; 4.000+
queryid referansında expired-cache ilk fill'i `22,12s` olduğundan katı cold-start
`<2s` isteyen deployment için temporal rollup optimizasyonu açık P1'dir.
Ayrıntılar [ERP benchmark runbook'undadır](docs/ERP_STACK_BENCHMARK.md).

PoWA snapshot, CPU/wait/JOIN/composite ve API kabul kontrolleri koşunun sonunda
otomatik çalışır. `real-validation` servisleri ve admin token hazırsa izole gerçek
index testini de aynı zincire eklemek için:

```bash
REALISTIC_VERIFY_RUNTIME=true bash scripts/run-realistic-workload.sh normal
```

Çıktılar `runtime/load-reports/` altında tutulur ve Git'e girmez. Profil hedefleri,
kaynak bütçesi, hard/soft kabul kuralları ve özel Compose proje kullanımı
[gerçekçi yük runbook'unda](docs/REALISTIC_LOAD_TEST.md) açıklanır.

## İterasyon 2.1-B — `pg_qualstats` altyapı durumu

Altyapı ve ilk ürün adımı tamamlandı: PostgreSQL 18 image'ı sabitlenmiş `pg_qualstats 2.1.4` içeriyor; kaynakta preload, güvenli başlangıç ayarları, extension/grant'lar ve PoWA datasource kaydı hazır. Collector predicate geçmişini repository'ye taşır. `GET /api/v1/queries/{queryId}/predicates` endpoint'i ve sorgu detayındaki **WHERE filtreleri ve index adayı gözlemleri** paneli; kolonları, örneklenen predicate çalışma sayısını, işlenen/elenen satırı, eleme oranını ve veri kapsamını açıklar.

Çıktı yalnız gözlemdir: Impact Score'a katılmaz, otomatik `CREATE INDEX` üretmez veya çalıştırmaz ve kullanıcıyı HypoPG/EXPLAIN doğrulamasına yönlendirir. Düşük örnekli kayıtlar `INSUFFICIENT_DATA` olarak işaretlenir.

Önemli veri sınırı şudur: kaynak `pg_qualstats()` hem `WHERE` hem kolon-kolon `JOIN` predicate'lerini yakalar. PoWA 5.2'nin standart remote datasource'u yalnız `WHERE`/filter predicate'lerini taşır; JOIN kapsamı artık reset ile aynı transaction'daki outbox ve düşük yetkili `join-snapshotter` üzerinden tamamlanır. Ayrıntılar [İterasyon 2.1-B](docs/ITERATION_2_1_B_PG_QUALSTATS.md) ve [2.5–2.7](docs/ITERATIONS_2_5_TO_2_7.md) runbook'larındadır.

## İterasyon 2.2 — HypoPG doğrulaması

HypoPG 1.4.3 kaynak PostgreSQL 18 image'ına sabitlendi ve ayrı, salt-okunur `evaluator` servisine bağlandı. Uygun tek kolonlu WHERE veya persisted iki kolonlu composite aday için aynı kaynak oturumunda önce normal, sonra sanal B-tree index ile plain `EXPLAIN` planı alınır. Sanal index seçilir ve planner-cost eşiği aşılırsa maliyet farkı, tahmini boyut, güven seviyesi ve kopyalanabilir `CREATE INDEX CONCURRENTLY` taslağı gösterilir.

Kapsam tek statement `SELECT`/`WITH`, en fazla iki kolonlu B-tree adayı ve yapılandırılmış `test-source/appdb` hedefidir. HypoPG tarafında `EXPLAIN ANALYZE` veya gerçek DDL yoktur ve `ddlExecuted=false` kalır. HypoPG adayının gerçek-index baseline/candidate karşılaştırması yalnız ayrı clone profilindedir; bağımsız sorgu ölçümü ise aşağıda açıklanan read-only kaynak yolunu kullanır. Collector'a dış kaynak eklemek o kaynağı otomatik evaluator kapsamına almaz. Temel güvenlik modeli [İterasyon 2.2](docs/ITERATION_2_2_HYPOPG.md), composite/clone uzantısı [2.5–2.7 belgesindedir](docs/ITERATIONS_2_5_TO_2_7.md).

## İterasyon 2.3 — `pg_stat_kcache` gerçek CPU telemetrisi

`pg_stat_kcache 2.3.2` PostgreSQL 18 image'ına sabitlendi ve PoWA 5.2 remote hattına bağlandı. Sorgu listesi ve detay ekranı execution user/system/total CPU süresini, CPU'nun DB süresindeki oranını ve OS filesystem read/write byte değerlerini gösterir. Extension kapalı, history yetersiz ve veri kullanılabilir durumları ayrı capability sonucu taşır; eksik veri sahte `0 CPU` olarak sunulmaz.

CPU bu iterasyonda gözlem modundadır: `scoreIncluded=false` kalır ve mevcut Impact Score ağırlıkları değişmez. Paralel worker CPU toplamı duvar saatini aşabileceği için oran `%100` üstünde olabilir. Kurulum, mevcut-volume migration'ı, sayaç semantiği, overhead komutu ve kabul ayrıntıları [İterasyon 2.3 runbook'undadır](docs/ITERATION_2_3_PG_STAT_KCACHE.md).

## İterasyon 2.4–2.7 — wait, JOIN, composite ve izole gerçek test

`pg_wait_sampling` release 1.1.11 sorgu bazındaki bekleme örneklerini I/O, lock, LWLock, client, IPC, timeout, activity, extension ve other sınıflarına ayırır. Değerler örnek sayısıdır; duvar saati veya CPU yüzdesi değildir ve `scoreIncluded=false` kalır. Sürüm, overhead ve mevcut-volume runbook'u [pg_wait_sampling belgesindedir](docs/PG_WAIT_SAMPLING.md).

PoWA'nın taşımadığı kolon-kolon JOIN kayıtları, `pg_qualstats` reset'iyle aynı source transaction'ında durable outbox'a alınır. Ayrı `join-snapshotter` yalnız source bounded header/chunk `fetch/ack` ve repository `ingest/finalize/status/purge` fonksiyonlarını çağırabilir. Repository finalize commit edilmeden source batch ack edilmez; tekrar teslim chunk receipt ile candidate/evidence anahtarlarında idempotenttir ve başarısız head batch sonraki batch'leri bloke etmez. Aynı batch/doğal anahtarla gelen birden çok ham `pg_qualstats` satırı finalde deterministik birleştirilir ve sayaçları toplanır; ham chunk konumları ile batch satır sayısı taşıma doğrulaması için korunur. Source-primary koruması için varsayılan `1.000.000` pending satır, `1 GiB` outbox storage veya `300 saniye` en eski batch eşiklerinden biri dolduğunda yeni capture/reset fail-closed durur; PoWA collector hatayı görünür kılar ve snapshotter son batch'i ack edince devre kendiliğinden kapanır.

JOIN eşitliği ile aynı tablodaki WHERE equality/range kanıtı en az iki snapshot ve asgari occurrence eşiklerini geçtiğinde iki kolonlu B-tree adayı oluşur. Equality/range kuralı kolon sırasını açıklar; mevcut index prefix'i ve planner faydası canlı kaynakta salt-okunur HypoPG evaluator tarafından doğrulanır. Bu kanıt da ana inceleme skoruna katılmaz.

Gerçek-index baseline/candidate çalışma testi varsayılan olarak kapalıdır. `real-validation` profili tmpfs üzerinde clone template'ten ayrı baseline/candidate veritabanları üretir, gerçek indexi yalnız candidate clone'da kurar ve dönüşümlü `EXPLAIN ANALYZE` medianlarını karşılaştırır. Çalıştırılabilir kapsam tek bir salt-okunur `SELECT`tir; `WITH` yalnız final komutu `SELECT` olan ve DML/DDL token'ı taşımayan tek statement kapsamında kabul edilir. Yapısal lexical/statement kapısı multi-statement, DDL/DML, `SELECT INTO`, DML CTE, row lock ve açık denylist'teki yan etkili routine adlarını ANALYZE'dan önce reddeder. Bu kapı bütün routine'leri volatility açısından sınıflandırmaz: aktif runner attestation'ı volatile/security-definer routine ve procedure'lere `EXECUTE` verilmediğini ayrıca kanıtlar. Ardından PostgreSQL plain `EXPLAIN` (`ANALYZE FALSE`) plan preflight'ı `ModifyTable`, `LockRows`, `Foreign Scan` veya `Custom Scan` düğümü bulunmadığını doğrulamadan gerçek çalışma başlamaz; her runner transaction'ı koşulsuz rollback edilir.

Sorgu detayındaki **Ana DB'de EXPLAIN ANALYZE** paneli, composite aday veya HypoPG şartı olmadan repository'deki herhangi bir persisted sorguyu gerçek kaynak verisi ve cache durumu üzerinde bir kez çalıştırır. Browser SQL gönderemez; backend exact sorguyu repository'den alır. Parametreli sorguda kullanıcı en fazla 128 JSON scalar bind değeri (`64 KiB`) girer; değerler yalnız bu istek boyunca bellekte taşınır ve repository'ye kaydedilmez. Çalışma ayrı `advisor_evaluator` rolüyle, plain-plan preflight sonrası explicit `READ ONLY` transaction içinde yapılır ve rollback edilir. PostgreSQL `EXPLAIN ANALYZE` sorguyu gerçekten yürüttüğü için kaynak yükü gerçektir; yalnız salt-okunur `SELECT` kabul edilir. Gerçek index karşılaştırmasının parametreli replay yolu ise exact query/candidate kimliğine bağlı, süreli ve audit metadatalı server-side sentetik/anonim fixture ile disposable clone kullanmaya devam eder.

Clone template manifesti ve dangerous-routine hardening kanıtı yalnız gerçek-index baseline/candidate karşılaştırmasında geçerlidir; bu yol kaynakta hâlâ hiçbir replay veya DDL çalıştırmaz. Doğrudan sorgu ölçümünde ise source DSN yalnız `evaluator` servisindedir; API parolayı almaz, database OID/rol/ACL/read-only/timeout durumu her istekte doğrulanır ve cevap `executionTarget=SOURCE_DATABASE`, `sourceDdlExecuted=false` ile gerçek execution rolünü taşır. Görsel plan ve kaynak çalışma sınırları [source EXPLAIN ANALYZE belgesinde](docs/SOURCE_EXPLAIN_ANALYZE.md), clone kurulumu [2.5–2.7 runbook'unda](docs/ITERATIONS_2_5_TO_2_7.md) açıklanır.

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
8. Sürekli workload için gerekli `quick`, `normal`, geniş katalog `erp` ve açık opt-in `stress` ayrımı artık gerçekçi yük runbook'u ve bounded generator ile uygulanmıştır; mutlak TPS hosttan bağımsız bir hard gate değildir.

**25 Temmuz 2026 kısa kalibrasyon kapanışı:** En yüksek doğruluk etkili maddeler kapatıldı. Ana dashboard/trend yalnız top-level statement toplamını kullanıyor; regresyon puanı ve “yavaşlayan sorgu” sayısı için her iki dönemde en az 20 çağrı ve en az `%20` artış gerekiyor, büyüklük katsayısı `%50`de tam değere ulaşıyor. Query/kcache sayaç resetinde reset sonrası ilk aktivite korunuyor; uzun collector gap'leri dönem sınırında yanlış toplam üretemiyor. API ve UI gerçek gözlem aralığını, coverage'ı, warm-up'ı ve önceki dönem güvenilirliğini açıkça gösteriyor; geçmiş yokken regresyon alanları `null` kalıyor. Observation-hour hacim modeli ve 85/70/40 priority sınırları korundu. Ortam profili ile uzun süreli production dağılım kalibrasyonu ayrı ürün işi olarak kalır; 2.3 CPU sinyali ölçüm görmeden skora eklenmedi.

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
| `workload` | Yalnız `realistic-load` profilinde; wrapper ile süreli veya açıkça `0` seçilirse sürekli karma yük | Yok |
| `web` | React + TypeScript arayüzü ve Nginx API proxy | Yok |

ERP ölçeğinde query-list satırları, overview kartları ve query detail'in temel
query-metrics satırı aynı window snapshot cache'ini paylaşır. Overview'un global
trendi ayrı bir window cache'inde aynı `60s` fresh / `300s` bounded-stale,
`4` entry LRU ve `100.000` satır sınırını kullanır. Her cache pencere başına
single-flight'tır; query-metrics ve global-trend refresh'leri aynı repository-wide
lock ile serialize edilir, dolayısıyla iki pahalı tarama aynı anda çalışmaz.
Scoped query-detail trendi ile collector-health her istekte repository'den canlı
okunur; endpoint bileşenleri farklı ölçüm sınırlarına sahip olabilir. Metrics
snapshot'ı için ayrıca `64 MiB` payload hard cap'i ve API için `1 GiB` container
zarfı vardır. Sınır aşımı eksik sonuç üretmek yerine fail-closed davranır. Ayar
ve çok-replica notları
[kurulum rehberindedir](docs/INSTALLATION.md#query-metrics-cache-kapasitesi).

```text
source-db:5432 ───────┐
external PG #1 ──────┼──okuma──> collector ──yazma──> repository-db:5433
external PG #N ──────┘                                      │
                                                            v
                                                   api:8000 ──> web:5173

api:8000 ──iç token──> evaluator:8010 ──salt-okunur EXPLAIN/ANALYZE──> configured source/appdb

source JOIN outbox ──fetch/ack──> join-snapshotter ──ingest──> repository-db
api ──admin + iç token──> clone-evaluator:8020 ──gerçek-index karşılaştırması──> disposable clone-db
```

Mimari sınırlar ve rol matrisi için [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) dosyasına bakın.

## Güvenlik sınırları

- Repository'deki kaynak kayıtlarında parola tutulmaz (`password = NULL`); collector Git dışında tutulan alias-bazlı `0600` pgpass secret'larını açılışta geçici `.pgpass` dosyasında birleştirir.
- `powa_collector`, PostgreSQL'ün hazır PoWA rollerini ve kaynakta `pg_read_all_stats` yetkisini kullanır.
- `advisor_api` yalnız repository DSN'i alır. Yapılandırma bilinen `source-db` hostunu reddeder; repository standart `5432` dahil herhangi bir geçerli port ve database adını kullanabilir. API health gate'i `advisor` repository şemasını pozitif olarak doğrulamadan container sağlıklı sayılmaz.
- Kaynak DSN'i yalnız ayrı `evaluator` servisindedir. Bu servis `advisor_evaluator` rolü, read-only transaction, ayrı planner/runtime timeout'ları, tek runtime slotu, connection limit, internal network ve token korumalı iç endpoint ile sınırlandırılır; ana API'ye kaynak parolası verilmez.
- HypoPG fonksiyonlarının PUBLIC yetkileri kaldırılmıştır. Evaluator yalnız sanal index oluşturur ve plain `EXPLAIN` çalıştırır; kopyalanabilir SQL'in kullanıcıya dönmesi gerçek DDL çalıştığı anlamına gelmez.
- Header gönderilmeyen API isteği `viewer` sayılır ve tam SQL maskelenir. Referans web istemcisi analiz ekranları için demonstrasyon amaçlı `analyst` header'ı gönderir; bu gerçek kullanıcı kimliği değildir.
- Annotation, CSV export ve gerçek-index karşılaştırmalı disposable-clone testi yalnız server-side
  SHA-256 registry'de eşleşen Bearer principal ile açılır. Actor istemci
  body/header'ından değil doğrulanmış `subject` değerinden gelir; API database
  rolünün annotation/audit tablolarına doğrudan write yetkisi yoktur.
- CSV export listeyle aynı filtrelerin tamamını uygular, 200 satır sayfa sınırına
  takılmaz ve server-side cursor ile sabit boyutlu partiler hâlinde akar.
- Gerçek-index karşılaştırmasının bind değerleri public API requestinden alınmaz. DBA yalnız sentetik/anonim scalar fixture'ı exact persisted aday ve normalize SQL hash'ine bağlar. Doğrudan dashboard EXPLAIN ANALYZE yolu ise SQL kabul etmeden, kullanıcının geçici JSON scalar bind dizisini token-korumalı source evaluator'a taşır ve saklamaz.
- Doğrudan runtime replay tek bir salt-okunur `SELECT` ile sınırlıdır. Yapısal kapı, yan-etkili rutin denylist'i, plain-`EXPLAIN` plan preflight'ı ve aktif source rol/read-only/ACL attestation'ından biri başarısızsa `EXPLAIN ANALYZE` başlamaz; başlayan transaction daima rollback edilir. `EXPLAIN ANALYZE` sorguyu gerçekten çalıştırdığı için düşük yetkili rol ve SQL kapısı dışındaki kaynak yükü bilinçli olarak korunur.
- Doğrudan dashboard çalıştırıcısı tek-kullanıcılı loopback kurulumda ek admin/Bearer kapısı olmadan açıktır. Referans UI tam SQL görünümü için demonstrasyon `analyst` header'ı gönderir. Web/API portunu başka makinelere açmadan önce bu endpoint'i gerçek kimlik doğrulama, rate limit ve kurum erişim politikası arkasına alın.
- Yerel/operator PAT modeli server-side kimlik sağlar fakat SSO değildir.
  İnternet erişimi verilen bir kurulumda TLS, rate limit ve OIDC/BFF veya
  kimlik doğrulayan reverse proxy eklenmeden üretim güvenliği sağlanmış sayılmaz.
- `.env` yalnız yerel geliştirme içindir; canlı ortamda secret manager ve parola rotasyonu kullanın.
- Docker port publish kuralları bazı firewall araçlarından önce uygulanabilir. Uzak web erişimini özellikle açtıysanız Linux sunucuda `DOCKER-USER` zinciri veya kurumun network policy katmanıyla yalnız web portuna izin verildiğini ayrıca doğrulayın.

## Testler

Her pull request ve `main` push'ında çalışan [hafif GitHub Actions CI](.github/workflows/ci.yml),
Compose yapılandırmasını, migration runner/manifest checksum sözleşmesini,
bütün shell scriptlerinin sözdizimini, JOIN snapshotter/workload/rol-rotasyonu
component testlerini, backend test image'ındaki tam pytest paketini ve Node.js
22 ile frontend test/build adımlarını doğrular. Bu hızlı
kapı PostgreSQL/PoWA image'ını derlemez ve tam stack'i başlatmaz. Aşağıdaki
gerçek PostgreSQL, telemetri, performans ve disposable clone kontrolleri ayrı
integration kabulü olarak çalıştırılmalıdır.

Haftalık ve manuel [PostgreSQL integration workflow'u](.github/workflows/postgres-integration.yml)
Ubuntu amd64 runner'da PostgreSQL/PoWA image'ını sıfırdan derler, temiz named
volume'leri başlatır, migration idempotency/temporal fixture'ı ve gerçek rol
drift onarımını doğrular. JOIN fixture'ı duplicate sayaç birleştirmesini,
overflow rollback'ini ve 25.001 satırlık üç parçalı taşımayı da gerçek
PostgreSQL üzerinde sınar; workflow sonunda yalnız kendi disposable CI
volume'lerini siler.

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

Bu ikinci script dashboard'ın gerçek-source fixture'sız tek-sorgu yolunu, source read-only/OID/rol/rollback sözleşmesini, operator fixture kaydını, gerçek-index yolunun admin-token sınırını, manifest ile canlı runner rol/ACL/routine politikasını, runner'ın DML/DDL/`SELECT INTO`/`nextval` negatif problarını, güvenli bind adaptasyonuyla gerçek index kullanımını, kaynak DDL değişmezliğini ve zorunlu clone cleanup'ını doğrular.

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

- PostgreSQL `18.x` (`postgres:18-trixie`; mevcut kabul ortamında `18.4`
  doğrulandı, fresh image rebuild'i daha yeni bir `18.x` patch'ine ilerleyebilir)
- PoWA Archivist `5.2.0` / `REL_5_2_0` — kaynak arşiv SHA-256 ile doğrulanır
- `pg_qualstats 2.1.4` — kaynak arşiv SHA-256 ile doğrulanır; sabit sürüme hedefli shared-memory düzeltmesi uygulanır
- `pg_stat_kcache 2.3.2` — PostgreSQL 18 uyumlu kaynak arşiv SHA-256 ile doğrulanır
- `pg_wait_sampling 1.1.11` / SQL extension `1.1` — kaynak arşiv SHA-256 ile doğrulanır
- HypoPG `1.4.3` — tam upstream commit ve kaynak arşiv SHA-256 ile doğrulanır
- PoWA Collector `1.3.2` — wheel SHA-256 ile sabitlenir
- Python `3.12`, Node `22`, Nginx `1.27`

Güncel tasarım dayanakları: [PoWA remote setup](https://powa.readthedocs.io/en/latest/remote_setup.html), [PoWA destekli stats extension'ları](https://powa.readthedocs.io/en/latest/components/stats_extensions/), [pg_qualstats](https://powa.readthedocs.io/en/latest/components/stats_extensions/pg_qualstats.html), [pg_stat_kcache](https://powa.readthedocs.io/en/latest/components/stats_extensions/pg_stat_kcache.html), [pg_wait_sampling](https://github.com/postgrespro/pg_wait_sampling), [HypoPG](https://github.com/HypoPG/hypopg), [PoWA güvenlik](https://powa.readthedocs.io/en/latest/security.html), [Docker Engine kurulumu](https://docs.docker.com/engine/install/).
