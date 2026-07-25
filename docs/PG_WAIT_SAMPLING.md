# İterasyon 2.4 — `pg_wait_sampling`

Bu iterasyon, sorgu süresini yalnız PostgreSQL execution ve gerçek CPU
metrikleriyle değil, örneklenmiş bekleme nedenleriyle de açıklar. I/O, SQL
lock, buffer pin, LWLock, client, IPC ve timeout sinyalleri PoWA repository'de
sorgu bazında saklanır. Wait telemetrisi bu aşamada gözlem amaçlıdır ve Impact
Score'a katılmaz.

## Sabitlenen sürüm

| Bileşen | Değer |
|---|---|
| Kaynak release | `pg_wait_sampling 1.1.11` |
| Git tag | `v1.1.11` |
| Commit | `7e3a5fc937393596c0a51c5881dd63d7208408d1` |
| Archive SHA-256 | `7ecd40b02292cfa1ff43efe27c9742fc107f8b51ff8522f0f021067f8d5e8d95` |
| SQL extension sürümü | `1.1` |
| PostgreSQL | `18` |
| PoWA Archivist | `5.2.0` |

Release ile SQL extension sürümü aynı değildir. `1.1.11` kaynak paketinin
`pg_wait_sampling.control` dosyası `default_version = '1.1'` taşır. Bu nedenle
`pg_extension.extversion` ve PoWA `powa_extension_config.version` alanlarında
beklenen değer `1.1`'dir. Uzak bir sunucunun yalnız bu metadata alanına bakarak
hangi patch release'i çalıştırdığı belirlenemez; paket yöneticisi veya image
provenance ayrıca doğrulanmalıdır.

