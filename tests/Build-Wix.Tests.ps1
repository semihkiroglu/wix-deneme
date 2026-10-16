$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot '../Build-Wix.ps1'
if (-not (Test-Path $script)) { throw 'Build-Wix tag/template implementation missing' }
. $script -Tag 'v7.0.0' -Output (Join-Path $PSScriptRoot 'unused')
if ((Get-InternalVersion 'v7.0.0') -ne '7.0.0.1') { throw 'Initial 7 release rejected' }
if ((Get-InternalVersion 'v10.2.3') -ne '10.2.3.1') { throw 'Numeric later release rejected' }
foreach ($bad in @('v6.0.2','v7.0.0-rc.1','7.0.0','v7.0.0/../other','v7.0.0;exit')) {
    $rejected = $false
    try { Get-InternalVersion $bad | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw "Unsafe/unsupported tag accepted: $bad" }
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('wix-template-' + [Guid]::NewGuid().ToString('N'))
$folder = Join-Path $root 'src/internal/SetBuildNumber'
New-Item -ItemType Directory -Force $folder | Out-Null
try {
    # Counts mirror the pinned v7.0.0 templates (1 / 33 / 1 matches); Set-InternalVersionTemplates enforces them.
    $props = '<Project><PackageVersion>{major}.{minor}.{patch}{dashlabel}</PackageVersion></Project>'
    $packages = '<Project>' + ((1..33 | ForEach-Object { "<PackageVersion Include=`"P$_`" Version=`"{packageversion}`" />" }) -join '') + '</Project>'
    $sdkJson = '{"msbuild-sdks":{"WixToolset.Sdk":"{packageversion}"}}'
    [IO.File]::WriteAllText((Join-Path $folder 'SomeVerInfo.props.pp'), $props)
    [IO.File]::WriteAllText((Join-Path $folder 'Directory.Packages.props.pp'), $packages)
    [IO.File]::WriteAllText((Join-Path $folder 'global.json.pp'), $sdkJson)
    Set-InternalVersionTemplates $root
    if ([IO.File]::ReadAllText((Join-Path $folder 'SomeVerInfo.props.pp')) -notmatch '\{patch\}\.1') { throw 'Package template unchanged' }
    if ([IO.File]::ReadAllText((Join-Path $folder 'Directory.Packages.props.pp')) -notmatch '\{packageversion\}\.1') { throw 'Dependency template unchanged' }
    if ([IO.File]::ReadAllText((Join-Path $folder 'global.json.pp')) -notmatch '\{packageversion\}\.1') { throw 'SDK template unchanged' }
    $replaced = @([regex]::Matches([IO.File]::ReadAllText((Join-Path $folder 'Directory.Packages.props.pp')), 'Version="\{packageversion\}\.1"')).Count
    if ($replaced -ne 33) { throw "Dependency template replaced $replaced of 33 occurrences" }
    [IO.File]::WriteAllText((Join-Path $folder 'SomeVerInfo.props.pp'), '<Project>unrecognized upstream template</Project>')
    $rejected = $false
    try { Set-InternalVersionTemplates $root } catch { $rejected = $true }
    if (-not $rejected) { throw 'Changed upstream template silently accepted' }
    [IO.File]::WriteAllText((Join-Path $folder 'SomeVerInfo.props.pp'), ($props + '<Extra><PackageVersion>{major}.{minor}.{patch}{dashlabel}</PackageVersion></Extra>'))
    $rejected = $false
    try { Set-InternalVersionTemplates $root } catch { $rejected = $true }
    if (-not $rejected) { throw 'Template with an unexpected occurrence count was silently accepted' }
} finally { Remove-Item $root -Recurse -Force }
Write-Host 'PASS: stable 7+ tags, rejection boundaries, exact three version replacements and incompatible-template rejection'

# nuget.config substitution: count-enforced, internal default, environment override.
$nugetRoot = Join-Path ([IO.Path]::GetTempPath()) ('wix-nugetcfg-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $nugetRoot | Out-Null
try {
    $cfg = '<?xml version="1.0"?><configuration><packageSources><add key="nuget" value="https://api.nuget.org/v3/index.json" /></packageSources></configuration>'
    [IO.File]::WriteAllText((Join-Path $nugetRoot 'nuget.config'), $cfg)
    Set-UpstreamNuGetSource $nugetRoot
    if ([IO.File]::ReadAllText((Join-Path $nugetRoot 'nuget.config')) -notmatch 'nuget\.c2tech\.local/v3/index\.json') { throw 'nuget.config was not redirected to the internal feed' }
    $env:WIX_NUGET_SOURCE = 'https://api.nuget.org/v3/index.json'
    [IO.File]::WriteAllText((Join-Path $nugetRoot 'nuget.config'), $cfg)
    Set-UpstreamNuGetSource $nugetRoot
    if ([IO.File]::ReadAllText((Join-Path $nugetRoot 'nuget.config')) -notmatch 'api\.nuget\.org/v3/index\.json') { throw 'WIX_NUGET_SOURCE override ignored' }
    Set-Item Env:WIX_NUGET_SOURCE -Value ''
    [IO.File]::WriteAllText((Join-Path $nugetRoot 'nuget.config'), '<configuration></configuration>')
    $rejected=$false; try { Set-UpstreamNuGetSource $nugetRoot | Out-Null } catch { $rejected=$_.Exception.Message -match 'nuget.config' }
    if (-not $rejected) { throw 'nuget.config without the expected source token was accepted' }
    foreach ($case in @(@('wix',$true),@('WixToolset.Sdk',$true),@('WixToolset.Core',$true),@('WixToolset.Util.wixext',$true),@('WixInternal.TestSupport',$false),@('WixInternal.BaseBuildTasks.Sources',$false))) {
        if ((Test-PublicPackage $case[0]) -ne $case[1]) { throw "Feed name rule misclassified $($case[0])" }
    }
} finally {
    [Environment]::SetEnvironmentVariable('WIX_NUGET_SOURCE', $null)
    Remove-Item $nugetRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'PASS: nuget.config is redirected to the internal feed with a count-enforced, overridable substitution'

# Execute the harness's real staging loop and check its Docker COPY contract.
& {
    $Source=Split-Path $PSScriptRoot -Parent
    $workspace=Join-Path ([IO.Path]::GetTempPath()) ('wix-staging-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $workspace | Out-Null
    try {
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'JenkinsSmoke.ps1'),[ref]$tokens,[ref]$errors)
        $stages=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Variable.VariablePath.UserPath -eq 'file'},$true))
        if ($errors.Count -or $stages.Count -ne 1) { throw 'Expected one valid harness staging loop' }
        . ([scriptblock]::Create($stages[0].Extent.Text))
        foreach ($line in Get-Content (Join-Path $Source 'Dockerfile') | Where-Object { $_ -match '^COPY ' }) {
            $parts=$line -split '\s+'
            foreach ($file in $parts[1..($parts.Count-2)]) {
                if (-not (Test-Path (Join-Path $workspace $file))) { throw "Harness omits Docker COPY source: $file" }
            }
        }
    } finally { Remove-Item $workspace -Recurse -Force }
    Write-Host 'PASS: actual Jenkins staging supplies all Docker COPY sources'
}

# Exercise the actual smoke loop without starting Jenkins or downloading tooling.
& {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'JenkinsSmoke.ps1'),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'Jenkins smoke script parse failed' }
    $loops=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.WhileStatementAst]},$true))
    if ($loops.Count -ne 1) { throw 'Expected one Jenkins polling loop' }
    $poll=[scriptblock]::Create($loops[0].Extent.Text)
    $server=[pscustomobject]@{HasExited=$false}
    $base='http://jenkins.invalid'
    $deadline=[DateTime]::UtcNow.AddMinutes(1)
    $startupDeadline=[DateTime]::UtcNow.AddMinutes(-1)
    $build=$null; $consoleOffset=0; $script:polls=0
    $Evidence=Join-Path ([IO.Path]::GetTempPath()) ('wix-live-console-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $Evidence | Out-Null
    function Invoke-RestMethod {
        param($Uri,$TimeoutSec)
        $script:polls++
        if ($script:polls -eq 2) { throw 'Expected temporary Jenkins status failure' }
        return [pscustomobject]@{building=($script:polls -lt 3);result= $(if ($script:polls -ge 3) {'SUCCESS'} else {$null})}
    }
    function Invoke-WebRequest { param($Uri,$TimeoutSec) return [pscustomobject]@{Content='running'} }
    function Start-Sleep { param($Seconds) }
    . $poll 3>$null
    if ($script:polls -ne 3 -or $build.result -ne 'SUCCESS') { throw 'Smoke loop did not recover from a temporary status failure' }
    $liveConsole=Join-Path $Evidence 'jenkins-build.log'
    if (-not (Test-Path $liveConsole) -or [IO.File]::ReadAllText($liveConsole) -ne 'running') { throw 'Live Jenkins console was not persisted before build completion' }
    Remove-Item $Evidence -Recurse -Force
    function Invoke-RestMethod { param($Uri,$TimeoutSec) throw 'Expected unavailable Jenkins job' }
    $build=$null; $rejected=$false
    try { . $poll 3>$null } catch { $rejected=$_.Exception.Message -match 'Jenkins job did not start' }
    if (-not $rejected) { throw 'Smoke loop lost its hard startup deadline' }
    $criticalDisk=[pscustomobject]@{DeviceID='C:';FreeSpace=0}
    $rejected=$false
    try { . $poll 3>$null } catch { $rejected=$_.Exception.Message -match 'Disk space exhausted' }
    if (-not $rejected) { throw 'Smoke loop keeps waiting after disk exhaustion' }
    Write-Host 'PASS: Jenkins status recovery, startup deadline and disk-exhaustion rejection'
}

