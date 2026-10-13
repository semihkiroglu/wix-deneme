param([Parameter(Mandatory)][string]$Tag, [string]$Output = 'C:\output')
$ErrorActionPreference = 'Stop'

function Get-InternalVersion([string]$ReleaseTag) {
    if ($ReleaseTag -notmatch '^v((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))$') { throw "Invalid stable release tag: $ReleaseTag" }
    $version = [version]$Matches[1]
    if ($version.Major -lt 7) { throw "WiX versions before 7 are excluded: $ReleaseTag" }
    return "$($Matches[1]).1"
}

function Set-InternalVersionTemplates([string]$Root) {
    $templates = @(
        @{ File='SomeVerInfo.props.pp'; Find='<PackageVersion>\{major\}\.\{minor\}\.\{patch\}\{dashlabel\}</PackageVersion>'; Replace='<PackageVersion>{major}.{minor}.{patch}.1</PackageVersion>' },
        @{ File='Directory.Packages.props.pp'; Find='Version="\{packageversion\}"'; Replace='Version="{packageversion}.1"' },
        @{ File='global.json.pp'; Find='("WixToolset.Sdk"\s*:\s*")\{packageversion\}(?=")'; Replace='$1{packageversion}.1' }
    )
    $updates = foreach ($item in $templates) {
        $path = Join-Path $Root "src/internal/SetBuildNumber/$($item.File)"
        $text = [IO.File]::ReadAllText($path)
        if (-not [regex]::IsMatch($text, $item.Find)) { throw "Unrecognized upstream version template: $path" }
        [pscustomobject]@{ Path=$path; Content=[regex]::Replace($text, $item.Find, $item.Replace) }
    }
    foreach ($update in $updates) { [IO.File]::WriteAllText($update.Path, $update.Content) }
}

