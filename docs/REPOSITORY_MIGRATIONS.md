# Repository migration modeli

Release yükseltmesi; yedek, writer-stop, explicit migrator ve doğrulanmış
cutover sırasıyla yapılır. Başarılı migration sonrası down migration yoktur;
ayrıntılar [upgrade/rollback runbook'undadır](UPGRADE_ROLLBACK.md).

PoWA repository şeması, boş volume kurulumu ve mevcut named volume yükseltmesi
için aynı `repository-migrate` servisi tarafından yönetilir. PostgreSQL'in
`docker-entrypoint-initdb.d` mekanizması yalnız PoWA extension'ını, cluster
rollerini ve ilk kaynak kaydını hazırlar; advisor şemasının sahibi değildir.

## Çalışma akışı

`docker compose up` sırasında sıralama şöyledir:

1. `repository-db` PoWA ve bootstrap rollerini hazırlar.
2. Tek seferlik `repository-migrate`, repository sağlıklı olduktan sonra
   manifestteki migration'ları uygular.
3. `collector`, `join-snapshotter` ve `api` ancak migrator başarıyla
   tamamlandığında başlar.

Elle veya mevcut bir named volume üzerinde aynı akışı çalıştırmak için:

```bash
bash scripts/migrate-repository.sh
```

Runner `sql/repository-migrations.manifest` dosyasını sırayla okur. Her dosyanın
SHA-256 değerini PostgreSQL'e bağlanmadan önce doğrular. Sonra tek transaction
içinde database'e özel advisory lock alır, migration'ları çalıştırır ve
`advisor_migrations.schema_migrations` tablosuna kaydeder. Herhangi bir SQL
hatasında bütün yeni migration'lar rollback olur. Aynı sürüm farklı ad, dosya
veya checksum ile görülürse; ya da database bu release'in tanımadığı daha yeni
bir sürüm içerirse işlem fail-closed durur.

İlk dört kayıt, daha önce init scriptleriyle tekrar çalıştırılan mevcut SQL
dosyalarının güvenli adoption baseline'ıdır. Bu dosyalar idempotent oldukları
için ledger bulunmayan mevcut volume üzerinde bir kez yeniden uygulanır; şema
var diye doğrulamadan yalnızca “uygulanmış” işaretlenmezler.

`0004` içindeki JOIN rol bağlama migration'ı, `JOIN_SOURCE_ALIAS` henüz PoWA'da
kayıtlı değilse bilinçli olarak no-op tamamlanır ve ledger'a yazılır. Demo
kaynak daha sonra eklendiğinde `scripts/enable-join-snapshotter.sh` rolü gerçek
server kimliğine bağlar. Dış kaynakta DBA ayrıca
`advisor_ingest.bind_join_source_role(...)` çağrısını, o kaynağa ayrılmış login
ile yapmalıdır. Bu tasarım, dış kaynak kurulumu beklerken tüm repository
açılışını bloke etmez.

`0010` JOIN transport staging/chunk protokolünü ve retention purge indekslerini
ileri yönlü ekler. Eski tek-payload fonksiyonları rolling upgrade sırasında
çağrılabilir kalır; yeni daemon yalnız bütün chunk receipt/range/row sayıları
eşleştiğinde batch'i public evidence tablolarına finalize eder. Source tarafındaki
metadata-only header list/chunk fonksiyonları versioned repository migration'ı
değildir; mevcut source volume'lerinde `scripts/enable-join-snapshotter.sh`
bunları rolling-compatible biçimde uygular.

`0011`, aynı source batch içinde `pg_qualstats` tarafından aynı final doğal
anahtarla üretilebilen birden çok ham satırı destekler. Staging kimliği yalnız
`chunk_no + row_in_chunk` ham konumudur; batch'in `row_count` değeri ham taşıma
sayısını korur. Finalize aşaması tekrarları doğal anahtarda deterministik olarak
birleştirir ve `occurences`, `execution_count`, `nbfiltered` sayaçlarını toplar.
Toplam `bigint` sınırını aşarsa batch public tabloya kısmen yazılmadan SQLSTATE
`22003` ile durur ve source ack edilmez. Rolling upgrade için korunan
`ingest_join_batch()` da aynı toplama kuralını uygular.

`0012`, binlerce fingerprint bulunan ERP repository'lerinde query-list
hesabının ölçek davranışını düzeltir. `powa_statements_history_current` artık
her sorgu serisi için iki ayrı index probe ile değil, tek set-wise taramayla
okunur; pencere öncesindeki son predecessor yine deterministik olarak korunur.
Planner'ın düşük set-returning-function tahmini yüzünden CPU/wait CTE'lerini
milyonlarca kez nested-loop ile karşılaştırması yalnız
`advisor.query_metrics(interval)` çağrısı içinde kapatılır. Çağıranın session
ayarı değişmez; fonksiyon imzası, grant'leri, reset/gap ve çok-rollü coverage
semantiği korunur. Migration checksum-frozen `0009` gövdesini yalnız beklenen
fragment tam bir kez bulunursa değiştirir, özelleştirilmiş/beklenmeyen şemada
fail-closed durur.

`0013`, overview ve query-detail trendlerini genel amaçlı delta fonksiyonunun
dışında tekrar gruplatmak yerine repository içinde doğrudan zaman kovalarına
indirger. Global ve tam sorgu kimliğiyle scoped iki overload bulunur. Scoped
çağrı server/database/query filtrelerini PoWA history/current taramalarına iter;
iki çağrı da her aktif seri için pencere öncesindeki tek gerçek predecessor'ı
okuyarak counter reset ve `3 x frequency` sınır-gap davranışını korur.

`0014`, ürün `1.1.0` scope/optimize yolları için scoped query-trend planını,
release bilgisini ve tablo yazma maliyeti sinyalini ekler. Bu migration uygulama
`1.1.0` ile birlikte yükseltilir; geri dönüş sınırı
[upgrade/rollback runbook'undadır](UPGRADE_ROLLBACK.md).

## Yeni migration ekleme

1. Mevcut migration dosyalarını değiştirmeyin. Özellikle
   `001_advisor_schema.sql`, bu migration sistemi yayımlandıktan sonra frozen
   baseline'dır.
2. İleri yönlü ve tekrar çalıştırılması güvenli bir SQL dosyası ekleyin.
3. Manifestin sonuna artan dört haneli sürüm, benzersiz ad, göreli dosya yolu ve
   SHA-256 ekleyin.
4. Transaction dışında çalışması gereken `CREATE INDEX CONCURRENTLY`, `VACUUM`
   gibi komutları doğrudan migration'a koymayın. Runner bütün batch'i tek
   transaction olarak uygular.
5. Unit testi ve Compose doğrulamasını çalıştırın:

```bash
python3 -m unittest deployment/repository/test_migration_runner.py -v
docker compose config --quiet
```

Checksum sapmasını çözmek için uygulanmış dosyanın hash'ini güncellemek doğru
değildir. Düzeltme yeni bir migration olarak eklenmelidir. Yedekten dönülen veya
elle değiştirilmiş bir repository önce ayrı bir ortamda incelenmelidir.
