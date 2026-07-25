# API kimliği ve audit actor modeli

Annotation, CSV export ve disposable-clone runtime doğrulaması istemcinin
gönderdiği actor/rol metnine güvenmez. Bu endpoint'ler standart
`Authorization: Bearer` header'ı ile doğrulanan, server-side registry'deki bir
principal ister. Audit actor her zaman registry'deki sabit `subject` alanıdır.

## Credential üretme

Raw token ve API ortamına verilecek SHA-256 registry girdisini üretin:

```bash
python3 scripts/generate-auth-credential.py \
  --credential-id mcan-cli-20260725 \
  --subject user:mcan \
  --roles analyst,annotator,admin
```

Script hiçbir dosyayı değiştirmez. Gösterdiği `adv_pat_v1_...` token'ı yalnız
bir kez secret manager'a kaydedin. Raw token'ı `.env`, Compose YAML, frontend
build değişkeni veya log içine koymayın. Scriptin ürettiği tek satırlık JSON
registry değerini API ortamına verin:

```dotenv
ADVISOR_AUTH_PRINCIPALS='[{"credential_id":"mcan-cli-20260725","subject":"user:mcan","token_sha256":"64_KARAKTER_LOWERCASE_SHA256","roles":["admin","analyst","annotator"]}]'
```

Boş liste varsayılandır ve korunan endpoint'leri fail-closed kapatır. Registry
yalnız hash taşır; API gelen yüksek entropili token'ın SHA-256 değerini bütün
kayıtlarla sabit zamanlı karşılaştırır. `credential_id` ve hash benzersizdir.
Aynı kullanıcı için iki farklı credential tanımlanarak kesintisiz token
rotation yapılabilir; eski kayıt kullanım sona erince kaldırılır.

## Roller

| Rol | Yetki |
|---|---|
| `analyst` | Bearer ile tam SQL görünürlüğü ve analiz endpoint'leri |
| `annotator` | Annotation oluşturma/güncelleme |
| `admin` | Annotation, tam streaming CSV ve disposable-clone runtime testi |

Bir credential birden çok rol taşıyabilir. Geçerli token olmadan gönderilen
`X-Advisor-Role: analyst` yalnız yerel demo analiz davranışını korur; hiçbir
write, export, runtime veya audit actor yetkisi üretmez. Eski
`X-Advisor-Admin-Token`, `X-Advisor-Actor` ve request body `updatedBy` alanları
kimlik doğrulama yolu değildir ve korunan endpoint'lerde kabul edilmez.

Eksik/geçersiz token `401` ve `WWW-Authenticate: Bearer`; doğrulanmış fakat
yetersiz rol `403` döndürür.

## İstek örnekleri

```bash
export ADVISOR_API_TOKEN='SECRET_MANAGERDAN_ALINAN_RAW_TOKEN'

curl -fsS -X PATCH \
  -H "Authorization: Bearer ${ADVISOR_API_TOKEN:?token gerekli}" \
  -H 'Content-Type: application/json' \
  --data '{"status":"IN_REVIEW","note":"Plan inceleniyor"}' \
  'http://127.0.0.1:8000/api/v1/queries/42/annotation?serverId=1&databaseId=16384'

curl -fsS \
  -H "Authorization: Bearer ${ADVISOR_API_TOKEN:?token gerekli}" \
  'http://127.0.0.1:8000/api/v1/export/queries.csv?window=24h&priority=CRITICAL&minCalls=20' \
  -o queries-24h.csv
```

Annotation response içindeki `updatedBy`, annotation satırındaki `updated_by`
ve `ANNOTATION_CREATED/UPDATED` audit actor aynı doğrulanmış subject olur.
API database rolünün tablolara doğrudan write yetkisi yoktur; yalnız sabit
`search_path` kullanan kontrollü database fonksiyonlarını çağırabilir. CSV için
stream başlamadan `QUERIES_EXPORT_REQUESTED`, cursor başarıyla bittikten sonra
kesin satır sayılı `QUERIES_EXPORT_COMPLETED` kaydı oluşur. İki kayıt aynı
`exportId`, `credentialId`, pencere ve filtreleri taşır; bu sayede aynı subject
ile eşzamanlı export'lar da eşleştirilebilir. Client bağlantıyı keserse yanlış
completion kaydı yazılmaz; eşleşen REQUESTED kaydı tamamlanmamış kalır.

`advisor_api` rolü yine de güvenilen uygulama sınırının parçasıdır: bu ortak DB
credential'ını ele geçiren biri kontrollü fonksiyonları doğrudan çağırabilir.
Bu nedenle credential yalnız API container'ında tutulmalı ve repository portu
loopback/private network dışına açılmamalıdır. Migration öncesindeki
istemci-kontrollü legacy audit actor değerleri geriye dönük kimlik kanıtı olarak
kabul edilmemelidir.

Bu PAT modeli yerel/operator erişiminde gerçek, server-side kimlik sağlar fakat
SSO değildir. API başka hostlara açılacaksa TLS, merkezi secret yönetimi, rate
limit ve tercihen OIDC/BFF + HttpOnly session ayrıca uygulanmalıdır. Raw PAT
browser bundle'ına gömülmemelidir.
