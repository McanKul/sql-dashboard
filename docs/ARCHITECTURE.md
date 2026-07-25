# Mimari

## Güncel topoloji

“İki sunucu” ifadesi bu repoda iki ayrı fiziksel makine değil, aynı Docker/OrbStack hostunda çalışan iki bağımsız PostgreSQL server/instance anlamına gelir. Port, veri dizini, kullanıcılar ve görevler ayrıdır.

```text
┌──────────────────────────── Docker / OrbStack hostu ────────────────────────────┐
│                                                                                 │
│  source-db (demo PG 18.4, :5432)             repository-db (PG 18.4, :5433)      │
│  ├─ appdb + örnek iş yükü                    ├─ powa_repository                  │
│  ├─ statement + qualstats + kcache + waits   ├─ PoWA 5.2 geçmişi                 │
│  ├─ HypoPG 1.4.3 + evaluator rolü            ├─ advisor view/not/audit katmanı   │
│  ├─ dedicated powa DB + JOIN outbox          └─ 90 gün retention                 │
│  └─ powa_collector read role                                                     │
│             │                                           ▲                       │
│  external PG #1 ───────> collector 1.3.2 ───────────────┤                       │
│  external PG #N ───────> (kaynak basina worker) ────────┘                       │
│  JOIN outbox ──fetch/ack──> join-snapshotter ──ingest────┘                       │
│  appdb ──salt-okunur──> evaluator :8010 ──iç sonuç──────┐                       │
│                                                         v                       │
│                                                  FastAPI :8000                  │
│                                                         │                       │
│                                                         v                       │
│                                                  Nginx + UI :5173               │
│                                                                                 │
│  [real-validation] API -> clone-evaluator -> tmpfs disposable clone-db          │
└─────────────────────────────────────────────────────────────────────────────────┘
```

Ana telemetry akışı tek yönlüdür: kaynak istatistikleri collector tarafından okunur, repository'ye yazılır, API repository'den okur ve web API'yi görüntüler. API container'ında kaynak veritabanı bağlantı bilgisi yoktur. İsteğe bağlı HypoPG doğrulaması bu sınırı API içinde delmez; kaynak DSN'i yalnız ayrı ve düşük yetkili `evaluator` container'ındadır.

## Neden iki PostgreSQL instance var?

- Sorgu geçmişinin depolama ve raporlama yükü uygulama veritabanından ayrılır.
- Repository arızası veya analitik sorgu yükü kaynak iş yüküne doğrudan bağlanmaz.
- PoWA sürüm yükseltme ve retention işlemleri uygulama şemasından bağımsız kalır.
- Aynı tasarım daha sonra fiziksel olarak ayrı bir repository hostuna taşınabilir.

Mevcut dağıtım topolojiyi tek hostta doğrular. Gerçek üretim dağıtımında kaynak PostgreSQL çoğunlukla zaten başka bir sunucudadır; mevcut Compose'taki `source-db` bu senaryonun güvenli, tekrarlanabilir simülasyonudur. `workload` normal başlangıçta çalışmaz; milyonlarca satırlı karma trafik için yalnız `realistic-load` profiliyle ve seed sonrasında özellikle açılır. Küçük fixture trafiğini `run-test-workload.sh` üretir. Resmî run wrapper'ı süreyi sınırlar; servisi doğrudan profille açarken `WORKLOAD_DURATION_SECONDS=0` elle durdurulana kadar çalışır. Hacimli ve monotonik seed baz init'ten ayrıdır, otomatik cleanup yapmaz ve gerçek production source üzerinde kullanılmamalıdır; böylece fresh acceptance ve 1 GiB tmpfs clone template'i küçük ve deterministik kalır.

## Bileşen sorumlulukları

### Kaynak instance

