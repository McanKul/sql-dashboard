# Changelog

Bu proje [Semantic Versioning](https://semver.org/) kullanır. Repository
migration'ları ileri yönlüdür; uygulama sürümü ile şema uyumluluğu yükseltme
runbook'unda belirtilir.

## 1.1.0 — 2026-07-26

- Ana kaynakta yalnız persisted, salt-okunur sorgular için gerçek `EXPLAIN ANALYZE`.
- Yerel, interaktif execution-plan grafiği ve hotspot incelemesi.
- 500 tablo / 4.000 fingerprint ERP yükü için tam kabul modu: collector,
  dashboard ingress, API, source EXPLAIN ve streaming CSV aynı yük penceresinde.
- Operations ekranında uygulama/build ve repository migration görünürlüğü.
- Kaynak capability sözleşmesi ve global server/database scope desteği.
- Repository migration hedefi `0014`.

Yükseltme ve geri dönüş: [Upgrade / rollback runbook](docs/UPGRADE_ROLLBACK.md).
