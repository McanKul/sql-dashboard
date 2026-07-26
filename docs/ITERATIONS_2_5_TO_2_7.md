# İterasyon 2.5–2.7: JOIN snapshot, composite aday ve disposable clone

Bu runbook üç hattı birlikte açıklar:

- `2.5`: PoWA 5.2'nin taşımadığı kolon-kolon JOIN predicate'lerini kaybetmeden alma
- `2.6`: JOIN ile aynı sorgu/tablodaki WHERE kanıtından iki kolonlu B-tree sırası üretme
- `2.7`: planner tarafından doğrulanmış adayı izlenen kaynağa dokunmadan gerçek index ile ölçme

Ana güvenlik kuralı değişmez: FastAPI yalnız repository DSN'i alır. HypoPG evaluator kaynakta salt-okunur planlama yapar. Gerçek DDL ise yalnız clone ağı ve clone credential'ı olan ayrı evaluator'da çalışır.

## 2.5 veri akışı ve teslim garantisi

Stock PoWA snapshot'ı `powa_qualstats_src()` ile WHERE/filter kayıtlarını taşır ve ardından `pg_qualstats_reset()` çağırır. JOIN kaydını resetten önce başka bir poller ile okumak yarış koşulu oluşturur. Bu sürüm `query_cleanup` değerini source tarafındaki şu wrapper'a çevirir:

```text
PoWA remote snapshot transaction
  -> advisor_join.capture_and_reset()
       1. pg_qualstats() tek MATERIALIZED okumada alınır
       2. JOIN içeren sorguların JOIN + ilgili WHERE satırları outbox'a yazılır
       3. aynı transaction içinde pg_qualstats_reset() çağrılır

join-snapshotter
  -> source advisor_join.list_batch_headers() (bounded, payload içermez)
  -> source advisor_join.fetch_batch_chunk() (tek seferde <=10.000 satır / <=8 MiB)
  -> repository advisor_ingest.ingest_join_chunk() (idempotent staging)
  -> bütün parçalar tam ve bitişikse advisor_ingest.finalize_join_batch()
  -> repository finalize commit başarılıysa source advisor_join.ack_batch()
```

Capture/reset hâlâ tek atomik source transaction'ıdır; transport parçalama bu
sınırı değiştirmez. Repository hatasında source batch silinmez. Her parça
`server_id + batch_id + chunk_no` ve SHA-256 payload kimliğiyle idempotenttir.
Kısmi parçalar public evidence tablolarında görünmez. Finalize sonrasında process
çökerse parçalar tekrar no-op teslim edilir ve source batch daha sonra ack edilir.
Bir snapshot ne kadar büyük olursa olsun snapshotter belleğinde aynı anda yalnız
bir parça tutulur. Header listesi içindeki her batch ayrı hata sınırıdır: bozuk
veya geçici olarak başarısız bir batch ack edilmeden source'da kalırken aynı
bounded cycle'daki sonraki batch'ler ilerleyebilir. Source hiçbir ack edilmemiş
batch'i zamana bağlı olarak sessizce silmez; outbox yaşı/boyutu izlenmeli ve kök
neden giderilmelidir. Repository'de finalize edilmiş tarihçe ve terk edilmiş
private staging için varsayılan 30 günlük retention uygulanır.

`pg_qualstats` tek reset sınırında final repository doğal anahtarı aynı olan
birden çok ham kayıt döndürebilir. Bu kayıtlar staging'de ham
`chunk_no + row_in_chunk` konumlarıyla ayrı tutulur; transport completeness ve
batch `row_count` hesabı bu ham sayı üzerinden yapılır. Yalnız atomik finalize
aşamasında aynı doğal anahtar bir satıra indirilir, üç sayaç toplanır ve diğer
metadata alanları kararlı minimum/boolean birleşimiyle seçilir. Sayısal taşma
veya final insert cardinality farkı tüm finalize işlemini fail-closed geri alır;
source batch ack edilmeden yeniden denenebilir kalır.

Source'un güvenliği veri kaybını sessizce kabul etmeye bırakılmaz. Her
`capture_and_reset()` çağrısının ilk adımı ack'siz outbox için üç strict decimal
GUC'u doğrular ve ölçer: `advisor_join.max_outbox_rows` (varsayılan `1000000`),
`advisor_join.max_outbox_bytes` (varsayılan `1073741824`) ve
`advisor_join.max_outbox_age_seconds` (varsayılan `300`). Bir eşik dolduğunda
fonksiyon SQLSTATE `54000` ile pending batch/satır/boyut/yaş ayrıntısını verir;
o transaction yeni outbox satırı yazmaz ve `pg_qualstats_reset()` çağırmaz.
Repository'deki collector errors alanı dolduğu için ürün health'i `DEGRADED`
olur. Snapshotter mevcut batch'leri finalize edip source'da ack ettiğinde canlı
kuyruk sıfırlanır ve sonraki collector turu ek bakım gerektirmeden ilerler.

