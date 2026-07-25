# Sayaç reseti ve zaman kapsamı

Ana sorgu metrikleri, `pg_stat_statements`, `pg_stat_kcache` ve
`pg_wait_sampling` tarafından üretilen kümülatif sayaçlardan hesaplanır. Sayaç
düştüğünde yeni dönemin ilk aktivitesi artık sıfırlanmaz:

```text
current >= previous  -> delta = current - previous
current < previous   -> delta = current, resetDetected = true
```

PoWA coalesced history satırlarında yalnız ilk/son composite değere bakılmaz.
İlgili `records` dizileri sıra ile değerlendirilir; böylece aynı chunk içinde
resetten sonra sayaç eski değeri yeniden aşsa bile reset görünür kalır. Normal
akış bir saatlik bounded predecessor aralığını kullanır. Bu aralıkta önceki
örnek yoksa yalnız o seri için en yakın eski gerçek record aranır. Retention
nedeniyle predecessor hiç yoksa ilk delta uydurulmaz ve coverage eksik kalır.

## API sözleşmesi

Her query list/detail kaydı şu alanları taşır:

- `observedFrom`, `observedTo`: seçili pencerede güvenilir interval ile
  ilişkilendirilebilen ilk zaman ve görülen son snapshot.
- `coveragePercent`: collector frekansının üç katını aşan gap'ler çıkarıldıktan
  sonra seçili pencerenin ölçülen yüzdesi.
- `resetDetected`: query, kcache veya wait kaynağında sayaç düşüşü görüldü.
- `previousPeriodAvailable`: önceki eş dönemde gerçek ölçüm intervali var.
- `comparisonReliable`: her iki dönem yeterli kapsama sahip, predecessor
  mevcut ve hiçbir kaynakta reset/gap yok.
- `warmingUp`: query geçmişi henüz önceki dönemi oluşturmadı; collector gap'i
  bu durumdan ayrı tutulur.

Önceki dönem yoksa `previousCalls`, `previousMeanExecTimeMs` ve
`regressionPercent` `null` döner. Gerçek ölçülmüş sıfır ise sıfır olarak kalır.
Güvenilmez regresyon, regression listesine veya Impact Score'un regression
bileşenine girmez.

Bir gap intervali pencere sınırını kesiyorsa hangi döneme ait olduğu
bilinemeyen delta current/previous toplamına yazılmaz. İki endpoint aynı
pencere içindeyse kümülatif toplam korunur, fakat `comparisonReliable=false`
kalır. Impact Score hacim katsayıları snapshot coverage süresine değil, metrik
tarafından temsil edilen süreye bölünür; uzun gap düşük bir denominator ile
skoru şişiremez.

## Migration ve doğrulama

Fresh kurulumda frozen `001_advisor_schema.sql`, mevcut volume upgrade'ında
ileri yönlü `007_reset_coverage.sql` aynı fonksiyon sözleşmesini oluşturur.
Migration runner ayrıntıları [repository migration belgesindedir](REPOSITORY_MIGRATIONS.md).

Çalışan demo repository üzerinde sentetik kayıtları transaction içinde ekleyip
tamamını rollback eden kabul testi:

```bash
bash scripts/verify-temporal-reliability.sh
```

Test query/kcache/wait resetini, chunk içi reseti, normal coalesce akışını,
uzun collector gap'ini, pencere sınırı attribution'ını ve eksik önceki dönem
`null` sözleşmesini doğrular.
