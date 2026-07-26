# İterasyon 2.1-B — `pg_qualstats` uygulama notu

## Durum

Altyapı ve ilk ürün adımı tamamlandı. PostgreSQL 18.x kaynağı predicate verisini üretir, PoWA 5.2 hattı desteklediği WHERE/filter kayıtlarını repository'de saklar ve sorgu detayı bunları açıklanabilir index-adayı gözlemleri olarak gösterir. Bu özellik otomatik index DDL'i üretmez veya çalıştırmaz. Bu iterasyonun kabul ortamında PostgreSQL 18.4 kullanılmıştır; floating `postgres:18-trixie` base image sonraki build'lerde daha yeni bir 18.x patch'i alabilir.

Tamamlananlar:

- PostgreSQL 18.x image'ına `pg_qualstats 2.1.4` sabit sürüm ve SHA-256 doğrulamasıyla eklenir.
- Kaynak `shared_preload_libraries=pg_stat_statements,pg_qualstats` ile başlar.
- Dedicated `powa` database içinde extension oluşturulur ve local PoWA datasource etkinleştirilir.
- Yeni demo remote server kaydı `extensions => ARRAY['pg_qualstats']` ile açılır. Etkin durum PoWA 5.2'de `PoWA.powa_extension_config` tablosunda tutulur.
- Mevcut volume'ler `scripts/enable-pg-qualstats.sh` ile silinmeden yükseltilebilir.
- Collector'a `pg_qualstats()` ve `pg_qualstats_reset()` için açık `EXECUTE` yetkisi verilir.
- Kabul testi kaynakta raw JOIN/WHERE yakalamayı, repository'de filter geçmişini ve gerçek kolon eşlemesini ayrı ayrı doğrular.
- Repository adapter'ı `advisor.predicate_metrics(...)` ve capability fonksiyonlarını kullanır; API `GET /api/v1/queries/{query_id}/predicates` endpoint'ini sunar.
- Sorgu detayındaki predicate paneli kolon, operator, eleme oranı, örnek kapsamı ve sinyal sınıfını gösterir; düşük veri `INSUFFICIENT_DATA` olarak ayrılır.

## Sabitlenen ayarlar

Demo varsayılanları:

```conf
shared_preload_libraries = 'pg_stat_statements,pg_qualstats'
pg_qualstats.track_constants = off
pg_qualstats.track_pg_catalog = off
pg_qualstats.resolve_oids = off
pg_qualstats.max = 10000
pg_qualstats.sample_rate = 0.1
```

`pg_qualstats.max`, demo `pg_stat_statements.max` kapasitesiyle aynı tutulur. Constants ve catalog takibi başlangıçta kapalıdır; predicate kolonunu görmek için literal değerleri saklamak gerekmez. `run-test-workload.sh` deterministik kabul için yalnız kendi oturumunda `sample_rate=1` yapar. Global değeri canlı sistemde ölçmeden `1` yapmak önerilmez.

Kaynak container için varsayılan shared memory sınırı `SOURCE_DB_SHM_SIZE=256mb` değeridir. `PG_QUALSTATS_MAX` büyütülürse extension shared-memory ihtiyacı ve container `/dev/shm` kapasitesi birlikte ölçülmelidir.

## Kurulum ve mevcut volume geçişi

Temiz kurulumda bootstrap otomatik çalışır:

```bash
docker compose up --build -d
bash scripts/verify.sh
```

Bu özellikten önce oluşturulmuş named volume'lerde init dosyaları tekrar çalışmaz. Image/container'lar yenilendikten sonra veri silmeden bir kez:

```bash
docker compose up --build -d source-db repository-db
bash scripts/enable-pg-qualstats.sh
docker compose up -d
bash scripts/verify.sh
```

Geçiş scripti extension/grant ve repository datasource aktivasyonunu idempotent uygular, collector'ı yeniden oluşturur ve force snapshot ister. `docker compose down -v` gerekmez.

Bu script PostgreSQL major yükseltme aracı değildir. PostgreSQL 17 veri dizini PostgreSQL 18 container'ına doğrudan bağlanmamalıdır; 17 → 18 geçişi doğrulanmış logical dump/restore veya `pg_upgrade` akışıyla, ayrı PG18 veri dizinine yapılmalıdır. Mevcut Compose stack'i PostgreSQL 18 veri dizinini `/var/lib/postgresql/18/docker` altında kullanır.

## Veri akışı ve önemli JOIN sınırı

```text
Kaynak pg_qualstats()
  ├─ kolon-sabit / tek taraflı WHERE-filter predicate
  └─ kolon-kolon JOIN predicate
             │
             v
PoWA 5.2 powa_qualstats_src(0)
  └─ yalnız tek tarafında kolon bulunan predicate
             │
             v
repository current/coalesced history
             │
             v
snapshot sonrası kaynak pg_qualstats_reset()
```

Kaynak extension iki predicate türünü de yakalar. Ancak PoWA 5.2'nin standart `powa_qualstats_src` filtresi kolon-kolon JOIN kayıtlarını remote repository'ye taşımaz. Bu nedenle mevcut repository geçmişi ve predicate API yalnız `WHERE`/filter predicate'leri için güvenilir kaynaktır. “JOIN yok” sonucu sorguda JOIN olmadığı anlamına gelmez.