- Uygulama test veritabanı `appdb` ve örnek tabloları barındırır.
- `shared_preload_libraries=pg_stat_statements,pg_qualstats,pg_stat_kcache,pg_wait_sampling`, `compute_query_id=on`, `track_io_timing=on` kullanır.
- `pg_stat_kcache.track=top`, `track_planning=off` ile yalnız execution CPU ve OS filesystem sayaçlarını toplar.
- `pg_wait_sampling` yalnız query profile örneklerini toplar; `sample_cpu=off` olduğu için CPU kaynağı `pg_stat_kcache` olarak kalır.
- HypoPG 1.4.3 yalnız `appdb` içinde `advisor_hypopg` şemasında etkinleştirilir; preload gerektirmez ve gerçek index oluşturmaz.
- Salt-okunur `advisor_evaluator` rolü yalnız gerekli tablo SELECT ve HypoPG fonksiyon EXECUTE yetkilerini taşır.
- Demo görünürlüğü için `pg_stat_statements.track=all` ayarlanmıştır.
- Remote snapshot fonksiyonları dedicated `powa` veritabanındadır.
- JOIN içeren sorguların JOIN ve ilgili WHERE satırları reset sınırında private, yedi günle sınırlı outbox'a yazılır.
- Collector kullanıcısı `powa.ignored_users` ile sorgu sonuçlarından çıkarılır.

### Repository instance

- PoWA'nın remote snapshot geçmişini saklar.
- `pg_qualstats` repository tabloları/fonksiyonları PoWA 5.2 şemasından gelir; repository database içinde ayrıca extension oluşturulmaz.
- Kaynak `source-db:5432` adıyla, 5 saniye frekans ve açıkça 90 gün retention ile kaydedilir.
- PoWA tablolarına kolon/trigger eklenmez; ürün nesneleri ayrı `advisor` şemasındadır. Tek istisna, pinned PoWA 5.2.0 paketindeki hatalı iki-parametreli `powa_qualstats_purge` kilit çağrısını doğru tek-parametreli imzaya çeviren, sürüm ve fonksiyon gövdesiyle korunan uyumluluk migrasyonudur.
- `advisor.query_metrics(interval)` 1h, 24h, 7d ve 30d pencerelerini besler.
- `advisor.kcache_deltas(timestamptz)` PoWA CPU sayaçlarını reset-safe farklara çevirir; capability olmayan kaynaklarda sorgu ekranları çalışmaya devam eder.
- `advisor.wait_deltas(timestamptz)` sampled wait sayaçlarını reset-safe farklara ve wait sınıflarına çevirir.
- Private `advisor_ingest` şeması JOIN batch'lerini saklar; public adapter'lar JOIN kanıtı ve iki kolonlu adayları API'ye açar.
- Kullanıcı annotation'ları ve değişiklik audit kayıtları burada tutulur.

### Collector

- Resmî `powa-collector` 1.3.2 paketidir.
- Compose DNS adları olan `source-db` ve `repository-db` kullanılır; container içindeki `localhost` başka container'ı göstermez.
- `.pgpass` kaynak satırında database alanı `*` olarak yazılır. PoWA'nın database-bazlı snapshot bağlantıları böylece kimlik doğrulayabilir.
- Gerçek kaynak credential'ları alias başına Git-dışı `runtime/collector/sources/*.pgpass` dosyalarında `0600` tutulur. Root entrypoint bunları salt-okunur mounttan geçici pgpass'a kopyalar ve collector sürecini `nobody` kullanıcısına düşürür.
- Repository'deki her `powa_servers.password` alanı `NULL` kalır.
- Collector, repository'deki her aktif server için ayrı worker açar. `scripts/register-source.sh` aynı alias'ı idempotent günceller, collector'ı restart eder ve ilk snapshot'ı doğrular.
- Collector doğrudan reset çağırmaz; `advisor_join.capture_and_reset()` JOIN outbox yazımıyla reset'i aynı source transaction'ında yapar.

### JOIN snapshotter

- Source ve repository için birbirinden ayrı login/secret kullanır; API veya collector credential'ı almaz.
- Source tarafında yalnız `fetch_batches()`/`ack_batch()`, repository tarafında yalnız kontrollü ingest/status/purge fonksiyonlarını çağırır.
- Repository commitinden önce source batch'i silmez. Tekrar teslim `(server_id, batch_id)` anahtarıyla idempotenttir.
- Salt-okunur container filesystem'i, düşürülmüş capability'ler ve yalnız source/repository ile paylaşılan iki internal ağla çalışır; ana `advisor` ağına katılmaz, DSN veya payload loglamaz.

