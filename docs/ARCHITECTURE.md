# Mimari

## Güncel topoloji

“İki sunucu” ifadesi bu repoda iki ayrı fiziksel makine değil, aynı Docker/OrbStack hostunda çalışan iki bağımsız PostgreSQL server/instance anlamına gelir. Port, veri dizini, kullanıcılar ve görevler ayrıdır.

```text
┌──────────────────────────── Docker / OrbStack hostu ────────────────────────────┐
│                                                                                 │
│  source-db (demo PG 18.4, :5432)             repository-db (PG 18.4, :5433)      │
│  ├─ appdb + örnek iş yükü                    ├─ powa_repository                  │
│  ├─ pg_stat_statements + pg_qualstats        ├─ PoWA 5.2 geçmişi                 │
│  ├─ HypoPG 1.4.3 + evaluator rolü            ├─ advisor view/not/audit katmanı   │
│  ├─ dedicated powa DB                        └─ 90 gün retention                 │
│  └─ powa_collector read role                                                     │
│             │                                           ▲                       │
│  external PG #1 ───────> collector 1.3.2 ───────────────┤                       │
│  external PG #N ───────> (kaynak basina worker) ────────┘                       │
│  appdb ──salt-okunur──> evaluator :8010 ──iç sonuç──────┐                       │
│                                                         v                       │
│                                                  FastAPI :8000                  │
│                                                         │                       │
│                                                         v                       │
│                                                  Nginx + UI :5173               │
└─────────────────────────────────────────────────────────────────────────────────┘
```

Ana telemetry akışı tek yönlüdür: kaynak istatistikleri collector tarafından okunur, repository'ye yazılır, API repository'den okur ve web API'yi görüntüler. API container'ında kaynak veritabanı bağlantı bilgisi yoktur. İsteğe bağlı HypoPG doğrulaması bu sınırı API içinde delmez; kaynak DSN'i yalnız ayrı ve düşük yetkili `evaluator` container'ındadır.

## Neden iki PostgreSQL instance var?

- Sorgu geçmişinin depolama ve raporlama yükü uygulama veritabanından ayrılır.
- Repository arızası veya analitik sorgu yükü kaynak iş yüküne doğrudan bağlanmaz.
- PoWA sürüm yükseltme ve retention işlemleri uygulama şemasından bağımsız kalır.
- Aynı tasarım daha sonra fiziksel olarak ayrı bir repository hostuna taşınabilir.

Mevcut dağıtım topolojiyi tek hostta doğrular. Gerçek üretim dağıtımında kaynak PostgreSQL çoğunlukla zaten başka bir sunucudadır; mevcut Compose'taki `source-db` bu senaryonun güvenli, tekrarlanabilir simülasyonudur. `workload` sürekli çalışmaz ve yalnız `demo` profiliyle özellikle açılır.

## Bileşen sorumlulukları

### Kaynak instance

- Uygulama test veritabanı `appdb` ve örnek tabloları barındırır.
- `shared_preload_libraries=pg_stat_statements,pg_qualstats`, `compute_query_id=on`, `track_io_timing=on` kullanır.
- HypoPG 1.4.3 yalnız `appdb` içinde `advisor_hypopg` şemasında etkinleştirilir; preload gerektirmez ve gerçek index oluşturmaz.
- Salt-okunur `advisor_evaluator` rolü yalnız gerekli tablo SELECT ve HypoPG fonksiyon EXECUTE yetkilerini taşır.
- Demo görünürlüğü için `pg_stat_statements.track=all` ayarlanmıştır.
- Remote snapshot fonksiyonları dedicated `powa` veritabanındadır.
- Collector kullanıcısı `powa.ignored_users` ile sorgu sonuçlarından çıkarılır.

### Repository instance

- PoWA'nın remote snapshot geçmişini saklar.
- `pg_qualstats` repository tabloları/fonksiyonları PoWA 5.2 şemasından gelir; repository database içinde ayrıca extension oluşturulmaz.
- Kaynak `source-db:5432` adıyla, 5 saniye frekans ve açıkça 90 gün retention ile kaydedilir.
- PoWA tablolarına kolon/trigger eklenmez; ürün nesneleri ayrı `advisor` şemasındadır.
- `advisor.query_metrics(interval)` 1h, 24h, 7d ve 30d pencerelerini besler.
- Kullanıcı annotation'ları ve değişiklik audit kayıtları burada tutulur.

