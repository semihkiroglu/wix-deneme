# Installs the pinned build environment in the disposable Windows container.
# Runs under Windows PowerShell 5.1 (the only shell in the base image).
# Every download below is an official Microsoft / PowerShell / git-for-windows /
# NuGet source; versions are fixed so image rebuilds stay reproducible.
[CmdletBinding()]
param(
    [string]$DownloadRoot = (Join-Path $env:TEMP 'ctech-buildenv-downloads')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Fixed Visual Studio Build Tools 2022 17.14.29 (17.14.37111.16) bootstrapper,
# taken from the 17.14.29 row of Microsoft's official release history:
# https://learn.microsoft.com/visualstudio/releases/2022/release-history
$VsBootstrapperUrl = 'https://download.visualstudio.microsoft.com/download/pr/83ec5fa2-d38d-43d5-9f58-31ea8e1c66e4/62d8e57ac5ccd56eabd627c9de2cafe4dc463f9db520a72673ed08b1e83c48b7/vs_BuildTools.exe'
$VsBootstrapperVersionPattern = '^17\.14\.29([+.]|$)'
$VsBuildNumber = '17.14.37111.16'
$VsBootstrapperSha256 = '62d8e57ac5ccd56eabd627c9de2cafe4dc463f9db520a72673ed08b1e83c48b7'
$VsRoot = 'C:\BuildTools'

$DotnetInstallUrl = 'https://dot.net/v1/dotnet-install.ps1'
# shortcut: dotnet-install.ps1 is served from the live dot.net channel; a Microsoft update breaks this pin
# loudly and deliberately — re-download, re-verify and bump the hash when the SDK set is intentionally moved.
$DotnetInstallSha256 = 'e8b873e18a81e5c4cd8ab69d84dac8fead291d50b3c44633cd7fddad709a13d6'
$Sdks = @('9.0.312', '8.0.419')
$X86RuntimeVersion = '8.0.25'
$DotnetRoot = 'C:\tools\dotnet'
$DotnetRootX86 = 'C:\tools\dotnet-x86'

$PwshUrl = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/PowerShell-7.6.6-win-x64.zip'
$PwshVersion = '7.6.6'
$PwshSha256 = '02fe458be20493fbdf43f61ea20610b811ee6c738ab1676c61b9cfcd1a33c860'
$MinGitUrl = 'https://github.com/git-for-windows/git/releases/download/v2.53.0.windows.2/MinGit-2.53.0.2-64-bit.zip'
$MinGitVersion = '2.53.0'
$MinGitSha256 = 'd4bf83d6a860ccae9af44e508e1e00a39f09db6fa78a9ba5543b94d87ca22a29'
$NuGetUrl = 'https://dist.nuget.org/win-x86-commandline/v7.9.0/nuget.exe'
$NuGetVersion = '7.9.0'
$NuGetSha256 = '992d70cac5b06c38efec91806caba64cdcc07e6d963a0959dbbbaf264d33b800'

function Get-PinnedFile([string]$Url, [string]$Path, [string]$Sha256 = '') {
    # Every download must carry its pinned hash; a forgotten pin fails loudly instead of skipping verification.
    if (-not $Sha256) { throw "Get-PinnedFile requires the pinned SHA-256 of $Url" }
    Write-Host "Downloading $Url"
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Path
    if (-not (Test-Path -LiteralPath $Path) -or (Get-Item -LiteralPath $Path).Length -eq 0) {
        throw "Download produced no file: $Url"
    }
    $actual = Get-Sha256 $Path
    if ($actual -ne $Sha256.ToLowerInvariant()) { throw "Download hash mismatch for $Url : expected $Sha256, got $actual" }
}

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

New-Item -ItemType Directory -Force -Path $DownloadRoot | Out-Null

# Upstream DTF still targets net20; install the genuine CLR 2/3.5 Windows feature.
if ([Environment]::OSVersion.Version.Build -ge 20348) {
    & dism.exe /Online /Add-Capability /CapabilityName:NetFx3 /NoRestart
    $featureExit = $LASTEXITCODE
} else {
    & sc.exe config wuauserv start= auto
    if ($LASTEXITCODE -ne 0) { throw 'Cannot enable container Windows Update for NetFx3' }
    try {
        & dism.exe /Online /Enable-Feature /FeatureName:NetFx3 /All /NoRestart
        $featureExit = $LASTEXITCODE
    } finally { & sc.exe config wuauserv start= disabled }
}
if ($featureExit -notin @(0,3010) -or -not (Test-Path "$env:WINDIR\Microsoft.NET\Framework\v2.0.50727\mscorlib.dll")) {
    throw "NET Framework 3.5 installation failed: $featureExit"
}

# --- Visual Studio Build Tools 17.14.29 -------------------------------------
$bootstrapper = Join-Path $DownloadRoot 'vs_BuildTools_17.14.29.exe'
Get-PinnedFile $VsBootstrapperUrl $bootstrapper -Sha256 $VsBootstrapperSha256
$bootstrapperVersion = (Get-Item $bootstrapper).VersionInfo.ProductVersion
if ($bootstrapperVersion -notmatch $VsBootstrapperVersionPattern) {
    throw "Unexpected Build Tools bootstrapper version: $bootstrapperVersion"
}

$vsArguments = @(
    '--quiet', '--wait', '--norestart', '--nocache', '--installPath', $VsRoot,
    '--add', 'Microsoft.VisualStudio.Workload.VCTools',
    '--add', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
    '--add', 'Microsoft.VisualStudio.Component.VC.Tools.ARM64',
    '--add', 'Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools',
    '--add', 'Microsoft.VisualStudio.Component.TestTools.BuildTools',
    '--add', 'Microsoft.VisualStudio.Component.VC.ATL',
    '--includeRecommended'
)
$process = Start-Process -FilePath $bootstrapper -ArgumentList $vsArguments -Wait -PassThru
# 3010 means success with a pending reboot; a container does not reboot and the
# installed tools are usable without it (documented container deployment flow).
if ($process.ExitCode -notin @(0, 3010)) {
    throw "Visual Studio Build Tools installation failed: $($process.ExitCode)"
}

$vsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vsWhere)) { throw "vswhere not found after installation: $vsWhere" }

