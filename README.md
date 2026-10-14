# WiX iç paket üretimi (v7+, Jenkins + Windows Docker)

Resmî `wixtoolset/wix` kaynak ağacından, **kaynak kod davranışı değiştirilmeden** (yalnız sürüm
şablonlarında kontrollü değişiklik) kurum içi `.1` paketleri üretir. Derleme ve upstream test
zinciri, Jenkins `windows1` agent'ında **Windows Docker container içinde** koşar; akış
`Jenkinsfile` + `Build-Wix.ps1` içindedir.

## Akış

- `Discover` → `Build` (container içinde tam upstream build + test zinciri) → `Publish`
  (başarılıysa iç feed'e).
- Sürüm: upstream `vX.Y.Z` → iç paket `X.Y.Z.1` (ilk hedef: `v7.0.0` → `7.0.0.1`). Kaynak değişikliği yalnız üç sürüm şablonunda
  (`src/internal/SetBuildNumber/*.pp`) ve upstream kaynak ağacı build sonunda doğrulanır
  (izlenen + izlenmeyen dosyalar; sabit release commit'i `b8977d6f88e7b68e000bac226a2814f236770570`).
- Container'da koşamayan 39 MsiE2E testi (Windows Firewall / Server servisi — Microsoft platform
  limiti) kanıtlı bir izinli liste ile sınırlıdır; TRX tutarlılığı doğrulanır ve liste dışı her
  hata build'i kırar. Ayrıntı: [docs/container-test-notes.md](docs/container-test-notes.md).
- GitHub tarafındaki `build-wix7.yml`, dispoze bir Windows runner'da gerçek Jenkins'i ayağa
  kaldırıp aynı zinciri uçtan uca koşar ve arşivi indirir (kanıt/CI hattı).

## Çıktı

Jenkins build arşivi: `.nupkg` + `.snupkg` (ör. `7.0.0.1`), `release-manifest.json`
(paket ve sembol hash'leri dahil) ve `WixAdditionalTools.exe`; test sonuçları (TRX) `logs/`
altında. Her build kendi artifact dizinini sıfırdan yazar; eski dosyalar arşive taşınamaz.

## Güvenlik ve yayın

Bu depo hiçbir iç feed adresi, API anahtarı veya kurumsal secret taşımaz; yayın anahtarı yalnız
Jenkins credential store'dan (`nuget-push-api-key`) verilir. Paket ve sembol dosyaları yayın
öncesi manifest hash'leriyle doğrulanır; feed'in ilan ettiği uç noktalar yalnız HTTPS ve feed
origin'i içinde kabul edilir. Container araç zinciri indirmeleri hash pinlidir (bkz.
`Install-BuildEnv.ps1`).

Lisans: upstream MS-RL (kaynak ağacına dokunulmaz).