### Collector

- Resmî `powa-collector` 1.3.2 paketidir.
- Compose DNS adları olan `source-db` ve `repository-db` kullanılır; container içindeki `localhost` başka container'ı göstermez.
- `.pgpass` kaynak satırında database alanı `*` olarak yazılır. PoWA'nın database-bazlı snapshot bağlantıları böylece kimlik doğrulayabilir.
- Gerçek kaynak credential'ları alias başına Git-dışı `runtime/collector/sources/*.pgpass` dosyalarında `0600` tutulur. Root entrypoint bunları salt-okunur mounttan geçici pgpass'a kopyalar ve collector sürecini `nobody` kullanıcısına düşürür.
- Repository'deki her `powa_servers.password` alanı `NULL` kalır.
- Collector, repository'deki her aktif server için ayrı worker açar. `scripts/register-source.sh` aynı alias'ı idempotent günceller, collector'ı restart eder ve ilk snapshot'ı doğrular.
- Predicate snapshot'ından sonra kaynak sayaçlarının tekrar yazılmaması için collector'a `pg_qualstats()` ve `pg_qualstats_reset()` üzerinde açık `EXECUTE` verilir.

### API ve web

- FastAPI, yalnız `repository-db:5433/powa_repository` bağlantısına sahiptir.
- Nginx `/api/*` trafiğini iç ağdaki API'ye proxy eder.
- Hostta API/DB portları varsayılan olarak `127.0.0.1` üzerinde, web `0.0.0.0:5173` üzerindedir.
- Frontend varsayılan build'de gerçek API kullanır; demo modu kapalıdır.
- API repository-only güvenlik sınırını korur. `GET /api/v1/queries/{query_id}/predicates` endpoint'i PoWA repository geçmişini okur; kaynak PostgreSQL'e doğrudan bağlanmaz.
- Sorgu detayındaki “WHERE filtreleri ve index adayı gözlemleri” paneli endpoint'in capability bilgisini ve predicate kanıtlarını gösterir. Predicate endpoint'i DDL üretmez veya çalıştırmaz.
- `POST /api/v1/queries/{query_id}/index-evaluations`, analyst yetkisi ve repository'deki seçili predicate kimliğiyle ayrı evaluator'a kontrollü istek gönderir. İstemciden SQL veya identifier kabul edilmez.

### HypoPG evaluator

- Ana API ile aynı image'dan, ayrı `uvicorn app.evaluator:app` süreci olarak çalışır ve host portu yayınlamaz.
- Bir `EVALUATOR_DATABASE_URL`, bir izinli server alias ve bir izinli database ile sınırlandırılmıştır; referans hedef `test-source/appdb`'dir.
- Kaynağa `advisor_evaluator` rolüyle bağlanır; read-only transaction, kısa statement/lock/transaction timeout ve connection limit uygular.
- Baseline ve sanal-index plain `EXPLAIN` planlarını aynı bağlantıda alır. Normalize parametre varsa PostgreSQL 18 `GENERIC_PLAN` kullanır; `EXPLAIN ANALYZE` çalıştırmaz.
- Yalnız uygun SELECT, tek kolonlu FILTER, B-tree operator ve mevcut eşdeğer index bulunmayan adayları değerlendirir. RLS etkin tabloyu ve repository/canlı katalog OID uyuşmazlığını reddeder.
- Sanal index planda kullanılır ve varsayılan `%10` planner-cost düşüşü aşılırsa `VALIDATED` döner. Yalnız bu durumda kopyalanabilir `CREATE INDEX CONCURRENTLY` taslağı bulunur; `ddlExecuted` daima `false` kalır.
- Container salt-okunur filesystem, düşürülmüş Linux capability'leri ve ayrı internal control/source network'leriyle sınırlandırılır. API–evaluator isteği ayrı token kullanır.
- Evaluator rolü PoWA toplamasında ignored-user'dır; repository sorgu adapter'ı aynı rolü ayrıca filtreleyerek advisor'ın kendi plan kontrollerinin dashboard telemetrisi olmasını engeller.

