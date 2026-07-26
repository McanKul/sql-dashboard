# Ana DB'de EXPLAIN ANALYZE ve görsel plan

Sorgu detayındaki **Ana DB'de EXPLAIN ANALYZE** işlemi, repository'de kalıcı
olan normalize SQL'i gerçek kaynak veritabanında yürütür. Browser SQL
gönderemez; yalnız sorgu kapsamı ve en fazla 128 geçici JSON scalar bind değeri
(`64 KiB` toplam JSON) gönderir. Advisor API/repository bu değerleri saklamaz;
ancak kaynak PostgreSQL'in `log_statement`, hata/audit veya extension loglama
politikası yürütülen `EXECUTE` metnini kaydedebilir. Hassas üretim değerleri
girmeden önce DBA kaynak log politikasını doğrulamalıdır.

## Çalışma akışı

```text
browser
  -> repository-only API (persisted SQL + server/database scope çözümü)
  -> token-protected evaluator
  -> advisor_evaluator @ source database
       1. lexical single-SELECT kapısı
       2. BEGIN ... READ ONLY
       3. database name/OID + role/ACL/timeout attestation
       4. EXPLAIN (ANALYZE FALSE, VERBOSE, FORMAT JSON) preflight
       5. EXPLAIN (ANALYZE, VERBOSE, BUFFERS, WAL, TIMING, SETTINGS, FORMAT JSON)
       6. ROLLBACK
```

Kaynak DSN/parolası API container'ında bulunmaz. HypoPG'nin kısa planlama
timeout'u değişmez; gerçek çalışma ayrı `120s` statement, `125s` transaction,
`130s` API ve `320s` reverse-proxy zarfı kullanır. Değerler özelleştirilirken
`lock < statement < transaction < API < proxy` sırası korunmalıdır; backend
üst sınırları sırasıyla `30s / 300s / 305s / 310s`, proxy üst zarfı `320s`dir.
İlk dört değer `.env` üzerinden aşağıdaki ayarlarla değiştirilebilir:

- `SOURCE_EXPLAIN_TIMEOUT_SECONDS`
- `EVALUATOR_RUNTIME_STATEMENT_TIMEOUT_MS`
- `EVALUATOR_RUNTIME_LOCK_TIMEOUT_MS`
- `EVALUATOR_RUNTIME_TRANSACTION_TIMEOUT_MS`

Evaluator tek slot kullanır ve kuyruk biriktirmez: slot doluyken yeni istek
`SOURCE_EVALUATOR_BUSY` ile çalıştırılmadan döner. HTTP istemcisi bağlantıyı
kesse bile başlamış libpq worker tamamlanana kadar slot bırakılmaz. Healthcheck
bu sırada evaluator'ı `busy` ve sağlıklı gösterir.

## Kabul edilen sorgular

Yalnız tek statement olan, final komutu `SELECT` olan read-only sorgular kabul
edilir. DML/DDL, DML CTE, `SELECT INTO`, row lock (`FOR UPDATE/SHARE`), birden
fazla statement, `U&"..."` Unicode identifier yazımı ve quoted/unquoted açık
denylist'teki yan etkili PostgreSQL rutinleri ANALYZE öncesinde reddedilir.
İkinci bağlantıda yerel read-only transaction'ı aşabilen bütün `dblink*`
çağrıları bu kapıya dahildir. `pg_stat_statements` tarafından
`interval $N`, `date $N`, `time $N` veya `timestamp $N` biçiminde normalize
edilen temporal ve yaygın built-in typed literal'lar yalnız yorum/string
dışındaki SQL tokenlarında eşdeğer cast'e çevrilir. Bind değerleri SQL'e string
birleştirmeyle eklenmez; PostgreSQL
`PREPARE`/`EXECUTE` ve psycopg literal adaptasyonu kullanılır.

PostgreSQL'in kendi dokümantasyonuna göre `EXPLAIN ANALYZE` sorguyu gerçekten
çalıştırır. Bu nedenle kaynak CPU, I/O, cache ve lock yükü gerçektir. `READ ONLY`
transaction ve düşük yetkili rol tablo yazılarını engeller; yine de harici yan
etkisi olan kullanıcı tanımlı bir fonksiyon bütün olası kurulumlarda statik
olarak kanıtlanamaz. Endpoint bu nedenle genel internete açılacaksa gerçek
kimlik doğrulama, rate limit ve kurum SQL politikası arkasına alınmalıdır.

