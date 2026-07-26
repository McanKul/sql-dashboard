# Gerçekçi toplu yük testi

Bu profil, küçük ve deterministik CI fixture'ını değiştirmeden source PostgreSQL'ü
cache dışına taşan veriyle doldurur ve ürünün bütün gözlem zincirini aynı zaman
aralığında sınar. Amaç tek bir yüksek TPS sayısı üretmek değil; CPU, fiziksel I/O,
temp dosyası, WAL, row-lock, JOIN ve seçici olmayan predicate sinyallerini birlikte
görmektir.

## Profiller

| Profil | Minimum veri hedefi | Varsayılan worker | Varsayılan süre | Kullanım |
|---|---:|---:|---:|---|
| `quick` | 25k müşteri, 250k sipariş, 750k kalem, 1m event | 8 | 120 sn | Laptop ve değişiklik kontrolü |
| `normal` | 100k müşteri, 1m sipariş, 4m kalem, 6m event | 24 | 600 sn | Önerilen uçtan uca yerel kabul |
| `erp` | `normal` veri + 500 gerçek tablo x 2k satır | 32 | 600 sn | Geniş katalog ve binlerce queryid kabulü |
| `stress` | 250k müşteri, 3m sipariş, 12m kalem, 20m event | 48 | 1800 sn | Açık kapasite/doygunluk testi |