Roller birbirinden ayrıdır:

| Rol | Erişim |
|---|---|
| `powa_collector` | `capture_and_reset()`; doğrudan reset yetkisi kaldırılır |
| `advisor_join_reader` | Source header list/chunk fetch, eski istemci için `fetch_batches()` ve `ack_batch()` |
| `advisor_join_ingest` | Yalnız bağlandığı source için chunk ingest/finalize, status ve source-retention wrapper'ları |
| `advisor_api` | Yalnız public adapter fonksiyonları; private ingest şemasına erişemez |

Local Compose iki farklı parola kullanır: `ADVISOR_JOIN_SOURCE_PASSWORD` ve `ADVISOR_JOIN_REPOSITORY_PASSWORD`. Repository login'i `JOIN_SOURCE_ALIAS` ile eşleşen tek `PoWA.powa_servers` kaydına `session_user` üzerinden bağlanır; request içindeki başka bir alias ingest, error ve purge çağrılarında fail-closed reddedilir. Global purge yalnız repository DBA bakım işidir. Her dış kaynak ayrı repository login/binding ve ayrı snapshotter deployment'ı kullanmalıdır. Üretimde parolaları collector/API/DBA parolalarıyla paylaşmayın. Snapshotter DSN'leri `_FILE` environment varyantlarıyla secret mounttan da okunabilir; DSN ve row payload loglanmaz.

Chunk üst sınırları protokol sabitidir; iki uç farklı environment değerleriyle
ayrışamaz. `JOIN_BATCH_LIMIT` aynı anda tutulan payload sayısı değil, tek cycle'da
tamamlanacak source batch sayısıdır. Compose daemon için varsayılan 256 MiB memory
envelope kullanır; her fetch yalnız bir en fazla 8 MiB JSONB parçayı materialize eder.

## 2.6 aday kuralları

İlk bilinçli kapsam tam olarak iki key kolonudur:

1. Aynı sorguda ve tabloda B-tree equality JOIN (`strategy=3`) görülür.
2. Farklı bir kolon üzerinde B-tree WHERE equality veya range (`strategy=1..5`) görülür.
3. Kanıt en az iki snapshot, beş JOIN occurrence ve beş filter occurrence içerir.
4. Katalogdan schema/table/kolon adları çözülemiyorsa aday üretilmez.

Aynı normalize `query_id` birden fazla PostgreSQL rolünce çalıştırılırsa JOIN ve
filter sayaçları ürünün `server + database + query_id` kimliğinde birleştirilir;
tek batch içinde tek aday ve tek evidence satırı üretilir.

Sıra kuralı API'de `orderingRule` olarak görünür:

- `SELECTIVE_EQUALITY_FILTER_THEN_JOIN`: equality WHERE filtresi en az `%20` eleme kanıtı taşıyorsa önce filtre
- `EQUALITY_JOIN_THEN_RANGE_FILTER`: range filtresinde önce equality JOIN, sonra range
- `EQUALITY_JOIN_THEN_FILTER`: diğer equality durumda önce JOIN, sonra filtre

Bu heuristic kesin fayda iddiası değildir. `scoreIncluded=false` kalır. Kullanıcı HypoPG doğrulaması istediğinde evaluator canlı katalogda aynı kolon sırasıyla başlayan geçerli B-tree index olup olmadığını kontrol eder; sonra composite sanal indexi gerçekten kullanan planı ve varsayılan `%10` planner-cost düşüşünü arar.

Endpoint:

```text
GET  /api/v1/queries/{queryId}/predicates?serverId=...&databaseId=...
POST /api/v1/queries/{queryId}/composite-index-evaluations?window=24h
```

İkinci endpoint yalnız repository'den yeniden yüklenen `candidateId` kabul eder; client SQL, schema, table veya kolon adı gönderemez.

## 2.7 disposable clone profili

Varsayılan `docker compose up` gerçek DDL servisini başlatmaz. Local demo template'i tmpfs üzerinde açmak için:

```bash
docker compose --profile real-validation up -d clone-db clone-evaluator
docker compose --profile real-validation ps
```

