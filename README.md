# PostgreSQL Sorgu Performansı ve Öneri Motoru

PDF v1.1'de tarif edilen ilk iterasyonun çalışan referans uygulamasıdır. Tek bir Docker/OrbStack hostu üzerinde **iki ayrı PostgreSQL sunucu süreci** çalışır: demo kaynak instance `5432`, PoWA repository instance `5433`. PoWA Collector istatistikleri kaynaktan repository'ye taşır; FastAPI yalnız repository'yi okur ve React arayüzü sonuçları gösterir. Aynı repository/collector, `scripts/register-source.sh` ile birden fazla gerçek PostgreSQL kaynağı izleyebilir.

> Bu sürümün amacı “önce hangi sorguya bakılmalı?” sorusunu yanıtlamaktır. Otomatik `CREATE/DROP INDEX`, SQL rewrite veya canlı veritabanına müdahale bilinçli olarak kapsam dışıdır.

## Hızlı başlangıç

Gerekenler:

- Çalışan Docker Engine + Docker Compose v2 veya macOS'ta OrbStack
- İlk image build'i için internet erişimi
- Kabul testi için `bash`, `curl` ve `python3`

Proje kökünde:

```bash
cp .env.example .env
chmod 600 .env
```

`.env` içindeki üç örnek parolayı değiştirin. Ardından:

```bash
docker info
docker compose version
docker compose config --quiet
docker compose up --build -d
docker compose ps
```

Bu komut demo PostgreSQL'ü ölçülebilir hedef olarak hazırlar ancak sürekli yük üreten `workload` servisini başlatmaz. `REGISTER_DEMO_SOURCE=false` yalnız **boş bir repository volume'ünün ilk kurulumu öncesinde** seçilirse demo kaydı oluşturulmaz; gerçek kaynak-only kurulumlarda bu seçenek kullanılabilir.

İlk build sırasında PostgreSQL 17 tabanı üzerinde PoWA Archivist 5.2.0 derlenir; bu nedenle sonraki başlatmalardan daha uzun sürer. Servisler sağlıklı olduktan sonra:

```bash
bash scripts/verify.sh
```

Başarılı sonuç `İlk iterasyon çalışma zamanı kabul kontrolleri tamamlandı.` satırı ile biter.

## Erişim adresleri

| Bileşen | Yerel adres | Varsayılan erişim |
|---|---|---|
| Web arayüzü | <http://localhost:5173> | Host ağına açık (`0.0.0.0`) |
| Web üzerinden API | <http://localhost:5173/api/v1/health> | Nginx proxy üzerinden |
| FastAPI | <http://localhost:8000/api/v1/health> | Yalnız loopback (`127.0.0.1`) |
| OpenAPI | <http://localhost:8000/docs> | Yalnız loopback |
| Kaynak PostgreSQL | `127.0.0.1:15432/appdb` | Yalnız loopback; container içinde `5432` |
| PoWA repository | `127.0.0.1:15433/powa_repository` | Yalnız loopback; container içinde `5433` |

Başka bir bilgisayardan yalnız `http://SUNUCU_IP:5173` adresini açın. API çağrıları arayüzün Nginx `/api` proxy'sinden geçer; `15432`, `15433` ve `8000` portlarını dış ağa açmayın.

Arayüzde şu analiz ekranları bulunur:

- Genel Bakış: yük özeti, en yüksek etkili sorgular ve trend
- Sorgular: arama, filtreleme, sıralama, sorgu detayı ve dönem karşılaştırması
- Sistem Sağlığı: son repository snapshot'ındaki seq scan, dead tuple, autovacuum ve uzun transaction sinyalleri; dönem seçici bu snapshot ekranında gösterilmez
- Operasyonlar: collector/retention görünürlüğü, repository kapasitesi, veritabanı ve cluster I/O, WAL/checkpoint ile güvenli index kullanım sinyalleri

## Kontrollü test yükü

Kaynak veritabanındaki `run_advisor_test_workload(iterations integer)` fonksiyonu dört tekrarlanabilir sorgu desenini çalıştırır. Fonksiyonu sarmalayan komut:

```bash
bash scripts/run-test-workload.sh 20
```

`iterations` değeri `1–1000` arasında olmalıdır. Collector frekansı demo için 5 saniyedir; iki snapshot oluşması ve fark metriklerinin görünmesi için komuttan sonra yaklaşık 10 saniye bekleyin.

Varsayılan kurulum **sürekli sentetik trafik üretmez**. Sürekli demo trafiğini özellikle açmak isterseniz:

```bash
docker compose --profile demo up -d workload
```

Durdurmak için:

```bash
docker compose stop workload
```

## Gerçek bir PostgreSQL kaynağı ekleme

Bu entegrasyon yalnız PostgreSQL içindir. Kaynak cluster'a uygun PoWA Archivist paketi önceden kurulmuş ve `pg_stat_statements` `shared_preload_libraries` içinde etkin olmalıdır. Script extension binary'si veya PostgreSQL ayarı kurmaz; gerekli restart kararı kaynak DBA'ya aittir.

1. Örneği Git dışındaki güvenli bir konuma kopyalayın:

   ```bash
   cp config/source.env.example /secure/prod-source.env
   chmod 600 /secure/prod-source.env
   printf '%s\n' 'GUCLU_COLLECTOR_PAROLASI' > /secure/powa-collector.password
   chmod 600 /secure/powa-collector.password
   ```

2. `/secure/prod-source.env` içindeki host, alias ve parola dosyası yolunu değiştirin.
3. Kaynak DBA hazırlığını da aynı komutla yapmak istiyorsanız `PREPARE_SOURCE=true` ve ayrı bir `SOURCE_ADMIN_PASSWORD_FILE` tanımlayın. Hazırlık daha önce yapıldıysa `false` bırakın.
4. Kaydedin ve ilk snapshot'ı doğrulayın:

   ```bash
   bash scripts/register-source.sh --env-file /secure/prod-source.env
   bash scripts/verify-source.sh production-main
   ```

