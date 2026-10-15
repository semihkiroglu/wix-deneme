# Runs one tag's Windows-container build on the Jenkins agent.
# Invoked by the Jenkinsfile with WIX_TAG/WIX_IMAGE/WIX_CONTAINER in the environment.
$ErrorActionPreference = 'Stop'
foreach ($name in @('WORKSPACE','WIX_TAG','WIX_IMAGE','WIX_CONTAINER')) {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "Missing environment variable: $name" }
}
$ws = $env:WORKSPACE
$tag = $env:WIX_TAG
$image = $env:WIX_IMAGE
$container = $env:WIX_CONTAINER
# The host/Docker kernel build selects the Windows Server base image for the ephemeral container.
$info = docker info --format '{{json .}}' | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $info.OSType -ne 'windows') { throw 'Windows Docker engine required' }
$storageDrive = $info.DockerRootDir.Substring(0,2)
$storageDisk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$storageDrive'"
if ($storageDisk.FreeSpace -lt 60GB) { throw "Docker storage $storageDrive needs at least 60 GiB free space before a cold build" }
Write-Host "Docker storage: $($info.DockerRootDir), free $([math]::Round($storageDisk.FreeSpace/1GB,1)) GiB"
$kernel = [regex]::Match($info.KernelVersion, '(?:^|[^0-9])10[.]0[. ]+([0-9]+)')
if (-not $kernel.Success) { throw "Unknown Docker kernel version: $($info.KernelVersion)" }
$build = [int]$kernel.Groups[1].Value
if ($build -eq 17763) { $base = 'mcr.microsoft.com/windows:1809' }
elseif ($build -ge 26100) { $base = 'mcr.microsoft.com/windows/server:ltsc2025' }
elseif ($build -ge 20348) { $base = 'mcr.microsoft.com/windows/server:ltsc2022' }
else { throw "No supported Windows container base image for Windows build $build" }
$outDir = Join-Path (Join-Path $ws 'artifacts') $tag
if (Test-Path -LiteralPath $outDir) { Get-ChildItem -LiteralPath $outDir -Force | Remove-Item -Recurse -Force }
$logDir = Join-Path $ws 'logs'
New-Item -ItemType Directory -Force -Path $outDir, $logDir | Out-Null
Write-Host "Windows host build $build -> $base"
docker build --force-rm -m 4GB --build-arg "BASE_IMAGE=$base" -f (Join-Path $ws 'Dockerfile') -t $image $ws
if ($LASTEXITCODE -ne 0) { throw "docker build for $tag failed with $LASTEXITCODE" }
$createArgs = @('create','--storage-opt','size=120GB','--name',$container,'-v',"${outDir}:C:\output")
if ($env:WIX_NUGET_SOURCE) { $createArgs += @('-e', "WIX_NUGET_SOURCE=$($env:WIX_NUGET_SOURCE)") }
$createArgs += @($image,'-Tag',$tag,'-Output','C:\output')
docker @createArgs | Out-Null
if ($LASTEXITCODE -ne 0) { throw "docker create for $tag failed with $LASTEXITCODE" }
$ErrorActionPreference = 'Continue'   # docker writes progress to stderr; keep it in the log, not an exception
docker start -a $container 2>&1 | Tee-Object -FilePath (Join-Path $logDir ($tag + '.log'))
$started = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
$exitCode = [int](docker wait $container)
docker rm -f $container | Out-Null
if ($started -ne 0) { throw "docker start for $tag failed with $started" }
if ($exitCode -ne 0) { throw "$tag build container exited with $exitCode" }
& (Join-Path $ws 'Publish-Wix.ps1') -Validate -ManifestDir $outDir
if ($LASTEXITCODE -ne 0) { throw "release manifest validation failed for $tag" }
Write-Host "build complete: $tag"