## `pg_qualstats` veri akışı

Kaynak extension raw predicate kaydını üretir. PoWA source fonksiyonu desteklediği kayıtları collector'a verir; collector repository'deki current history'ye yazar, coalesce/purge işlemlerini uygular ve başarıyla tamamlanan snapshot sonrasında kaynak sayaçlarını resetler.

```text
source pg_qualstats()
  -> PoWA powa_qualstats_src(0)
  -> collector
  -> repository powa_qualstats_* current/coalesced history
  -> source pg_qualstats_reset()
```

Burada iki farklı kapsam vardır:

- Raw `pg_qualstats()` kolon-sabit WHERE/filter ve kolon-kolon JOIN predicate'lerini yakalar.
- PoWA 5.2'nin standart `powa_qualstats_src` filtresi yalnız tek tarafında kolon bulunan kayıtları repository'ye taşır. Kolon-kolon JOIN predicate'leri bu standart history hattında yoktur.

Bu yüzden endpoint kapsamı açıkça `WHERE_FILTER_ONLY`, `joinsAvailable=false` ve `ddlGenerated=false` olarak raporlanır. Repository verisi JOIN yokluğu kanıtı olarak kullanılamaz. JOIN tarihçesi ürünleştirildiğinde ana API'ye kaynak credential vermek yerine düşük yetkili, audit edilen ayrı source snapshotter kullanılmalıdır.

Predicate sayaçlarının statement sayaçlarından ayrı semantiği vardır. API'deki `occurrences`, PoWA geçmişindeki `occurences` alanının toplamıdır ve örneklenen predicate çalışmasını ifade eder; `pg_stat_statements.calls` değildir. `rowsProcessed`, `execution_count` ile predicate değerlendirmesinde işlenen satırları; `rowsFiltered`, `nbfiltered` ile elenen satırları gösterir. `filterRatio`, `rowsFiltered / rowsProcessed` oranıdır. Düşük örnekli veri `INSUFFICIENT_DATA` olarak sınıflanır; güçlü sinyal bile yalnız inceleme adayıdır, kesin index faydası değildir.

## HypoPG doğrulama akışı

```text
UI seçili predicate kimliği
  -> repository-only API: predicate/sorgu/OID kanıtını yeniden yükler
  -> token korumalı evaluator
  -> configured source/appdb, aynı backend oturumu
       1. plain EXPLAIN baseline
       2. hypopg_create_index(single-column btree)
       3. plain EXPLAIN hypothetical
       4. plan kullanımı, cost ve tahmini boyut karşılaştırması
       5. hypopg_reset + bağlantıyı kapat
  -> VALIDATED ise kopyalanabilir SQL; hiçbir durumda DDL execution yok
```

Bu yol telemetry toplama hattından ayrıdır ve yalnız kullanıcı isteğinde çalışır. Collector parolası evaluator tarafından kullanılmaz. Mevcut Compose evaluator'ı internal source ağı üzerinden yalnız `test-source/appdb` hedefine erişir; collector'a kaydedilmiş diğer kaynaklar kendiliğinden doğrulama kapsamına girmez. Dış kaynak veya çoklu database için ayrı düşük yetkili rol, DSN, ağ allowlist'i ve evaluator routing gerekir. Ayrıntılı runbook [İterasyon 2.2 belgesindedir](ITERATION_2_2_HYPOPG.md).

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

Eşikler: `CRITICAL >= 85`, `HIGH >= 70`, `MEDIUM >= 40`, aksi `LOW`. Puan bir mutlak sağlık garantisi değildir; seçilen pencere ve ilgili veritabanı içindeki öncelik sırasıdır. `dbLoadPercent` de ilgili server+database'in ölçülen sorgu süresindeki paydır. Aynı `query_id` birden fazla PostgreSQL rolünce çalıştırılmışsa metrikler tek sorgu satırında birleştirilir; annotation anahtarı `server_id + database_id + query_id` ile çakışmaz.