Kaynaklar: [1.1.11 release'i](https://github.com/postgrespro/pg_wait_sampling/releases/tag/v1.1.11),
[resmî extension dokümanı](https://github.com/postgrespro/pg_wait_sampling/blob/v1.1.11/README.md),
[PoWA entegrasyonu](https://powa.readthedocs.io/en/latest/components/stats_extensions/pg_wait_sampling.html),
[PostgreSQL 18 wait event türleri](https://www.postgresql.org/docs/18/monitoring-stats.html).

## Kaynak PostgreSQL ayarları

```conf
shared_preload_libraries = 'pg_stat_statements,pg_qualstats,pg_stat_kcache,pg_wait_sampling'

pg_wait_sampling.profile_period = 10
pg_wait_sampling.profile_pid = off
pg_wait_sampling.profile_queries = top
pg_wait_sampling.sample_cpu = off
```

`pg_stat_statements`, utility statement query ID'lerinin doğru kalması için
preload listesinde `pg_wait_sampling` önünde olmalıdır. Preload ekleme ve
çıkarma cluster restart gerektirir. Diğer wait GUC'leri SIGHUP seviyesindedir;
dosya veya `ALTER SYSTEM` değişikliğinden sonra reload gerekir. Period değeri
integer milisaniyedir; `10` kullanılmalı, `10ms` kullanılmamalıdır.

PoWA yalnız `pg_wait_sampling_profile` verisini taşır ve NULL event satırlarını
repository'ye yazmaz. CPU zaten `pg_stat_kcache` ile ölçüldüğünden
`sample_cpu=off`, kullanılmayan CPU/idle profile girdilerini azaltır.
`profile_pid=off` gereksiz PID kardinalitesini kaldırır. `profile_queries=top`
ise dashboard'un top-level sorgu kapsamıyla eşleşir.

## Veri akışı ve semantik

```text
pg_wait_sampling_profile
  -> PoWA powa_wait_sampling_src(0)
  -> powa_wait_sampling_src_tmp
  -> powa_wait_sampling_history[_current]
  -> advisor.wait_deltas(...)
  -> advisor.query_metrics(...)
  -> API ve sorgu detay ekranı
```

PoWA kaydı `(server, database, query, event type, event)` başına kümülatif
sample sayacıdır. Adapter history array'lerini ve current kayıtlarını birlikte
okur, timestamp'e göre sıralar ve ardışık farkları hesaplar. Sayaç restart veya
manuel reset nedeniyle düşerse yeni sayaç değeri reset sonrası katkı olarak
kabul edilir. Pencere öncesi baseline bulunmayan ilk kümülatif değer pencereye
komple yazılmaz.

Sample sayısı kesin süre değildir. Sabit 10 ms period altında
`sample × 10 ms`, yaklaşık backend-wait süresi olarak düşünülebilir; paralel
worker ve eşzamanlı session'lar nedeniyle sorgu wall time'ını aşabilir. CPU
process-time ile wait sample'ları tek bir yüzde paydasında toplanmaz. Arayüzdeki
wait payları yalnız sorgunun wait örnekleri arasındaki dağılımdır.

Bir sorgu için wait satırı olmaması telemetry hatası anlamına gelmez; sorgu
gerçekten örneklenebilir bir beklemeye girmemiş olabilir. Capability durumu
extension kaydı ve snapshot pipeline sağlığından, sample toplamı ise ayrı
değerlendirilir.

## Fresh stack

Yeni volume ile normal kurulumda extension, PoWA datasource ve repository
tabloları init aşamasında hazırlanır. Genel PoWA server geçmişi 90 gün kalırken
`pg_wait_sampling` datasource'u ayrıca 30 günlük extension retention alır:

```bash
docker compose build source-db collector api web
docker compose up -d
```

Source healthcheck tamamlandıktan ve collector en az iki snapshot aldıktan
sonra wait dağılımları görünür. Hiç wait üretmeyen sorguların `0 sample`
göstermesi beklenen davranıştır.

## Mevcut PostgreSQL 18 volume'ünü geçirme

Init scriptleri mevcut named volume üzerinde yeniden çalışmaz. Image build ve
source container recreate işleminden sonra idempotent geçiş scriptini çalıştırın:

```bash
docker compose build source-db
docker compose up -d --force-recreate source-db repository-db
bash scripts/enable-pg-wait-sampling.sh
docker compose up -d --force-recreate api evaluator web
```

Geçiş scripti:

- image label'ında release `1.1.11` provenance'ını doğrular;
- SQL extension sürümünün `1.1` olduğunu kontrol eder;
- preload ve dört profile GUC'ini doğrular;
- source ve repository PoWA datasource'larını idempotent etkinleştirir;
- fresh init ile aynı 30 günlük extension retention politikasını uygular;
- rerunnable advisor schema adapter'ını uygular;
- veri değiştirmeyen transaction advisory lock beklemesi üretir;
- iki snapshot arasında pozitif, reset-safe `Lock/advisory` deltası doğrular.

Script yalnız demo alias'ı `test-source` içindir. PostgreSQL major yükseltmesi
yapmaz ve volume silmez.

## Haricî PostgreSQL kaynağı

DBA, hedef major sürüme uygun binary paketlerini işletim sistemine kurmalı,
preload ve GUC ayarlarını yapmalı, ardından PostgreSQL'i restart etmelidir.
`scripts/register-source.sh --prepare` binary kurmaz, `postgresql.conf`
değiştirmez ve restart yapmaz; yalnız monitoring database, rol, extension ve
grant hazırlığını tamamlar.

Örnek konfigürasyon için `config/source.env.example` dosyasını Git dışında
kopyalayın ve ardından:

```bash
scripts/register-source.sh --env-file /secure/path/source.env --prepare
scripts/verify-source.sh production-main
```

Kaynak kabulünde şu koşullar doğrulanmalıdır:

- `pg_wait_sampling` monitoring database'de kurulu ve preload edilmiş;
- SQL extension sürümü `1.1`;
- collector rolü `powa_wait_sampling_src(0)` çağırabiliyor;
- `profile_queries=top`, `profile_pid=off`, `sample_cpu=off`;
- PoWA repository'de snapshot, aggregate, purge ve reset işlemleri etkin.
- PoWA repository'de `pg_wait_sampling` extension retention değeri 30 gün.

## Overhead benchmark

```bash
bash scripts/benchmark-wait-sampling.sh
```

Parametreler:

```text
benchmark-wait-sampling.sh [runs] [seconds] [clients] [jobs] [scale]
varsayılan:                    3       5         4       2      10
```

Benchmark çalışan Compose stack'inin ayarlarını değiştirmez. Aynı PostgreSQL
image'ından iki disposable container açar: baseline mevcut
`pg_stat_statements + pg_qualstats + pg_stat_kcache` preload setini, treatment
aynı sete ek olarak production wait ayarlarını kullanır. İki veritabanı
ısıtılır, ölçüm sırası her tur ters çevrilir ve median TPS karşılaştırılır.
Container'lar ve anonim verileri çıkışta otomatik silinir.

Bu kısa mikro-benchmark production overhead garantisi değildir. Canlı karar
için normal ve stress workload profilleri, collector/repository büyümesi ve
uzun süreli CPU kullanımı ayrıca ölçülmelidir. Yalnız `profile_period` değerini
büyütmek geçerli bir kapalı-baseline değildir; `history_period` varsayılan
10 ms kalırsa background worker yine aynı sıklıkta backend listesini tarar.

## Kapasite ve retention

Bir `(query,event)` profile serisi oluştuktan sonra kümülatif satır sonraki PoWA
snapshot'larında tekrar taşınır. Genel server retention'ı 90 gün olsa da wait
datasource override'ı 30 gündür; çok sayıda query/event bulunan sistemlerde bu
horizon dahi repository'yi hızla büyütebilir. Şunları izleyin:

```sql
SELECT pg_size_pretty(pg_total_relation_size('"PoWA".powa_wait_sampling_history'));
SELECT pg_size_pretty(pg_total_relation_size('"PoWA".powa_wait_sampling_history_current'));
```

PoWA 5.2 extension-bazlı retention destekler. Ürün ekranlarının maksimum wait
penceresi 30 gün olduğundan fresh init, mevcut-volume geçişi ve
`register-source.sh` aşağıdaki datasource politikasını idempotent uygular:

```sql
UPDATE "PoWA".powa_extension_config
   SET retention = interval '30 days'
 WHERE extname = 'pg_wait_sampling'
   AND srvid = :server_id;
```

Bu extension override'ı genel kaynak retention değerini değiştirmez. Daha kısa
bir operasyonel politika seçilecekse dashboard pencere sözleşmesi ve kapasite
planı birlikte güncellenmelidir.

## Kabul kontrolleri

```bash
bash -n scripts/enable-pg-wait-sampling.sh
bash -n scripts/benchmark-wait-sampling.sh
bash -n scripts/verify-source.sh
```

Çalışan demo stack üzerinde:

```bash
bash scripts/enable-pg-wait-sampling.sh
bash scripts/verify.sh
```

Beklenen temel durum:

```text
extension SQL version = 1.1
profile_period         = 10
profile_pid            = off
profile_queries        = top
sample_cpu             = off
PoWA operations        = 4
wait retention         = 30 days
collector errors       = 0
scoreIncluded          = false
```

Datasource geçici olarak kapatılacaksa history silmeden şu fonksiyon
kullanılabilir:

```sql
SELECT "PoWA".powa_deactivate_extension(:server_id, 'pg_wait_sampling');
```

Preload'dan tamamen çıkarmak ayrıca PostgreSQL restart gerektirir.