JOIN ürün özelliği için ana API'ye geniş kaynak parolası vermek yerine ayrı bir `source-snapshotter` tasarlanmalıdır. Bu servis en az ayrı secret, düşük yetki, read-only transaction, statement timeout, açık audit ve capability fallback ile sınırlandırılmalıdır.

Repository database içinde ayrıca `CREATE EXTENSION pg_qualstats` çalıştırılmaz. PoWA 5.2 repository şeması gerekli qualstats tablolarını ve snapshot/aggregate/purge/reset fonksiyonlarını zaten sağlar; extension yalnız kaynak monitoring database'inde gerekir.

## Predicate API ve sayaç semantiği

Endpoint sorgu kimliği yanında kaynak ve veritabanı bağlamını zorunlu alır:

```http
GET /api/v1/queries/{query_id}/predicates?window=24h&serverId={server_id}&databaseId={database_oid}
```

`capability.coverage` daima `WHERE_FILTER_ONLY`, `joinsAvailable` ve `ddlGenerated` daima `false` döner. `available`, ilgili kaynakta `pg_qualstats` datasource'unun etkinliğini; `dataAvailable`, seçili pencere ve sorgu için repository'de örnek bulunup bulunmadığını anlatır. Veri yokluğu sıfır yük veya JOIN yokluğu olarak yorumlanmaz.

Sayaçların kaynağı ve API karşılığı şöyledir:

| PoWA/pg_qualstats alanı | API alanı | Anlamı |
|---|---|---|
| `occurences` | `occurrences` | Sampling'e giren predicate çalışma sayısı; statement `calls` sayısı değildir |
| `execution_count` | `rowsProcessed` | Predicate değerlendirmesinde işlenen satır sayacı |
| `nbfiltered` | `rowsFiltered` | Predicate tarafından elenen satır sayacı |
| `nbfiltered / execution_count` | `filterRatio` | İşlenen satırlar içindeki elenme oranı; payda yoksa unavailable |

Panel `INDEX_CANDIDATE`, `REVIEW`, `INDEX_CONDITION_OBSERVED`, `OBSERVED` ve `INSUFFICIENT_DATA` sinyallerini kullanır. Bunlar telemetry tabanlı inceleme işaretleridir. Endpoint SQL planı değiştirmez, `CREATE INDEX` metni üretmez ve veritabanında DDL çalıştırmaz; gerçek fayda için HypoPG/EXPLAIN ile ayrıca doğrulama gerekir.

## Yerel 2.1.4 shared-memory düzeltmesi

Sabit `2.1.4` kaynağında `track_constants=off` iken query-example hash'i startup sırasında oluşturulmasına rağmen bunun belleği `pgqs_memsize()` hesabına dahil edilmiyordu. Yüksek `pg_qualstats.max` değerinde bu durum PostgreSQL startup aşamasında shared-memory hatasına yol açtı.

Image build'i [pg_qualstats-2.1.4-shmem.patch](../deployment/postgres/pg_qualstats-2.1.4-shmem.patch) dosyasını yalnız sabitlenen `2.1.4` kaynağına uygular ve eksik rezervasyonu ekler. Patch'in uygulanamaması build'i durdurur; farklı upstream sürüme sessizce taşınmaz.

## Ürün adımının durumu ve sıradakiler

Tamamlanan ürün işleri:

1. Repository'deki filter predicate verisi için adapter ve API sözleşmesi eklendi.
2. Kolon adı, operator, occurrence/filter oranı ve veri kapsamı açıklanabilir biçimde sunuldu.
3. Düşük örnek ve eksik history durumları `0` yerine capability ve `INSUFFICIENT_DATA` ile ayrıldı.
4. Index adayı yalnız gözlem olarak üretildi; otomatik `CREATE INDEX` kapalı tutuldu.
5. Ayrı İterasyon 2.2'de uygun tek kolonlu B-tree adayları HypoPG/plain-EXPLAIN ile doğrulandı; yalnız `VALIDATED` sonuçta kopyalanabilir SQL açıldı.

Sıradaki bağımsız işler:

1. Sinyal eşiklerini gerçek veri hacmi ve sampling overhead ölçümleriyle kalibre etmek.
2. JOIN için özel snapshotter gereksinimini ayrı güvenlik ve overhead kabulüyle uygulamak.
3. Çoklu dış kaynak/database için evaluator registry/routing tasarlamak.

HypoPG doğrulamasının SELECT/tek kolonlu B-tree/configured `appdb` sınırı ve işletim modeli [İterasyon 2.2 notundadır](ITERATION_2_2_HYPOPG.md).

Kaynaklar: [pg_qualstats 2.1.4](https://github.com/powa-team/pg_qualstats/releases/tag/2.1.4), [PoWA pg_qualstats entegrasyonu](https://powa.readthedocs.io/en/latest/components/stats_extensions/pg_qualstats.html), [PoWA remote setup](https://powa.readthedocs.io/en/latest/remote_setup.html), [PoWA FAQ](https://powa.readthedocs.io/en/latest/FAQ.html).
