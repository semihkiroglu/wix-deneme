# WiX iç paket üretimi (v7+, Jenkins + Windows Docker)

Resmî `wixtoolset/wix` kaynak ağacından, **kaynak kod davranışı değiştirilmeden** (yalnız sürüm
şablonlarında ve NuGet kaynağında kontrollü değişiklik) kurum içi `.1` paketleri üretir. Derleme ve
upstream test zinciri, Jenkins `windows1` agent'ında **Windows Docker container içinde** koşar; akış
`Jenkinsfile` (ince orkestrasyon), host script'i `Run-TagBuild.ps1` ve konteyner içi `Build-Wix.ps1`
üzerindedir.

## Akış

- `Discover` → `Build` (container içinde tam upstream build + test zinciri) → `Publish`
  (başarılıysa iç feed'e).
- Sürüm: upstream `vX.Y.Z` → iç paket `X.Y.Z.1` (ilk hedef: `v7.0.0` → `7.0.0.1`). Kaynak değişikliği yalnız
  üç sürüm şablonu (`src/internal/SetBuildNumber/*.pp`) ve NuGet kaynağı ikamesidir (`nuget.config`);
  build sonunda izlenen + izlenmeyen dosyalarla doğrulanır. Her manifest kaynak commit'ini kaydeder
  (`source_sha`).
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
  her gün 03:00 saat diliminde (Europe/Istanbul; dakika Jenkins dağıtımıyla belirlenir).
  `PUBLISH` parametresi varsayılan `true`; yalnız yayın (push) yapmadan koşmak için `false`.
- **Kimlikler:** `nuget-push-api-key` (Secret text) → yayın anahtarı `NUGET_API_KEY` olarak enjekte
  edilir. Feed adresi `FEED_URL` ortam değişkeninden okunur ve **zorunludur** (tanımsızsa koşu hemen
  hata verir). Private depo checkout'u için Jenkins'te bir git credential'ı tanımlanmalıdır. GitHub
  Releases API için opsiyonel `GITHUB_TOKEN` (rate limit) verilebilir.
- **Prod kaynağı (iç kural):** canlıdaki job, `Jenkinsfile` + tüm bağımlılıklarını içeren **iç git
  projesinden** koşar ("Pipeline script from SCM"); GitHub deposu geliştirme ve smoke kanıtı içindir.
- **Ağ (hedef iç ağ):** container; `github.com` (klon + pwsh/MinGit indirmeleri),
  `download.visualstudio.microsoft.com` (VS Build Tools), `dot.net` + MS CDN (.NET SDK),
  `dist.nuget.org` (pinli `nuget.exe` indirmesi — erişilebilir olduğu doğrulandı),
  `nuget.c2tech.local` (NuGet — tüm paketler internal feed'den), `mcr.microsoft.com` (baz imaj)
  adreslerine erişir. `api.nuget.org`/`globalcdn.nuget.org` iç ağdan **kapalıdır**; bu yüzden klondaki
  NuGet kaynağı kontrollü olarak `nuget.c2tech.local`'a çevrilir (`WIX_NUGET_SOURCE` ile override
  edilebilir; CI smoke internetli adresi kullanır). VS Build Tools `nuget.exe` CLI'sını taşımaz;
  alternatif olarak aynı binary iç feed'deki `NuGet.CommandLine` paketinden de alınabilir. Agent ayrıca
  `api.github.com` (sürüm keşfi) ve iç feed'e erişir.
- **Kalıcı durum:** Jenkins workspace kalıcıdır; keşif kararı `artifacts/<tag>/release-manifest.json`
  ve feed sorgusundan okunur. Her koşu yalnız kendi log/artifact'ını arşivler.

## Yeni upstream sürümü (keşif davranışı)

Her koşuda `wixtoolset/wix` Releases listesi okunur (stable, ≥ v7.0.0) ve her etiket için
`build / publish / skip` kararı verilir (karar dosyası `discovery.json` arşivlenir): yerel manifest
yoksa **build**; manifest var ama feed'de eksik paket varsa **publish** (yeniden derleme olmadan);
her şey yayınlanmışsa **skip**. Yeni bir sürüm ilk koşuda derlenir; upstream test zinciri koşar ve TRX
tutarlılığı doğrulanır (sonuç sayıları loga yazılır). Tek manuel adım yayın setidir: public paket
künyesi pinli değilse koşu manifest aşamasında açık hatayla durur → `$ExpectedPublicPackages`'e
eklenir (nuget.org'a erişebilen bir makineden doğrulanır; hangi paketlerin feed'e gideceğini bu liste
belirler) → sonraki koşu üretir ve yayınlar.

## Kendi ortamında deneme

- `tests/JenkinsSmoke.ps1` — gerçek Jenkins WAR'ını indirip geçici bir örnekte ayağa kaldırır,
  job oluşturur ve bu `Jenkinsfile`'ı uçtan uca koşturur (disposable Windows makinede).
- `tests/Build-Wix.Tests.ps1`, `tests/Publish-Wix.Tests.ps1` (mock feed — gerçek push yok),
  `tests/VswhereBootstrap.Tests.ps1`, `tests/Storage.Tests.ps1` — yerel doğrulama testleri.
- Yayın (push) yapmadan koşmak için job'u `PUBLISH=false` ile çalıştırın; keşif aşaması yerel manifest
  bulunduğunda feed'e yalnız salt-okunur sorgu yapabilir.

## Güvenlik ve yayın

Bu depo hiçbir iç feed adresi, API anahtarı veya kurumsal secret taşımaz; yayın anahtarı yalnız
Jenkins credential store'dan (`nuget-push-api-key`) verilir. Paket ve sembol dosyaları yayın
öncesi manifest hash'leriyle doğrulanır; feed'in ilan ettiği uç noktalar yalnız HTTPS ve feed
origin'i içinde kabul edilir (açıkça yapılandırılan ayrı HTTPS sembol sunucusu hariç). Container
araç zinciri indirmeleri hash pinlidir (bkz. `Install-BuildEnv.ps1`).

Lisans: upstream MS-RL (kaynak ağacına dokunulmaz).
