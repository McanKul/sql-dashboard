# Upgrade ve rollback runbook'u

Bu runbook aynı PostgreSQL major sürümünde SQL Dashboard `1.1.1` ve repository
şema `0016` için güvenli yükseltme sınırını tanımlar. Üretimde image'ları sürüm
ve digest ile sabitleyin. Önce staging restore provası yapın.

> **Uyarı:** `dropdb`, `docker compose down --volumes` ve yanlış Compose proje
> adı kalıcı veri kaybına yol açar. Yedek checksum'u, hedef proje, veritabanı ve
> volume kimlikleri doğrulanmadan silme veya restore çalıştırmayın.

## 1. Ön kontrol ve yedek

Aktif sürüm, migration ledger ve hedefleri kaydedin:

```bash
cat VERSION
docker compose config --quiet
docker compose exec -T repository-db \
  psql -X -U postgres -p 5433 -d powa_repository -AtF '|' -v ON_ERROR_STOP=1 \
  -c "SELECT version,name,checksum,installed_at FROM advisor_migrations.schema_migrations ORDER BY version"
```

Tutarlı repository yedeği alın ve checksum'u ayrı kaydedin:

```bash
bash scripts/backup-repository.sh
dump_path="$(ls -1t backups/powa_repository-*.dump | head -n 1)"
shasum -a 256 "$dump_path" | tee "${dump_path}.sha256"
docker compose exec -T repository-db \
  pg_restore --list < "$dump_path" >/dev/null
```

Linux'ta `shasum` yerine `sha256sum` kullanın. Dump; `.env`, login parolaları,
collector pgpass dosyaları, TLS anahtarları ve kaynak veritabanını içermez.

## 2. Writer'ları durdur ve migration'ı uygula

```bash
docker compose stop collector join-snapshotter api web
docker compose ps
bash scripts/migrate-repository.sh
```

Migrator manifest checksum'larını doğrular, advisory lock alır ve bütün bekleyen
migration'ları tek transaction içinde uygular. Hata olursa bu transaction geri
alınır; hatayı düzeltmeden servisleri açmayın.

Ledger hedefi doğrulayın:

```bash
docker compose exec -T repository-db \
  psql -X -U postgres -p 5433 -d powa_repository -AtF '|' -v ON_ERROR_STOP=1 \
  -c "SELECT max(version),count(*) FROM advisor_migrations.schema_migrations"
```

`1.1.1` için beklenen son sürüm `0016` olmalıdır.

## 3. Servisleri aç, doğrula ve cutover yap

```bash
docker compose up -d collector join-snapshotter evaluator query-metrics-snapshot-worker
# 1h ve 24h state satırları ready olduktan sonra:
docker compose up -d api web
docker compose ps
curl -fsS http://127.0.0.1:8000/api/v1/health
bash scripts/verify.sh
```

Health yanıtında uygulama `1.1.1`, migration `current=expected=0016` ve
`upToDate=true` bekleyin. Collector için yeni snapshot zamanı ilerlemeden ve
web/API smoke testi geçmeden trafiği açmayın. Dış source bağlantılarını alias,
database OID ve capability kapsamıyla yeniden doğrulayın.

## Başarısız yükseltme

- Migration transaction'ı başarısızsa şema otomatik geri alınır. Logu saklayın,
  ileri yönlü düzeltme hazırlayın ve migrator'ı tekrar çalıştırın.
- Migration başarıyla commit edildiyse desteklenen bir **down migration yoktur**.
  Tercih edilen yol ileri yönlü düzeltmedir.
- Eski uygulamayı yalnız yayımlanmış uyumluluk tablosu o uygulama sürümünün
  mevcut şemayı okuyabildiğini açıkça söylüyorsa yeniden deploy edin.

## Yedekten geri dönüş

Başarılı migration sonrası gerçek rollback gerekiyorsa üretim repository'si
üzerine doğrudan restore etmeyin. Yedeği ayrı Compose projesinde ve ayrı volume'de
restore edin; checksum, ledger `0013`, server/snapshot/annotation/audit sayıları
ile en eski-yeni snapshot zamanlarını doğrulayın. Ardından writer'lar kapalıyken
kontrollü cutover yapın.

```bash
COMPOSE_PROJECT_NAME=advisor-rollback-verify docker compose up -d repository-db
# Ayrı doğrulama veritabanına pg_restore; hedef kimliği ve checksum ikinci kez doğrulanır.
```

Eski ve yeni repository'ye aynı anda collector veya snapshotter yazdırmayın.
Kaynak PostgreSQL rollback'u bu dump'ın kapsamı dışındadır; kendi PITR/yedekleme
prosedürüyle yönetilmelidir.
