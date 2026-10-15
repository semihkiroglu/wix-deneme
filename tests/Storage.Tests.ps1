# Execute the workflow's actual preparation block; only OS/Docker boundaries are mocked.
$ErrorActionPreference='Stop'
$text=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../.github/workflows/build-wix7.yml'))
$match=[regex]::Match($text,'(?ms)      - name: Prepare disposable Windows Docker storage\r?\n.*?        run: \|\r?\n(?<code>.*?)(?=      - name:)')
if (-not $match.Success) { throw 'Disposable runner Docker storage preparation missing' }
$prepare=[scriptblock]::Create(($match.Groups['code'].Value -replace '(?m)^          ',''))
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('wix-storage-' + [Guid]::NewGuid().ToString('N'))
$oldProgramData=$env:ProgramData; $oldRunner=$env:RUNNER_ENVIRONMENT; $oldActions=$env:GITHUB_ACTIONS
$env:ProgramData=$testRoot
$script:free=100GB; $script:containers=@(); $script:restarts=0
function Get-CimInstance { param($ClassName,$Filter) [pscustomobject]@{FreeSpace=$script:free} }
function docker {
    $global:LASTEXITCODE=0
    if ($args[0] -eq 'ps') { return $script:containers }
    if ($args[0] -eq 'info') { $global:LASTEXITCODE=0; return 'D:\wix-docker' }
    throw "Unexpected docker invocation: $args"
}
function dockerd { $global:LASTEXITCODE=0 }
function Restart-Service { param($Name) $script:restarts++ }
function Get-Service {
    param($Name)
    $service=[pscustomobject]@{}
    $service | Add-Member ScriptMethod WaitForStatus { param($Status,$Timeout) }
    return $service
}
try {
    $env:GITHUB_ACTIONS='true'; $env:RUNNER_ENVIRONMENT='self-hosted'
    $rejected=$false
    try { . $prepare } catch { $rejected=$_.Exception.Message -match 'github-hosted' }
    if (-not $rejected -or $script:restarts -or (Test-Path $testRoot)) { throw 'Shared host was modified' }
    $env:RUNNER_ENVIRONMENT='github-hosted'; $script:free=20GB
    $rejected=$false
    try { . $prepare } catch { $rejected=$_.Exception.Message -match 'free space' }
    if (-not $rejected -or $script:restarts) { throw 'Low-space runner was accepted' }
    $script:free=100GB; $script:containers=@('unrelated-container')
    $rejected=$false
    try { . $prepare } catch { $rejected=$_.Exception.Message -match 'containers' }
    if (-not $rejected -or $script:restarts) { throw 'Existing container workload was disturbed' }
    $script:containers=@()
    $testConfigPath=Join-Path $testRoot 'Docker/config/daemon.json'
    New-Item -ItemType Directory -Force (Split-Path $testConfigPath) | Out-Null
    [IO.File]::WriteAllText($testConfigPath,'{"debug":false,"exec-opts":["isolation=process"]}')
    . $prepare
    $actual=Get-Content $testConfigPath -Raw | ConvertFrom-Json
    if ($actual.'data-root' -ne 'D:\wix-docker' -or $actual.debug -ne $false -or $actual.'exec-opts'[0] -ne 'isolation=process' -or $script:restarts -ne 1) { throw 'Docker config was not merged and applied exactly once' }
    Write-Host 'PASS: shared-host refusal, free-space refusal, workload refusal and config-preserving D: relocation'
    $pipeline=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../Run-TagBuild.ps1'))
    $guard=[regex]::Match($pipeline,'(?ms)(?<code>\$storageDrive = .*?)(?=Write-Host "Docker storage:)')
    if (-not $guard.Success) { throw 'Production Docker storage free-space guard missing' }
    $checkStorage=[scriptblock]::Create($guard.Groups['code'].Value)
    $info=[pscustomobject]@{DockerRootDir='D:\docker'}
    $script:free=20GB; $rejected=$false
    try { . $checkStorage } catch { $rejected=$_.Exception.Message -match 'free space' }
    if (-not $rejected) { throw 'Production build accepted insufficient Docker storage' }
    $script:free=100GB
    . $checkStorage
    Write-Host 'PASS: production disk guard rejects 20 GiB and accepts 100 GiB without changing daemon settings'
} finally {
    $env:ProgramData=$oldProgramData; $env:RUNNER_ENVIRONMENT=$oldRunner; $env:GITHUB_ACTIONS=$oldActions
    if (Test-Path $testRoot) { Remove-Item $testRoot -Recurse -Force }
}
