# ERP stack kaynak/repository benchmark'ı

`scripts/benchmark-erp-stack.sh`, mevcut realistic workload kabul akışını
değiştirmeden sarar ve aynı koşu penceresinde hem kaynak PostgreSQL'ün hem PoWA
repository'nin toplam işletim maliyetini ölçer. Kaynak container sayacı ERP
workload'u, observer sorgularını ve benchmark sampler'ını birlikte kapsar; bu
değer tek başına gözlem katmanının izole overhead'i değildir. Ayrı
`observerOwnedSql` alanı, `powa_collector` ve `advisor_join_reader` için tracker'ın
görebildiği SQL alt kümesini ayrıca raporlar.

Harness anlık `docker stats` yüzdesini kullanmaz. PostgreSQL 18 kümülatif
istatistiklerini ve container cgroup CPU/block-I/O/bellek sayaçlarını yalnız
workload generator pipeline'ının hemen önce ve hemen sonrasında okur. Wrapper
preflight/manifest kontrolleri baseline'dan önce; FORCE snapshot, DB verifier
ve isteğe bağlı disposable-clone kabulü ise after snapshot'tan sonra kalır.
Bağlantı sayısı, anlık bellek kullanımı, collector lag ve snapshot freshness
yalnız bu generator penceresinde periyodik örneklenir.

Bu kesin sınır iki aşamalı, fail-closed bir el sıkışmayla kurulur. Wrapper
`docker compose ... run workload` öncesinde private geçici dizine atomik
`start-ready` marker'ı yazar ve benchmark baseline'i almadan devam etmez.
Pipeline bittiğinde `end-ready` marker'ında bekler; benchmark monitorleri
durdurup after snapshot'i aldıktan sonra post-load kontrollere izin verir.
Marker dizini benchmark tarafından `0700`, payload'lar `0600` oluşturulur;
symlink/geniş izin, bozuk JSON, erken marker, subprocess exit'i ve timeout
koşuyu non-zero sonlandırır. Generator başarılıysa wrapper'ın post-load
kontrolleri tamamen çalışır ve nihai exit code ayrı bir hard guardrail olarak
rapora girer. Generator pipeline non-zero dönerse wrapper yine `end-ready`
marker'ını yayımlar; harness after snapshot'ı aldıktan sonra post-load kapıları
çalıştırılmadan özgün pipeline exit code'u korunarak çıkar.
Query-metrics veya global-trend stale-while-revalidate cache'i bir probe
cevabından sonra repository yenilemesine devam ederse harness
`advisor-query-metrics-cache-refresh` ve `advisor-global-trend-cache-refresh`
application/query etiketlerinin ikisini de izler. Her iki işin bitmesini ve iki
saniyelik stabil idle durumunu bekler; bu CPU/I/O ölçüm penceresine dahil edilir
ve sonraki koşuya sızmaz. İki cache refresh'i backend'deki ortak
repository-wide lock nedeniyle eşzamanlı çalışmaz.
Baseline'da PostgreSQL metric SQL'i cgroup sayaçlarından önce, finalde ise
cgroup sayaçlarından sonra çalışır; böylece harness'ın kendi metric SQL maliyeti
container CPU/I/O deltasına tek taraflı sızmaz. END marker'ında halen çalışan
probe'lar önce tamamlanır, ardından final sayaçları alınır.

## Çalıştırma