# Upstream WixInternal.MSTestSupport.MsbuildRunner runs exactly this query. The
# real vswhere default product list excludes BuildTools, so it must be empty here.
$early = @(& $vsWhere -property installationPath -version '[17.0,18.0)' | Where-Object { $_ })
if ($early.Count -ne 0) { throw "Unexpected VS instance before launcher install: $($early -join ', ')" }

$instances = @(& $vsWhere -products * -version '[17.14,17.15)' -property installationPath | Where-Object { $_ })
$builds = @(& $vsWhere -products * -version '[17.14,17.15)' -property installationVersion | Where-Object { $_ })
if ($instances.Count -ne 1 -or $instances[0] -ne $VsRoot -or $builds.Count -ne 1 -or $builds[0] -ne $VsBuildNumber) {
    throw "Pinned Build Tools registration mismatch: $($instances -join ', ') / $($builds -join ', ')"
}
Write-Host "Installed Build Tools build: $($builds[0])"

foreach ($relative in @('MSBuild\Current\Bin\MSBuild.exe', 'MSBuild\Current\Bin\amd64\MSBuild.exe', 'Common7\Tools\VsDevCmd.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $VsRoot $relative))) { throw "Build tool missing: $relative" }
}
$toolsets = @(Get-ChildItem -LiteralPath (Join-Path $VsRoot 'VC\Tools\MSVC') -Directory)
foreach ($arch in @('x86', 'x64', 'arm64')) {
    $found = @($toolsets | ForEach-Object { Join-Path $_.FullName "bin\Hostx64\$arch\cl.exe" } | Where-Object { Test-Path -LiteralPath $_ })
    if (-not $found.Count) { throw "MSVC compiler missing for $arch" }
}
# --- VS compiler environment select -----------------------------------------
# VS Build Tools default vswhere filter doesn't list Build Tools as an
# installable product, so the real exe can't be discovered by upstream's
# direct call without a -products * hint. Replace it with a thin shim that
# forwards every argument and only adds -products * when the caller passed
# none; the original stays beside it and reports the real registration.
$installerDir = Split-Path -Parent $vsWhere
$realVswhere = Join-Path $installerDir 'vswhere-real.exe'
Move-Item -LiteralPath $vsWhere -Destination $realVswhere -Force

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path -LiteralPath $csc)) { throw 'In-box C# compiler not found' }
& $csc /nologo /target:exe "/out:$vsWhere" (Join-Path $PSScriptRoot 'VswhereBootstrap.cs')
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $vsWhere)) { throw "VswhereBootstrap compilation failed: $LASTEXITCODE" }

$selected = @(& $vsWhere -property installationPath -version '[17.0,18.0)' | Where-Object { $_ })
if ($selected.Count -ne 1 -or $selected[0] -ne $VsRoot) {
    throw "Launcher did not select the Build Tools instance: $($selected -join ', ')"
}

