# PDF v1.1 incelemesi

İncelenen belge: **PostgreSQL Sorgu Performansı ve Öneri Motoru — İlk İterasyon Teknik Mimari, Kurulum ve Uygulama Dokümantasyonu**, sürüm 1.1, 22 Temmuz 2026, 32 sayfa. Belgenin kopyası repoda: [swl_dashboard.pdf](swl_dashboard.pdf).

## Sonuç

PDF'nin ana mimari kararı doğrudur ve bu repoda uygulanmıştır: tek test hostunda iki bağımsız PostgreSQL instance, PoWA remote mode collector, ayrı repository, repository-only FastAPI ve özel web arayüzü. İlk iterasyon hedefinin otomatik düzeltme üretmek yerine yüksek etkili sorguları sıralamak olması da doğru kapsam seçimidir.

Belge doğrudan uygulanabilir bir temel sağlıyor; fakat container çalışması ve güncel PoWA davranışı için aşağıdaki düzeltmeler gereklidir. Repo bu düzeltmeleri uygular.

## Doğru bulunan kararlar

| PDF kararı | Değerlendirme | Repodaki karşılığı |
|---|---|---|
| Tek test hostu, iki PostgreSQL instance | Doğru | `source-db:5432`, `repository-db:5433` |
| PoWA remote mode ve hazır collector | Doğru | `collector` servisi, sürüm 1.3.2 |
| API yalnız repository'yi okur | Kritik ve doğru güvenlik sınırı | API'de yalnız `repository-db:5433`; source DSN doğrulamayla reddedilir |
| PoWA tabloları değiştirilmez | Doğru upgrade sınırı | Ürün nesneleri ayrı `advisor` şemasında |
| 1h/24h/7d/30d rapor pencereleri | Doğru | API ve SQL adapter katmanında destekli |
| Impact Score ile önceliklendirme | Doğru ilk iterasyon çıktısı | Ağırlıklı, açıklanabilir skor ve priority eşikleri |
| Eş dönem regresyonu | Doğru | Önceki aynı süreli pencere karşılaştırması |
| Annotation + audit | Doğru | `query_annotations`, trigger ve `audit_log` |
| Otomatik DDL/rewrite yok | Doğru güvenlik/kapsam kararı | Operations API'de de `false` olarak raporlanır |
| 90 günlük başlangıç hedefi | Uygun, kapasiteyle izlenmeli | Remote server kaydında açık `90 days` |
| React/TypeScript ve FastAPI | Uygun | Nginx arkasında UI, repository adapter'lı FastAPI |

## Uygulamada yapılan zorunlu düzeltmeler

### 1. Sürümler sabitlendi

Belge tarihindeki güncel sürümler PoWA Archivist **5.2.0** (`REL_5_2_0`) ve PoWA Collector **1.3.2**'dir. Repo:

- PoWA release arşivini belirli tag'den indirir ve SHA-256 doğrular.
- Collector wheel'ini `1.3.2` olarak ve SHA-256 ile sabitler.
- `main/master` veya kontrolsüz `latest` kaynak koduna dayanmaz.

### 2. Container içinde `localhost` kullanılmaz

PDF'nin native tek-host örneklerinde `localhost` doğrudur; Docker'da değildir. Her container'ın `localhost` adresi kendisini gösterir. Bu nedenle:

- Kaynak hostname: `source-db`
- Repository hostname: `repository-db`
- Collector repository DSN: `repository-db:5433/powa_repository`
- API DSN: `repository-db:5433/powa_repository`

Hosttan kullanıcı erişimi için varsayılan `127.0.0.1:15432/15433/8000` ayrı port publish katmanıdır; container içi PostgreSQL portları `5432/5433` olarak kalır.

### 3. `.pgpass` kaynak database alanı wildcard olmalıdır

Collector yalnız dedicated `powa` veritabanına değil, keşfedilen uygulama database'lerine de bağlanarak database-bazlı snapshot alır. Kaynak satırında database alanı `*` olmalıdır:

```text
source-db:5432:*:powa_collector:PAROLA
```

Kaynak uygulama database'lerinde collector'ın etkin `CONNECT` izni de gereklidir. Demo bootstrap'ı `appdb` için bu izni `powa_collector` rolüne açıkça verir. Sertleştirilmiş bir üretim ortamında her izlenecek database için aynı izin verilmelidir; aksi halde collector repository'ye erişse bile per-database veri toplayamaz.

