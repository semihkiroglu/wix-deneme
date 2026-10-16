# WiX iç paket üretimi (v7+; Jenkins + Windows container)

Upstream `wixtoolset/wix` kaynak ağacından, **kaynak kod davranışı değiştirilmeden** kurum içi `.1`
paketleri üretir (ilk hedef: `v7.0.0` → `7.0.0.1`). Derleme ve upstream test zinciri, Jenkins
`windows1` agent'ında **Windows Docker container'ı içinde** koşar. Akış üç katmandır: `Jenkinsfile`
(ince orkestrasyon), host scripti `Run-TagBuild.ps1` (docker) ve container içi `Build-Wix.ps1`
(üretim).

## Neden bu hat var

- **Birebir upstream davranışı:** kaynak koda dokunulmaz; izinli tek müdahale üç sürüm şablonu
  (`src/internal/SetBuildNumber/*.pp`) ve `nuget.config` kaynağıdır. Build sonunda hem izlenen hem
  izlenmeyen dosyalar denetlenir; izinli liste dışındaki tek bir değişiklik koşuyu kırar.
- **Testler bypass edilmez:** upstream'in kendi test zinciri koşar; TRX sayaç/özet tutarlılığı
  doğrulanır. Container'da koşamayan 39 MsiE2E testi (Windows Firewall / Server servisi — platform
  limiti) kanıtlı izinli listeyle sınırlıdır; liste dışı her hata build'i kırar (liste `Build-Wix.ps1`
  içindedir).
- **Dış bağımlılık içeride:** tüm NuGet trafiği iç feed'den (`nuget.c2tech.local`) akar; klondaki tek
  kaynak adresi kontrollü olarak ikame edilir (`WIX_NUGET_SOURCE` ile geçersiz kılınabilir).
- **Kimlik:** her paket `X.Y.Z.1` sürümünü, her manifest kaynak commit'ini (`source_sha`) taşır.

## Nasıl çalışır (her koşuda)

1. **Discover** — upstream sürüm listesi (api.github.com) iç feed ile karşılaştırılır; her etiket için:
   - `build`: yerelde manifest yok → tam derleme + test zinciri,
   - `publish`: manifest var ama feed'de eksik var → **yeniden derlemeden** yalnız gönderim,
   - `skip`: hepsi yayınlanmış → hiçbir şey.
   Karar özeti konsola yazılır, ayrıntısı `discovery.json` olarak arşivlenir.
2. **Build** (yalnız gerekiyorsa) — geçici container: toolchain kurulumu → upstream klon (tag) →
   version/nuget ikamesi → tüm modüllerin derlemesi → test zinciri (Burn 185 / MsiE2E 53 / WixE2E 8) →
   paketler + sembol paketleri + `release-manifest.json` → host'a taşınır.
3. **Publish** (yalnız gerekiyorsa ve `PUBLISH` açıksa) — public paketler ve sembolleri feed'e
   gönderilir; her paket hash readback ile doğrulanır; var olan paketin üzerine farklı içerikle
   yazılmaz.

**Kaynak tüketimi:** yeni bir şey yoksa Build/Publish adımları tamamen atlanır (docker hiç başlamaz);
günlük koşu saniyeler sürer. Kısmi yayında bile yeniden derleme yapılmaz.

## Kullanım

- **Job:** Pipeline → "Pipeline script from SCM" → bu depo, Script Path `Jenkinsfile`.
  Zamanlama dosyada gömülüdür: her gün **03:00** (Europe/Istanbul). Parametre `PUBLISH`
  (varsayılan `true`; yalnız derleme provası için `false`).
- **Ortam:** `FEED_URL` **zorunludur** (ör. `https://nuget.c2tech.local/v3/index.json`); tanımsızsa
  koşu ilk adımda durur.
- **Credential'lar:** `nuget-push-api-key` (Secret text; feed push anahtarı) ve depo checkout'u için
  bir git credential'ı. Keşif, `api.github.com`'un anonim kotasını kullanır; yoğun kullanımda
  `GITHUB_TOKEN` tanımlanabilir.
- **İlk koşu önerisi:** önce `PUBLISH=false` (derle + test et, push yok) → yeşilse `PUBLISH=true`
  (bu kez yalnız yayın yapar).
- **Yeni upstream sürümü:** günlük koşu kendiliğinden derler ve test eder. Tek manuel adım, public
  paket künyesi pinidir: pinli değilse koşu manifest aşamasında açık hatayla durur; listeyi
  `Build-Wix.ps1` içindeki `$ExpectedPublicPackages`'e ekleyip yeniden koşmak yeterlidir.
- **Workspace kalıcıdır:** keşif kararı `artifacts/<tag>/release-manifest.json` üzerinden verilir;
  workspace silinirse sistem sürümü "yeni" sanıp bir kez yeniden derler (~1 saat).

## Çıktı

Jenkins arşivi: `.nupkg` + `.snupkg` + `release-manifest.json` + `WixAdditionalTools.exe`; test
sonuçları (TRX) ve build logları `logs/` altında. Her koşu yalnız kendi çıktısını arşivler.

## Gereksinimler (hedef ortam)

- `windows1` etiketli agent; Windows container destekli Docker; Docker data-root diski ≥ 60 GiB boş
  (koşu başında denetlenir; her build container'ı 120 GB yazılabilir katman alır).
- Ağ: `github.com` (klon, pwsh/MinGit), `download.visualstudio.microsoft.com` (VS Build Tools),
  `dot.net` (SDK), `dist.nuget.org` (nuget.exe), `api.github.com` (sürüm listesi),
  `nuget.c2tech.local` (paketler), `mcr.microsoft.com` (baz imaj). `api.nuget.org` iç ağdan
  kapalıdır; bu yüzden NuGet kaynağı iç feed'e ikame edilir.
- Toolchain indirmelerinin tamamı pinli SHA-256'dır (`Install-BuildEnv.ps1`); hash tutmazsa koşu
  durur.

## Güvenlik ve yayın

Bu depo hiçbir API anahtarı veya kurumsal secret taşımaz; yayın anahtarı yalnız Jenkins credential
store'dan (`nuget-push-api-key`) verilir. Paket ve sembol dosyaları yayın öncesi manifest hash'leriyle
doğrulanır; feed'in ilan ettiği uç noktalar yalnız HTTPS ve feed origin'i içinde kabul edilir (açıkça
yapılandırılan ayrı HTTPS sembol sunucusu hariç).

## Sorun giderme

- Karar bilgisi önce konsolda: `discovery result: build=[...] publish=[...]`; ayrıntı `discovery.json`.
- `skip` beklerken `build` geliyorsa: workspace temizlenmiş olabilir (yerel manifest yok) → bir kez
  yeniden derler; kalıcı çözüm workspace'i korumaktır.
- Publish'ta 409/hash uyuşmazlığı: var olan paket yerel içerikle aynıysa "exists" kabul edilir;
  farklıysa koşu durur ve paketin üzerine yazılmaz.
- `FEED_URL` hatası: Jenkins global env'de tanımlı değil demektir.

Lisans: kaynak ağaç upstream MS-RL; bu depo yalnız derleme hattıdır.