### API ve web

- FastAPI, yalnız `repository-db:5433/powa_repository` bağlantısına sahiptir.
- Nginx `/api/*` trafiğini iç ağdaki API'ye proxy eder.
- Hostta API, DB ve web portları varsayılan olarak yalnız `127.0.0.1` üzerindedir. Web'in `0.0.0.0:5173` yayını bilinçli opt-in'dir ve kimlik doğrulayan/TLS sonlandıran reverse proxy sınırı gerektirir.
- Frontend varsayılan build'de gerçek API kullanır; demo modu kapalıdır.
- API repository-only güvenlik sınırını korur. `GET /api/v1/queries/{query_id}/predicates` endpoint'i PoWA repository geçmişini okur; kaynak PostgreSQL'e doğrudan bağlanmaz.
- Sorgu nesnesindeki `cpu` alanı PoWA repository geçmişinden user/system/total CPU ve filesystem I/O sunar; `scoreIncluded=false` ile gözlem modundadır.
- Sorgu detayı WHERE, JOIN ve persisted composite aday kanıtlarını gösterir. Endpoint güvenli SQL taslağı üretebilir ama DDL çalıştırmaz.
- `POST /api/v1/queries/{query_id}/index-evaluations`, analyst yetkisi ve repository'deki seçili predicate kimliğiyle ayrı evaluator'a kontrollü istek gönderir. İstemciden SQL veya identifier kabul edilmez.

### HypoPG evaluator

- Ana API ile aynı image'dan, ayrı `uvicorn app.evaluator:app` süreci olarak çalışır ve host portu yayınlamaz.
- Bir `EVALUATOR_DATABASE_URL`, bir izinli server alias ve bir izinli database ile sınırlandırılmıştır; referans hedef `test-source/appdb`'dir.
- Kaynağa `advisor_evaluator` rolüyle bağlanır; read-only transaction, kısa statement/lock/transaction timeout ve connection limit uygular.
- Baseline ve sanal-index plain `EXPLAIN` planlarını aynı bağlantıda alır. Normalize parametre varsa PostgreSQL 18 `GENERIC_PLAN` kullanır; `EXPLAIN ANALYZE` çalıştırmaz.
- Yalnız uygun SELECT, en fazla iki kolonlu B-tree adayı ve mevcut eşdeğer index prefix'i bulunmayan adayları değerlendirir. RLS etkin tabloyu ve repository/canlı katalog OID uyuşmazlığını reddeder.
- Sanal index planda kullanılır ve varsayılan `%10` planner-cost düşüşü aşılırsa `VALIDATED` döner. Yalnız bu durumda kopyalanabilir `CREATE INDEX CONCURRENTLY` taslağı bulunur; `ddlExecuted` daima `false` kalır.
- Container salt-okunur filesystem, düşürülmüş Linux capability'leri ve ayrı internal control/source network'leriyle sınırlandırılır. API–evaluator isteği ayrı token kullanır.
- Evaluator rolü PoWA toplamasında ignored-user'dır; repository sorgu adapter'ı aynı rolü ayrıca filtreleyerek advisor'ın kendi plan kontrollerinin dashboard telemetrisi olmasını engeller.

### Disposable clone evaluator

- Varsayılan stack'te çalışmaz; yalnız `real-validation` profili açıldığında tmpfs `clone-db` ve ayrı evaluator başlar.
- Ana API yalnız token korumalı control ağına bağlıdır ve clone DB credential'ı almaz. Clone evaluator source/repository ağı veya DSN'i almaz.
- Her iş için aynı template'ten ayrı baseline/candidate database üretir; gerçek index yalnız candidate clone'da kurulur ve iş sonunda iki database zorunlu olarak silinir.
- DDL öncesinde cluster marker'ı, tam admin rolü, `datistemplate` ve template manifesti; ölçüm öncesinde tam runner rolü tekrar doğrulanır.
- Runner `pg_read_all_data` taşısa da yalnız izole clone ağına erişir ve `READ ONLY` transaction, statement/lock/transaction timeout ile sınırlandırılır.
- Clone evaluator bütün Linux capability'lerini düşürür. PostgreSQL container'ı ise fresh tmpfs dizinlerini hazırlayıp `postgres` uid/gid'sine geçebilmek için yalnız `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETGID` ve `SETUID` capability'lerini geri alır.

