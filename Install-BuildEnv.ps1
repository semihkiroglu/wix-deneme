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
$VsRoot = 'C:\BuildTools'

$DotnetInstallUrl = 'https://dot.net/v1/dotnet-install.ps1'
$Sdks = @('9.0.312', '8.0.419')
$X86RuntimeVersion = '8.0.25'
$DotnetRoot = 'C:\tools\dotnet'
$DotnetRootX86 = 'C:\tools\dotnet-x86'

$PwshUrl = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/PowerShell-7.6.6-win-x64.zip'
$PwshVersion = '7.6.6'
$MinGitUrl = 'https://github.com/git-for-windows/git/releases/download/v2.53.0.windows.2/MinGit-2.53.0.2-64-bit.zip'
$MinGitVersion = '2.53.0'
$NuGetUrl = 'https://dist.nuget.org/win-x86-commandline/v7.9.0/nuget.exe'
$NuGetVersion = '7.9.0'

# Legacy MSTest reference payload, Microsoft.VisualStudio.TestTools.TestPlatform.Legacy.Common
# from the VS 17 release channel manifest (payload URL and sha256 as published in
# VisualStudio.vsman). No Build Tools component ships this v10.0.0.0 assembly, but
# upstream WixToolsetTests.Dtf.Compression references it without a HintPath.
$LegacyCommonVsixUrl = 'https://download.visualstudio.microsoft.com/download/pr/12aa1305-dd17-4f26-8429-d072cda64c80/5e45d0660f67ae22ae6307699bca214cea2a998ca8f534328f85beb5377b4f77/payload.vsix'
$LegacyCommonVsixSha256 = '5e45d0660f67ae22ae6307699bca214cea2a998ca8f534328f85beb5377b4f77'
$LegacyMstestSha256 = 'deecfaf419f82cc0f8a97456e5e2c0114ba96853d5f5ab95544d269b4c5898ab'
$LegacyMstestIdentity = 'Microsoft.VisualStudio.QualityTools.UnitTestFramework, Version=10.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a'

function Get-PinnedFile([string]$Url, [string]$Path) {
    Write-Host "Downloading $Url"
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Path
    if (-not (Test-Path -LiteralPath $Path) -or (Get-Item -LiteralPath $Path).Length -eq 0) {
        throw "Download produced no file: $Url"
    }
}

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

New-Item -ItemType Directory -Force -Path $DownloadRoot | Out-Null

# Burn tests require the real OS binary and initialized shell folders, not placeholders.
if (-not (Test-Path "$env:WINDIR\System32\consent.exe")) { throw 'Windows container base lacks consent.exe required by upstream Burn tests' }
foreach ($folder in @('Startup', 'MyPictures', 'Templates')) {
    $path = [Environment]::GetFolderPath([Environment+SpecialFolder]$folder, [Environment+SpecialFolderOption]::Create)
    if (-not $path -or -not (Test-Path $path)) { throw "Container profile folder unavailable: $folder" }
}

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
Get-PinnedFile $VsBootstrapperUrl $bootstrapper
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

# --- vswhere launcher (image-only) ------------------------------------------
# Upstream cannot see the Build Tools product, so vswhere.exe is replaced by a
# compiled shim that forwards every argument to the real tool and only adds
# '-products *' when the caller passed no products filter. Nothing is faked: the
# original executable stays beside it and reports the real registration.
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

# --- Serialized upstream MSBuild (container-only) ---------------------------
# The solution's Win32 and reference's x86 instances write the same native recipe.
# Keep upstream commands intact and forward them to the genuine compiler with -m:1.
$serialMsbuild = 'C:\tools\msbuild\MSBuild.exe'
New-Item -ItemType Directory -Force (Split-Path -Parent $serialMsbuild) | Out-Null
& $csc /nologo /target:exe "/out:$serialMsbuild" (Join-Path $PSScriptRoot 'MsbuildBootstrap.cs')
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $serialMsbuild)) { throw 'MSBuild launcher compilation failed' }
& $serialMsbuild -version -nologo
if ($LASTEXITCODE -ne 0) { throw 'Genuine MSBuild launcher preflight failed' }

