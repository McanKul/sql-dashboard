# İterasyon 2.3 — `pg_stat_kcache` CPU telemetrisi

## Durum ve kapsam

Bu iterasyon sorgu bazında PostgreSQL süresinin yanında işletim sisteminin
ölçtüğü gerçek CPU tüketimini gösterir. PostgreSQL 18 image'ı
`pg_stat_kcache 2.3.2` içerir; PoWA 5.2 remote datasource'u sayaçları ayrı
repository'ye taşır ve ana API kaynak veritabanına bağlanmadan bunları sunar.

İlk ürün kapsamı bilinçli olarak gözlem modundadır:

- execution user CPU, system CPU ve toplam CPU süresi;
- toplam CPU'nun `pg_stat_statements` execution süresine oranı;
- işletim sistemi filesystem katmanındaki read/write byte sayaçları;
- extension kapalı, veri henüz oluşmamış ve veri kullanılabilir durumlarının
  ayrı capability sonucu;
- sorgu listesinde CPU görünümü/sıralaması, detay paneli ve CSV export;
- CPU sinyali **Impact Score'a dahil değildir** ve otomatik aksiyon üretmez.

Planning takibi bu iterasyonda kapalıdır. Böylece gösterilen CPU, sorgunun
planlanması değil yürütülmesi sırasında tüketilen kaynaktır.

## Sabitlenen sürüm ve ayarlar

- `pg_stat_kcache 2.3.2`
- tag: `REL2_3_2`
- source archive SHA-256:
  `d5da20b5d8808f60dc1427c94d69186ff1d48fa1235ff672f5d0457b370304fb`

Referans kaynak ayarları:

```conf
shared_preload_libraries = 'pg_stat_statements,pg_qualstats,pg_stat_kcache'
pg_stat_kcache.track = top
pg_stat_kcache.track_planning = off
```

`track=top`, ana dashboard'ın top-level statement toplamlarıyla aynı kapsamı
kullanır. PL/pgSQL wrapper içindeki alt statement'lar `pg_stat_statements.track=all`
ile ham PoWA verisinde kalabilir; ana sorgu listesinde wrapper ve iç sorgu aynı
DB süresine iki kez yazılmaz.

## Veri akışı ve sayaç semantiği

```text
source pg_stat_kcache()
  -> PoWA powa_kcache_src(0)
  -> powa-collector
  -> repository powa_kcache_metrics[_current]
  -> advisor.kcache_deltas(...)
  -> advisor.query_metrics(...)
  -> queries API / CSV
  -> sorgu listesi ve detay paneli
```

PoWA kayıtları kümülatiftir. `advisor.kcache_deltas` coalesce edilmiş ve güncel
storage tier'larını tek zaman çizelgesinde birleştirir, aynı
server/database/query/user/top-level anahtarında ardışık örnek farkını alır ve
sayaç resetinde negatif sonuç üretmez. İlk snapshot yalnız baseline'dır; bir
sorgu için ölçüm göstermek adına en az iki snapshot gerekir.

CPU sayaçları upstream extension'da saniyedir; API milisaniyeye çevirir.
`percentOfExecTime`, toplam user+system CPU'nun `pg_stat_statements`
execution süresine oranıdır. Paralel worker CPU'ları toplandığında bu oran
`%100`ü aşabilir; değer clamp edilmez ve duvar saati gibi yorumlanmaz.

Filesystem read/write, PostgreSQL shared buffer sayaçları değildir. Bunlar OS
katmanında ölçülen byte değerleridir; platform bazı `getrusage` alanlarını
sağlamıyorsa alan `null` kalır. Eksik capability veya yetersiz history hiçbir
zaman sahte `0 CPU` olarak gösterilmez.

## API sözleşmesi

Her sorgu nesnesi şu gözlem alanını taşır:

```json
{
  "cpu": {
    "capability": {
      "available": true,
      "version": "2.3.2",
      "dataAvailable": true,
      "source": "PoWA pg_stat_kcache",
      "coverage": "EXECUTION_ONLY",
      "reason": "..."
    },
    "userTimeMs": 123.4,
    "systemTimeMs": 12.3,
    "totalTimeMs": 135.7,
    "percentOfExecTime": 74.2,
    "filesystemReadsBytes": 8192,
    "filesystemWritesBytes": 0,
    "scoreIncluded": false
  }
}
```

