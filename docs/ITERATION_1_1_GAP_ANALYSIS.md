# İterasyon 1.1 belge boşluk analizi

İncelenen güncel belge: [postgresql_dashboard_veri_kullanimi_raporu.pdf](postgresql_dashboard_veri_kullanimi_raporu.pdf)

- Belge başlığı: **PostgreSQL SQL Dashboard — Mevcut Veri Kullanımı ve İterasyon 1.1 Geliştirme Değerlendirme Raporu**
- Rapor tarihi: 23 Temmuz 2026
- Sayfa sayısı: 19
- İndirilen dosya SHA-256: `81DAF49678516515F2B15B2487A7B588F37542413C9BB468C92870E064F4E800`
- İnceleme tarihi: 24 Temmuz 2026

## Sonuç

Belge doğrudan İterasyon 2 uygulama şartnamesi değildir. İterasyon 1 ile index/JOIN önerilerine odaklanan İterasyon 2 arasına bir **İterasyon 1.1 — Gözlemlenebilirlik Zenginleştirme** aşaması koyar. Mevcut repo bu rapor hazırlandıktan sonra rows-per-call, dürüst p95-unavailable sunumu, sunucu düzeyi I/O/WAL/checkpoint, index geçmişi, kontrollü DML workload ve WHERE/filter predicate gözlem paneli gibi alanlarda ilerlemiştir; ancak belgedeki kabul kriterlerinin tamamını karşılamaz.

En önemli teknik ayrım şudur:

1. Bazı veriler PoWA repository'de zaten vardır ve yalnız adapter/API/UI tarafından kullanılmamaktadır.
2. Bazı veriler kaynak PostgreSQL'de vardır ama PoWA 5.2 statement geçmişine taşınmamaktadır.
3. Bazı veriler PostgreSQL 18.4'te, PoWA 5.2 geçmiş tipinde veya mevcut ayarlarda yoktur ve capability olarak raporlanmalıdır.

## Mevcut altyapıda doğrulanan veri sınırları

Kaynak PostgreSQL 18.4 `pg_stat_statements` görünümü `min_exec_time`, `max_exec_time`, `stddev_exec_time`, query-level blok yazma/kirletme, temp read/write ve süreleri, planning toplamları, WAL record/FPI, JIT ve parallel-worker alanlarını sağlar. `track_io_timing=on`, `pg_stat_statements.track_planning=off` durumundadır.

PoWA 5.2 `powa_statements_history_record` tipi şu yüksek değerli alanları repository'ye taşır, fakat mevcut `advisor.v_query_samples` bunların çoğunu seçmez:

- `shared_blks_dirtied`, `shared_blks_written`
- `temp_blks_read`, `temp_blks_written`
- shared/local/temp read ve write süreleri
- `plans`, `total_plan_time`
- `wal_records`, `wal_fpi`, `wal_bytes`
- JIT sayaç ve süreleri

PoWA 5.2 statement geçmişi şu alanları taşımaz:

- `min_exec_time`, `max_exec_time`, `stddev_exec_time`
- `pg_stat_statements_info.stats_reset` ve `dealloc`
- `wal_buffers_full` query düzeyinde
- PostgreSQL 18'deki parallel-worker statement alanları

Bu nedenle min/max/stddev ve pg_stat_statements veri kalitesi geçmişi yalnız repository SQL'i genişletilerek üretilemez. Kaynakta periyodik özel snapshot alan, ayrı yetkili bir servis/datasource gerekir. Tek seferlik canlı kaynak okuması geçmiş pencere metriği gibi sunulmamalıdır.

Denetim anında kaynak `pg_stat_statements_info.dealloc=150` değerindeydi. Bu, kapasite nedeniyle statement kayıtlarının çıkarıldığını ve belgedeki veri kalitesi kartının teorik değil, mevcut demo için de gerekli olduğunu gösterir.

## Belge maddelerinin mevcut durumu