### 4. Retention açıkça kayda yazılmalıdır

“Hedef 90 gün” demek tek başına PoWA ayarını değiştirmez. Varsayılan değer sürüme göre hedeflenenden kısa olabilir. Repo `powa_register_server(... retention => interval '90 days')` çağrısında değeri açıkça verir ve kabul testinde repository kaydını doğrular.

`.env` içindeki `RETENTION_DAYS` yalnız API/operasyon sunum ayarıdır; mevcut PoWA kaydının yerine geçmez.

### 5. Demo snapshot frekansı üretim frekansından ayrıldı

PDF'deki 300 saniye örneğinde sorgunun iki snapshot arasında görünmesi yaklaşık 10 dakika sürebilir. İlk iterasyon kurulumu hızlı doğrulamak için:

- Demo frequency: **5 saniye**
- Beklenen minimum: **iki snapshot**, yaklaşık 10 saniye
- Production: ölçülen overhead ve tazelik ihtiyacına göre daha yüksek değer

Bu yüzden 5 saniye üretim önerisi değildir; kabul testini hızlandıran bilinçli ayardır.

### 6. `pg_stat_statements.track` demo ve üretimde farklı ele alınmalıdır

PDF production için `track=top` önerir; bu düşük sürprizli başlangıç ayarıdır. Repodaki test fonksiyonu PL/pgSQL içinden sorgular çalıştırdığı için inner statement'ları görünür yapmak amacıyla demo kaynağında `track=all` kullanılır.

- Demo/acceptance: `all`
- Production başlangıcı: çoğunlukla `top`
- `all` seçimi: ek görünürlük/overhead ölçülerek

Bu fark belgede açık olmalıdır; aksi halde test fonksiyonu çalıştığı halde beklenen sorgular dashboardda görünmeyebilir.

### 7. PostgreSQL 17'de tarihsel lock zinciri vaat edilmemelidir

PDF sistem sağlığına lock bekleme/blocker sinyali ekliyor. PoWA 5.2'nin `pg_stat_lock` veri kaynağı PostgreSQL **19** gerektirir. Bu stack PostgreSQL 17 kullandığı için güvenilir geçmiş lock/blocker zinciri üretmiyormuş gibi davranmaz.

Uygulama:

- Seq scan, dead tuple, autovacuum: kullanılabilir
- Uzun transaction: PoWA `pg_stat_activity` geçmişinden kullanılabilir
- Lock wait/blocker chain: capability `available=false`, gerekçe PostgreSQL 19 gereksinimi

Canlı anlık `pg_locks` sorgusu eklemek API'nin repository-only sınırını bozacağı için bu iterasyonda tercih edilmemiştir.

### 8. Repository'de preload gerekmiyor

Remote mode repository kendi performansını local background worker ile toplamıyorsa `powa` veya `pg_stat_statements` preload ve restart zorunlu değildir. Kaynak instance'ta `pg_stat_statements` preload zorunluluğu devam eder. Repo yalnız kaynak command'ında preload ayarı yapar.

### 9. PoWA'nın hazır rollerinden yararlanıldı

Genel `GRANT ALL TABLES` yaklaşımı yerine PoWA 5.2'nin rol modeli kullanılır:

- `advisor_api`: `powa_read_all_data`
- `powa_collector`: `powa_read_all_data`, `powa_write_all_data`, `powa_snapshot`
- Kaynakta collector: `pg_read_all_stats`, `powa_snapshot` ve gerekli function execute

Repository kaynak kaydında düz metin parola yoktur; libpq `.pgpass` kullanılır. Gerçek kaynaklar alias bazlı `0600` secret dosyalarıyla eklenir ve collector açılışında tek geçici pgpass içinde birleştirilir.

### 10. Çoklu gerçek kaynak kaydı idempotent hale getirildi

PDF'deki tek hard-coded source örneği demo için yeterlidir, fakat ürün entegrasyonu için yeterli değildir. Repo `scripts/register-source.sh` ile host, port, monitoring DB, collector rolü, frequency ve retention'ı config/CLI üzerinden alır; aynı alias tekrar verildiğinde server id ve geçmiş korunarak kayıt güncellenir. Hazırlık SQL'i opsiyonel olarak uygulanabilir, parola repository'ye yazılmaz ve ilk snapshot ayrıca doğrulanır. Sürekli sentetik workload yalnız `demo` Compose profiliyle açılır.

## PDF kapsamıyla repo davranışının karşılaştırması

