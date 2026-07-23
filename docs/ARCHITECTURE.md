# Mimari

## İlk iterasyon topolojisi

“İki sunucu” ifadesi bu repoda iki ayrı fiziksel makine değil, aynı Docker/OrbStack hostunda çalışan iki bağımsız PostgreSQL server/instance anlamına gelir. Port, veri dizini, kullanıcılar ve görevler ayrıdır.

```text
┌──────────────────────────── Docker / OrbStack hostu ────────────────────────────┐
│                                                                                 │
│  source-db (demo PG 17, :5432)               repository-db (PG 17, :5433)        │
│  ├─ appdb + örnek iş yükü                    ├─ powa_repository                  │
│  ├─ pg_stat_statements                       ├─ PoWA 5.2 geçmişi                 │
│  ├─ dedicated powa DB                        ├─ advisor view/not/audit katmanı   │
│  └─ powa_collector read role                 └─ 90 gün retention                 │
│             │                                           ▲                       │
│  external PG #1 ───────> collector 1.3.2 ───────────────┤                       │
│  external PG #N ───────> (kaynak basina worker) ────────┘                       │
│                                                         │                       │
│                                                         v                       │
│                                                  FastAPI :8000                  │
│                                                         │                       │
│                                                         v                       │
│                                                  Nginx + UI :5173               │
└─────────────────────────────────────────────────────────────────────────────────┘
```

Akış tek yönlüdür: kaynak istatistikleri collector tarafından okunur, repository'ye yazılır, API repository'den okur ve web API'yi görüntüler. API container'ında kaynak veritabanı bağlantı bilgisi yoktur.

## Neden iki PostgreSQL instance var?

- Sorgu geçmişinin depolama ve raporlama yükü uygulama veritabanından ayrılır.
- Repository arızası veya analitik sorgu yükü kaynak iş yüküne doğrudan bağlanmaz.
- PoWA sürüm yükseltme ve retention işlemleri uygulama şemasından bağımsız kalır.
- Aynı tasarım daha sonra fiziksel olarak ayrı bir repository hostuna taşınabilir.

Bu iterasyon topolojiyi tek hostta doğrular. Gerçek üretim dağıtımında kaynak PostgreSQL çoğunlukla zaten başka bir sunucudadır; mevcut Compose'taki `source-db` bu senaryonun güvenli, tekrarlanabilir simülasyonudur. `workload` sürekli çalışmaz ve yalnız `demo` profiliyle özellikle açılır.

## Bileşen sorumlulukları

### Kaynak instance

- Uygulama test veritabanı `appdb` ve örnek tabloları barındırır.
- `shared_preload_libraries=pg_stat_statements`, `compute_query_id=on`, `track_io_timing=on` kullanır.
- Demo görünürlüğü için `pg_stat_statements.track=all` ayarlanmıştır.
- Remote snapshot fonksiyonları dedicated `powa` veritabanındadır.
- Collector kullanıcısı `powa.ignored_users` ile sorgu sonuçlarından çıkarılır.

### Repository instance

- PoWA'nın remote snapshot geçmişini saklar.
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

### API ve web

- FastAPI, yalnız `repository-db:5433/powa_repository` bağlantısına sahiptir.
- Nginx `/api/*` trafiğini iç ağdaki API'ye proxy eder.
- Hostta API/DB portları varsayılan olarak `127.0.0.1` üzerinde, web `0.0.0.0:5173` üzerindedir.
- Frontend varsayılan build'de gerçek API kullanır; demo modu kapalıdır.

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
| `powa_collector` | Etkin `CONNECT`, `pg_read_all_stats`, PoWA snapshot/execute | PoWA read/write/snapshot | Snapshot taşıma |
| `advisor_api` | Bağlantı yok | PoWA read + advisor kontrollü write | API sorguları ve not/audit |
| API isteği `viewer` | Yok | API üzerinden maskeli SQL | Varsayılan görüntüleme |
| API isteği `analyst` | Yok | API üzerinden tam SQL | Analiz istemcisi |
| API isteği `admin` | Yok | Tam SQL + CSV export | API yönetim demonstrasyonu |

API rollerinin `X-Advisor-Role` header'ı ile seçildiğini unutmayın. Header göndermeyen API isteği `viewer` olur; tek kullanıcılı referans web istemcisi ayrı bir kullanıcı/rol arayüzü göstermeden analiz verisini almak için sabit `analyst` isteği gönderir. Bu, davranışı ve maskeleme politikasını doğrulamak içindir; gerçek kimlik doğrulama değildir.

## Bilinen ilk iterasyon sınırları

- Otomatik index veya SQL rewrite önerisi yoktur.
- PostgreSQL 17 + PoWA 5.2 ile geçmiş lock/blocker zinciri sunulmaz. PoWA'nın `pg_stat_lock` veri kaynağı PostgreSQL 19 gerektirir; UI bunu unavailable capability olarak açıklar.
- Demo snapshot frekansı 5 saniyedir. Canlıda ölçülen yük ve ihtiyaç doğrultusunda daha yüksek frekans seçilmelidir.
- Kaynakta PoWA extension binary'si ve `pg_stat_statements` preload gerekir; salt bağlantı parolası vanilla PostgreSQL'ü izlenebilir hale getirmez.
- Bütün dış kaynaklar bir collector deployment'ında ortak libpq `PGSSLMODE` kullanır. Kaynak başına farklı client certificate/SSL profili gerekirse ayrı collector deployment'ı gerekir.
- Header tabanlı rol modeli, TLS terminasyonu, SSO, rate limit ve merkezi secret store üretim öncesi tamamlanmalıdır.