## `pg_qualstats` veri akışı

Kaynak extension raw predicate kaydını üretir. PoWA source fonksiyonu desteklediği kayıtları collector'a verir; collector repository'deki current history'ye yazar, coalesce/purge işlemlerini uygular ve başarıyla tamamlanan snapshot sonrasında kaynak sayaçlarını resetler.

```text
source pg_qualstats()
  -> PoWA powa_qualstats_src(0)
  -> collector
  -> repository powa_qualstats_* current/coalesced history
  -> source advisor_join.capture_and_reset()
       -> JOIN + ilgili WHERE satırları durable outbox
       -> pg_qualstats_reset() aynı transaction
```

Burada iki farklı kapsam vardır:

- Raw `pg_qualstats()` kolon-sabit WHERE/filter ve kolon-kolon JOIN predicate'lerini yakalar.
- PoWA 5.2'nin standart `powa_qualstats_src` filtresi yalnız tek tarafında kolon bulunan kayıtları repository'ye taşır. Kolon-kolon JOIN predicate'leri bu standart history hattında yoktur.

Stock PoWA history tek başına JOIN yokluğu kanıtı değildir. Ayrı outbox hattı sağlıklıysa endpoint `WHERE_AND_JOIN_SNAPSHOT` ve `joinsAvailable=true` döner; snapshotter kapalıysa dürüstçe `WHERE_FILTER_ONLY` fallback'i korunur. Ana API hiçbir durumda source credential almaz.

Predicate sayaçlarının statement sayaçlarından ayrı semantiği vardır. API'deki `occurrences`, PoWA geçmişindeki `occurences` alanının toplamıdır ve örneklenen predicate çalışmasını ifade eder; `pg_stat_statements.calls` değildir. `rowsProcessed`, `execution_count` ile predicate değerlendirmesinde işlenen satırları; `rowsFiltered`, `nbfiltered` ile elenen satırları gösterir. `filterRatio`, `rowsFiltered / rowsProcessed` oranıdır. Düşük örnekli veri `INSUFFICIENT_DATA` olarak sınıflanır; güçlü sinyal bile yalnız inceleme adayıdır, kesin index faydası değildir.

## HypoPG doğrulama akışı

```text
UI seçili predicate kimliği
  -> repository-only API: predicate/sorgu/OID kanıtını yeniden yükler
  -> token korumalı evaluator
  -> configured source/appdb, aynı backend oturumu
       1. plain EXPLAIN baseline
       2. hypopg_create_index(tek WHERE veya iki kolonlu composite btree)
       3. plain EXPLAIN hypothetical
       4. plan kullanımı, cost ve tahmini boyut karşılaştırması
       5. hypopg_reset + bağlantıyı kapat
  -> VALIDATED ise kopyalanabilir SQL; hiçbir durumda DDL execution yok
```

Bu yol telemetry toplama hattından ayrıdır ve yalnız kullanıcı isteğinde çalışır. Collector parolası evaluator tarafından kullanılmaz. Mevcut Compose evaluator'ı internal source ağı üzerinden yalnız `test-source/appdb` hedefine erişir; collector'a kaydedilmiş diğer kaynaklar kendiliğinden doğrulama kapsamına girmez. Dış kaynak veya çoklu database için ayrı düşük yetkili rol, DSN, ağ allowlist'i ve evaluator routing gerekir. Ayrıntılı runbook [İterasyon 2.2 belgesindedir](ITERATION_2_2_HYPOPG.md).

## `pg_stat_kcache` veri akışı

