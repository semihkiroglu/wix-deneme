# WiX iç paket üretimi (v7+; Jenkins + Windows container)

Upstream `wixtoolset/wix` kaynak ağacından kurum içi `.1` paketleri üretir (ör. `v7.0.0` → `7.0.0.1`).
Kaynak koda dokunulmaz: yalnız sürüm şablonları ve NuGet kaynağı ikame edilir. Test koşulmaz — tag,
upstream'in kendi test kapısından geçmiş resmi bir sürümdür; bizim kapımız derleme yeşili +
manifest/hash doğrulamasıdır. Derleme, Jenkins `windows1` agent'ında bir Windows Docker container'ı
içinde koşar.

## Ne yapar

Her gün upstream sürüm listesi kontrol edilir:
- **build** — yeni tag: klon → sürüm ikamesi → derleme → paketleme,
- **publish** — eksik yayın: yeniden derlemeden feed'e gönderim,
- **skip** — yeni bir şey yok: docker hiç başlamaz (saniyeler sürer).

Çıktı: 47 nupkg + sembol paketleri + `release-manifest.json` (+ `WixAdditionalTools.exe`); loglar
`logs/` altında.

## Ne kullanır

| Bileşen | Rol |
|---|---|
| `Jenkinsfile` | ince orkestrasyon; günlük 03:00 (Europe/Istanbul), `PUBLISH` parametresi |
| `Run-TagBuild.ps1` / `Clear-TagRun.ps1` | host'ta docker container kurulumu + temizlik |
| `Build-Wix.ps1` + `Install-BuildEnv.ps1` | container içi üretim + toolchain (VS Build Tools 17.14, .NET SDK 8/9, MinGit, pwsh — hepsi SHA-256 pinli) |
| İç NuGet feed (`nuget.c2tech.local`) | paket kaynağı + yayın hedefi (`FEED_URL` zorunlu) |
| Jenkins credential | `nuget-push-api-key` (push), git checkout credential'ı |

## Kullanım / sorun giderme

- Job: Pipeline → "Pipeline script from SCM" → bu depo, Script Path `Jenkinsfile`.
- `FEED_URL` tanımsızsa koşu ilk adımda durur; `PUBLISH=false` ile yalnız derleme provası yapılır.
- Karar özeti konsolda: `discovery result: build=[...] publish=[...]`; ayrıntı `discovery.json`.
- Yayınlanacak set isim kuralıdır: `wix` + `WixToolset.*`; `WixInternal.*` arşivde kalır.

Lisans: kaynak ağaç upstream MS-RL; bu depo yalnız derleme hattıdır.
