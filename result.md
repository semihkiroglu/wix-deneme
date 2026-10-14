# WiX 7.0.0 Jenkins Docker gece devri — sonuç (14.10.2026)

## Durum
**Blocked.** Gerçek Windows runtime'da baseline v7.0.0 build PASS elde edilemedi. Üç ayrı yaklaşım denenip üçü de farklı noktalarda fail oldu. Helper regression testler (Build-Wix.Tests.ps1, VswhereBootstrap.Tests.ps1, Publish-Wix.Tests.ps1) her commit'te PASS. Üretim `main`'i (b1fcc0f) korunmuş durumda.

## Denenenler (gerçek run ID + HEAD + sonuç)

| # | HEAD   | Run ID         | Yaklaşım                                                                                                | Sonuç                                   |
|---|--------|----------------|---------------------------------------------------------------------------------------------------------|-----------------------------------------|
| 1 | b2ab9c3 | 38473780325    | `MsbuildBootstrap.exe` PATH head'inde; CTECH_MSBUILD'a -m:1 ekleyen launcher                            | FAIL @ "Building internal Release" — NuGet wrapper'ın 0.0.0.0 ürün sürümünü okuyup slnx restore'u reddediyor |
| 2 | 9ad3da7 | 38484584524    | Wrapper.exe → `msbuild.cmd` shim; NuGet msbuild.exe araması gerçek derleyiciye düşüyor (17.14.40.60911) | FAIL @ "Building internal Release" — dtf.cmd'ın ilk msbuild çağrısı (SfxCA.vcxproj) cmd.exe'den 1 ile dönüyor, dtf.slnx -t:Pack atlandı, Dtf nupkg üretilmedi |
| 3 | 75bf887 | 38490924958    | Wrapper tamamen kaldırıldı; VsDevCmd'in gerçek MSBuild'ı doğrudan kullanılıyor                           | 3h+ sonra Jenkins adımı hâlâ tamamlanmadı (iptal) — upstream `msbuild -m` ile paralel; muhtemelen WiX pipeline'ın wixnative race tarafında asılı |

## Yardımcı testler (PASS)
- `./tests/Build-Wix.Tests.ps1` — `Get-InternalVersion`, `Set-InternalVersionTemplates`, Jenkins staging loop, smoke poll recovery → PASS
- `./tests/VswhereBootstrap.Tests.ps1` — VswhereBootstrap.exe 9 senaryo + MSBuild shim yokluğu → 17/17 PASS
- `./tests/Publish-Wix.Tests.ps1` (Windows PowerShell 5.1) → PASS

## Kalıcı artifact
Hiçbir PASS olmadığı için Jenkins'ten indirilen nupkg/snupkg/WixAdditionalTools.exe yok. Tek somut ürün son derece kısmi:

- `/home/ubuntu/.hermes/cache/scratch/wix-jenkins-evidence-38484584524/jenkins-wix7-smoke-38484584524/artifacts/artifacts/v7.0.0/logs/dtf_sfxca.binlog` (621656 bayt): SfxCA.vcxproj x86/x64/ARM64 için compile + link başarılı; binlog içinde "Build succeeded"; fakat dtf.slnx Pack hedefi hiç çalışmadı.

Diğer evidence klasörleri: `38473780325`, `38484584524`. `38490924958` iptal edildiği için evidence indirilemedi.

## Main durumu
`main` korunmadı: **b1fcc0fa** üzerinde hiçbir değişiklik yapılmadı. Branch `jenkins-wix` HEAD `75bf887` (wrapper tamamen kaldırılmış hal); geri alma veya başka yaklaşım denemek branch üzerinden yapılabilir, main teslim edilmedi.

## BaGetter push
Yapılmadı. Hiçbir gerçek PASS olmadığı için `/Publish-Wix.ps1 -FeedUrl ... -ManifestDir artifacts/v7.0.0` çağrısı invoke edilmedi. BaGetter URL hâlâ placeholder (`https://nuget.example.internal/v3/index.json`).

## Kalan riskler
1. **Wrapper'sız paralel race**: 38490924958'in hangi aşamada takıldığı binlog indirilemeden teyit edilemedi (run iptal edildi). Muhtemel sebep: `wixnative.exe.recipe` race (3 platform için paralel çalışan `wixnative_t.proj`). `src/wix/wix.cmd` `-m` ile çalıştırıyor.
2. **Tanı eksik**: `.cmd shim`'in neden wrapper.exe'den farklı cmd.exe exit kodu verdiği (SfxCA.dll üretildiği, binlog "Build succeeded" dediği halde `|| exit /b`'in tetiklenmesi) Windows'ta kısa bir probe ile kesin olarak ayıklanmadı. Muhtemelen cmd.exe'nin `.cmd` ve `.exe` parser'ı farklı tokenizasyon, ya da wrapper.exe'nin `Process.Start`'ı farklı lpCommandLine yayıyor. Kısa bir actual Windows probe (yalnızca `msbuild SfxCA/sfxca_t.proj ...`) iki yol arasındaki farkı izole edebilirdi.
3. **Kurumsal sunucu**: `windows1` label'lı Jenkins agent'a erişim yok; sadece GHA windows-2025 runner ile harness üzerinden rehearsal yapıldı.

## Sonraki adım için öneri
Mevcut çalışmayı durdurup kullanıcıya çıkmak mantıklı. Üç yaklaşımın hiçbiri PASS vermedi; sahte başarı yok, baseline yok. Kullanıcı yeni bir karar verene kadar branch'i temiz tutmak için 75bf887 HEAD'i koruyorum.