| Alan | PDF beklentisi | İlk iterasyon durumu |
|---|---|---|
| Normalize SQL ve metrik listesi | Var | Uygulandı |
| Impact Score | Var | Uygulandı; score breakdown API'de |
| Regresyon | Var | Uygulandı |
| Sorgu detay/trend | Var | Uygulandı |
| Sistem sağlığı | Var | PG17'de mümkün sinyaller uygulandı; lock açıkça sınırlı |
| Annotation/audit | Var | API'de uygulandı ve acceptance testte doğrulanır; tek kullanıcılı kurulumda takım iş akışı UI'dan kaldırıldı |
| Collector/retention ekranı | Var | Operasyonlar ekranında repository kapasitesi, collector/retention, I/O, WAL/checkpoint ve index telemetrisiyle uygulandı |
| Kurulum anlatımı | Kullanıcı ek talebi | Dashboard'dan çıkarıldı; platform ve dış kaynak adımları `docs/INSTALLATION.md` içinde |
| Otomatik index/SQL rewrite | Kapsam dışı | Uygulanmadı; Operasyonlar ekranı index gözlemlerinin DROP önerisi olmadığını ve PK/unique bilgisinin repository'de doğrulanamadığını açıkça belirtir |
| Native distro kurulumu | Ayrıntılı runbook | Tasarım referansı; doğrulanmış rota Compose |

## Güvenlik açısından ek notlar

PDF'nin repository-only API, ayrı roller, secret saklama ve SQL metni görünürlüğü kararları yerindedir. Repoda bunların temel davranışı uygulanmıştır. Bununla birlikte ilk iterasyonun şu parçaları üretim kimlik doğrulaması değildir:

- `X-Advisor-Role` header'ı istemci tarafından seçilebilir.
- Referans web istemcisi tam sorgu ekranı için `analyst` header'ını varsayılan gönderir.
- Annotation `updatedBy` alanı istemci girdisidir.
- `.env` secret manager değildir.
- Web varsayılan olarak HTTP `5173` sunar; TLS terminasyonu yoktur.

Dolayısıyla dış/üretim erişiminden önce HTTPS, OIDC/SSO, güvenilir actor propagation, rate limit, merkezi secret yönetimi ve network policy gerekir.

## İlk iterasyon kabul kararı

Aşağıdakiler sağlanırsa PDF'deki ilk iterasyon amacı karşılanır:

1. İki PostgreSQL instance `5432` ve `5433` üzerinde bağımsız çalışır.
2. Collector en az iki snapshot'ı hatasız yazar.
3. Repository remote kaydı 90 gün retention ve `NULL` parola taşır.
4. Test fonksiyonu kontrollü sorgu yükü üretir.
5. API yalnız repository bağlantısına sahiptir.
6. Sorgular gerçek PoWA fark metrikleriyle sıralanır ve SQL yetkisiz rolde maskelenir.
7. Annotation değişikliği audit kaydı oluşturur.
8. UI Genel Bakış, Sorgular, Sistem Sağlığı ve Operasyonlar ekranlarını açar. Takım iş akışı tek kullanıcılı kurulum kararıyla UI kapsamı dışında kalır; annotation API'leri backend'de durur.
9. 24 saatlik sorgu listesi kabul ortamında 2 saniyenin altında yanıt verir.

Bu kontroller `bash scripts/verify.sh` ile otomatikleştirilmiştir. Sonuç olarak PDF'nin ilk iterasyon mimarisi **doğru**, yukarıdaki sürüm/container/capability düzeltmeleri ise uygulama için **gerekli**dir.

## Dayanaklar

- [PoWA remote setup](https://powa.readthedocs.io/en/latest/remote_setup.html)
- [PoWA mimarisi](https://powa.readthedocs.io/en/latest/architecture.html)
- [PoWA güvenlik ve remote roller](https://powa.readthedocs.io/en/latest/security.html)
- [PoWA Archivist kurulumu](https://powa.readthedocs.io/en/latest/components/powa-archivist/installation.html)
- [PoWA Collector kurulum ve yapılandırması](https://powa.readthedocs.io/en/latest/components/powa-collector/index.html#configuration)
- [PoWA Archivist 5.2.0 release](https://github.com/powa-team/powa-archivist/releases/tag/REL_5_2_0)
- [PoWA Collector 1.3.2 release](https://github.com/powa-team/powa-collector/releases/tag/1.3.2)