Ölçüm `advisor_evaluator` rolüyle yapılır; özgün uygulama rolü, search path'i ve
session GUC'leri taklit edilmez. RLS veya session-context bağımlı sorgularda plan
uygulama oturumuyla birebir olmayabilir. Ayrıca PostgreSQL'in raporladığı
execution time, sonuç satırlarının istemciye ağ üzerinden taşınmasını içermez.

Rolün veri erişimi explicit bir zarf olmalıdır. Demo/Compose hedefinde
`ADVISOR_EVALUATOR_READ_SCHEMAS=public,advisor_erp bash scripts/enable-hypopg.sh`
komutu yapılandırılan şemalarda doğrudan ACL drift'ini temizler; yalnız şema
`USAGE` ve mevcut tablolarda `SELECT` verir. Şema sahibi, mevcut tablo sahipleri
ve provisioning rolü için gelecek tabloların default privilege'ı da `SELECT`
olarak ayarlanır. Daha sonra farklı bir owner tablo oluşturacaksa DBA bu owner'ı
ayrıca kapsamalı veya script'i yeniden çalıştırmalıdır. Virgülle ayrılan adlar
basit PostgreSQL identifier olmalı; sistem şemaları kabul edilmez. Uzak kaynakta
aynı dar grant modeli DBA tarafından hedef database üzerinde uygulanır.

Kaynaklar: [PostgreSQL EXPLAIN](https://www.postgresql.org/docs/18/sql-explain.html),
[Using EXPLAIN](https://www.postgresql.org/docs/18/using-explain.html).

## Görsel plan

PostgreSQL JSON çıktısı doğal bir plan-node ağacıdır. Dashboard bu ağacı ham
JSON yerine önce interaktif bir grafikte gösterir:

- pan, zoom, ekrana sığdır ve yön değiştirme;
- süre, satır-tahmin sapması, maliyet ve I/O odak modları;
- tablo/index, actual/planned rows, loop, buffer, temp ve WAL rozetleri;
- seçilen node için koşullar ve özet metrikler; bütün alanlar için ham JSON;
- en ağır node, cardinality sapması ve temp/filter darboğaz özetleri;
- büyük ERP planlarında dal açma/kapama ve minimap;
- hata ayıklamak için ikincil, lazy açılan ham JSON.

Araştırmada [PEV2](https://github.com/dalibo/pev2) node vurguları ve plan UX'i
için referans alındı. PEV2 olgun bir PostgreSQL görselleştiricisidir ancak Vue,
Bootstrap ve kendi global UI durumunu getirir. Mevcut React uygulamasında CSS ve
runtime çakışması oluşturmamak için hosted servise plan göndermek veya Vue
component gömmek yerine, aynı fikirler yerel
[React Flow custom node](https://reactflow.dev/learn/customization/custom-nodes)
ve [Dagre tree layout](https://reactflow.dev/examples/layout/dagre) ile
uygulandı. Plan verisi üçüncü taraf bir servise gönderilmez. Dalibo'nun hosted
servisi planları saklayabildiğini açıkça belirttiği için hassas ERP planları oraya otomatik
gönderilmez: [explain.dalibo.com veri sınırı](https://explain.dalibo.com/about).

## Response sözleşmesi

Başarılı cevap şu kanıtları taşır:

```json
{
  "status": "RUNTIME_VALIDATED",
  "executionTarget": "SOURCE_DATABASE",
  "sourceExecuted": true,
  "sourceDdlExecuted": false,
  "transactionRolledBack": true,
  "validation": {
    "statementClass": "READ_ONLY_SELECT",
    "planPreflight": "READ_ONLY",
    "transactionReadOnly": true,
    "executionRole": "advisor_evaluator",
    "databaseId": 16384,
    "plan": { "Plan": { "Node Type": "Aggregate" } }
  }
}
```

API–evaluator HTTP bağlantısı başarısız olursa çalışma ve rollback durumu kesin
olarak bilinemeyeceği için `sourceExecuted` ve `transactionRolledBack` alanları
`null` döner; arayüz bunu başarılı güvenlik kanıtı gibi sunmaz.