Capability etkin ama sorgu iki snapshot arasında çalışmadıysa
`dataAvailable=false` olur ve bütün ölçüm alanları `null` döner.

## Kısa puan/eşik kalibrasyonu

2.3'e geçmeden önce önceki denetimde açık kalan iki yüksek etkili hata kapatıldı:

1. Ana dashboard ve trend toplamları yalnız top-level statement delta'larından
   hesaplanır; wrapper ile nested statement DB zamanı çift sayılmaz.
2. Regresyon sinyali için her iki eş pencerede en az 20 çağrı ve en az `%20`
   ortalama süre artışı gerekir. Regresyon hacim katsayısı `%50` artışta tam
   değere ulaşır; küçük pozitif gürültü puan veya “yavaşlayan sorgu” sayısı
   üretmez.

Süre, physical read, çağrı, temp ve WAL bileşenlerinin mevcut
`percentile × observation-hour volume` modeli ile 85/70/40 priority sınırları
korundu. `pg_stat_kcache` ilk olarak gerçek iş yükünde dağılımı gözlenecek bir
bağımsız sinyaldir; ölçüm görmeden ağırlıkların toplamı değiştirilmedi.

## Kurulum ve mevcut volume yükseltmesi

Temiz kurulumda extension, preload, local/remote PoWA datasource ve repository
adapter'ı init sırasında hazırlanır:

```bash
docker compose up -d --build
bash scripts/verify.sh
```

PostgreSQL 18 named volume'ü zaten varsa yeni image ve preload command'ının
çalışması için container'ları yeniden oluşturun, sonra idempotent migration'ı
uygulayın:

```bash
docker compose build source-db repository-db
docker compose up -d --force-recreate source-db repository-db
bash scripts/enable-pg-stat-kcache.sh
docker compose up -d --build --force-recreate api web
```

Script volume silmez. Kaynakta extension/datasource'u, repository'de remote
datasource ve advisor SQL adapter'ını etkinleştirir; kontrollü workload ile
history ve CPU alanını doğrular.

Gerçek bir dış kaynakta PostgreSQL major sürümüne uygun extension binary'si
önceden kurulmalı, `shared_preload_libraries` değişikliği sonrası cluster restart
edilmeli ve monitoring database içinde extension oluşturulmalıdır.
`scripts/register-source.sh --prepare` işletim sistemi paketi kurmaz veya
cluster restart etmez; yalnız hazır binary/preload üzerinde extension, rol,
grant ve PoWA kayıtlarını tamamlar.

## Overhead kontrolü

Kısa, sırayla `track=none` ve `track=top` ölçümü:

```bash
bash scripts/benchmark-pg-stat-kcache.sh 7 50
```

Script medyan süreleri ve gözlenen farkı raporlar; sonucu hard gate yapmaz.
Bu mikro test production eşzamanlılığı, kernel cache durumu ve uzun süreli entry
büyümesini temsil etmez. Canlı rollout'ta aynı sorgu karmasıyla önce/sonra CPU,
latency ve collector lag trendi ayrıca izlenmelidir.

## Kabul kriterleri

`bash scripts/verify.sh` şunları doğrular:

- image artifact'ı, extension sürümü, preload ve `top/off` GUC'ları;
- source ve remote PoWA datasource fonksiyonları;
- collector history ilerlemesi ve boş kalan staging tablosu;
- reset-safe query CPU alanları ile capability sözleşmesi;
- `scoreIncluded=false`, top-level toplam ve regresyon gate'i;
- API, UI build, HypoPG/predicate özellikleri ve mevcut güvenlik sınırlarının
  geriye dönük çalışması.

Kaynaklar: [pg_stat_kcache release'leri](https://github.com/powa-team/pg_stat_kcache/releases),
[pg_stat_kcache kaynak dokümanı](https://github.com/powa-team/pg_stat_kcache),
[PoWA pg_stat_kcache entegrasyonu](https://powa.readthedocs.io/en/latest/components/stats_extensions/pg_stat_kcache.html),
[PoWA remote setup](https://powa.readthedocs.io/en/latest/remote_setup.html).
