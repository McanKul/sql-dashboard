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
  -> source advisor_join.fetch_batches()
  -> repository advisor_ingest.ingest_join_batch()
  -> repository commit başarılıysa source advisor_join.ack_batch()
```

Repository hatasında source batch silinmez. Repository commitinden sonra process çökerse aynı batch tekrar gelir; `(server_id, batch_id)` anahtarı duplicate ingest'i etkisiz yapar ve batch daha sonra ack edilir. Outbox terk edilirse source tarafında yedi günlük üst sınır, repository tarafında varsayılan 30 günlük retention uygulanır.

Roller birbirinden ayrıdır:

| Rol | Erişim |
|---|---|
| `powa_collector` | `capture_and_reset()`; doğrudan reset yetkisi kaldırılır |
| `advisor_join_reader` | Source `fetch_batches()` ve `ack_batch()` |
| `advisor_join_ingest` | Yalnız bağlandığı source için repository ingest/status/source-retention wrapper'ları |
| `advisor_api` | Yalnız public adapter fonksiyonları; private ingest şemasına erişemez |

Local Compose iki farklı parola kullanır: `ADVISOR_JOIN_SOURCE_PASSWORD` ve `ADVISOR_JOIN_REPOSITORY_PASSWORD`. Repository login'i `JOIN_SOURCE_ALIAS` ile eşleşen tek `PoWA.powa_servers` kaydına `session_user` üzerinden bağlanır; request içindeki başka bir alias ingest, error ve purge çağrılarında fail-closed reddedilir. Global purge yalnız repository DBA bakım işidir. Her dış kaynak ayrı repository login/binding ve ayrı snapshotter deployment'ı kullanmalıdır. Üretimde parolaları collector/API/DBA parolalarıyla paylaşmayın. Snapshotter DSN'leri `_FILE` environment varyantlarıyla secret mounttan da okunabilir; DSN ve row payload loglanmaz.

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
# .env'deki degeri kopyalamak yerine tercihen secret manager'dan alin.
export RUNTIME_ADMIN_TOKEN='AYNI_GUCLU_RUNTIME_OPERATOR_TOKENI'
curl -fsS -X POST \
  -H 'Content-Type: application/json' \
  -H 'X-Advisor-Role: admin' \
  -H "X-Advisor-Admin-Token: ${RUNTIME_ADMIN_TOKEN:?runtime token gerekli}" \
  -d '{"serverId":1,"databaseId":16384,"candidateId":"CANDIDATE_ID"}' \
  'http://127.0.0.1:8000/api/v1/queries/QUERY_ID/runtime-index-validations?window=24h'
```

Clone evaluator iki rastgele job database oluşturur. Baseline ve candidate aynı `appdb` template'inden fiziksel kopyadır. Gerçek B-tree yalnız candidate kopyada oluşturulur; warm-up sonrasında baseline/candidate `EXPLAIN ANALYZE` koşuları dönüşümlü yapılır ve median süreler karşılaştırılır. Sonuç ne olursa olsun job database bağlantıları sonlandırılır ve database'ler düşürülür.

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

Bu script sentetik fixture kaydı, admin çağrısı, `candidateIndexUsed=true`, kaynak
index fingerprint'i, clone template manifesti ve job database cleanup'ını birlikte
assert eder.

### Fail-closed replay kapsamı

`EXPLAIN ANALYZE` sorguyu gerçekten çalıştırır. `pg_stat_statements` normalize SQL'i `$1` gibi parametreleri değerleriyle birlikte saklamaz. Bu nedenle bu sürüm:

- multi-statement, DML/DDL ve row-lock SELECT'i reddeder; yalnız tek `SELECT`/`WITH` çalıştırır;
- client'tan serbest SQL veya bind değeri kabul etmez;
- fixture'ı exact candidate, server/database/query kimliği ve normalize SQL SHA-256 değeriyle eşleştirir; disabled, expired veya hash'i değişmiş kayıt `REPLAY_FIXTURE_REQUIRED` döndürür;
- en fazla 16, `$1`'den başlayan bitişik parametre ve aynı sayıda JSON scalar kabul eder; toplam fixture 8 KiB, her string 2.048 karakter ile sınırlıdır;
- değer sınıfını `SYNTHETIC`/`ANONYMIZED`, onaylayan operatoru, ticket'ı, onay/expiry zamanını private tabloda tutar; `advisor_api` tabloyu doğrudan okuyamaz;
- bind değerlerini ham SQL'e birleştirmez; doğrulanmış prepared statement'ın `EXECUTE` argümanları psycopg'un type-aware literal adaptörüyle güvenli biçimde üretilir. Clone cluster failed-statement ve bind metnini Docker loguna yazmayacak şekilde başlatılır.

Parametresiz sorgu için de kayıt açık olmalıdır ve fixture JSON değeri `[]` olur.

### Ağ ve credential sınırı

```text
source-db <-> evaluator                 (evaluator_source)
repository-db <-> api                  (advisor)
source-db <-> join-snapshotter          (join_source, internal)
join-snapshotter <-> repository-db      (join_repository, internal)
api <-> clone-evaluator                (clone_control)
clone-evaluator <-> clone-db           (clone_data)
```

`join-snapshotter` ana `advisor` ağına katılmaz. `api` clone DB credential'ı ve `clone_data` ağı almaz. `clone-evaluator` source/repository DSN'i veya bu ağları almaz. `clone-db` her bağlantıda `advisor.validation_clone=on` marker'ı taşır; evaluator marker, tam admin/runner rolü, template işareti ve bootstrap manifestini DDL/ölçüm öncesinde tekrar doğrular. PostgreSQL container'ına tmpfs bootstrap için yalnız sahiplik ve uid/gid geçiş capability'leri geri verilir; clone evaluator bütün Linux capability'lerini düşürür.

Local template sentetik demo verisidir. Üretim benzeri testte aynı servisi yalnız önceden hazırlanmış, erişimi kısıtlı ve gerekiyorsa anonimleştirilmiş clone/restore üzerinde kullanın. `real-validation` profilini genel kullanıma açmadan gerçek kimlik doğrulama, rate limit, audit retention, kaynak veri sınıflandırması ve kapasite sınırı ekleyin. Server-side `RUNTIME_ADMIN_TOKEN` browser'ın admin rolünü kendi kendine ileri sürmesini engeller; kullanıcı kimliği/SSO değildir.

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