$docker=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../Dockerfile'))
# MSI database creation over MAX_PATH needs OS-wide long paths; the base image does not enable them.
if ($docker -notmatch 'LongPathsEnabled /t REG_DWORD /d 1 /f') { throw 'MSI creation over long paths fails unless the image enables LongPathsEnabled' }
Write-Host 'PASS: OS-wide long paths are enabled in the image'

# The database itself is opened through an 8.3 short name (LongPathUtil.CreateOrGetShortPath -> GetShortPathNameW); container volumes create no aliases by default.
$build=(Get-Content $script -Raw)
if (-not $build.Contains("'8dot3name','set','C:','0'")) { throw 'Build-Wix must enable 8.3 short names for MSI creation over long paths' }
if ($build -notmatch 'wix-8dot3-probe') { throw 'Build-Wix must fail fast when the container cannot create 8.3 short names' }
Write-Host 'PASS: the container enables the 8.3 short names MSI creation over long paths needs'

# The native toolchain keeps the ATL component installed.
$envScript=(Get-Content (Join-Path $PSScriptRoot '../Install-BuildEnv.ps1') -Raw)
if (-not $envScript.Contains('Microsoft.VisualStudio.Component.VC.ATL')) { throw 'Install-BuildEnv must keep the ATL component for the native toolchain' }
Write-Host 'PASS: the environment installs ATL for the native toolchain'

