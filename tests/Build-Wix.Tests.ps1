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
foreach ($setting in @('TESTINGPLATFORM_DIAGNOSTIC=1','TESTINGPLATFORM_DIAGNOSTIC_VERBOSITY=Trace','TESTINGPLATFORM_DIAGNOSTIC_OUTPUT_DIRECTORY=C:\output\logs\testdiagnostics')) {
    if (-not $docker.Contains($setting)) { throw "Test diagnostics would be lost inside the build container: $setting" }
}
# Upstream LongPathFixture runs `Database.Create` (MsiOpenDatabase) on a >MAX_PATH path; msi.dll only allows that when long paths are enabled OS-wide.
if (-not $docker.Contains('Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f')) { throw 'LongPathFixture fails inside the container unless the image enables LongPathsEnabled' }
Write-Host 'PASS: test diagnostics write into the mounted artifact output and OS-wide long paths are enabled in the image'

# The database itself is opened through an 8.3 short name (LongPathUtil.CreateOrGetShortPath -> GetShortPathNameW); container volumes create no aliases by default.
$build=(Get-Content $script -Raw)
if (-not $build.Contains("'8dot3name','set','C:','0'")) { throw 'Build-Wix must enable 8.3 short names for the upstream long-path MSI test' }
if ($build -notmatch 'wix-8dot3-probe') { throw 'Build-Wix must fail fast when the container cannot create 8.3 short names' }
Write-Host 'PASS: the container enables the 8.3 short names the upstream long-path MSI test relies on'

# The upstream ComPlusExtensionTests native test component is an ATL project (atlbase.h); the Build Tools install must include and verify it.
$envScript=(Get-Content (Join-Path $PSScriptRoot '../Install-BuildEnv.ps1') -Raw)
if (-not $envScript.Contains('Microsoft.VisualStudio.Component.VC.ATL')) { throw 'Install-BuildEnv must install the ATL component required by the upstream ComPlus native test component' }
if (-not ($envScript.Contains('atlmfc') -and $envScript.Contains('atlbase.h'))) { throw 'Install-BuildEnv must verify the installed ATL headers' }
Write-Host 'PASS: the environment installs and verifies ATL for the upstream native test component'

# The container-limited MsiE2E allowlist and its TRX verification (see docs/container-test-notes.md).
if (-not $build.Contains('$AllowedContainerFailures')) { throw 'Build-Wix must carry the verified container-limited failure list' }
if (-not $build.Contains('WixToolsetTest.MsiE2E.trx')) { throw 'Build-Wix must check the MsiE2E results against the allowlist' }
if (-not (Test-Path (Join-Path $PSScriptRoot '../docs/container-test-notes.md'))) { throw 'Container test limitation notes missing' }
if (-not $build.Contains('Assert-TrxConsistent')) { throw 'Build-Wix must validate TRX completeness/consistency, not just Failed nodes' }
if (-not $build.Contains('outside the container-limited')) { throw 'Build-Wix must refuse test chain failures outside the container-limited stage' }
if (-not $build.Contains('--untracked-files=all')) { throw 'Build-Wix must guard untracked files in the upstream checkout' }
if (-not $build.Contains('$ExpectedUpstreamCommits')) { throw 'Build-Wix must pin each release tag to its recorded upstream commit' }
if (-not $build.Contains('b8977d6f88e7b68e000bac226a2814f236770570')) { throw 'The v7.0.0 upstream commit pin is missing from Build-Wix' }
if (-not $build.Contains('Get-FileHash $symbol')) { throw 'Manifest symbol packages need their own hash for publication verification' }

