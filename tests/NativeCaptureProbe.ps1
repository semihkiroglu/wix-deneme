# Diagnose upstream's actual native process-capture path; no build/test bypass.
param([string]$Tool, [string]$ProbeRoot)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Native capture probe requires Windows' }
if ($Tool) {
    Add-Type -Path (Join-Path $ProbeRoot 'CaptureProbe.dll')
    $result = [CaptureProbe]::Execute($Tool, '-property installationPath -version [17.0,18.0)')
    Write-Host "NATIVE_CAPTURE_RETURNED exit=$($result.ExitCode) lines=$($result.StandardOutput.Count)"
    if ($result.ExitCode -ne 0) { throw 'Native captured child failed' }
    exit 0
}
$ProbeRoot = Join-Path $env:RUNNER_TEMP 'wix-native-capture-probe'
New-Item -ItemType Directory -Force $ProbeRoot | Out-Null
$sha = 'b8977d6f88e7b68e000bac226a2814f236770570'
$files = foreach ($name in @('ExternalExecutable.cs', 'ExternalExecutableResult.cs')) {
    $path = Join-Path $ProbeRoot $name
    Invoke-WebRequest "https://raw.githubusercontent.com/wixtoolset/wix/$sha/src/internal/WixInternal.MSTestSupport/$name" -OutFile $path
    $path
}
$caller = Join-Path $ProbeRoot 'CaptureProbe.cs'
[IO.File]::WriteAllText($caller, @'
using WixInternal.MSTestSupport;
public sealed class CaptureProbe : ExternalExecutable {
    private CaptureProbe(string tool) : base(tool) {}
    public static ExternalExecutableResult Execute(string tool, string args) {
        return new CaptureProbe(tool).Run(args, true);
    }
}
'@)
Add-Type -Path ($files + $caller) -OutputAssembly (Join-Path $ProbeRoot 'CaptureProbe.dll')
$real = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $real)) { throw 'Real Microsoft vswhere missing' }
$wrapper = Join-Path $ProbeRoot 'vswhere.exe'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $csc /nologo /target:exe "/out:$wrapper" (Join-Path (Split-Path $PSScriptRoot -Parent) 'VswhereBootstrap.cs')
if ($LASTEXITCODE -ne 0) { throw 'Wrapper compilation failed' }
$env:CTECH_VSWHERE_REAL = $real
$hostExe = (Get-Process -Id $PID).Path
foreach ($candidate in @($real, $wrapper)) {
    $name = if ($candidate -eq $real) { 'real' } else { 'wrapper' }
    $output = Join-Path $ProbeRoot "$name.out.log"
    $errorLog = Join-Path $ProbeRoot "$name.err.log"
    $arguments = "-NoProfile -File `"$PSCommandPath`" -Tool `"$candidate`" -ProbeRoot `"$ProbeRoot`""
    $process = Start-Process $hostExe -ArgumentList $arguments -PassThru -RedirectStandardOutput $output -RedirectStandardError $errorLog
    if (-not $process.WaitForExit(20000)) {
        Stop-Process -Id $process.Id -Force
        throw "NATIVE_CAPTURE_HANG: $name; upstream native reader did not return within 20 seconds"
    }
    Get-Content $output,$errorLog
    if ($process.ExitCode -ne 0) { throw "NATIVE_CAPTURE_FAILED: $name exit=$($process.ExitCode)" }
    Write-Host "NATIVE_CAPTURE_PASS: $name"
}