Komut tekrar çalıştırılabilir: aynı alias yeni satır açmaz; bağlantı/frequency/retention değerlerini günceller. Kaynak parolası repository'de tutulmaz. Alias başına `runtime/collector/sources/*.pgpass` altında `0600` bir secret oluşur, collector yeniden başlar ve ilk snapshot beklenir. Ayrıntılar ve kaynak tarafı kurulum adımları [kurulum rehberindedir](docs/INSTALLATION.md#gerçek-bir-postgresql-kaynağını-ekleme).

## Servisler ve veri akışı

| Compose servisi | Görev | Kalıcı veri |
|---|---|---|
| `source-db` | PostgreSQL 17, `appdb`, `pg_stat_statements`, remote PoWA fonksiyonları | `source_data` |
| `repository-db` | PostgreSQL 17, PoWA geçmişi ve `advisor` şeması | `repository_data` |
| `collector` | PoWA Collector 1.3.2; kaynaktan snapshot alır | Yok |
| `api` | Repository-only FastAPI okuma/annotation katmanı | Repository'de |
| `workload` | Yalnız `demo` profili açıldığında sürekli sentetik sorgu yükü | Yok |
| `web` | React + TypeScript arayüzü ve Nginx API proxy | Yok |

```text
source-db:5432 ───────┐
external PG #1 ──────┼──okuma──> collector ──yazma──> repository-db:5433
external PG #N ──────┘                                      │
                                                            v
                                                   api:8000 ──> web:5173
```

Mimari sınırlar ve rol matrisi için [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) dosyasına bakın.

## Güvenlik sınırları

- Repository'deki kaynak kayıtlarında parola tutulmaz (`password = NULL`); collector Git dışında tutulan alias-bazlı `0600` pgpass secret'larını açılışta geçici `.pgpass` dosyasında birleştirir.
- `powa_collector`, PostgreSQL'ün hazır PoWA rollerini ve kaynakta `pg_read_all_stats` yetkisini kullanır.
- `advisor_api` yalnız repository DSN'i alır. Yapılandırma doğrulaması `source-db`, `5432` veya `appdb` içeren API DSN'ini reddeder.
- Header gönderilmeyen API isteği `viewer` sayılır ve tam SQL maskelenir. `X-Advisor-Role: analyst` ve `admin` SQL'i görür; CSV export yalnız `admin` içindir. Referans web istemcisi analiz ekranlarını gösterebilmek için şu anda `analyst` header'ı gönderir.
- Bu header tabanlı rol seçimi ilk iterasyon demonstrasyonudur, kimlik doğrulama değildir. İnternet erişimi verilen bir kurulumda OIDC/SSO veya kimlik doğrulayan reverse proxy eklenmeden üretim güvenliği sağlanmış sayılmaz.
- `.env` yalnız yerel geliştirme içindir; canlı ortamda secret manager ve parola rotasyonu kullanın.
- Docker port publish kuralları bazı firewall araçlarından önce uygulanabilir. Linux sunucuda `DOCKER-USER` zinciri veya kurumun network policy katmanıyla yalnız web portuna izin verildiğini ayrıca doğrulayın.

## Testler

Tüm çalışma zamanı kabul kontrolleri:

```bash
bash scripts/verify.sh
```

Bu script Compose geçerliliğini, iki PostgreSQL portunu, extension sürümlerini, 90 gün retention'ı, test fonksiyonunu, iki snapshot'ı, collector sağlığını, gerçek API metriklerini, SQL maskelemesini, 2 saniyelik API hedefini, annotation audit kaydını ve API'nin kaynak DSN taşımadığını kontrol eder.

Backend unit testleri:

```bash
docker build -f backend/Dockerfile.test -t postgresql-advisor/backend-tests backend
docker run --rm postgresql-advisor/backend-tests
```

Frontend unit testleri:

```bash
docker run --rm -v "$PWD/frontend:/app" -w /app node:22-alpine sh -c 'npm ci && npm test'
```

## İşletim

Durum ve loglar:

```bash
docker compose ps
docker compose logs --tail=100 collector api web
```

Repository yedeği:

```bash
bash scripts/backup-repository.sh
```

Yedek `backups/powa_repository-<UTC-zaman>.dump` olarak oluşturulur. Normal durdurma veriyi korur:

```bash
docker compose down
```

`docker compose down -v` ise **hem kaynak hem repository volume'lerini ve bütün geçmişi kalıcı olarak siler**. Yalnız yeniden üretilebilir test verisi için ve gerekli yedek alındıktan sonra kullanın.

## Belgeler

- [Kurulum ve işletim rehberi](docs/INSTALLATION.md)
- [Mimari ve güvenlik sınırları](docs/ARCHITECTURE.md)
- [PDF v1.1 uygunluk ve düzeltme incelemesi](docs/PDF_REVIEW.md)

## Sabitlenen temel sürümler

- PostgreSQL `17` (`postgres:17-trixie`)
- PoWA Archivist `5.2.0` / `REL_5_2_0` — kaynak arşiv SHA-256 ile doğrulanır
- PoWA Collector `1.3.2` — wheel SHA-256 ile sabitlenir
- Python `3.12`, Node `22`, Nginx `1.27`

Güncel tasarım dayanakları: [PoWA remote setup](https://powa.readthedocs.io/en/latest/remote_setup.html), [PoWA güvenlik](https://powa.readthedocs.io/en/latest/security.html), [Docker Engine kurulumu](https://docs.docker.com/engine/install/).