function New-TestTrx([string]$Path, [string]$Counters, [string]$Results) {
    [IO.File]::WriteAllText($Path, '<TestRun xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010"><ResultSummary outcome="Failed"><Counters ' + $Counters + ' /></ResultSummary><Results>' + $Results + '</Results></TestRun>')
}
$trx=Join-Path ([IO.Path]::GetTempPath()) ('wix-allowlist-' + [Guid]::NewGuid().ToString('N') + '.trx')
try {
    # Real semantics: skipped tests are NotExecuted nodes while counters.notExecuted is 0 (skipped = total - executed).
    New-TestTrx $trx 'total="3" executed="2" passed="1" failed="1" error="0" timeout="0" aborted="0" inconclusive="0" passedButRunAborted="0" notRunnable="0" notExecuted="0"' '<UnitTestResult testName="A.B" outcome="Failed" /><UnitTestResult testName="A.C" outcome="Passed" /><UnitTestResult testName="A.D" outcome="NotExecuted" />'
    $failed=@(Assert-TrxConsistent (Get-TrxState $trx) $trx 1)
    if ($failed.Count -ne 1 -or $failed[0] -ne 'A.B') { throw 'TRX failed-test extraction is wrong' }
    New-TestTrx $trx 'total="3" executed="3" passed="1" failed="2" error="0" timeout="0" aborted="0" inconclusive="0" passedButRunAborted="0" notRunnable="0" notExecuted="0"' '<UnitTestResult testName="A.B" outcome="Failed" /><UnitTestResult testName="A.C" outcome="Passed" /><UnitTestResult testName="A.D" outcome="NotExecuted" />'
    $rejected=$false; try { Assert-TrxConsistent (Get-TrxState $trx) $trx 1 | Out-Null } catch { $rejected=$_.Exception.Message -match 'counter' }
    if (-not $rejected) { throw 'TRX with summary counters that disagree with its results was accepted' }
    New-TestTrx $trx 'total="2" executed="1" passed="1" failed="0" error="0" timeout="0" aborted="1" inconclusive="0" passedButRunAborted="0" notRunnable="0" notExecuted="0"' '<UnitTestResult testName="A.B" outcome="Passed" /><UnitTestResult testName="A.C" outcome="Aborted" />'
    $rejected=$false; try { Assert-TrxConsistent (Get-TrxState $trx) $trx 1 | Out-Null } catch { $rejected=$true }
    if (-not $rejected) { throw 'TRX with an aborted test was accepted' }
    New-TestTrx $trx 'total="1" executed="1" passed="1" failed="0" error="1" timeout="0" aborted="0" inconclusive="0" passedButRunAborted="0" notRunnable="0" notExecuted="0"' '<UnitTestResult testName="A.B" outcome="Passed" />'
    $rejected=$false; try { Assert-TrxConsistent (Get-TrxState $trx) $trx 1 | Out-Null } catch { $rejected=$_.Exception.Message -match 'run-level' }
    if (-not $rejected) { throw 'TRX with run-level errors was accepted' }
    New-TestTrx $trx 'total="1" executed="1" passed="1" failed="0" error="0" timeout="0" aborted="0" inconclusive="0" passedButRunAborted="0" notRunnable="0" notExecuted="0"' '<UnitTestResult testName="A.B" outcome="Passed" />'
    $rejected=$false; try { Assert-TrxConsistent (Get-TrxState $trx) $trx 40 | Out-Null } catch { $rejected=$_.Exception.Message -match 'at least' }
    if (-not $rejected) { throw 'TRX with fewer results than the expected minimum was accepted' }
} finally { Remove-Item $trx -Force }
Write-Host 'PASS: TRX state/consistency validation rejects partial or unexpected results'

# Toolchain payloads must be hash-pinned (Install-BuildEnv.ps1 constants + -Sha256 verification).
foreach ($pin in @(
    '62d8e57ac5ccd56eabd627c9de2cafe4dc463f9db520a72673ed08b1e83c48b7',
    'e8b873e18a81e5c4cd8ab69d84dac8fead291d50b3c44633cd7fddad709a13d6',
    '02fe458be20493fbdf43f61ea20610b811ee6c738ab1676c61b9cfcd1a33c860',
    'd4bf83d6a860ccae9af44e508e1e00a39f09db6fa78a9ba5543b94d87ca22a29',
    '992d70cac5b06c38efec91806caba64cdcc07e6d963a0959dbbbaf264d33b800'
)) { if (-not $envScript.Contains($pin)) { throw "Install-BuildEnv is missing a pinned payload hash: $pin" } }
if (@([regex]::Matches($envScript, 'Get-PinnedFile \S+ \S+ -Sha256')).Count -lt 6) { throw 'All toolchain payload downloads must pass -Sha256' }
Write-Host 'PASS: the toolchain payloads are hash-pinned'

# The smoke harness must not verify downloads against sidecar checksums fetched from the same source.
$smoke=(Get-Content (Join-Path $PSScriptRoot 'JenkinsSmoke.ps1') -Raw)
foreach ($pin in @('393bf2476352dd726519fd1f92ce66eac7d23c0936e6967420b717060c4c40d0','a86853ec2e2933f37a4b471ba65099b61e03c87a80c2ef8fe2315eb135672d43')) {
    if (-not $smoke.Contains($pin)) { throw "JenkinsSmoke is missing a pinned download hash: $pin" }
}
if ($smoke.Contains('$war.sha256') -or $smoke.Contains('$manager.sha256')) { throw 'JenkinsSmoke must not rely on sidecar checksum files from the same remote' }
Write-Host 'PASS: Jenkins downloads are pinned to embedded hashes'

# Per-build archives must not be able to retain stale packages from earlier runs.
$jenkinsfile=(Get-Content (Join-Path $PSScriptRoot '../Jenkinsfile') -Raw)
if (-not ($jenkinsfile.Contains('Get-ChildItem -LiteralPath $outDir') -and $jenkinsfile.Contains('Remove-Item -Recurse -Force'))) { throw 'The per-tag artifact directory must be cleared before each build so stale packages cannot be archived' }
Write-Host 'PASS: the per-tag artifact directory is cleared before each build'

# Documentation must describe the delivered pipeline, and process snapshots must not live in the repository.
$readme=(Get-Content (Join-Path $PSScriptRoot '../README.md') -Raw)
if (-not ($readme.Contains('v7.0.0') -and $readme.Contains('Jenkins'))) { throw 'README must describe the WiX 7 Jenkins pipeline' }
if ($readme.Contains('6.0.2')) { throw 'README still describes the WiX 6.0.2 Actions build' }
foreach ($residue in @('progress.json','result.md','telegram-summary.txt')) {
    if (Test-Path (Join-Path $PSScriptRoot "../$residue")) { throw "Process residue must not live in the repository: $residue" }
}
Write-Host 'PASS: README matches the delivered pipeline and no process residue is committed'