function Invoke-Native([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed with exit code $LASTEXITCODE" }
}

function Invoke-Upstream([string[]]$Commands) {
    $batch = Join-Path $env:TEMP ('wix-' + [Guid]::NewGuid().ToString('N') + '.cmd')
    $lines = @('@echo off', "call `"$env:CTECH_VSDEVCMD`" -no_logo -arch=amd64", 'if errorlevel 1 exit /b 1')
    foreach ($command in $Commands) { $lines += @($command, 'if errorlevel 1 exit /b 1') }
    [IO.File]::WriteAllLines($batch, $lines + 'exit /b 0')
    try { Invoke-Native 'cmd.exe' @('/d','/c',$batch) } finally { Remove-Item $batch -Force }
}

function Read-PackageXml($Zip) {
    $entries = @($Zip.Entries | Where-Object { $_.FullName -match '^[^/]+[.]nuspec$' })
    if ($entries.Count -ne 1) { throw 'Expected exactly one package nuspec' }
    $reader = [IO.StreamReader]::new($entries[0].Open())
    try {
        $text = $reader.ReadToEnd()
        if ($text -match '(?i)<!DOCTYPE|<!ENTITY') { throw 'Unsafe package XML' }
        return ,([xml]$text)
    } finally { $reader.Dispose() }
}

function Get-EntryBytes($Entry) {
    if ($null -eq $Entry) { throw 'Missing package entry' }
    $stream = $Entry.Open(); $memory = [IO.MemoryStream]::new()
    try { $stream.CopyTo($memory); return ,$memory.ToArray() } finally { $stream.Dispose(); $memory.Dispose() }
}

function Add-PortablePackages([string]$Artifacts, [string]$Version) {
    $scratch = Join-Path $env:TEMP 'wix-symbol-packages'
    foreach ($project in Get-ChildItem 'src' -Recurse -Filter '*.csproj' -File | Sort-Object FullName -Unique) {
        $binary = Join-Path $Artifacts "$($project.BaseName).$Version.nupkg"
        if (-not (Test-Path $binary) -or @(Get-ChildItem $project.DirectoryName -Filter '*.nuspec' -File).Count) { continue }
        $text = [IO.File]::ReadAllText($project.FullName)
        if ($project.BaseName.EndsWith('.wixext') -or $text -match 'WixExt[.]props|(?is)<IncludeBuildOutput>\s*false|<NoBuild>\s*true|<NuspecFile>|<PackAsTool>\s*true') { continue }
        $zip = [IO.Compression.ZipFile]::OpenRead($binary)
        try { $hasAssembly = @($zip.Entries | Where-Object { $_.FullName -match '^lib/[^/]+/[^/]+[.]dll$' }).Count -gt 0 } finally { $zip.Dispose() }
        if (-not $hasAssembly) { continue }
        $folder = Join-Path $scratch $project.BaseName
        New-Item -ItemType Directory -Force $folder | Out-Null
        Invoke-Native $env:CTECH_MSBUILD @($project.FullName,'-t:Rebuild;Pack','-p:Configuration=Release','-p:NoBuild=false','-p:BuildProjectReferences=false','-p:DebugType=portable','-p:IncludeSymbols=true','-p:SymbolPackageFormat=snupkg',"-p:PackageOutputPath=$folder",'-nologo','-v:minimal')
        $newBinary = Join-Path $folder "$($project.BaseName).$Version.nupkg"
        $symbol = Join-Path $folder "$($project.BaseName).$Version.snupkg"
        if (-not (Test-Path $newBinary)) { throw "Rebuilt package missing: $newBinary" }
        if (Test-Path $symbol) { Copy-Item $newBinary,$symbol -Destination $Artifacts -Force }
    }
    if (-not @(Get-ChildItem $Artifacts -Filter '*.snupkg').Count) { throw 'No supported symbol packages produced' }
}

function Write-ReleaseManifest([string]$Folder, [string]$ReleaseTag, [string]$Sha, [string]$Version) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Linq;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
public static class PortableIdentity {
    public static string Read(byte[] pdb, byte[] dll) {
        using (var source = new MemoryStream(pdb))
        using (var provider = MetadataReaderProvider.FromPortablePdbStream(source))
        using (var assembly = new PEReader(new MemoryStream(dll))) {
            var id = provider.GetMetadataReader().DebugMetadataHeader.Id.ToArray();
            var guid = new Guid(id.Take(16).ToArray());
            var entries = assembly.ReadDebugDirectory().Where(x => x.Type == DebugDirectoryEntryType.CodeView).ToArray();
            if (entries.Length != 1 || assembly.ReadCodeViewDebugDirectoryData(entries[0]).Guid != guid || entries[0].Stamp != BitConverter.ToUInt32(id,16))
                throw new InvalidDataException("Portable PDB does not belong to its package DLL");
            return guid.ToString("N") + "ffffffff";
        }
    }
}
'@
    $notes = "CTech self-compiled build from WiX Toolset $ReleaseTag source (upstream commit $Sha). Not an official WiX binary distribution."
    $packages = foreach ($file in Get-ChildItem $Folder -Filter '*.nupkg' -File | Sort-Object Name) {
        $zip = [IO.Compression.ZipFile]::Open($file.FullName, [IO.Compression.ZipArchiveMode]::Update)
        try {
            $xml = Read-PackageXml $zip
            $metadata = $xml.SelectSingleNode('/*[local-name()="package"]/*[local-name()="metadata"]')
            $id = $metadata.SelectSingleNode('*[local-name()="id"]').InnerText
            $actual = $metadata.SelectSingleNode('*[local-name()="version"]').InnerText
            if ($actual -ne $Version) { throw "Unexpected package version: $id $actual" }
            foreach ($dep in $xml.SelectNodes('//*[local-name()="dependency"]')) {
                if ($dep.id -match '^(WixToolset[.]|WixInternal[.]|wix$)') {
                    $lower=[regex]::Match($dep.version,'\d+(?:\.\d+){2,3}').Value
                    if ($lower -ne $Version) { throw "Unpatched dependency: $id -> $($dep.id) $($dep.version)" }
                }
            }
            $node = $metadata.SelectSingleNode('*[local-name()="releaseNotes"]')
            if ($null -eq $node) { $node=$xml.CreateElement('releaseNotes',$metadata.NamespaceURI); [void]$metadata.AppendChild($node) }
            $node.InnerText = $notes
            $nuspec = @($zip.Entries | Where-Object { $_.FullName -match '^[^/]+[.]nuspec$' })[0]
            $name = $nuspec.FullName; $nuspec.Delete()
            $writer = [IO.StreamWriter]::new($zip.CreateEntry($name).Open(), [Text.UTF8Encoding]::new($false))
            try { $xml.Save($writer) } finally { $writer.Dispose() }
        } finally { $zip.Dispose() }
        $symbols = @()
        $symbol = Join-Path $Folder "$id.$Version.snupkg"
        if (Test-Path $symbol) {
            $binaryZip=[IO.Compression.ZipFile]::OpenRead($file.FullName); $symbolZip=[IO.Compression.ZipFile]::OpenRead($symbol)
            try {
                $symbolXml=Read-PackageXml $symbolZip
                if ([string]$symbolXml.package.metadata.version -ne $Version -or [string]$symbolXml.package.metadata.id -ne $id) { throw "Invalid symbols counterpart: $symbol" }
                $pdbs = foreach ($entry in $symbolZip.Entries | Where-Object { $_.FullName.EndsWith('.pdb') }) {
                    $bytes=Get-EntryBytes $entry
                    $dll=Get-EntryBytes ($binaryZip.GetEntry($entry.FullName.Substring(0,$entry.FullName.Length-4)+'.dll'))
                    [pscustomobject]@{ name=$entry.Name; key=[PortableIdentity]::Read($bytes,$dll); sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) }
                }
                if (-not @($pdbs).Count) { throw "Symbol package lacks PDBs: $symbol" }
                $symbols=@([pscustomobject]@{ file=[IO.Path]::GetFileName($symbol); pdbs=@($pdbs) })
            } finally { $binaryZip.Dispose(); $symbolZip.Dispose() }
        }
        $public = $false
        if (-not $id.StartsWith('WixInternal.')) {
            $upstream = $ReleaseTag.Substring(1)
            $reference = Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/$($id.ToLowerInvariant())/$upstream/$($id.ToLowerInvariant()).nuspec" -SkipHttpErrorCheck
            if ($reference.StatusCode -notin @(200,404)) { throw "Official package lookup indeterminate: $id HTTP $($reference.StatusCode)" }
            $public = $reference.StatusCode -eq 200
        }
        [pscustomobject]@{ id=$id; file=$file.Name; sha256=(Get-FileHash $file.FullName -Algorithm SHA256).Hash; public=$public; symbols=$symbols }
    }
    if (-not ($packages | Where-Object id -eq 'wix') -or -not ($packages | Where-Object id -eq 'WixToolset.Sdk')) { throw 'CLI/SDK packages missing' }
    [pscustomobject]@{ tag=$ReleaseTag; source_sha=$Sha; version=$Version; packages=@($packages) } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $Folder 'release-manifest.json') -Encoding utf8
}

if ($MyInvocation.InvocationName -eq '.') { return }
$version = Get-InternalVersion $Tag
if ($env:OS -ne 'Windows_NT') { throw 'WiX native build requires Windows' }
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    # Install in the disposable container; exporting the VS installation as a layer fails on Windows.
    & (Join-Path $PSScriptRoot 'Install-BuildEnv.ps1')
    & 'C:\tools\pwsh\pwsh.exe' -NoProfile -File $PSCommandPath -Tag $Tag -Output $Output
    exit $LASTEXITCODE
}
$Output=[IO.Path]::GetFullPath($Output)
New-Item -ItemType Directory -Force $Output | Out-Null
$source=Join-Path $PWD 'wix-source'
try {
    Invoke-Native 'git.exe' @('clone','--depth','1','--branch',$Tag,'https://github.com/wixtoolset/wix.git',$source)
    Set-Location $source
    $sha=(& git.exe rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $sha -notmatch '^[0-9a-f]{40}$') { throw 'Upstream revision unavailable' }
    $actualTag=(& git.exe describe --tags --exact-match).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualTag -ne $Tag) { throw 'Upstream source is not the requested release tag' }
    Set-InternalVersionTemplates $source
    $env:RuntimeTestsEnabled='true'; $env:WixOfficialBuild='false'; $env:SignBuild='false'; $env:NUGET_XMLDOC_MODE='skip'
    $rsp=Join-Path (Split-Path $env:CTECH_MSBUILD) 'MSBuild.rsp'
    [IO.File]::AppendAllText($rsp,"`r`n-p:NuGetAudit=false`r`n-p:CheckEolTargetFramework=false`r`n-warnAsMessage:NU1901,NU1902,NU1903,NU1904,NETSDK1138`r`n")
    Invoke-Native 'reg.exe' @('add','HKLM\Software\Policies\Microsoft\Windows\Installer','/t','REG_SZ','/v','Logging','/d','voicewarmupx','/f')
    Invoke-Native 'reg.exe' @('add','HKLM\Software\WOW6432Node\Policies\Microsoft\Windows\Installer','/t','REG_SZ','/v','Logging','/d','voicewarmupx','/f')
    Invoke-Upstream @('call src\clean.cmd','call src\build_init.cmd','call src\dtf\dtf.cmd release','call src\internal\internal.cmd release','call src\libs\libs.cmd release','call src\api\api.cmd release','call src\burn\burn.cmd release','call src\wix\wix.cmd release','call src\tools\tools.cmd release')
    Invoke-Upstream @('msbuild src\ext\Util\wixext\WixToolset.Util.wixext.csproj -Restore -t:Build -p:Configuration=Release -nologo -m -warnaserror -bl:build\logs\util_prebuild.binlog','msbuild src\ext\Util\wixext\WixToolset.Util.wixext.csproj -t:Pack -p:Configuration=Release -p:NoBuild=true -nologo -warnaserror -bl:build\logs\util_prepack.binlog')
    $util=Join-Path $source "build/artifacts/WixToolset.Util.wixext.$version.nupkg"
    $env:WIX_EXTENSIONS=Join-Path $env:TEMP 'wix-extension-cache'
    $cache=Join-Path $env:WIX_EXTENSIONS ".wix/extensions/WixToolset.Util.wixext/$version"
    New-Item -ItemType Directory -Force $cache | Out-Null
    [IO.Compression.ZipFile]::ExtractToDirectory($util,$cache)
    $config='src/ext/NetFx/netcoresearch/packages.config'
    if (-not (Test-Path $config)) { throw 'Original NetFx native hosting manifest missing' }
    Invoke-Native 'nuget.exe' @('restore',$config,'-PackagesDirectory','packages','-NonInteractive')
    Invoke-Upstream @('call src\ext\ext.cmd release inc')
    $canonical='src\ext\PowerShell\wixext\WixToolset.PowerShell.wixext.csproj'
    if (Test-Path $canonical) {
        Invoke-Upstream @("msbuild $canonical -Restore -t:Rebuild -p:Configuration=Release -p:BuildProjectReferences=false -nologo -warnaserror -bl:build\logs\powershell_canonical_build.binlog",'msbuild src\ext\PowerShell\test\WixToolsetTest.PowerShell\WixToolsetTest.Powershell.csproj -t:Rebuild;Test -p:Configuration=Release -p:BuildProjectReferences=false -nologo -warnaserror -bl:build\logs\powershell_canonical_test.binlog')
        $wrong=Join-Path $source "build/artifacts/WixToolset.Powershell.wixext.$version.nupkg"
        if (Test-Path $wrong) { Remove-Item $wrong -Force }
        Invoke-Upstream @("msbuild $canonical -t:Pack -p:Configuration=Release -p:NoBuild=true -p:BuildProjectReferences=false -nologo -warnaserror -bl:build\logs\powershell_canonical_pack.binlog")
    }
    Invoke-Upstream @('call src\setup\setup.cmd release','call src\test\test.cmd release','call src\internal\finalize.cmd release')
    $artifacts=Join-Path $source 'build/artifacts'
    Add-PortablePackages $artifacts $version
    Write-ReleaseManifest $artifacts $Tag $sha $version
    $allowed=@('src/internal/SetBuildNumber/SomeVerInfo.props.pp','src/internal/SetBuildNumber/Directory.Packages.props.pp','src/internal/SetBuildNumber/global.json.pp')
    $changed=@(& git.exe diff HEAD --name-only)
    if ($LASTEXITCODE -ne 0 -or @($changed | Where-Object { $_ -notin $allowed }).Count -or $changed.Count -ne 3) { throw 'Unexpected upstream source modification' }
    Invoke-Native 'git.exe' @('diff','--check')
    Copy-Item (Join-Path $artifacts '*') -Destination $Output -Force
    $additional=Join-Path $source 'build/setup/Release/WixAdditionalTools.exe'
    if (-not (Test-Path $additional)) { $additional=@(Get-ChildItem (Join-Path $source 'build') -Recurse -File -Filter 'WixAdditionalTools.exe')[0].FullName }
    if (-not $additional) { throw 'Additional Tools missing' }
    Copy-Item $additional -Destination $Output
    Write-Host "BUILD_COMPLETE: $Tag -> $version; packages and Additional Tools at $Output"
} finally {
    $logs=Join-Path $Output 'logs'; New-Item -ItemType Directory -Force $logs | Out-Null
    if (Test-Path (Join-Path $source 'build/logs')) { Copy-Item (Join-Path $source 'build/logs/*') -Destination $logs -Recurse -Force }
    if (Test-Path (Join-Path $source 'build')) {
        foreach ($folder in Get-ChildItem (Join-Path $source 'build') -Recurse -Directory -Filter 'TestResults') {
            $relative=[IO.Path]::GetRelativePath((Join-Path $source 'build'),$folder.FullName)
            $destination=Join-Path $logs "test-results/$relative"
            New-Item -ItemType Directory -Force $destination | Out-Null
            Copy-Item (Join-Path $folder.FullName '*') -Destination $destination -Recurse -Force
        }
    }
}
