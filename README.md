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

## Hedef ortama entegrasyon

- **Agent:** `windows1` etiketli Windows Server host'u; Docker (Windows container) çalışır durumda.
  Docker data-root diski ≥ 60 GiB boş olmalı (build guard'ı); her build container'ı 120 GB
  yazılabilir katman alır.
- **Job:** "Pipeline script from SCM" → bu depo, `Jenkinsfile`. Zamanlama dosyada gömülüdür:
  her gün 03:00 (Europe/Istanbul). `PUBLISH` parametresi varsayılan `true`; kuru koşu için `false`.
- **Kimlikler:** `nuget-push-api-key` (Secret text) → yayın anahtarı `NUGET_API_KEY` olarak enjekte
  edilir. Feed adresi `FEED_URL` ortam değişkeninden okunur; tanımsızsa dosyadaki yer tutucu
  kullanılır — gerçek yayın öncesi mutlaka tanımlanmalıdır. GitHub Releases API için opsiyonel
  `GITHUB_TOKEN` (rate limit) verilebilir.
- **Ağ:** container; `github.com` (klon + pwsh/MinGit indirmeleri), `download.visualstudio.microsoft.com`
  (VS Build Tools), `dot.net` + MS CDN (.NET SDK), `dist.nuget.org` (nuget.exe), `mcr.microsoft.com`
  (baz imaj) adreslerine erişebilmeli. Agent ayrıca `api.github.com` (sürüm keşfi), `mcr.microsoft.com`
  (imaj çekme) ve iç feed'e erişir.
- **Kalıcı durum:** Jenkins workspace kalıcıdır; keşif kararı `artifacts/<tag>/release-manifest.json`
  ve feed sorgusundan okunur. Her koşu yalnız kendi log/artifact'ını arşivler.

## Yeni upstream sürümü (keşif davranışı)

Her koşuda `wixtoolset/wix` Releases listesi okunur (stable, ≥ v7.0.0) ve her etiket için
`build / publish / skip` kararı verilir (karar dosyası `discovery.json` arşivlenir): yerel manifest
yoksa **build**; manifest var ama feed'de eksik paket varsa **publish** (yeniden derleme olmadan);
her şey yayınlanmışsa **skip**. Yepyeni bir sürüm ilk görüldüğünde süreç bilinçli olarak durur:
(1) koşu, sabitlenmemiş commit'i hata mesajında bildirir → `$ExpectedUpstreamCommits`'e eklenir;
(2) sonraki koşu testleri koşar ve ölçülen sonuç sayılarını hata mesajında bildirir →
`$ExpectedTestCounts`'a eklenir; (3) sonraki koşu üretir ve yayınlar. Bu iki pin bilinçli bir
güvenlik kapısıdır (taşınmış tag ve beklenmeyen test seti tespiti).

## Kendi ortamında deneme

- `tests/JenkinsSmoke.ps1` — gerçek Jenkins WAR'ını indirip geçici bir örnekte ayağa kaldırır,
  job oluşturur ve bu `Jenkinsfile`'ı uçtan uca koşturur (disposable Windows makinede).
- `tests/Build-Wix.Tests.ps1`, `tests/Publish-Wix.Tests.ps1` (mock feed — gerçek push yok),
  `tests/VswhereBootstrap.Tests.ps1`, `tests/Storage.Tests.ps1` — yerel doğrulama testleri.
- Gerçek feed'e dokunmadan koşmak için job'u `PUBLISH=false` ile çalıştırın.

## Güvenlik ve yayın

Bu depo hiçbir iç feed adresi, API anahtarı veya kurumsal secret taşımaz; yayın anahtarı yalnız
Jenkins credential store'dan (`nuget-push-api-key`) verilir. Paket ve sembol dosyaları yayın
öncesi manifest hash'leriyle doğrulanır; feed'in ilan ettiği uç noktalar yalnız HTTPS ve feed
origin'i içinde kabul edilir. Container araç zinciri indirmeleri hash pinlidir (bkz.
`Install-BuildEnv.ps1`).

Lisans: upstream MS-RL (kaynak ağacına dokunulmaz).