`CLONE_SOURCE_ALIAS` repository'deki kaynak alias'ıyla birebir eşleşmelidir
(demo varsayılanı `test-source`). Aynı isimli veritabanına sahip başka bir
kaynak yanlış template üzerinde çalıştırılamasın diye bu kimlik ve
`CLONE_TEMPLATE_DATABASE` manifestte saklanır; evaluator request, ayar ve
manifest üçlüsünü job oluşturmadan önce karşılaştırır.

### Dashboard'dan doğrudan sorgu planı

**Sorgular** ekranında bir sorgu detayını açın. Normalize SQL kartının altındaki
**Clone'da EXPLAIN ANALYZE** paneli composite aday, HypoPG sonucu veya replay
fixture gerektirmez. Parametresiz sorgu doğrudan çalışır. `$1...$N` içeren bir
sorguda panel exact sayıda JSON scalar değer ister; örneğin:

```json
["paid", 42]
```

Browser serbest SQL göndermez. API `serverId`, `databaseId` ve `queryId` ile
repository'deki exact persisted SQL'i çözer; en fazla 16 bind değeri yalnız istek
boyunca bellekte taşınır ve kalıcılaştırılmaz. Clone evaluator tek bir
`advisor_query_*` database oluşturur, runner policy/plain-plan preflight'ından
sonra bir kez gerçek `EXPLAIN ANALYZE` çalıştırır ve database'i koşulsuz temizler.
Bu yolda gerçek index veya başka DDL yoktur; sonuç
`executionTarget=DISPOSABLE_CLONE`, `sourceDdlExecuted=false` ve
`cloneDdlExecuted=false` taşır.

Aynı çağrının HTTP karşılığı:

```bash
curl -fsS -X POST \
  -H 'Content-Type: application/json' \
  -H 'X-Advisor-Role: analyst' \
  -d '{"serverId":1,"databaseId":16384,"bindValues":["paid"]}' \
  'http://127.0.0.1:8000/api/v1/queries/QUERY_ID/explain-analyze?window=24h'
```

Bu doğrudan çalıştırıcı tek-kullanıcılı, dış erişime kapalı ve loopback ile sınırlı yerel kurulum için
açıktır; ek admin/Bearer kapısı yoktur. Örnekteki `analyst` header'ı yalnız
referans UI'ın tam SQL görünürlüğünü yansıtır. Web/API portunu uzaktan erişime açarsanız endpoint'i gerçek kimlik
doğrulama, rate limit ve kurum network policy katmanı arkasına alın.

### Gerçek-index karşılaştırma yolu

Sorgu detayında önce **Composite adayı doğrula** ile `VALIDATED` aday üretilir.
Browser server-side admin secret'ını taşımaz ve kendi kendine runtime yetkisi
veremez. UI yalnız operator fixture'ının hazır olup olmadığını gösterir. DBA exact
persisted candidate ve repository'deki exact normalize SQL için sentetik veya
kurum prosedürüne göre anonimleştirilmiş scalar fixture'ı önce private registry'ye
kaydeder:

```bash
printf '%s\n' '["paid"]' | bash scripts/register-runtime-replay-fixture.sh \
  --candidate-id CANDIDATE_ID \
  --values-file - \
  --approved-by dba-operator \
  --ticket PERF-1234 \
  --value-class SYNTHETIC
```

`--expires-at` verilmezse kayıt scripti yedi günlük süre atar; daha kısa kurum
politikasında gelecekteki ISO-8601 zamanını açıkça verin.

Public runtime endpoint'i daha sonra yalnız güvenilir yerel/operator istemcisi,
admin rolü ve token'la çağırır; client SQL veya bind değeri göndermez. Endpoint
fixture hash/identity/expiry kontrolünden sonra aynı persisted adayı HypoPG ile
yeniden doğrular:

```bash
export ADVISOR_API_TOKEN='SECRET_MANAGERDAN_ALINAN_RAW_TOKEN'
curl -fsS -X POST \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer ${ADVISOR_API_TOKEN:?api token gerekli}" \
  -d '{"serverId":1,"databaseId":16384,"candidateId":"CANDIDATE_ID"}' \
  'http://127.0.0.1:8000/api/v1/queries/QUERY_ID/runtime-index-validations?window=24h'
```

Clone evaluator iki rastgele job database oluşturur. Baseline ve candidate aynı `appdb` template'inden fiziksel kopyadır. Gerçek B-tree yalnız candidate kopyada oluşturulur; warm-up sonrasında yalnız güvenlik kapılarını geçen tek salt-okunur `SELECT` için baseline/candidate `EXPLAIN ANALYZE` koşuları dönüşümlü yapılır ve median süreler karşılaştırılır. Sonuç ne olursa olsun runner transaction'ları rollback edilir, job database bağlantıları sonlandırılır ve database'ler düşürülür. Kaynak veritabanı hiçbir zaman replay veya DDL hedefi değildir.