# --- Selected .NET SDKs and x86 runtimes ------------------------------------
# The image contains only these SDKs, so unlike the disposable GitHub runner no
# preinstalled SDK hiding or VS InstallCleanup is needed (nor possible).
$dotnetInstall = Join-Path $DownloadRoot 'dotnet-install.ps1'
Get-PinnedFile $DotnetInstallUrl $dotnetInstall -Sha256 $DotnetInstallSha256
foreach ($sdk in $Sdks) {
    & $dotnetInstall -Version $sdk -InstallDir $DotnetRoot -Architecture x64 -NoPath
}
# x86 Core + Desktop 8.0.25 runtimes for the upstream Burn integration helpers.
& $dotnetInstall -Version $X86RuntimeVersion -Runtime dotnet -InstallDir $DotnetRootX86 -Architecture x86 -NoPath
& $dotnetInstall -Version $X86RuntimeVersion -Runtime windowsdesktop -InstallDir $DotnetRootX86 -Architecture x86 -NoPath

$installedSdks = @(& (Join-Path $DotnetRoot 'dotnet.exe') --list-sdks)
foreach ($sdk in $Sdks) {
    if (-not @($installedSdks | Where-Object { $_ -match [regex]::Escape($sdk) }).Count) { throw "SDK not installed: $sdk" }
}
$installedRuntimes = @(& (Join-Path $DotnetRootX86 'dotnet.exe') --list-runtimes)
foreach ($runtime in @('Microsoft.NETCore.App 8.0.25', 'Microsoft.WindowsDesktop.App 8.0.25')) {
    if (-not @($installedRuntimes | Where-Object { $_ -like "$runtime*" }).Count) { throw "x86 runtime not installed: $runtime" }
}

# --- PowerShell 7, git CLI, nuget.exe ---------------------------------------
$pwshZip = Join-Path $DownloadRoot 'PowerShell-7.6.6-win-x64.zip'
Get-PinnedFile $PwshUrl $pwshZip -Sha256 $PwshSha256
Expand-Archive -LiteralPath $pwshZip -DestinationPath 'C:\tools\pwsh' -Force
$pwshVersion = & 'C:\tools\pwsh\pwsh.exe' -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
if ($pwshVersion -ne $PwshVersion) { throw "Unexpected PowerShell version: $pwshVersion" }

$gitZip = Join-Path $DownloadRoot 'MinGit-2.53.0.2-64-bit.zip'
Get-PinnedFile $MinGitUrl $gitZip -Sha256 $MinGitSha256
Expand-Archive -LiteralPath $gitZip -DestinationPath 'C:\tools\git' -Force
$gitVersion = & 'C:\tools\git\cmd\git.exe' --version
if ($gitVersion -notmatch "\b$([regex]::Escape($MinGitVersion))\b") { throw "Unexpected git version: $gitVersion" }

New-Item -ItemType Directory -Force -Path 'C:\tools\nuget' | Out-Null
$nuget = 'C:\tools\nuget\nuget.exe'
# Visual Studio Build Tools ships no nuget.exe CLI (only NuGet.Build.Tasks.Console.exe), so the pinned download is the single source.
Get-PinnedFile $NuGetUrl $nuget -Sha256 $NuGetSha256
$nugetVersion = (Get-Item $nuget).VersionInfo.ProductVersion
if ($nugetVersion -notlike "$NuGetVersion*") { throw "Unexpected nuget.exe version: $nugetVersion" }

# Environment-only settings proven on the validated build with this historical
# toolchain: without them NuGet audit / EOL warnings fail the pinned build.
# Applied to the image's MSBuild response file, never to any upstream source.
$msbuildRsp = Join-Path $VsRoot 'MSBuild\Current\Bin\amd64\MSBuild.rsp'
$msbuildOptions = @(
    '-p:NuGetAudit=false'
    '-p:CheckEolTargetFramework=false'
    '-warnAsMessage:NU1901,NU1902,NU1903,NU1904,NETSDK1138'
)
[System.IO.File]::AppendAllText($msbuildRsp, [Environment]::NewLine + ($msbuildOptions -join [Environment]::NewLine) + [Environment]::NewLine)

# Cleanup of this script's own downloads only.
Remove-Item -LiteralPath $DownloadRoot -Recurse -Force

Write-Host 'Installed paths:'
Write-Host "  Visual Studio Build Tools: $VsRoot ($VsBuildNumber)"
Write-Host "  .NET SDKs: $($Sdks -join ', ') in $DotnetRoot"
Write-Host "  x86 .NET 8.0.25 Core + Desktop in $DotnetRootX86"
Write-Host "  PowerShell ${PwshVersion}: C:\tools\pwsh"
Write-Host "  git ${MinGitVersion}: C:\tools\git"
Write-Host "  nuget.exe ${NuGetVersion}: C:\tools\nuget\nuget.exe"
