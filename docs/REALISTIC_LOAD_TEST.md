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
| `stress` | 250k müşteri, 3m sipariş, 12m kalem, 20m event | 48 | 1800 sn | Açık kapasite/doygunluk testi |

Seed hedef-count bazlı, tek seeder kilitli ve monotonik/idempotenttir. Aynı profil
yeniden çalıştırıldığında tablolara hedef kadar satır daha eklemez; daha büyük bir
profilden küçüğüne dönmek satır silmez. Otomatik rollback/cleanup yoktur. Bu akış
yalnız izole, yeniden üretilebilir test source'u içindir ve gerçek production
veritabanında çalıştırılmamalıdır. Baz `init-source.sh` değiştirilmez; normal
`docker compose up` hâlâ hızlı ve küçük kalır. `stress` source PostgreSQL'ün CPU ve
disk I/O'sunu bilinçli olarak doyurabilir; yeterli boş disk, en az 8 GiB Docker
belleği ve test boyunca başka ağır workload olmaması önerilir.

## Çalıştırma

Ana stack sağlıklı çalışırken:

```bash
bash scripts/run-realistic-workload.sh normal
```

Süre ve worker sayısı ikinci ve üçüncü argümanla değiştirilebilir:

```bash
bash scripts/run-realistic-workload.sh normal 900 32
```

Bu wrapper bounded koşuyu garanti eder. Workload servisini doğrudan
`docker compose --profile realistic-load up workload` ile açarsanız varsayılan
`WORKLOAD_DURATION_SECONDS=0` sürekli moddur; `docker compose stop workload` ile
kontrollü biçimde durdurulmalıdır.

Script sırasıyla şunları yapar:

1. Source, repository, collector, JOIN snapshotter, API ve evaluator health
   preflight'ını yapar.
2. Seçilen minimum veri hedefini batch'li ve idempotent biçimde hazırlar.
3. Workload image'ını build eder ve bounded karma trafiği çalıştırır.
4. PoWA remote snapshot'ını zorlar ve repository'nin ilerlediğini doğrular.
5. Generator hata oranı ve süre bütünlüğü ile yalnız bu koşunun veri hacmi, CPU,
   waits, JOIN/WHERE kanıtı, composite aday ve collector/snapshotter sinyallerini;
   ardından post-load API health/gecikmesini kontrol eder.

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

Generator sınırlı sayıda sabit, parametreli fingerprint kullanır. Worker'lar
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

Dinamik SQL veya run-id içeren query yorumu kullanılmaz. Böylece
`pg_stat_statements.max` ve PoWA repository fingerprint sayısı koşu süresiyle
sınırsız büyümez. Yeni iş verisi kontrollü büyür; seeder dışında generator
hedef tabloları sınırsız çoğaltmaz.

## Kabul kuralları

Hosta bağlı mutlak TPS hard gate değildir. Aşağıdakiler hard gate'tir:

- generator'ın tamamlanması, worker kaybı olmaması ve hata oranının sınırda kalması;
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

## 2.7 sınırı

Gerçekçi source seed'i clone template'e otomatik kopyalanmaz. 2.7 acceptance,
gerçek DDL'yi yalnız disposable candidate database'de çalıştıran küçük,
deterministik ve server-side fixture'ı doğrulamaya devam eder. Çok gigabaytlık
source restore'unun baseline ve candidate ile üç kopyasını almak ayrı kapasite
kararıdır; mevcut 1 GiB tmpfs sınırına sessizce sığdırılmaya çalışılmaz.
Dolayısıyla bu kapı büyük normal source üzerindeki runtime hızını değil, izolasyon,
gerçek index kullanımı, ölçüm ve zorunlu cleanup mekanizmasını kanıtlar.