Seed hedef-count bazlı, tek seeder kilitli ve monotonik/idempotenttir. Aynı profil
yeniden çalıştırıldığında tablolara hedef kadar satır daha eklemez; daha büyük bir
profilden küçüğüne dönmek satır silmez. Otomatik rollback/cleanup yoktur. Bu akış
yalnız izole, yeniden üretilebilir test source'u içindir ve gerçek production
veritabanında çalıştırılmamalıdır. Baz `init-source.sh` değiştirilmez; normal
`docker compose up` hâlâ hızlı ve küçük kalır. `8 GiB` Docker belleği base/quick
geliştirme için alt öneridir; `erp` veya `stress` kapasite koşusu için yeterlilik
iddiası değildir. `stress` source PostgreSQL'ün CPU ve disk I/O'sunu bilinçli
olarak doyurabilir. Referans `erp 600 32` koşusuna başlangıç headroom'u olarak en
az 12 vCPU, Docker'a ayrılmış 16 GiB kullanılabilir bellek, 30 GiB boş disk ve
test boyunca başka ağır workload olmaması önerilir. Bu sertifikalı minimum
değildir; ölçüm kapsamı ve hosta özel kalibrasyon
[ERP benchmark runbook'undadır](ERP_STACK_BENCHMARK.md#kapsam-kanıt-sınırı-ve-referans-host).

## Çalıştırma

Ana stack sağlıklı çalışırken:

```bash
bash scripts/run-realistic-workload.sh normal
```

Süre ve worker sayısı ikinci ve üçüncü argümanla değiştirilebilir:

```bash
bash scripts/run-realistic-workload.sh normal 900 32
```

Geniş ERP kataloğunu ve fingerprint kapasitesini sınamak için:

```bash
bash scripts/run-realistic-workload.sh erp 600 32
```

İlk ERP hazırlığı `advisor_erp` altında tam 500 yönetilen tablo, tablo başına
2.000 deterministik satır ve primary key dahil iki indeks oluşturur. Bu açıkça
veri/DDL üreten, yalnız izole test source'u için tasarlanmış bir adımdır. Sonraki
steady-state benchmark koşularında seed süresini ölçümden çıkarmak için önce bir
normal hazırlama yapın, ardından yalnız eşleşen `READY` manifestiyle çalışmasına
izin verilen opt-in'i kullanın:

```bash
bash scripts/prepare-realistic-workload.sh erp --yes
REALISTIC_SKIP_PREPARE=true bash scripts/run-realistic-workload.sh erp 600 32
```

`REALISTIC_SKIP_PREPARE` yalnız `true`/`false` kabul eder. `true` iken manifest
schema sürümü, profil, durum ve ERP tablo/satır hedeflerinden biri uyuşmazsa koşu
başlamadan kapanır; kaynakta seed veya başka hazırlama yazımı yapmaz.

Bu wrapper bounded koşuyu garanti eder. Workload servisini doğrudan
`docker compose --profile realistic-load up workload` ile açarsanız varsayılan
`WORKLOAD_DURATION_SECONDS=0` sürekli moddur; `docker compose stop workload` ile
kontrollü biçimde durdurulmalıdır. ERP profili sürekli modu kabul etmez; doğrudan
Compose kullanımında süreyle birlikte tam katalog kontratı açıkça verilmelidir:

```bash
WORKLOAD_PROFILE=erp \
WORKLOAD_DURATION_SECONDS=600 \
WORKLOAD_WORKERS=32 \
WORKLOAD_ERP_TABLE_COUNT=500 \
WORKLOAD_ERP_QUERY_VARIANTS_PER_TABLE=8 \
WORKLOAD_ERP_ROWS_PER_TABLE=2000 \
docker compose --profile realistic-load up workload
```

Script sırasıyla şunları yapar:

1. Source, repository, collector, JOIN snapshotter, API ve evaluator health
   preflight'ını yapar.
2. Seçilen minimum veri hedefini batch'li ve idempotent biçimde hazırlar.
3. Workload image'ını build eder ve bounded karma trafiği çalıştırır.
4. PoWA remote snapshot'ını zorlar ve repository'nin ilerlediğini doğrular.
5. Generator hata oranı ve süre bütünlüğü ile yalnız bu koşunun veri hacmi, CPU,
   waits, JOIN/WHERE kanıtı, composite aday ve collector/snapshotter sinyallerini;
   ardından post-load API health/gecikmesini kontrol eder.

Post-load query-list doğrulaması, kapasite harness'ıyla aynı `24h` pencereyi
varsayılan olarak kullanır. Standalone doğrulamada cache gerçekten soğuk
olabileceği için ilk, süreye dahil edilmeyen warmup isteğinin timeout'u `45s`'dir;
sonraki ölçümlü istekler `5s` sınırını ve `2s` p95 kapısını korur. Gerekirse bu
iki davranış host shell'inde `REALISTIC_API_WINDOW` (`1h`, `24h`, `7d`, `30d`) ve
`REALISTIC_API_WARMUP_TIMEOUT_SECONDS` (`5..120`) ile değiştirilir; warmup
latency dağılımına katılmaz.

Repository hostu geçici olarak CPU-starved olduğunda post-load database counter
sorgusunun verifier'ı süresiz bekletmemesi için yalnız bu read-only sorguya
varsayılan `30s` server-side `statement_timeout` uygulanır. Sınır host shell'inde
`REALISTIC_DATABASE_METRICS_TIMEOUT_SECONDS` (`5..120`) ile değiştirilebilir.
Timeout veya SQL hatası kabul eşiğini gevşetmez; koşuyu fail-closed durdurur ve
`advisor-realistic-database-metric-verifier` application name'i tanı için
`pg_stat_activity` üzerinde görünür.

2.7 disposable clone kabulünü de zincire eklemek için stack admin token ve
`real-validation` profiliyle başlatılmış olmalıdır:

```bash
REALISTIC_VERIFY_RUNTIME=true bash scripts/run-realistic-workload.sh normal
```

Özel Compose proje adı veya birden fazla Compose dosyası kullanılıyorsa standart
Compose değişkenleri korunur. Örneğin yerel kabul stack'i için:

```bash
COMPOSE_PROJECT_NAME=postgresql-advisor-final-live \
COMPOSE_FILE="compose.yaml:compose.networks.fixed.yaml" \
REALISTIC_VERIFY_RUNTIME=true \
bash scripts/run-realistic-workload.sh normal
```

Tracked overlay'deki subnet'ler kurumsal ağ/VPN ile çakışırsa
`ADVISOR_NETWORK_SUBNET`, `EVALUATOR_CONTROL_SUBNET` ve aynı dosyada listelenen
diğer subnet değişkenlerini `.env` içinde kurulum başına özelleştirin.

## Trafik modeli

Generator normal profillerde sınırlı sayıda sabit, parametreli fingerprint
kullanır. `erp` profili ayrıca allowlist içindeki 500 ilişki üzerinde sekiz
salt-okunur sorgu ailesini deterministik olarak dolaşır: point read, tenant/state
aggregate, tarih aralığı, JSON channel, tutar aralığı, grouping, komşu tablo JOIN
ve CTE rollup. Böylece tam 4.000 bounded template etiketi süre veya run-id ile
sınırsız büyümeden üretilir. Aynı template reader/reporter `SET ROLE` permission
context'lerinde ayrı PostgreSQL `queryid` alabileceği için gerçek queryid sayısı
4.000 veya daha fazladır; exact kabul kontratı deterministik template etiketidir. Worker'lar
farklı `SET ROLE` kimlikleri ve `application_name` değerleriyle şu trafiği
karıştırır:

- indexli müşteri/sipariş okumaları ve gerçekçi browse sorguları;
- JSON ve tarih filtreli geniş taramalar;
- iki/üç tabloluk JOIN, aggregate ve düşük `work_mem` ile temp spill;
- order/event INSERT, sipariş durum UPDATE ve bounded bakım DELETE'leri;
- az sayıda hot-row UPDATE ve kısa lock hold;
- CPU ağırlıklı hash/JSON işlemleri.

Bağlantılar yalnız bu profil için oluşturulan `advisor_workload_login` rolüyle
açılır. Rol superuser değildir, `NOINHERIT` kullanır ve yalnız dar kapsamlı
reader/writer/reporter rollerine geçebilir; workload'a source admin parolası
verilmez.

Run-id içeren query yorumu kullanılmaz. ERP ilişki adları yalnız `1..500` tam
sayılarından üretilir ve driver identifier quoting'iyle render edilir; runtime
sorguları salt-okunurdur. `pg_stat_statements.max=50000` varsayılanı 4.000 ERP
hedefi ve ana workload fingerprintleri için headroom bırakır. Yeni iş verisi
kontrollü büyür; seeder dışında generator DDL çalıştırmaz veya ERP tablolarını
değiştirmez.

## Kabul kuralları

Hosta bağlı mutlak TPS hard gate değildir. Aşağıdakiler hard gate'tir:

- generator'ın tamamlanması, worker kaybı olmaması, toplam hata oranının
  varsayılan `%1` (`REALISTIC_MAX_ERROR_RATE`) ve her tekil operasyonun hata
  oranının `%5` (`REALISTIC_MAX_OPERATION_ERROR_RATE`) altında kalması;
- `erp` için 500 tablo/1m satır/1.000 indeks ACL zarfı, 4.000 öğelik generator
  sweep'inin `%100` tamamlanması, source/repository'de tam 4.000 deterministik
  template etiketi ve en az 4.000 gerçek queryid;
- PoWA snapshot'ının ilerlemesi, collector ve JOIN snapshotter'ın taze/sağlıklı olması;
- etiketli sabit workload fingerprintleri ve pg_stat_kcache CPU kanıtı;
- `pg_wait_sampling` içinde kontrollü `Lock` örneği;
- WHERE ve JOIN predicate geçmişi ile en az bir composite aday;
- write/WAL ilerlemesi, deadlock olmaması ve API health.

Fiziksel I/O wait sayısı işletim sistemi cache'i ve disk hızına bağlıdır; veri
shared buffers'tan büyük olsa da sıfır olabilir. Bu nedenle I/O wait yokluğu
warning'dir, CPU/I/O byte sayaçları ve temp spill ile birlikte yorumlanır.

Ham generator logu ve son kabul özeti `runtime/load-reports/` altında zaman
damgalı tutulur. Bu dizin Git'e dahil edilmez.

Source/repository toplam CPU, block-I/O, bellek ve bağlantı zarfını aynı generator
penceresinde ölçmek için `bash scripts/benchmark-erp-stack.sh run erp` kullanılır.
Bu harness varsayılan `24h` penceresinde query-list, global overview ve son listeden
seçilen query-detail/trend batch'lerini round-robin ölçer; her batch sonrasında
peak sampler ile aynı `ERP_BENCHMARK_SAMPLE_SECONDS` aralığını bekler. Overview
query-metrics ile ayrı global-trend SWR cache'lerini ve canlı collector health'i;
detail ise cache'li temel satır ile canlı scoped trendi birlikte sınar. Varsayılan
eşzamanlılık list/detail için `2`, overview için `1`; p95 tavanları `2s`, `8s` ve
`2s`'dir. Legacy rapor root'u query-list özetini korurken `api.byEndpoint`,
`api.matrixErrorCount` ve `api.probePlan` matrisi additive olarak açıklar.
Harness kapanışta query-metrics ve global-trend refresh etiketlerinin ikisini de
izleyip repository işi stabil idle olmadan ölçüm sınırını kapatmaz.
Bu rapordaki source container deltası workload, observer SQL ve sampler toplamıdır;
saf observer overhead'i değildir. Tracker'ın görebildiği `powa_collector` ve
`advisor_join_reader` alt kümesi ayrıca `observerOwnedSql` alanında yer alır.
Kalibre edilmemiş repository/source CPU oranı varsayılan olarak yalnız raporlanır.
Aynı koşu 7d/30d veya tamamen dolmuş retention soak testi değildir; saf gözlem
maliyeti için aynı seed/limitlerle observer kapalı/açık A/B ve en az üç tekrar
gerekir.
Ayrıntılı sınırlar ve cgroup v1/v2 davranışı
[ERP benchmark runbook'unda](ERP_STACK_BENCHMARK.md) açıklanır.

## 2.7 sınırı

Gerçekçi source seed'i clone template'e otomatik kopyalanmaz. 2.7 acceptance,
gerçek DDL'yi yalnız disposable candidate database'de çalıştıran küçük,
deterministik ve server-side fixture'ı doğrulamaya devam eder. Çok gigabaytlık
source restore'unun baseline ve candidate ile üç kopyasını almak ayrı kapasite
kararıdır; mevcut 1 GiB tmpfs sınırına sessizce sığdırılmaya çalışılmaz.
Dolayısıyla bu kapı büyük normal source üzerindeki runtime hızını değil, izolasyon,
gerçek index kullanımı, ölçüm ve zorunlu cleanup mekanizmasını kanıtlar.
