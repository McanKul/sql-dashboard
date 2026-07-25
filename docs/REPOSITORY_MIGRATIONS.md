# Repository migration modeli

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