if (-not $build.Contains('--untracked-files=all')) { throw 'Build-Wix must guard untracked files in the upstream checkout' }
if (-not $build.Contains('source_sha=$Sha')) { throw 'The release manifest must record the actual upstream commit of every build' }
if (-not $build.Contains('Get-FileHash $symbol')) { throw 'Manifest symbol packages need their own hash for publication verification' }
if ($build.Contains('test.cmd') -or $build.Contains('$AllowedContainerFailures') -or $build.Contains('Assert-TrxConsistent')) { throw 'Build-Wix must stay test-free; a green build is the gate' }
if ($build.Contains('$ExpectedPublicPackages')) { throw 'The dead per-release public pin must not return; the name rule is the classifier' }
if ($build.Contains('v3-flatcontainer')) { throw 'Build-Wix must not contact nuget.org (blocked on the build network)' }
if (-not $build.Contains('nuget.c2tech.local')) { throw 'The internal feed must be the default NuGet source substitution target' }
if (-not $build.Contains('WIX_NUGET_SOURCE')) { throw 'The NuGet source substitution needs its environment override' }
if (-not $build.Contains("'nuget.config'")) { throw 'The nuget.config substitution must be in the guarded allowlist' }
if (-not $build.Contains('$changed.Count -lt 3')) { throw 'The diff guard must accept the no-op substitution case (three template files)' }
# Toolchain payloads must be hash-pinned (Install-BuildEnv.ps1 constants + -Sha256 verification).
foreach ($pin in @(
    '62d8e57ac5ccd56eabd627c9de2cafe4dc463f9db520a72673ed08b1e83c48b7',
    'e8b873e18a81e5c4cd8ab69d84dac8fead291d50b3c44633cd7fddad709a13d6',
    '02fe458be20493fbdf43f61ea20610b811ee6c738ab1676c61b9cfcd1a33c860',
    'd4bf83d6a860ccae9af44e508e1e00a39f09db6fa78a9ba5543b94d87ca22a29',
    '992d70cac5b06c38efec91806caba64cdcc07e6d963a0959dbbbaf264d33b800'
)) { if (-not $envScript.Contains($pin)) { throw "Install-BuildEnv is missing a pinned payload hash: $pin" } }
if (@([regex]::Matches($envScript, 'Get-PinnedFile \S+ \S+ -Sha256')).Count -lt 6) { throw 'All toolchain payload downloads must pass -Sha256' }
if ($envScript.Contains('CommonExtensions\Microsoft\NuGet\NuGet.exe')) { throw 'Build Tools ships no nuget.exe CLI; the dead lookup branch must not return' }
Write-Host 'PASS: the toolchain payloads are hash-pinned'