Her yanıt şu güvenlik alanlarını taşır:

```json
{
  "ddlTarget": "DISPOSABLE_CLONE",
  "sourceDdlExecuted": false,
  "cloneDdlExecuted": true,
  "cloneDestroyed": true
}
```

`cloneDestroyed=false` ise ölçüm başarılı görünse bile sonuç `CLONE_CLEANUP_FAILED` olur ve operator temizliği gerekir.

Demo hattının bütününü tek komutla kabul etmek için normal `verify.sh` tamamlandıktan sonra:

```bash
bash scripts/verify-real-validation.sh
```

Bu script dashboard'daki fixture'sız tek-query yolunu, sentetik fixture kaydını,
admin gerçek-index çağrısını, `candidateIndexUsed=true`, kaynak index fingerprint'ini,
manifest policy revision/dangerous-routine kanıtını, canlı runner
rol/ACL/routine/foreign-server politikasını, doğrudan
DML/DDL/`SELECT INTO`/`nextval` negatif problarını ve bütün job database
cleanup'larını birlikte assert eder.

### Fail-closed replay kapsamı

`EXPLAIN ANALYZE` sorguyu gerçekten çalıştırır. `pg_stat_statements` normalize SQL'i `$1` gibi parametreleri değerleriyle birlikte saklamaz. Bu nedenle bu sürüm:

- yalnız tek bir salt-okunur `SELECT` çalıştırır; `WITH` ancak final komutu `SELECT` olan ve DML/DDL token'ı taşımayan tek statement kapsamında kabul edilir;
- ilk yapısal lexical/statement kapısında multi-statement, DDL/DML, `SELECT INTO`, DML CTE, row-lock biçimleri ve açık denylist'teki yan etkili routine adlarını reddeder. Lexical kapı sorgudaki bütün routine'leri volatility açısından sınıflandırmaz;
- job database oluşturmadan önce template manifestindeki beklenen runner policy revision'ını ve dangerous-routine hardening kanıtını doğrular;
- her runner transaction'ında exact kimlik/rol bayrakları ve üyeliği, aktif/default read-only durumu, timeout'lar, `row_security`, `search_path`, JIT, TEMP/CREATE yokluğu, dangerous routine `EXECUTE` yokluğu ve foreign-server `USAGE` yokluğunu atteste eder. Dangerous kapsamı volatile veya security-definer routine'leri, procedure'leri ve sistem şemaları dışında SQL/PLpgSQL harici dillerde tanımlı routine'leri içerir;
- doğrulanmış bind'lerle PostgreSQL plain `EXPLAIN` (`ANALYZE FALSE`) plan preflight'ı çalıştırır ve plandaki `ModifyTable`, `LockRows`, `Foreign Scan` veya `Custom Scan` düğümlerini reddeder; yalnız bu kapıdan sonra `EXPLAIN ANALYZE` çalışabilir. Her runner transaction'ı koşulsuz rollback edilir;
- hiçbir public client'tan serbest SQL kabul etmez; SQL her zaman repository'deki exact query kimliğinden gelir;
- doğrudan dashboard yolu bind değerlerini request'te JSON scalar olarak kabul eder fakat kaydetmez; gerçek-index karşılaştırma yolu browser bind'i kabul etmez;
- gerçek-index karşılaştırma fixture'ını exact candidate, server/database/query kimliği ve normalize SQL SHA-256 değeriyle eşleştirir; disabled, expired veya hash'i değişmiş kayıt `REPLAY_FIXTURE_REQUIRED` döndürür;
- en fazla 16, `$1`'den başlayan bitişik parametre ve aynı sayıda JSON scalar kabul eder; toplam fixture 8 KiB, her string 2.048 karakter ile sınırlıdır;
- değer sınıfını `SYNTHETIC`/`ANONYMIZED`, onaylayan operatoru, ticket'ı, onay/expiry zamanını private tabloda tutar; `advisor_api` tabloyu doğrudan okuyamaz;
- bind değerlerini ham SQL'e birleştirmez; doğrulanmış prepared statement'ın `EXECUTE` argümanları psycopg'un type-aware literal adaptörüyle güvenli biçimde üretilir. Clone cluster failed-statement ve bind metnini Docker loguna yazmayacak şekilde başlatılır.

Gerçek-index karşılaştırmasında parametresiz sorgu için de fixture kaydı açık
olmalıdır ve JSON değeri `[]` olur. Doğrudan dashboard yolunda parametresiz sorgu
fixture olmadan çalışır.