Sorgu analiz listesi `SELECT`, `WITH`, `INSERT`, `UPDATE`, `DELETE` ve `MERGE` ifadelerine odaklanır; baştaki SQL yorumları desteklenir. Bootstrap `CREATE/ALTER/GRANT` DDL kayıtları puanlamaya alınmaz. Bu erken filtre, yeni hazırlanmış cluster'lardaki binlerce extension DDL kaydının rapor sorgularını yavaşlatmasını engeller.

## Rol ve veri erişim matrisi

| Kimlik | Kaynak DB | Repository | Amaç |
|---|---|---|---|
| `postgres` | Yönetici | Yönetici | Yalnız bootstrap/test |
| `powa_collector` | Etkin `CONNECT`, `pg_read_all_stats`, PoWA snapshot/execute, `pg_qualstats()`/`reset()` | PoWA read/write/snapshot | Snapshot taşıma |
| `advisor_evaluator` | Yalnız yapılandırılmış DB/schema/table SELECT ve üç HypoPG fonksiyonu; read-only, connection limit 2 | Yok | İsteğe bağlı plain-EXPLAIN plan doğrulaması |
| `advisor_api` | Bağlantı yok | PoWA read + advisor kontrollü write | API sorguları ve not/audit |
| API isteği `viewer` | Yok | API üzerinden maskeli SQL | Varsayılan görüntüleme |
| API isteği `analyst` | Yok | API üzerinden tam SQL | Analiz istemcisi |
| API isteği `admin` | Yok | Tam SQL + CSV export | API yönetim demonstrasyonu |

API rollerinin `X-Advisor-Role` header'ı ile seçildiğini unutmayın. Header göndermeyen API isteği `viewer` olur; tek kullanıcılı referans web istemcisi ayrı bir kullanıcı/rol arayüzü göstermeden analiz verisini almak için sabit `analyst` isteği gönderir. Bu, davranışı ve maskeleme politikasını doğrulamak içindir; gerçek kimlik doğrulama değildir.

## Bilinen sınırlar

- Predicate/index-adayı gözlem paneli ve dar kapsamlı HypoPG doğrulaması vardır. Yalnız `VALIDATED` sonuç kopyalanabilir `CREATE INDEX CONCURRENTLY` taslağı taşır; otomatik DDL, index silme veya SQL rewrite yoktur.
- HypoPG kapsamı SELECT/tek statement, tek kolonlu B-tree predicate ve yapılandırılmış tek alias/database ile sınırlıdır. JOIN/composite, DML, expression/partial/covering index ve çoklu evaluator routing desteklenmez.
- Planner cost düşüşü gerçek süre garantisi değildir; gösterilen SQL üretimde ayrıca DBA incelemesi gerektirir.
- PostgreSQL 18.4 + PoWA 5.2 ile geçmiş lock/blocker zinciri sunulmaz. PoWA'nın `pg_stat_lock` veri kaynağı PostgreSQL 19 gerektirir; UI bunu unavailable capability olarak açıklar.
- Demo snapshot frekansı 5 saniyedir. Canlıda ölçülen yük ve ihtiyaç doğrultusunda daha yüksek frekans seçilmelidir.
- Kaynakta PoWA, `pg_stat_statements` ve `pg_qualstats` binary'leri ile iki stats extension'ın preload edilmesi gerekir; salt bağlantı parolası vanilla PostgreSQL'ü izlenebilir hale getirmez.
- Raw JOIN predicate'leri kaynakta yakalanır ancak PoWA 5.2 standart remote qualstats datasource'u bunları repository geçmişine taşımaz.
- Bütün dış kaynaklar bir collector deployment'ında ortak libpq `PGSSLMODE` kullanır. Kaynak başına farklı client certificate/SSL profili gerekirse ayrı collector deployment'ı gerekir.
- Header tabanlı rol modeli, TLS terminasyonu, SSO, rate limit ve merkezi secret store üretim öncesi tamamlanmalıdır.