# The smoke harness must not verify downloads against sidecar checksums fetched from the same source.
$smoke=(Get-Content (Join-Path $PSScriptRoot 'JenkinsSmoke.ps1') -Raw)
foreach ($pin in @('393bf2476352dd726519fd1f92ce66eac7d23c0936e6967420b717060c4c40d0','a86853ec2e2933f37a4b471ba65099b61e03c87a80c2ef8fe2315eb135672d43')) {
    if (-not $smoke.Contains($pin)) { throw "JenkinsSmoke is missing a pinned download hash: $pin" }
}
if ($smoke.Contains('$war.sha256') -or $smoke.Contains('$manager.sha256')) { throw 'JenkinsSmoke must not rely on sidecar checksum files from the same remote' }
Write-Host 'PASS: Jenkins downloads are pinned to embedded hashes'

# The Jenkinsfile stays thin orchestration; the host scripts must keep their guarantees.
$jenkinsfile=(Get-Content (Join-Path $PSScriptRoot '../Jenkinsfile') -Raw)
$runtag=(Get-Content (Join-Path $PSScriptRoot '../Run-TagBuild.ps1') -Raw)
$clearrun=(Get-Content (Join-Path $PSScriptRoot '../Clear-TagRun.ps1') -Raw)
if (-not ($runtag.Contains('Get-ChildItem -LiteralPath $outDir') -and $runtag.Contains('Remove-Item -Recurse -Force'))) { throw 'The per-tag artifact directory must be cleared before each build so stale packages cannot be archived' }
if (-not $jenkinsfile.Contains("(Get-Location) 'logs'")) { throw 'The persistent logs directory must be cleared at the start of every run so stale logs cannot be archived' }
if (-not $runtag.Contains('WIX_NUGET_SOURCE')) { throw 'Run-TagBuild must forward WIX_NUGET_SOURCE into the build container' }
if (-not ($runtag.Contains('docker @createArgs') -and $runtag.Contains('Tee-Object'))) { throw 'Run-TagBuild must provision and log the container build itself' }
if (-not ($clearrun.Contains('docker rm -f') -and $clearrun.Contains('docker rmi'))) { throw 'Clear-TagRun must scope cleanup to this build own containers and images' }
if (-not ($jenkinsfile.Contains('Run-TagBuild.ps1') -and $jenkinsfile.Contains('Clear-TagRun.ps1'))) { throw 'The Jenkinsfile must delegate to the repository scripts' }
if ($jenkinsfile.Contains('__WS__')) { throw 'The Jenkinsfile must not carry render placeholders' }
if (-not $jenkinsfile.Contains('FEED_URL is required')) { throw 'A missing FEED_URL must fail the run loudly' }
if (-not ($jenkinsfile.Contains('checkout scm') -and $jenkinsfile.Contains('WIX_PIPELINE_SOURCE'))) { throw 'The Checkout stage must branch: harness workspace vs real SCM checkout' }
if (-not $smoke.Contains('FEED_URL')) { throw 'The smoke harness must provide an explicit FEED_URL' }
foreach ($file in @('Run-TagBuild.ps1','Clear-TagRun.ps1')) {
    if (-not $smoke.Contains($file)) { throw "The smoke harness must stage $file into the workspace" }
}
Write-Host 'PASS: the Jenkinsfile is thin orchestration over the repository scripts'

# Documentation must describe the delivered pipeline, and process snapshots must not live in the repository.
$readme=(Get-Content (Join-Path $PSScriptRoot '../README.md') -Raw)
if (-not ($readme.Contains('v7.0.0') -and $readme.Contains('Jenkins'))) { throw 'README must describe the WiX 7 Jenkins pipeline' }
if ($readme.Contains('6.0.2')) { throw 'README still describes the WiX 6.0.2 Actions build' }
foreach ($residue in @('progress.json','result.md','telegram-summary.txt')) {
    if (Test-Path (Join-Path $PSScriptRoot "../$residue")) { throw "Process residue must not live in the repository: $residue" }
}
Write-Host 'PASS: README matches the delivered pipeline and no process residue is committed'
