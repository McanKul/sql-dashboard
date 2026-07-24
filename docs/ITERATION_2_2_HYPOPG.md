# İterasyon 2.2 — HypoPG plan doğrulaması

## Durum ve kapsam

Bu iterasyon tamamlandı. PostgreSQL 18 image'ı, tam commit ve SHA-256 ile sabitlenen **HypoPG 1.4.3** içerir. Sorgu detayındaki WHERE gözlemi kullanıcı isteğiyle kaynak veritabanında doğrulanır; gerçek index oluşturulmaz.

İlk güvenli kapsam bilinçli olarak dardır:

- yalnız `SELECT`/`WITH` ile başlayan tek statement;
- yalnız PoWA/pg_qualstats tarafından çözümlenmiş `FILTER` türündeki tek kolonlu predicate;
- yalnız B-tree uyumlu operator ve tek kolonlu B-tree adayı;
- yalnız evaluator için açıkça izin verilen server alias ve uygulama veritabanı;
- referans Compose kurulumunda `test-source` / `appdb`.

`INSERT`, `UPDATE`, `DELETE`, `MERGE`, JOIN/composite adayları, expression/partial/covering indexler ve RLS etkin tablolar bu iterasyonda doğrulanmaz. Mevcut geçerli B-tree index aynı kolonla başlıyorsa yeni SQL önerilmez.

## Doğrulama akışı

```text
repository WHERE kanıtı
  -> POST /api/v1/queries/{query_id}/index-evaluations
  -> ayrı evaluator servisi
  -> aynı kaynak bağlantısında baseline plain EXPLAIN
  -> hypopg_create_index() ile yalnız sanal index
  -> aynı bağlantıda ikinci plain EXPLAIN
  -> plan kullanımı + planner cost + tahmini boyut karşılaştırması
  -> hypopg_reset() + bağlantıyı kapatma
```

HypoPG nesnesi yalnız evaluator'ın backend oturumunda yaşadığı için oluşturma ve iki plan aynı bağlantıda çalıştırılır. Parametre içeren normalize sorgularda PostgreSQL 18 `GENERIC_PLAN`; parametresiz sorgularda plain plan kullanılır. Her iki durumda da komut **`EXPLAIN ANALYZE` değildir**: sorgu yürütülmez, gerçek süre ölçülmez ve DML yan etkisi oluşmaz.

Varsayılan olarak sanal indexin planda kullanılması ve planner toplam maliyetini en az `%10` düşürmesi gerekir. Planner cost süre değildir; sonuç yalnız PostgreSQL istatistikleri ve planner varsayımları altında bir doğrulamadır. `hypopg_relation_size()` değeri de gerçek disk tüketimi değil, tahmini index boyutudur.

Endpoint sonuçları:

| Durum | Anlamı |
|---|---|
| `VALIDATED` | Sanal index kullanıldı ve yapılandırılmış maliyet düşüşü eşiği aşıldı. |
| `NO_IMPROVEMENT` | Eşdeğer index var veya sanal index yeterli plan faydası sağlamadı. |
| `INSUFFICIENT` | Predicate örneği/satır kanıtı henüz yeterli değil. |
| `UNSAFE` | Sorgu, tablo, kolon, operator veya kimlik eşleşmesi güvenli değil. |
| `UNAVAILABLE` | Kaynak/evaluator/HypoPG yapılandırılmamış ya da zaman aşımına uğradı. |

## SQL önerisi ile gerçek DDL arasındaki sınır

Yalnız `VALIDATED` sonucu `candidate.createIndexSql` alanını açar. Örnek çıktı şu biçimdedir:

```sql
CREATE INDEX CONCURRENTLY idx_advisor_orders_status_1234abcd
ON public.orders USING btree (status);
```

Bu metin kopyalanabilir bir DBA taslağıdır. Uygulama bu SQL'i çalıştırmaz; her cevapta `ddlExecuted=false` kalır. `hypopg_create_index()` çağrısına verilen `CREATE INDEX` de katalogda veya diskte index oluşturan gerçek DDL değil, yalnız oturum içi sanal index tanımıdır.

Canlıda çalıştırmadan önce DBA en az mevcut/örtüşen indexleri, tablo ve index boyutunu, yazma yükünü, bakım penceresini, `CREATE INDEX CONCURRENTLY` koşullarını ve üretim planını ayrıca incelemelidir. Bu iterasyon SQL rewrite, otomatik uygulama, rollback veya index silme önerisi değildir.

## Güvenlik sınırları