### Ağ ve credential sınırı

```text
source-db <-> evaluator                 (evaluator_source)
repository-db <-> api                  (advisor)
source-db <-> join-snapshotter          (join_source, internal)
join-snapshotter <-> repository-db      (join_repository, internal)
api <-> clone-evaluator                (clone_control)
clone-evaluator <-> clone-db           (clone_data)
```

`join-snapshotter` ana `advisor` ağına katılmaz. `api` clone DB credential'ı ve `clone_data` ağı almaz. `clone-evaluator` source/repository DSN'i veya bu ağları almaz; bu nedenle kaynak hiçbir koşulda runtime test veya DDL hedefi olamaz. `clone-db` her bağlantıda `advisor.validation_clone=on` marker'ı taşır; evaluator beklenen admin/runner kimliğini, template işaretini ve manifestteki runner policy revision/dangerous-routine kanıtını doğrular. Job database'deki gerçek rol/üyelik/ACL/routine/foreign-server durumu her runner transaction'ında ayrıca atteste edilir. Eksik, eski veya uyuşmayan değer işi fail-closed durdurur. PostgreSQL container'ına tmpfs bootstrap için yalnız sahiplik ve uid/gid geçiş capability'leri geri verilir; clone evaluator bütün Linux capability'lerini düşürür.

Local template sentetik demo verisidir. PostgreSQL archive restore işlemi archive sahibinin seçtiği kodu bootstrap yetkileriyle çalıştırabilir; `--no-owner` ve `--no-privileges` archive'ı sanitize etmez. Bu nedenle üretim benzeri testte yalnız güvenilir kaynaktan alınmış, önceden hazırlanmış, erişimi kısıtlı ve gerekiyorsa anonimleştirilmiş clone/restore kullanın. Clone ağı dış egress'e kapalıdır; plan kapısı foreign/custom scan'i de reddeder. Gerçek-index karşılaştırma endpoint'i `admin` rollü, server-side hash registry'de doğrulanan Bearer principal ister. Doğrudan dashboard sorgu endpoint'i tek-kullanıcılı loopback dağıtımında açıktır. Genel kullanıma açmadan TLS, gerçek kimlik doğrulama, rate limit, audit retention, kaynak veri sınıflandırması ve kapasite sınırı ekleyin. Yerel PAT modeli SSO değildir; ayrıntılar [AUTHENTICATION.md](AUTHENTICATION.md) içindedir.

## Mevcut demo volume'ünü 2.5–2.6'ya geçirme

Named volume üzerinde Docker init dosyaları yeniden çalışmaz. Önce yeni Compose tanımının source/repository mount ve environment değerleriyle container'ları yeniden oluşturun; ardından idempotent geçişi çalıştırın:

```bash
docker compose up --build -d --force-recreate source-db repository-db
bash scripts/enable-join-snapshotter.sh
docker compose up -d --force-recreate evaluator api web
```

Script mevcut uygulama verisini ve PoWA geçmişini silmez. Ayrı source/repository snapshotter rollerini oluşturur veya parolalarını döndürür, repository login'ini `test-source` server kimliğine bağlar, atomik capture/reset wrapper'ını ve repository adapter'ını yeniden uygular, doğrudan tablo/global-purge/reset yetkilerinin kapalı olduğunu doğrular. Son olarak collector'ı iki kısa kabul burst'ü boyunca kontrollü durdurup başlatarak iki non-empty JOIN snapshot'ı, at-least-once aktarımı ve persisted composite aday oluşumunu kanıtlar. Bu otomatik workload kabulü yalnız Compose içindeki `test-source` demo kaydı içindir; haricî kaynak hazırlığı `register-source.sh --prepare`, ayrı bound repository login'i ve kaynak başına ayrı snapshotter deployment'ı gerektirir.

## Kabul kontrolleri

```bash
# Snapshotter process/unit
docker build -t postgresql-advisor/join-snapshotter:iteration-2.5 \
  -f deployment/join-snapshotter/Dockerfile .

# Bütün default stack
bash scripts/verify.sh

# Opsiyonel clone servis sağlığı
docker compose --profile real-validation exec -T clone-db \
  psql -U clone_admin -d postgres -Atqc \
  "SELECT current_setting('advisor.validation_clone', true), count(*) FROM pg_database WHERE datname LIKE 'advisor_%';"
```

İş olmayan durumda `advisor_%` job database sayısı sıfır olmalıdır. Template üzerinde candidate index kalmamalıdır.