`pg_stat_kcache()` kümülatif execution CPU ve filesystem sayaçlarını üretir.
PoWA collector bunları `powa_kcache_metrics` history tablolarına taşır;
`advisor.kcache_deltas` ardışık örnekleri reset-safe farklara çevirir ve yalnız
top-level statement'ları `query_metrics` ile birleştirir. CPU saniyeleri API'de
milisaniyeye çevrilir. Paralel worker toplamı duvar saatini aşabildiği için CPU
oranı clamp edilmez. Ayrıntı [İterasyon 2.3 runbook'undadır](ITERATION_2_3_PG_STAT_KCACHE.md).

## `pg_wait_sampling` veri akışı

PoWA collector sorgu/event bazındaki kümülatif profile örneklerini repository'ye
taşır. `advisor.wait_deltas` resetleri eksi delta üretmeden ele alır ve eventleri
I/O, lock, LWLock, client, IPC, timeout, activity, extension ve other sınıflarına
ayırır. Bunlar süre değil örnek sayısıdır; Impact Score'a katılmaz. Ayrıntı
[İterasyon 2.4 runbook'undadır](PG_WAIT_SAMPLING.md).

## Analiz modeli

Impact Score, aynı rapor penceresinde **kaynak sunucu + veritabanı** içindeki sorguları göreli olarak sıralar:

| Bileşen | Ağırlık |
|---|---:|
| Toplam çalışma süresi | %40 |
| Fiziksel blok okuma | %20 |
| Çağrı sıklığı | %15 |
| Temp block yazımı | %10 |
| Önceki eş döneme regresyon | %10 |
| WAL üretimi | %5 |

Eşikler: `CRITICAL >= 85`, `HIGH >= 70`, `MEDIUM >= 40`, aksi `LOW`. Regresyon bileşeni ve “yavaşlayan sorgu” sayısı için her iki eş pencerede en az 20 çağrı ve en az `%20` ortalama süre artışı gerekir; büyüklük katsayısı `%50` artışta tamdır. Puan bir mutlak sağlık garantisi değildir; seçilen pencere ve ilgili veritabanı içindeki öncelik sırasıdır. `pg_stat_kcache` CPU sinyali bu iterasyonda puana katılmaz. `dbLoadPercent` de ilgili server+database'in ölçülen top-level sorgu süresindeki paydır. Aynı `query_id` birden fazla PostgreSQL rolünce çalıştırılmışsa metrikler tek sorgu satırında birleştirilir; annotation anahtarı `server_id + database_id + query_id` ile çakışmaz.

Sorgu analiz listesi `SELECT`, `WITH`, `INSERT`, `UPDATE`, `DELETE` ve `MERGE` ifadelerine odaklanır; baştaki SQL yorumları desteklenir. Bootstrap `CREATE/ALTER/GRANT` DDL kayıtları puanlamaya alınmaz. Bu erken filtre, yeni hazırlanmış cluster'lardaki binlerce extension DDL kaydının rapor sorgularını yavaşlatmasını engeller.

## Rol ve veri erişim matrisi

| Kimlik | Kaynak DB | Repository | Amaç |
|---|---|---|---|
| `postgres` | Yönetici | Yönetici | Yalnız bootstrap/test |
| `powa_collector` | Etkin `CONNECT`, `pg_read_all_stats`, PoWA snapshot/execute ve yalnız atomik `capture_and_reset()` wrapper'ı | PoWA read/write/snapshot | Snapshot taşıma |
| `advisor_evaluator` | Yalnız yapılandırılmış DB/schema/table SELECT ve üç HypoPG fonksiyonu; read-only, connection limit 2 | Yok | İsteğe bağlı plain-EXPLAIN plan doğrulaması |
| `advisor_join_reader` | Yalnız JOIN outbox `fetch/ack` fonksiyonları | Yok | Source batch okuma ve teslim sonrası ack |
| `advisor_join_ingest` | Yok | Tek server kimliğine bağlı private ingest/status/source-purge wrapper'ları; tablo ve global purge erişimi yok | JOIN batch yazımı |
| `advisor_workload_login` | Yalnız opt-in realistic test rollerine `SET ROLE` ve stats okuma; admin yetkisi yok | Yok | İzole source üzerinde karma yük oturumlarını açma |
| `advisor_api` | Bağlantı yok | PoWA read + advisor kontrollü write | API sorguları ve not/audit |
| `clone_admin` / `clone_runner` | Yalnız tmpfs clone cluster'ı; kaynak ağa yol yok | Yok | Clone oluşturma/index ve read-only gerçek plan ölçümü |
| API isteği `viewer` | Yok | API üzerinden maskeli SQL | Varsayılan görüntüleme |
| API isteği `analyst` | Yok | API üzerinden tam SQL | Analiz istemcisi |
| API isteği `admin` + server-side token | Yok | Tam SQL + CSV export + clone runtime başlatma | Güvenilir yerel/operator istemcisi |

Header göndermeyen API isteği `viewer` olur; tek kullanıcılı referans web
istemcisi ayrı bir kullanıcı/rol arayüzü göstermeden analiz verisini almak için
sabit `analyst` isteği gönderir. Bu, davranışı ve maskeleme politikasını
doğrulamak içindir; gerçek kimlik doğrulama değildir. `admin` rolü ise yalnız
`X-Advisor-Role: admin` ile seçilemez: `X-Advisor-Admin-Token` değerinin
sunucudaki `RUNTIME_ADMIN_TOKEN` ile eşleşmesi gerekir. Secret browser'a
gönderilmez.

## Bilinen sınırlar

- Predicate/index-adayı gözlem paneli ve dar kapsamlı HypoPG doğrulaması vardır. Yalnız `VALIDATED` sonuç kopyalanabilir `CREATE INDEX CONCURRENTLY` taslağı taşır; otomatik DDL, index silme veya SQL rewrite yoktur.
- HypoPG kapsamı SELECT/tek statement, en fazla iki kolonlu B-tree adayı ve yapılandırılmış tek alias/database ile sınırlıdır. DML, expression/partial/covering index ve çoklu evaluator routing desteklenmez.
- Planner cost düşüşü gerçek süre garantisi değildir; gösterilen SQL üretimde ayrıca DBA incelemesi gerektirir.
- Clone runtime sonucu yalnız template verisinin istatistikleri, operator onaylı sentetik/anonim bind fixture'ı ve seçilen cache profili için geçerlidir. Fixture exact persisted aday + query kimliği + normalize SQL hash'ine bağlı, private ve süreli olabilir; eşleşme yoksa `EXPLAIN ANALYZE` başlamadan fail-closed durur.
- PostgreSQL 18.4 + PoWA 5.2 ile geçmiş lock/blocker zinciri sunulmaz. PoWA'nın `pg_stat_lock` veri kaynağı PostgreSQL 19 gerektirir; UI bunu unavailable capability olarak açıklar.
- Demo snapshot frekansı 5 saniyedir. Canlıda ölçülen yük ve ihtiyaç doğrultusunda daha yüksek frekans seçilmelidir.
- Kaynakta PoWA ile `pg_stat_statements`, `pg_qualstats`, `pg_stat_kcache` ve `pg_wait_sampling` binary/preload hazırlığı gerekir; salt bağlantı parolası vanilla PostgreSQL'ü izlenebilir hale getirmez.
- Raw JOIN predicate'leri kaynakta yakalanır ancak PoWA 5.2 standart remote qualstats datasource'u bunları repository geçmişine taşımaz.
- Bütün dış kaynaklar bir collector deployment'ında ortak libpq `PGSSLMODE` kullanır. Kaynak başına farklı client certificate/SSL profili gerekirse ayrı collector deployment'ı gerekir.
- Analyst header modeli, TLS terminasyonu, SSO, rate limit ve merkezi secret store üretim öncesi tamamlanmalıdır.
- Server-side admin token tarayıcının kendi kendine yetki vermesini engeller ama kullanıcı kimliği/SSO değildir. `real-validation` profili güvenilir kullanıcı sınırı, rate limit ve kimlik doğrulayan proxy olmadan internet erişimine açılmamalıdır.
- Realistic workload kabulündeki API gecikmesi yük bittikten sonraki repository/UI toparlanmasını ölçer; yük altındaki kullanıcı deneyimi için ayrı eşzamanlı performans testi gerekir. `REALISTIC_VERIFY_RUNTIME=true` ise büyük source'u kopyalamaz, küçük deterministik tmpfs fixture üzerinde izolasyon ve gerçek-index mekanizmasını kanıtlar.