- Ana API repository-only kalır ve kaynak DSN'i taşımaz.
- Kaynağa yalnız ayrı `evaluator` servisi, `advisor_evaluator` rolüyle bağlanır.
- Rol `NOSUPERUSER`, `NOINHERIT`, `NOCREATEDB`, `NOCREATEROLE`, `NOREPLICATION`, `NOBYPASSRLS`, `CONNECTION LIMIT 2` ve `default_transaction_read_only=on` ile sınırlandırılır.
- HypoPG ayrı `advisor_hypopg` şemasındadır; PUBLIC schema/function yetkileri kaldırılır ve role yalnız gereken üç fonksiyon verilir.
- Planlama `REPEATABLE READ READ ONLY` transaction, statement/lock/idle/transaction timeout ve RLS kontrolü altında yapılır.
- API ile evaluator arasındaki iç endpoint token korumalıdır; evaluator container'ı salt-okunur filesystem, düşürülmüş capability ve iki internal network ile çalışır.
- İstemciden SQL, tablo veya kolon adı kabul edilmez. API bunları repository kanıtından çıkarır; evaluator canlı katalog OID'leri ve quote edilmiş identifier'larla tekrar doğrular.
- `advisor_evaluator`, `powa.ignored_users` listesinde tutulur; repository adapter'ı da bu rolün kayıtlarını dışlar. Böylece evaluator'ın kendi `EXPLAIN` sorguları izlenen sorgu metnini veya puanını değiştirmez.

## Kurulum ve mevcut volume

Temiz demo volume'ünde init script'i HypoPG extension'ını ve `advisor_evaluator` rolünü hazırlar. PostgreSQL 18'e daha önce taşınmış mevcut demo volume'ünde image'ı yeniledikten sonra bir kez çalıştırın:

```bash
bash scripts/enable-hypopg.sh
docker compose up -d --force-recreate evaluator api web
```

Script yalnız Compose içindeki `source-db/appdb` hedefini hazırlar; dış kaynağa bağlanmaz ve işletim sistemine extension binary'si kurmaz.

Bağımsız API kontrolü için predicate yanıtındaki gerçek kimlikleri kullanın:

```bash
curl -fsS -H 'X-Advisor-Role: analyst' \
  -H 'Content-Type: application/json' \
  -X POST \
  'http://localhost:8000/api/v1/queries/QUERY_ID/index-evaluations?window=24h' \
  -d '{"serverId":1,"databaseId":16384,"qualId":"QUAL_ID","relationId":RELATION_OID}'
```

Her başarılı veya olumsuz sonuçta `ddlExecuted=false` beklenir. SQL yalnız `status=VALIDATED` olduğunda bulunmalıdır.

## Dış kaynak sınırı ve runbook

Collector birden fazla dış PostgreSQL kaynağını izleyebilir; bu durum o kaynakların otomatik olarak HypoPG evaluator kapsamına girdiği anlamına gelmez. Mevcut referans dağıtım **tek evaluator DSN'i + tek izinli alias + tek izinli database** kullanır ve internal `evaluator_source` ağı yalnız demo `source-db` hedefine açıktır.

Bir dış kaynak için:

1. Hedef uygulama database'ini ve repository'deki sabit alias'ı belirleyin. Her database ayrı HypoPG extension nesneleri ve ayrı izin değerlendirmesi gerektirir.
2. Kaynak hosta PostgreSQL major sürümüyle uyumlu, sabitlenmiş HypoPG 1.4.3 binary'sini DBA yöntemiyle kurun; hedef database içinde extension'ı ayrı bir şemada oluşturun.
3. `scripts/enable-hypopg.sh` içindeki rol/revoke/grant modelini şablon alın; yalnız gereken şemalara `USAGE`, gereken tablolara `SELECT` ve üç HypoPG fonksiyonuna `EXECUTE` verin. Collector parolasını yeniden kullanmayın.
4. Dış hedefe yalnız TCP 5432 erişebilen ayrı evaluator deployment/network policy hazırlayın. Referans Compose'un internal demo ağını geniş internete açmayın; firewall allowlist kullanın.
5. Secret manager üzerinden `EVALUATOR_DATABASE_URL`, `EVALUATOR_ALLOWED_SERVER_ALIAS`, `EVALUATOR_ALLOWED_DATABASE` ve ayrı `EVALUATOR_TOKEN` tanımlayın. TLS için `verify-full` ve kurum CA'sı kullanın.
6. Evaluator health kontrolünde doğru database, `advisor_evaluator`, HypoPG `1.4.3` ve `default_read_only=on` değerlerini; dış API sonucunda da `ddlExecuted=false` koşulunu doğrulayın.

Tek API instance'ı şu anda yalnız bir `EVALUATOR_URL` kullanır. Birden fazla dış alias/database için evaluator registry/routing henüz yoktur; her hedefi varmış gibi göstermek yerine capability `UNAVAILABLE` kalmalıdır. Çoklu evaluator yönlendirmesi ayrı bir iterasyondur.

## Sabitlenen sürüm

- HypoPG `1.4.3`
- upstream commit `21d5461ad1868434cc47d9aa656d7afc2b24c464`
- commit archive SHA-256 `a57c34a0e2752176a1ba3d3b990cffe8ed8d65fccda96052a7f5605c274f554f`

Kaynaklar: [HypoPG 1.4.3](https://github.com/HypoPG/hypopg/releases/tag/1.4.3), [HypoPG kullanım dokümanı](https://hypopg.readthedocs.io/en/rel1_stable/usage.html), [PostgreSQL 18 EXPLAIN](https://www.postgresql.org/docs/18/sql-explain.html), [PostgreSQL 18 CREATE INDEX](https://www.postgresql.org/docs/18/sql-createindex.html).