# --- Selected .NET SDKs and x86 runtimes ------------------------------------
# The image contains only these SDKs, so unlike the disposable GitHub runner no
# preinstalled SDK hiding or VS InstallCleanup is needed (nor possible).
$dotnetInstall = Join-Path $DownloadRoot 'dotnet-install.ps1'
Get-PinnedFile $DotnetInstallUrl $dotnetInstall
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
Get-PinnedFile $PwshUrl $pwshZip
Expand-Archive -LiteralPath $pwshZip -DestinationPath 'C:\tools\pwsh' -Force
$pwshVersion = & 'C:\tools\pwsh\pwsh.exe' -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
if ($pwshVersion -ne $PwshVersion) { throw "Unexpected PowerShell version: $pwshVersion" }

$gitZip = Join-Path $DownloadRoot 'MinGit-2.53.0.2-64-bit.zip'
Get-PinnedFile $MinGitUrl $gitZip
Expand-Archive -LiteralPath $gitZip -DestinationPath 'C:\tools\git' -Force
$gitVersion = & 'C:\tools\git\cmd\git.exe' --version
if ($gitVersion -notmatch "\b$([regex]::Escape($MinGitVersion))\b") { throw "Unexpected git version: $gitVersion" }

New-Item -ItemType Directory -Force -Path 'C:\tools\nuget' | Out-Null
$nuget = 'C:\tools\nuget\nuget.exe'
Get-PinnedFile $NuGetUrl $nuget
$nugetVersion = (Get-Item $nuget).VersionInfo.ProductVersion
if ($nugetVersion -notlike "$NuGetVersion*") { throw "Unexpected nuget.exe version: $nugetVersion" }

# --- Legacy MSTest reference (official VS payload) --------------------------
$legacyVsix = Join-Path $DownloadRoot 'Legacy.Common.payload.vsix'
Get-PinnedFile $LegacyCommonVsixUrl $legacyVsix
$payloadHash = Get-Sha256 $legacyVsix
if ($payloadHash -ne $LegacyCommonVsixSha256) { throw "Legacy.Common payload hash mismatch: $payloadHash" }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$publicAssemblies = Join-Path $VsRoot 'Common7\IDE\PublicAssemblies'
$referenceAssemblies = Join-Path $VsRoot 'Common7\IDE\ReferenceAssemblies\v4.0'
New-Item -ItemType Directory -Force -Path $publicAssemblies, $referenceAssemblies | Out-Null
$legacyDll = Join-Path $publicAssemblies 'Microsoft.VisualStudio.QualityTools.UnitTestFramework.dll'

$archive = [System.IO.Compression.ZipFile]::OpenRead($legacyVsix)
try {
    $targets = @(
        @{ Entry = 'Contents/Common7/IDE/PublicAssemblies/Microsoft.VisualStudio.QualityTools.UnitTestFramework.dll'; Path = $legacyDll },
        @{ Entry = 'Contents/Common7/IDE/ReferenceAssemblies/v4.0/Microsoft.VisualStudio.QualityTools.UnitTestFramework.dll'; Path = (Join-Path $referenceAssemblies 'Microsoft.VisualStudio.QualityTools.UnitTestFramework.dll') }
    )
    foreach ($target in $targets) {
        $entry = @($archive.Entries | Where-Object { $_.FullName -eq $target.Entry })
        if ($entry.Count -ne 1) { throw "Legacy MSTest payload entry missing: $($target.Entry)" }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry[0], $target.Path, $true)
        $hash = Get-Sha256 $target.Path
        if ($hash -ne $LegacyMstestSha256) { throw "Legacy MSTest hash mismatch: $hash" }
    }
} finally {
    $archive.Dispose()
}

$identity = [Reflection.AssemblyName]::GetAssemblyName($legacyDll).FullName
if ($identity -ne $LegacyMstestIdentity) { throw "Unexpected legacy MSTest identity: $identity" }
Write-Host "Legacy MSTest reference: $identity"

# The upstream <Reference> has no HintPath, so MSBuild resolves it through the
# AssemblyFoldersEx search path; register the two real folders holding the file
# (64-bit and 32-bit views, as an MSBuild host may run in either).
foreach ($registryRoot in @(
    'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319\AssemblyFoldersEx',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319\AssemblyFoldersEx'
)) {
    foreach ($folder in @($publicAssemblies, $referenceAssemblies)) {
        $key = Join-Path $registryRoot ("CTech BuildTools " + (Split-Path -Leaf $folder))
        New-Item -Path $key -Force | Out-Null
        Set-ItemProperty -Path $key -Name '(Default)' -Value $folder
    }
}

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