| Belge alanı | Durum | Mevcut davranış / boşluk | Önerilen aşama |
|---|---|---|---|
| Normalize SQL, calls, total/mean süre | Var | PoWA deltalarından sorgu listesi ve detayda kullanılıyor | Koru |
| Eş dönem karşılaştırması | Kısmi | Çalışıyor; küçük pozitif değişimler fazla puanlanıyor, geçmiş kapsamı görünmüyor | `2.0` kalibrasyon |
| Rows / call | Var | Sorgu detayında gösteriliyor | Koru |
| Süre / satır ve blok / satır | Yok | SELECT ve DML semantiği ayrılarak eklenmeli | `1.1-P1` |
| Query cache hit | Kısmi | Hit/read ve oran gösteriliyor; minimum blok hacmi/güven etiketi yok | `1.1-P0` |
| Query I/O timing | Yok | PoWA repository'de mevcut, adapter atıyor | `1.1-P0` |
| Dirtied/written block | Yok | PoWA repository'de mevcut, adapter atıyor | `1.1-P1` |
| Temp read/write, byte, per-call ve süre | Kısmi | Yalnız temp written block puanlamada/listede var | `1.1-P0` |
| Query WAL record/FPI/per-call | Kısmi | Query-level yalnız toplam byte var; server-level ayrıntı Operasyonlar ekranında mevcut | `1.1-P1` |
| Min/max/stddev kararlılık | Yok / repository'de desteklenmiyor | Kaynak görünümde var, PoWA statement geçmişinde yok | Özel source snapshot datasource |
| Gerçek p95/p99 | Bilinçli olarak yok | UI güvenilir dağılım olmadığını açıkça söylüyor | Doğru davranış, koru |
| `stats_reset`, `dealloc`, snapshot boşluğu ve veri güveni | Yok | Bazı I/O datasource'ları reset-aware; pg_stat_statements kalitesi UI/API'de yok | `1.1-P0` + source snapshot |
| Top movers | Yok | Yalnız current/previous mean karşılaştırması var | `1.1-P0` |
| Yeni ağır sorgu | Yok | Önceki dönemde yoktan yüksek yüke çıkış ayrı sınıflanmıyor | `1.1-P0` |
| Saatlik/günlük heatmap | Yok | Trend var, davranış heatmap'i yok | `1.1-P1` |
| Deployment öncesi/sonrası | Yok | Deployment marker veri modeli/API/UI yok | `1.1-P1` |
| Tablo/index dönemsel delta | Büyük ölçüde var | Reset-safe delta ve güvenli index sinyalleri mevcut; 1h coverage toleransı düzeltilmeli | `2.0` doğruluk |
| Planning toplamı | Destekleniyor fakat kapalı | PoWA alanı var; source `track_planning=off` | `1.1-P2`, overhead testi sonrası |
| Planning min/max/stddev | Yok | PoWA geçmiş tipi yalnız plans ve total_plan_time taşıyor | Capability / özel snapshot |
| JIT | Veri var, ürün kullanmıyor | PoWA geçmişinde alanlar mevcut | `1.1-P2` |
| Parallel-worker görünürlüğü | Kaynakta var, üründe unavailable | PostgreSQL 18.4 görünümünde alanlar var; PoWA 5.2 statement geçmişi bunları taşımıyor | Capability `available=false` / özel source snapshot |
| WHERE/filter predicate ve index-adayı gözlemi | Var | Repository adapter, predicate API ve sorgu detay paneli uygulanmış; otomatik DDL yok | `2.1-B` tamamlandı |
| JOIN predicate geçmişi | Unavailable | Raw kaynak yakalayabilir; stok PoWA 5.2 hattı repository'ye taşımıyor | Düşük yetkili source snapshotter |
| Kullanıcı tanımlı eşikler | Yok | Sabit SQL eşikleri kullanılıyor | Daha sonraki bağımsız ürün işi |

## Belgeye göre eksik kabul kriterleri

İterasyon 1.1 henüz tamamlanmış sayılamaz. Eksik ana kabul maddeleri:

- Kararlılık, query-level I/O, temp, WAL, geçmiş ve veri kalitesini ayrı ve açıklanabilir bölümlerde sunmak
- Reset/dealloc/snapshot boşluklarını görünür kılmak
- Top movers ve yeni ağır sorguları üretmek
- Düşük örnekli sorgularda kararlılık ve oran bulgularını bastırmak
- Desteklenmeyen alanları sıfır yerine `unsupported/unavailable` olarak döndürmek
- Query-level temp ve WAL metriklerini per-call değerlerle tamamlamak
- 90 günlük veri hacminde yeni endpointleri ölçmek

## İterasyon 2.1 kararı: `pg_qualstats`

İlk yeni araç **`pg_qualstats`** olarak seçildi. Kaynakta WHERE/JOIN predicate görünürlüğü ve güvenilir index adayı üretme temeli bu araçla başlar.

`2.1-B` altyapı adımının güncel durumu:

1. **Tamamlandı:** Sürüm `2.1.4` ve kaynak SHA-256 değeri sabitlenerek PostgreSQL image içinde derlendi.
2. **Tamamlandı:** Kaynak `shared_preload_libraries` listesine eklendi; restart ve mevcut-volume geçişi belgelendi.
3. **Tamamlandı:** Dedicated `powa` database içinde extension oluşturuldu ve local PoWA datasource etkinleştirildi.
4. **Tamamlandı:** Yeni remote kayıt `extensions => ARRAY['pg_qualstats']` ile açılıyor; gerçek etkinlik PoWA 5.2 `PoWA.powa_extension_config` tablosunda tutuluyor.
5. **Tamamlandı:** Collector snapshot/reset yetkisi, repository history, staging temizliği ve katalog kolon eşlemesi kabul testine bağlandı. Repository database içinde ayrıca `CREATE EXTENSION pg_qualstats` gerekmez; PoWA repository tabloları/fonksiyonları kullanılır.
6. **Tamamlandı:** `track_constants=off`, `sample_rate=0.1`, `max=10000` ve container shared-memory sınırı tanımlandı. Sabit `2.1.4` kaynağındaki `track_constants=off` bellek hesabı eksikliği sürümle sınırlı hedefli patch ile düzeltildi.
7. **Tamamlandı:** Repository adapter, capability modeli, `GET /api/v1/queries/{query_id}/predicates` endpoint'i ve predicate/index-adayı sorgu detay paneli eklendi.
8. **Tamamlandı:** Çıktı “index adayı gözlemi” olarak sunuluyor; `ddlGenerated=false`, otomatik `CREATE INDEX` ve SQL rewrite yok.
9. **İterasyon 2.2'de tamamlandı:** Uygun SELECT/tek kolonlu B-tree sinyalleri ayrı salt-okunur evaluator ile aynı kaynak oturumunda HypoPG/plain-EXPLAIN kullanılarak doğrulanıyor; yalnız `VALIDATED` sonuç kopyalanabilir SQL taşıyor. Gerçek veri/overhead kalibrasyonu, JOIN geçmişi ve çoklu dış kaynak routing'i sıradadır.

Kaynak `pg_qualstats()` kolon-kolon JOIN predicate'lerini de yakalasa da PoWA 5.2 standart `powa_qualstats_src` hattı yalnız tek tarafında kolon bulunan WHERE/filter predicate'lerini repository'ye taşır. Bu nedenle altyapının repository kabulü WHERE/filter geçmişini kapsar; JOIN tarihçesi için ayrı, düşük yetkili source snapshotter gerekir. Ayrıntı [İterasyon 2.1-B notundadır](ITERATION_2_1_B_PG_QUALSTATS.md).

Predicate endpoint'i bu sınırı makine tarafından okunabilir biçimde `coverage=WHERE_FILTER_ONLY`, `joinsAvailable=false` ve `ddlGenerated=false` alanlarıyla bildirir. `occurrences`, PoWA'daki `occurences` değerinden gelen örneklenmiş predicate çalışma sayısıdır; statement çağrı sayısı değildir. `rowsProcessed` kaynak `execution_count`, `rowsFiltered` kaynak `nbfiltered` sayacıdır; `filterRatio` ikincisinin birincisine oranıdır. Örnek azsa güçlü index sinyali yerine `INSUFFICIENT_DATA` döner.

## Repository-only sınırının güncellenmesi

İterasyon 2'de repository-only yaklaşımı mutlak ürün sınırı olmaktan çıkarılabilir. Yine de ana FastAPI sürecine geniş source credential vermek yerine iki yol ayrılmalıdır:

- Tarihsel ve PoWA tarafından taşınabilen metrikler ana API'ye repository üzerinden gelmeye devam eder. `pg_qualstats` bu yolu WHERE/filter predicate'leri için kullanır; stok PoWA hattı kolon-kolon JOIN'leri taşımaz.
- HypoPG/EXPLAIN için ayrı `evaluator` servisi İterasyon 2.2'de yapılandırılmış `test-source/appdb` hedefinde uygulandı; kaynak secret'ı ana API'ye verilmez, read-only transaction ve kısa timeout kullanılır. PoWA'nın taşımadığı özel JOIN snapshotları için ayrı `source-snapshotter` hâlâ gerekir.

Böylece kaynak erişimi mümkün olur fakat dashboard API'sinin güvenlik sınırı gereksiz yere genişletilmez. Source erişimi/HypoPG hazırlığı olmayan veya tek evaluator allowlist'inde bulunmayan gerçek kaynaklarda doğrulama `UNAVAILABLE` döner; geri kalan repository ekranları çalışmaya devam eder. Ayrıntı [İterasyon 2.2 belgesindedir](ITERATION_2_2_HYPOPG.md).
