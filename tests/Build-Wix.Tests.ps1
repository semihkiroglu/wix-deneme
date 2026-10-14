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
    [IO.File]::WriteAllText((Join-Path $folder 'SomeVerInfo.props.pp'), '<Project><PackageVersion>{major}.{minor}.{patch}{dashlabel}</PackageVersion></Project>')
    [IO.File]::WriteAllText((Join-Path $folder 'Directory.Packages.props.pp'), '<PackageVersion Include="X" Version="{packageversion}" />')
    [IO.File]::WriteAllText((Join-Path $folder 'global.json.pp'), '{"msbuild-sdks":{"WixToolset.Sdk":"{packageversion}"}}')
    Set-InternalVersionTemplates $root
    if ([IO.File]::ReadAllText((Join-Path $folder 'SomeVerInfo.props.pp')) -notmatch '\{patch\}\.1') { throw 'Package template unchanged' }
    if ([IO.File]::ReadAllText((Join-Path $folder 'Directory.Packages.props.pp')) -notmatch '\{packageversion\}\.1') { throw 'Dependency template unchanged' }
    if ([IO.File]::ReadAllText((Join-Path $folder 'global.json.pp')) -notmatch '\{packageversion\}\.1') { throw 'SDK template unchanged' }
    [IO.File]::WriteAllText((Join-Path $folder 'SomeVerInfo.props.pp'), '<Project>unrecognized upstream template</Project>')
    $rejected = $false
    try { Set-InternalVersionTemplates $root } catch { $rejected = $true }
    if (-not $rejected) { throw 'Changed upstream template silently accepted' }
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
$trx=Join-Path ([IO.Path]::GetTempPath()) ('wix-allowlist-' + [Guid]::NewGuid().ToString('N') + '.trx')
[IO.File]::WriteAllText($trx,'<TestRun xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010"><Results><UnitTestResult testName="A.B" outcome="Failed" /><UnitTestResult testName="A.C" outcome="Passed" /><UnitTestResult testName="A.D" outcome="NotExecuted" /></Results></TestRun>')
try { $failed=@(Get-TrxFailedTests $trx) } finally { Remove-Item $trx -Force }
if ($failed.Count -ne 1 -or $failed[0] -ne 'A.B') { throw 'TRX failed-test extraction is wrong' }
Write-Host 'PASS: container-limited MsiE2E allowlist, TRX verification and limitation notes are in place'