Ana stack sağlıklıyken önerilen kapasite kabulü 500 tablo ve tam 4.000 bounded
template (rol context'ine göre en az 4.000 gerçek queryid) üreten `erp` profilidir:

```bash
bash scripts/benchmark-erp-stack.sh run erp
```

Fresh demo volume `DEMO_SOURCE_FREQUENCY=60` ile kaydolur. Eski named volume'lerde
init script tekrar çalışmadığı için önceki `5s` değeri korunabilir; benchmark bu
durumu build/seed/yük başlamadan fail-closed reddeder. Bundled demo kaydını bir
kez üretim-temsili değere taşımak için:

```bash
docker compose exec -T repository-db \
  psql -X -U postgres -p 5433 -d powa_repository -v ON_ERROR_STOP=1 \
  -c 'UPDATE "PoWA".powa_servers SET frequency=60 WHERE alias='"'"'test-source'"'"';'
docker compose restart collector
```

Gerçek kaynaklar aynı değeri `scripts/register-source.sh --frequency 60` ile
idempotent biçimde almalıdır. Benchmark source kaydını kendisi değiştirmez.

Süre ve worker sayısı mevcut realistic wrapper ile aynı sınırlara sahiptir:

```bash
bash scripts/benchmark-erp-stack.sh run quick 120 8
bash scripts/benchmark-erp-stack.sh run normal 600 24
bash scripts/benchmark-erp-stack.sh run stress 1800 48
```

Harness varsayılan olarak seed'i ölçümden önce bir kez hazırlar ve içteki
realistic wrapper'a `REALISTIC_SKIP_PREPARE=true` geçirir. Böylece 500 tablolu
ERP seed/ANALYZE işlemi ölçüm penceresinde ikinci kez çalışmaz; rapor sabit veri
hacmindeki steady-state workload, dashboard probe'ları ve PoWA gözlem maliyetini
karşılaştırır. Workload image build/pull işlemi de baseline'dan önce tamamlanır
ve ölçüm sırasında aynı image yeniden kullanılır. Aşağıdaki compatibility modu
seed hazırlığını iç wrapper'ın preflight'ına bırakır; `start-ready` marker'ı
seed tamamlandıktan sonra üretildiği için seed maliyeti yine ölçüm dışındadır:

```bash
ERP_BENCHMARK_PREPARE_FIRST=false \
  bash scripts/benchmark-erp-stack.sh run erp 600 32
```

Birden fazla Compose projesi çalışıyorsa hedef açıkça verilmelidir:

```bash
COMPOSE_PROJECT_NAME=postgresql-advisor \
  bash scripts/benchmark-erp-stack.sh run normal
```

`COMPOSE_FILE` açıkça verilmemişse harness çalışan `source-db` container'ının
Compose `config_files` etiketini devralır. Böylece prepare, build ve run aynı
override dosyalarını kullanır; özel ağ veya deployment override'ı sessizce
kaybolmaz.

Workload çalıştırmadan salt-okunur metric preflight'ı alınabilir:

```bash
bash scripts/benchmark-erp-stack.sh snapshot
```

Tam rapor varsayılan olarak
`runtime/load-reports/<UTC>-<profil>-erp-stack.json` yoluna atomik olarak
yazılır. `ERP_BENCHMARK_REPORT_DIR` farklı bir dizin seçebilir.

## Kapsam, kanıt sınırı ve referans host

HTTP gecikme hard gate'i varsayılan UI penceresi `24h` ile üç endpoint'i
round-robin sırada ölçer:

1. Source'a göre filtrelenmiş
   `GET /api/v1/queries?window=24h&pageSize=50&serverId=<id>` query-list isteği
2. Global `GET /api/v1/overview?window=24h` isteği; query-metrics tabanlı kartlar
   ve top queries, ayrı SWR cache'teki global trend ile canlı collector health'i
   birlikte kapsar
3. Son başarılı query-list batch'inin ilk satırından seçilen kimlikle
   `GET /api/v1/queries/<queryId>?window=24h&serverId=<id>&databaseId=<oid>`;
   detail temel satırı ile canlı query trendini birlikte kapsar

Her endpoint batch'inden sonra `ERP_BENCHMARK_SAMPLE_SECONDS` kadar beklenir ve
döngü query-list → overview → query-detail olarak devam eder. Varsayılan
concurrency query-list/detail için `2`, global overview için `1`'dir. Query-list
boşsa detail seçimi oluşana kadar ilgili batch açıkça skipped sayılır; ERP kabulü
query-list'in veri döndürmesini ayrıca hard gate yaptığı için bu durum sessizce
başarılı kabul edilmez.

Bu matris varsayılan `24h` dashboard yollarını yük altında kapsar; `7d`/`30d`
pencerelerini veya 30/90 günlük retention tamamen doluyken davranışı sınamaz.
Koşunun `PASSED` olması 500 tablo/4.000 bounded template kardinalitesini, bu
24 saatlik endpoint matrisini ve aynı 10 dakikalık penceredeki guardrail'leri
doğrular; uzun geçmiş kapasitesi veya bütün kullanıcı akışları için genel SLO
garantisi değildir. Release qualification için hedef retention hacmiyle ayrı
soak testi ve 7d/30d endpoint matrisi gerekir.

26 Temmuz 2026'da aynı hazır ERP manifesti üzerinde iki başarılı referans ölçüm
kaydedildi. On dakikalık koşu uzun kaynak/repository zarfını, üç dakikalık koşu
ise güncel üç-endpoint API matrisini doğrular:

| Alan | 600 saniyelik kaynak zarfı | 180 saniyelik endpoint matrisi |
|---|---:|---:|
| Container ortamı | arm64 OrbStack, 10 vCPU, yaklaşık 11,7 GiB kullanılabilir Docker belleği | Aynı host ve hazır manifest |
| Profil | `erp`, 32 worker, 60 saniye cadence | `erp`, 32 worker, 60 saniye cadence |
| Workload | 133.603/133.603 başarılı, 221,89 TPS, 4.000/4.000 template | 40.666/40.666 başarılı, 224,08 TPS, 4.000/4.000 template |
| Source container | ortalama 8,55 core; 3,13 GiB pencere tepesi; 5,39 GiB block I/O; 39 bağlantı tepesi | ortalama 8,02 core; 2,65 GiB pencere tepesi; 2,85 GiB block I/O; 38 bağlantı tepesi |
| Repository container | ortalama 0,43 core; 1,37 GiB pencere tepesi; 6,96 GiB block I/O; 5 bağlantı tepesi | ortalama 0,78 core; 2,28 GiB pencere tepesi; 2,89 GiB block I/O; 6 bağlantı tepesi |
| Query-list API | concurrency 2, 216 başarılı örnek, p95 0,177 saniye | concurrency 2, 22 başarılı örnek, p95 0,261 saniye |
| Overview API | Ölçülmedi | concurrency 1, 11 başarılı örnek, p95 0,121 saniye |
| Query detail/trend API | Ölçülmedi | concurrency 2, 22 başarılı örnek, p95 0,126 saniye |
| Sonuç | Ortama özel CPU/bellek/I/O eşikleriyle `PASSED` | 61/61 guardrail `PASSED` |

600 saniyelik rapor üç-endpoint matrisi eklenmeden önce üretildiği için yalnız
query-list değerini içerir; overview/detail iddiası 180 saniyelik ikinci rapora
aittir. Yeni harness her endpoint'i `api.byEndpoint` altında ayrı kaydeder.

Aynı gün hemen önceki 180 saniyelik koşu snapshot sequence `6998 -> 7002` ile
`powa_coalesce=100` periyodik sınırını geçti. Repository bu pencerede ortalama
1,03 core ve 8,13 GiB block I/O gördü; bilinçli `1 core / 8 GiB` laboratuvar
eşiklerini az farkla aştı. Sonraki `7009 -> 7013` steady-state koşusunun
`0,78 core / 2,89 GiB` sonucu bu farkın sıradan koşu gürültüsü olmadığını
gösterir. Kapasite planı yalnız steady-state medyanına göre yapılmamalı;
`powa_coalesce` sınırına denk gelen periyodik bakım penceresi ayrıca ölçülmeli ve
repository için CPU/I/O headroom bırakılmalıdır. Daha düşük `powa_coalesce`
değeri spike boyutu ile daha sık coalesce ve history satır sayısı arasında bir
değiş tokuştur; hedef retention hacmiyle ölçmeden değiştirilmemelidir.

Bu iki eski schema-v4 raporunun ham sayaçları yeni rate formülüyle geriye dönük
hesaplandığında maintenance-inclusive `6998 -> 7002` penceresinde repository
read/write/total hızları sırasıyla `9,46 / 31,67 / 41,13 MiB/s`; steady-state
`7009 -> 7013` penceresinde `7,50 / 8,43 / 15,93 MiB/s` olur. Toplam repository
I/O zarfı yaklaşık `2,58×`, write zarfı yaklaşık `3,75×` büyümüştür. Bu nedenle
disk kapasitesi yalnız toplam GiB veya steady-state ortalamasıyla değil,
maintenance-inclusive write-rate üst zarfı ve gecikme ölçümüyle boyutlanmalıdır.
Yeni raporlar bu hesabı doğrudan `derivedMetrics.repository.containerIo` altında
taşır ve pencere etiketini elle sequence yorumlamaya bırakmaz.

### Cold-cache sınırı

Yukarıdaki API p95 değerleri, harness'ın ölçümden önce yaptığı bounded warmup
sonrasındaki kullanıcı yoludur; cold-start SLO'su değildir. Aynı 4.000-template
repository'de cache `300s` üstü yaşa ulaştıktan sonra ilk `24h` query-list
isteği `22,12s` sürdü. Ayrı plan ölçümünde `advisor.query_metrics(24h)` yaklaşık
`23,08s` ve `1,24 GiB` temp read/write; global trend yaklaşık `6,68s` ve
`1,35 GiB` temp read/write üretti. Sonraki SWR-korumalı çağrılar tabloda görülen
`0,261s / 0,121s / 0,126s` p95 değerlerine döndü.

Bu nedenle `2s / 8s / 2s` kapıları yalnız warm/SWR steady-state davranışını
kanıtlar. API rebuild sonrasında trafik açmadan önce full verifier veya eşdeğer
bounded warmup çalıştırın ve cold fill için proxy/readiness timeout'unu ayrıca
boyutlandırın. Bu önlem `300s` üstü tamamen idle cache'i çözmez. İlk veya expired
cache isteğinde de `<2s` zorunlu olan 4.000+ queryid deployment için açık P1,
multi-user temporal rollup'un raw record'ları ikinci kez açmadan tek geçişli
hesaplanmasıdır. Ölçümde `work_mem` artırmak veya JIT'i kapatmak güvenli kazanç
üretmedi; stale sınırını körlemesine uzatmak ya da her dakika idle refresh
çalıştırmak veri tazeliği/repository yükü değiş tokuşunu gizlediği için çözüm
olarak kabul edilmez.

Bu tek koşu sertifikalı minimum veya production kapasite tahmini değildir.
Source CPU'su mevcut 10 vCPU'nun büyük bölümünü kullandığı ve tabloda yalnız iki
PostgreSQL container'ı yer aldığı için aynı 32-worker kabul profiline başlangıç
headroom'u olarak en az 12 vCPU, Docker'a ayrılmış 16 GiB kullanılabilir bellek
ve 30 GiB boş disk önerilir. Hedef hostta en az üç izole koşunun medyanını alın;
daha küçük veya büyük zarfı ancak ölçümle kabul edin.

Source container sayıları ERP workload'u, observer SQL'i ve sampler'ı birlikte;
repository sayıları collector yazıları ile API probe SQL'ini birlikte kapsar.
Dolayısıyla repository/source CPU oranı veya `PASSED` sonucu saf gözlem overhead'i
değildir. Observer'ın marjinal maliyeti için aynı seed, sorgu programı, cache
sıcaklığı ve container limitleriyle observer kapalı/açık A/B koşuları yapın ve
en az üç tekrarın medyanını karşılaştırın. A/B yapılmadan source üzerindeki ürün
yükünün kabul edildiğini iddia etmeyin.

## Ölçülen alanlar

Schema version `4` raporunda her hedef için `before`, `after` ve `delta`
bulunur:

- `measurementBoundary` içinde start/end ready/continue ve wrapper bitiş
  zamanları; `generatorElapsedSeconds` salt generator süresini,
  `elapsedSeconds` generator ile sınırda halen çalışan probe'ların kapanışını
  kapsayan sayaç penceresini gösterir
- `sourceFrequencySeconds`; harness bu değeri yalnız okur, değiştirmez
- Container CPU kullanım süresi (`cpu.stat` veya cgroup v1 fallback'i)
- Container block read/write byte sayaçları
- Cgroup sürümü; v2'de exact `max`/`oom`/`oom_kill`, v1'de `failcnt` bellek
  baskı sayacı
- Cgroup anlık bellek, container ömrü boyunca peak, limit/unlimited durumu ve
  `memory.events` içindeki `max`, `oom`, `oom_kill` sayaçları
- Ölçüm penceresinde periyodik örneklerden hesaplanan source/repository bellek
  peak değeri
- `pg_stat_io` read/write/extend/fsync sayaçları ve süreleri
- Database byte boyutu ve büyümesi
- Transaction, block hit/read, temp, tuple, session ve active-time sayaçları
- Anlık ve koşu içi tepe bağlantı sayısı
- Source `pg_stat_statements` toplam occupancy/count/max, `dealloc`, collector
  rolüne ait entry ve hem `advisor-realistic` hem `advisor-erp` call sayıları
- Source observer rollerinin tracker ayarları; görülebilen statement/call,
  plan/execute süresi ve `pg_stat_kcache` user/system CPU deltaları. Güvenli
  self-observation ayarında rol tracker'ı `none` ise ilgili delta sıfırdır ve saf
  observer overhead'i olarak yorumlanmaz
- Baseline'da mevcut her appdb `pg_stat_statements`
  `(userid, dbid, queryid, toplevel)` anahtarının `stats_since` ve
  `minmax_stats_since` sürekliliği
- Repository PoWA query serisi, history chunk ve current sample sayıları
- Collector durumu, hata sayısı, server'a ait `powa_coalesce`, snapshot sequence,
  lag ve freshness
- Yük altında 24h query-list, global overview ve seçilmiş query-detail/trend için
  endpoint-bazlı p50/p95/max gecikmesi, concurrency, örnek ve hata sayıları
- Geriye uyumluluk için query-list'i temsil etmeye devam eden `api` root alanları;
  additive `api.byEndpoint`, bütün matris hatalarını toplayan
  `api.matrixErrorCount` ve rotation/delay/detail-selection bilgisini taşıyan
  `api.probePlan`
- Source JOIN outbox batch/row/oldest-age/largest-batch/storage backlog'u
- Repository JOIN retention süresini aşmış batch/row purge borcu

`pg_stat_database`, `pg_stat_io`, `pg_stat_statements`, observer
`pg_stat_kcache` entry'leri veya cgroup sayacı reset
olursa delta güvenilmez kabul edilir ve koşu fail olur. Global timestamp'i
değiştirmeyen scoped `pg_stat_statements_reset(...)` çağrıları da baseline
anahtarının kaybolması veya entry `stats_since` değişimi üzerinden yakalanır.
Container restart'ı ve koşu sırasında bellek limitinin değişmesi ayrıca
kontrol edilir.

### Türetilmiş kapasite metrikleri ve PoWA bakım sınıfı

Schema version `4` korunur; yeni okuyucular additive `derivedMetrics` alanını,
eski okuyucular mevcut `before`/`after`/`delta` alanlarını kullanabilir.
`derivedMetrics.source.containerIo` ve
`derivedMetrics.repository.containerIo` içinde şu hızlar bulunur:

- `readBytesPerSecond`
- `writeBytesPerSecond`
- `totalBytesPerSecond`

Payda `derivedMetrics.measurementSeconds` ile gösterilen gerçek cgroup ölçüm
penceresidir (`elapsedSeconds`); generator'ın nominal CLI süresi değildir.
Sayaç eksikse, geriye gitmişse veya ölçüm süresi geçersizse hız `null` kalır.
Bunlar PostgreSQL logical query throughput'u değil, container block-I/O
hızlarıdır. Source değeri workload + observer + sampler'ı; repository değeri
collector + API probe SQL'ini aynı kapsamla taşır.

`derivedMetrics.powaMaintenance`, her snapshot'ta yakalanan PoWA extension
sürümü, server kimliği, `powa_coalesce` ve monotonik `coalesce_seq` kanıtından
periyodik bakım sınırını hesaplar. Harness'ın doğruladığı PoWA `5.2.0` sırası
server offset'ini de içerir:

```text
aggregate: (coalesce_seq + (server_id % 20)) % powa_coalesce = 0
purge:     (coalesce_seq + (server_id % 20)) % powa_coalesce = 1
```

`aggregateBoundaryCrossings` ve `purgeBoundaryCrossings`, baseline'da zaten
tamamlanmış snapshot'ı tekrar saymayan `(before, after]` aralığı içindir. Bu
nedenle `server_id=1`, `powa_coalesce=100`, sequence `6998 -> 7002` penceresi
aggregate `6999` ve purge `7000` olmak üzere `1 / 1` crossing üretir.

Sınıflama fail-closed'dur:

- Kanıtlı en az bir aggregate veya purge crossing'i
  `classification=MAINTENANCE_INCLUSIVE`, `maintenanceInclusive=true` ve
  `steadyStateEligible=false` üretir.
- Server/config sabit, sequence monotonik ve pozitif ilerlemiş, crossing sıfırsa
  `classification=STEADY_STATE_ELIGIBLE`, `maintenanceInclusive=false` ve
  `steadyStateEligible=true` olur.
- Extension sürümü desteklenen `5.2.0` değilse, server/config/sequence eksik
  veya değişmişse ya da sequence gerilerse `classification=UNKNOWN`,
  `maintenanceInclusive=null` ve
  `steadyStateEligible=false` olur; nedenler `unknownReasons` altında kalır.
- Sequence hiç ilerlememişse sınırın geçilmediği bilinse bile koşu bakım-dışı
  kapasite kanıtı sayılmaz ve `INSUFFICIENT_SNAPSHOT_PROGRESS` olur.

Bu etiket yalnız PoWA'nın periyodik aggregate/purge penceresini yorumlar;
guardrail sonucu veya genel bir SLO sertifikası değildir. Mevcut eşikler aynen
uygulanır ve maintenance-inclusive bir koşu yeterli headroom ile `PASSED`
olabilir. Production kapasitesi için steady-state tekrarlarının medyanını ve
maintenance-inclusive tekrarların üst zarfını ayrı raporlayın; bakım koşusunu
gürültü diye atmayın. `powa_coalesce` değerini spike'ı gizlemek amacıyla
değiştirmeyin; retention hacminde aggregate sıklığı/history büyüklüğü etkisini
ayrı ölçün.

Hard gate hem `snapts` değerinin before/after arasında mikro-saniye cinsinden
ilerlemesini hem de 5 saniyelik peak örneklerinde görülen, birbirinden farklı ve
strictly-increasing `snapts` geçişlerinin süre/frekans için beklenen aralıkta
kalmasını ister. Böylece `coalesce_seq` wrap/reset davranışına dayanmadan,
repository'de 60s yazarken collector'ın eski 5s cadence ile çalışması veya koşu
boyunca yalnız tek snapshot üretmesi yanlış geçemez.

## Varsayılan guardrail'ler

Donanımdan bağımsız varsayılanlar şunları zorunlu tutar:

- Existing realistic workload/verifier başarıyla tamamlanmalı.
- Baseline başlamadan collector `HEALTHY/errors=0`, JOIN transport `HEALTHY`,
  source outbox ve repository staging tamamen boş olmalı; recovery maliyeti
  workload maliyetine karışmamalı.
- Source toplama aralığı koşu boyunca değişmemeli ve varsayılan en az `30s`
  olmalı; temsilî ERP kapasite koşusu için `60s` önerilir.
- Kümülatif sayaçlar geriye gitmemeli ve istatistik reset'i olmamalı.
- Baseline appdb pgss entry'lerinden hiçbiri kaybolmamalı veya yeni
  `stats_since` ile yeniden oluşmamalı.
- Source/repository cgroup v2 `max`/`oom`/`oom_kill` veya cgroup v1 `failcnt`
  baskı deltası sıfır kalmalı; bellek limiti koşu sırasında değişmemeli.
- Source üzerinde en az bir tagged ERP call ve repository `snapts` değerinde en
  az bir mikro-saniye ilerleme oluşmalı; gerçek snapshot sayısı varsayılan
  `%80..%150 + 1` cadence aralığında kalmalı.
- `pg_stat_statements.dealloc` ve collector-owned entry deltası sıfır kalmalı;
  occupancy varsayılan `%90` sınırını aşmamalı.
- 24h API matrisi query-list → global overview → seçilmiş query-detail/trend
  sırasıyla dönmeli. Query-list ve detail varsayılan concurrency `2` ile p95
  `2s`; overview concurrency `1` ile p95 `8s` altında kalmalı. Herhangi bir
  endpoint'teki hata ortak matrix error tavanına dahil edilmeli.
- Ölçüm başlamadan önce her kullanılabilir endpoint için yapılan tek soğuk
  cache/connection ısındırma isteğinin 45 saniyelik ayrı timeout'u vardır; bu
  süreler p95'e katılmaz. Ölçüm penceresindeki her istek 15 saniyede fail-closed
  olur. Query-metrics ve global-trend arka plan refresh'leri ile scoped detail
  trendi ve collector-health'in canlı repository maliyeti container CPU/I/O
  sayaçlarına dahil edilir; kapanış iki refresh etiketini de idle olana kadar
  bekler.
- Source JOIN outbox ve repository retention purge borcu bounded kalmalı.
- Collector koşu sonunda `HEALTHY`, hatasız ve lag/freshness sınırı içinde
  olmalı. Varsayılan sınır `max(30 saniye, source frequency × 4)` değeridir.
- Peak bağlantılar her PostgreSQL `max_connections` değerinin varsayılan `%90`
  sınırını aşmamalı.
- Source ve repository deadlock üretmemeli.
- Tek koşudaki database büyümesi hedef başına varsayılan 4 GiB'ı aşmamalı.
- Peak sampler en fazla üç geçici hata üretmeli ve istenen süre/aralık için
  beklenen örneklerin varsayılan en az `%80`'ini başarıyla almalı.

Mutlak CPU, bellek, I/O ve repository/source CPU oranı makine, Docker limiti,
profil, cache sıcaklığı ve tracker topolojisine bağlıdır. Kalibre edilmemiş bir
ortamı yanlış reddetmemek için bunların varsayılanı `0`, yani raporla ama hard
gate uygulama şeklindedir. CI veya kapasite ortamında en az üç koşunun medyanıyla
ölçülmüş bütçeler şu değişkenlerle etkinleştirilir:

| Değişken | Varsayılan | Anlamı |
|---|---:|---|
| `ERP_BENCHMARK_SAMPLE_SECONDS` | `5` | Peak örnekleme ve her API endpoint batch'i sonrası bekleme aralığı |
| `ERP_BENCHMARK_PREFLIGHT_TIMEOUT_SECONDS` | `300` | Wrapper'ın start-ready marker'ı için üst sınır |
| `ERP_BENCHMARK_BASELINE_TIMEOUT_SECONDS` | `max(60, frequency × 2)` | Sağlıklı, outbox/staging'siz clean baseline bekleme sınırı |
| `ERP_BENCHMARK_WORKLOAD_GRACE_SECONDS` | `300` | İstenen süreye ek end-ready bekleme payı |
| `ERP_BENCHMARK_SYNC_TIMEOUT_SECONDS` | `300` | Wrapper'ın her continue marker'ını bekleme üst sınırı |
| `ERP_MIN_PEAK_SAMPLES` | `floor(duration / interval × 0.80)`, en az `1` | Minimum başarılı bağlantı/bellek/lag peak örneği |
| `ERP_MIN_SOURCE_FREQUENCY_SECONDS` | `30` | Minimum source toplama aralığı; `0` yalnız bilinçli olarak kapatır |
| `ERP_MIN_COLLECTOR_SNAPSHOTS` | `floor(duration / frequency × 0.80)`, en az `1` | Minimum gerçek snapshot sayısı |
| `ERP_MAX_COLLECTOR_SNAPSHOTS` | `ceil(duration / frequency × 1.50) + 1` | Maksimum gerçek snapshot sayısı |
| `ERP_MAX_SOURCE_CONNECTIONS` | `max_connections × 0.90` | Source peak bağlantı sınırı |
| `ERP_MAX_REPOSITORY_CONNECTIONS` | `max_connections × 0.90` | Repository peak bağlantı sınırı |
| `ERP_MAX_COLLECTOR_LAG_SECONDS` | `max(30, frequency × 4)` | Collector peak lag sınırı |
| `ERP_MAX_SNAPSHOT_FRESHNESS_SECONDS` | aynı | Snapshot peak freshness sınırı |
| `ERP_MIN_SNAPSHOT_ADVANCE_MICROSECONDS` | `1` | Minimum `snapts` ilerlemesi |
| `ERP_MIN_SOURCE_TAGGED_CALLS_DELTA` | `1` | Minimum ERP call ilerlemesi |
| `ERP_MAX_PGSS_OCCUPANCY_PERCENT` | `90` | Source pgss occupancy tavanı |
| `ERP_API_CONCURRENCY` | `2` | Her query-list ve query-detail batch'indeki eşzamanlı probe sayısı; `1..8` |
| `ERP_API_OVERVIEW_CONCURRENCY` | `1` | Global overview batch'indeki eşzamanlı probe sayısı; `1..8` |
| `ERP_MAX_API_P95_SECONDS` | `2` | Yük altı query-list API p95 tavanı; legacy `api.p95Seconds` alanını da yönetir |
| `ERP_MAX_API_OVERVIEW_P95_SECONDS` | `8` | Yük altı global overview API p95 tavanı |
| `ERP_MAX_API_DETAIL_P95_SECONDS` | `2` | Yük altı seçilmiş query-detail/trend API p95 tavanı |
| `ERP_MIN_API_SAMPLES` | `5` | Minimum başarılı query-list API örneği; endpoint p95 kapıları ayrıca gerçek overview/detail örneği ister |
| `ERP_MAX_API_ERRORS` | `0` | Bütün endpoint matrisi için izin verilen toplam probe hatası |
| `ERP_MAX_JOIN_OUTBOX_BATCHES` | `100` | Source outbox batch tavanı |
| `ERP_MAX_JOIN_OUTBOX_ROWS` | `1000000` | Source outbox toplam satır tavanı |
| `ERP_MAX_JOIN_OUTBOX_LARGEST_BATCH_ROWS` | `250000` | En büyük outbox batch satır tavanı |
| `ERP_MAX_JOIN_OUTBOX_OLDEST_AGE_SECONDS` | lag sınırı | En eski source outbox yaşı |
| `ERP_MAX_JOIN_OUTBOX_PAYLOAD_BYTES` | `536870912` | Outbox row heap/payload tavanı |
| `ERP_MAX_JOIN_OUTBOX_STORAGE_BYTES` | `1073741824` | Source outbox storage tavanı |
| `ERP_MAX_JOIN_PURGE_DEBT_BATCHES` | `0` | Retention'ı aşan repo batch tavanı |
| `ERP_MAX_JOIN_PURGE_DEBT_ROWS` | `0` | Retention'ı aşan repo row tavanı |
| `ERP_MAX_SOURCE_DB_GROWTH_BYTES` | `4294967296` | Source büyüme tavanı |
| `ERP_MAX_REPOSITORY_DB_GROWTH_BYTES` | `4294967296` | Repository büyüme tavanı |
| `ERP_MAX_SOURCE_AVG_CPU_CORES` | `0` | Source ortalama core tavanı; `0` kapalı |
| `ERP_MAX_REPOSITORY_AVG_CPU_CORES` | `0` | Repository ortalama core tavanı; `0` kapalı |
| `ERP_MAX_REPOSITORY_SOURCE_CPU_RATIO` | `0` | Repository/source toplam CPU oranı; kalibrasyon sonrası etkinleştirilir |
| `ERP_MAX_SOURCE_IO_BYTES` | `0` | Source toplam block-I/O tavanı; `0` kapalı |
| `ERP_MAX_REPOSITORY_IO_BYTES` | `0` | Repository toplam block-I/O tavanı; `0` kapalı |
| `ERP_MAX_SOURCE_MEMORY_BYTES` | `0` | Ölçüm penceresi source bellek peak tavanı; `0` kapalı |
| `ERP_MAX_REPOSITORY_MEMORY_BYTES` | `0` | Ölçüm penceresi repository bellek peak tavanı; `0` kapalı |
| `ERP_MAX_MEMORY_PRESSURE_EVENTS_DELTA` | `0` | Her DB container için v2 `memory.events:max` / v1 `failcnt` delta tavanı |
| `ERP_MAX_OOM_EVENTS_DELTA` | `0` | Cgroup v2 `oom` delta tavanı; v1'de unavailable/SKIP |
| `ERP_MAX_OOM_KILL_EVENTS_DELTA` | `0` | Cgroup v2 `oom_kill` delta tavanı; v1'de unavailable/SKIP |
| `ERP_MAX_SAMPLING_ERRORS` | `3` | İzin verilen peak sampler hatası |
| `ERP_REQUIRE_CGROUP_METRICS` | `true` | CPU/I/O/bellek current/peak/limit yoksa fail et |
| `ERP_REQUIRE_CGROUP_MEMORY_EVENTS` | `true` | V2 exact event veya v1 `failcnt` sayacı beklenmedik biçimde yoksa fail et |
| `ERP_BENCHMARK_FAIL_ON_GUARDRAIL` | `true` | Guardrail ihlalinde non-zero dön |

`ERP_MIN_SOURCE_FREQUENCY_SECONDS` yalnız kabul eşiğidir; PoWA source
konfigürasyonunu değiştirmez. Frekans deployment/register adımında açıkça
ayarlanmalı, benchmark raporundaki `sourceFrequencySeconds` ile doğrulanmalıdır.

Cgroup v1 memory fallback'i current/peak/limit ve `memory.failcnt` değerini
raporlar; `failcnt` artışı varsayılan olarak hard failure'dır. V1'in sunmadığı
exact `oom`/`oom_kill` sayaçları otomatik `SKIP` olur ve raporda
`unavailableExactOnV1` altında görünür. Cgroup v2'de `max`, `oom` ve `oom_kill`
exact kapıları eksiksiz ve fail-closed kalır. Sürümü bilinmeyen veya beklenen
sayacı eksik platform ancak bilinçli olarak
`ERP_REQUIRE_CGROUP_MEMORY_EVENTS=false` ile gevşetilebilir.

Örneğin repository'nin ortalama bir core'u ve source CPU maliyetinin `%50`'sini
aşmamasını zorlamak için:

```bash
ERP_MAX_REPOSITORY_AVG_CPU_CORES=1 \
ERP_MAX_REPOSITORY_SOURCE_CPU_RATIO=0.50 \
ERP_MAX_REPOSITORY_IO_BYTES=10737418240 \
ERP_MAX_REPOSITORY_MEMORY_BYTES=1073741824 \
  bash scripts/benchmark-erp-stack.sh run erp
```

Bu benchmark source ve repository PostgreSQL container maliyetini görür; API,
collector ve snapshotter daemon CPU/belleğini ayrı container maliyeti olarak
toplamaz. Source container deltası da workload ile gözlem sorgularını ayırmaz.
`observerOwnedSql` yalnız tracker'ın kaydettiği rol bazlı alt kümeyi verir; gerçek
izole observer overhead'i için aynı seed ve sorgu programıyla observer kapalı/açık
A/B koşusu gerekir. API probe'larının repository üzerinde oluşturduğu iş gerçek
dashboard trafiği olarak ölçüme bilinçli biçimde dahildir. Başka testler aynı anda
repository sorguluyorsa o maliyet de rapora girer. Kapasite karşılaştırmaları için
stack'in izole olması, aynı seed profili ve aynı Docker CPU/bellek limitleriyle en
az üç koşunun medyanının alınması önerilir.
