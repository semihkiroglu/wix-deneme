# Host-side driver: build the pipeline image and run a container probe script inside it.
# Diagnostic only on test_only dispatches; it does not gate the Jenkins smoke.
param([string]$ContainerScript = 'MsiLongPathProbeContainer.ps1')
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'MSI long-path probe requires Windows' }
$root = Split-Path $PSScriptRoot -Parent

Write-Host '--- host system volume 8dot3 baseline ---'
& fsutil 8dot3name query C:
Add-Type -Namespace ProbeHost -Name Kernel -MemberDefinition '[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern uint GetShortPathName(string lpszLongPath, System.Text.StringBuilder lpszShortPath, uint cchBuffer);'
$hostFile = Join-Path $env:SystemRoot 'Temp\wixprobe-host.msi'
[IO.File]::WriteAllText($hostFile, 'x')
$buffer = New-Object System.Text.StringBuilder 600
[void][ProbeHost.Kernel]::GetShortPathName($hostFile, $buffer, 600)
Write-Host "HOST_SHORT result=$($buffer.ToString())"

$info = docker info --format '{{json .}}' | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $info.OSType -ne 'windows') { throw 'Windows Docker engine required' }
$kernel = [regex]::Match($info.KernelVersion, '(?:^|[^0-9])10[.]0[. ]+([0-9]+)')
if (-not $kernel.Success) { throw "Unknown Docker kernel version: $($info.KernelVersion)" }
$build = [int]$kernel.Groups[1].Value
if ($build -ge 26100) { $base = 'mcr.microsoft.com/windows/server:ltsc2025' }
elseif ($build -ge 20348) { $base = 'mcr.microsoft.com/windows/server:ltsc2022' }
else { throw "No supported Windows container base image for Windows build $build" }
Write-Host "PROBE_BASE build=$build base=$base"

$image = 'wix-longpath-probe'
try {
    docker build --force-rm --build-arg "BASE_IMAGE=$base" -f (Join-Path $root 'Dockerfile') -t $image $root
    if ($LASTEXITCODE -ne 0) { throw 'Probe image build failed' }
    docker run --rm --entrypoint powershell -v "${PSScriptRoot}:C:\probe" $image -NoProfile -ExecutionPolicy Bypass -File "C:\probe\$ContainerScript"
    if ($LASTEXITCODE -ne 0) { throw "Container probe failed with $LASTEXITCODE" }
    Write-Host "CONTAINER_PROBE_PASS: $ContainerScript"
} finally {
    docker rmi -f $image 2>$null | Out-Null
}
