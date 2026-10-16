param([Parameter(Mandatory)][string]$Tag, [string]$Output = 'C:\output')
$ErrorActionPreference = 'Stop'

function Get-InternalVersion([string]$ReleaseTag) {
    if ($ReleaseTag -notmatch '^v((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))$') { throw "Invalid stable release tag: $ReleaseTag" }
    $version = [version]$Matches[1]
    if ($version.Major -lt 7) { throw "WiX versions before 7 are excluded: $ReleaseTag" }
    return "$($Matches[1]).1"
}

function Set-InternalVersionTemplates([string]$Root) {
    # Count = the exact number of version tokens in the pinned upstream templates; a changed count means the
    # upstream text moved, so the replacement must be re-verified instead of silently editing a different shape.
    $templates = @(
        @{ File='SomeVerInfo.props.pp'; Count=1; Find='<PackageVersion>\{major\}\.\{minor\}\.\{patch\}\{dashlabel\}</PackageVersion>'; Replace='<PackageVersion>{major}.{minor}.{patch}.1</PackageVersion>' },
        @{ File='Directory.Packages.props.pp'; Count=33; Find='Version="\{packageversion\}"'; Replace='Version="{packageversion}.1"' },
        @{ File='global.json.pp'; Count=1; Find='("WixToolset.Sdk"\s*:\s*")\{packageversion\}(?=")'; Replace='$1{packageversion}.1' }
    )
    $updates = foreach ($item in $templates) {
        $path = Join-Path $Root "src/internal/SetBuildNumber/$($item.File)"
        $text = [IO.File]::ReadAllText($path)
        $matches = [regex]::Matches($text, $item.Find).Count
        if ($matches -ne $item.Count) { throw "Unexpected upstream version template: $path has $matches of $($item.Count) expected version tokens" }
        [pscustomobject]@{ Path=$path; Content=[regex]::Replace($text, $item.Find, $item.Replace) }
    }
    foreach ($update in $updates) { [IO.File]::WriteAllText($update.Path, $update.Content) }
}

function Set-UpstreamNuGetSource([string]$Root) {
    # The build network blocks api.nuget.org and the internal feed serves the packages instead; redirect the
    # single upstream source token exactly like the version templates (count-enforced).
    $target = $env:WIX_NUGET_SOURCE
    if (-not $target) { $target = 'https://nuget.c2tech.local/v3/index.json' }
    $path = Join-Path $Root 'nuget.config'
    if (-not (Test-Path -LiteralPath $path)) { throw "Upstream nuget.config missing: $path" }
    $text = [IO.File]::ReadAllText($path)
    $find = 'https://api.nuget.org/v3/index.json'
    $count = [regex]::Matches($text, [regex]::Escape($find)).Count
    if ($count -ne 1) { throw "Unexpected upstream nuget.config: found $count of 1 expected source token" }
    [IO.File]::WriteAllText($path, $text.Replace($find, $target))
    Write-Host "NuGet source redirected: $find -> $target"
}

function Invoke-Native([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed with exit code $LASTEXITCODE" }
}

function New-UpstreamBatch([string[]]$Commands) {
    $batch = Join-Path $env:TEMP ('wix-' + [Guid]::NewGuid().ToString('N') + '.cmd')
    $lines = @('@echo off', "call `"$env:CTECH_VSDEVCMD`" -no_logo -arch=amd64", 'if errorlevel 1 exit /b 1')
    foreach ($command in $Commands) { $lines += @($command, 'if errorlevel 1 exit /b 1') }
    [IO.File]::WriteAllLines($batch, $lines + 'exit /b 0')
    return $batch
}

function Invoke-Upstream([string[]]$Commands) {
    $batch = New-UpstreamBatch $Commands
    try { Invoke-Native 'cmd.exe' @('/d','/c',$batch) } finally { Remove-Item $batch -Force }
}

function Invoke-UpstreamResult([string[]]$Commands) {
    $batch = New-UpstreamBatch $Commands
    # Out-Host keeps the chain output in the console/log without polluting the exit-code capture.
    try { & cmd.exe @('/d','/c',$batch) | Out-Host; return $LASTEXITCODE } finally { Remove-Item $batch -Force }
}

function Get-TrxState([string]$TrxPath) {
    $xml = New-Object System.Xml.XmlDocument
    $xml.Load($TrxPath)
    $namespace = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $summary = $xml.SelectSingleNode('//*[local-name()="ResultSummary"]', $namespace)
    if ($null -eq $summary) { throw "TRX has no result summary: $TrxPath" }
    $counters = $summary.SelectSingleNode('*[local-name()="Counters"]', $namespace)
    if ($null -eq $counters) { throw "TRX has no counters: $TrxPath" }
    $results = @($xml.SelectNodes('//*[local-name()="UnitTestResult"]', $namespace) | ForEach-Object { [pscustomobject]@{ Name = $_.GetAttribute('testName'); Outcome = $_.GetAttribute('outcome') } })
    [pscustomobject]@{ Outcome = $summary.GetAttribute('outcome'); Counters = $counters; Results = $results }
}

function Assert-TrxConsistent($State, [string]$TrxPath, [string[]]$ExpectedOutcomes = @('Completed')) {
    # Mirrors the real VSTest/xunit TRX shape: counters.total/passed/failed track the individual results and
    # 'executed' counts Passed+Failed; skipped tests appear as NotExecuted nodes while counters.notExecuted
    # stays 0. The run must be complete and consistent and end in the expected summary state; an aborted or
    # partial run breaks these equalities or flips a run-level counter.
    $bad = @('error','timeout','aborted','inconclusive','passedButRunAborted','notRunnable') | Where-Object { [int]$State.Counters.GetAttribute($_) -ne 0 }
    if ($bad.Count) { throw "TRX reports run-level errors ($($bad -join ', ')): $TrxPath" }
    if ($State.Outcome -notin $ExpectedOutcomes) { throw "TRX summary outcome '$($State.Outcome)' is not one of $($ExpectedOutcomes -join '/'): $TrxPath" }
    $counts = @{ Passed = 0; Failed = 0; NotExecuted = 0 }
    foreach ($result in $State.Results) {
        if ($result.Outcome -notin @('Passed','Failed','NotExecuted')) { throw "Unexpected test outcome '$($result.Outcome)' for '$($result.Name)': $TrxPath" }
        $counts[$result.Outcome]++
    }
    $passed = [int]$State.Counters.GetAttribute('passed')
    $failed = [int]$State.Counters.GetAttribute('failed')
    $total = [int]$State.Counters.GetAttribute('total')
    $executed = [int]$State.Counters.GetAttribute('executed')
    if ($passed -ne $counts.Passed) { throw "TRX counter 'passed' is $passed but $($counts.Passed) results carry it: $TrxPath" }
    if ($failed -ne $counts.Failed) { throw "TRX counter 'failed' is $failed but $($counts.Failed) results carry it: $TrxPath" }
    if ($total -ne @($State.Results).Count) { throw "TRX total is $total but $(@($State.Results).Count) results are listed: $TrxPath" }
    if ($executed -ne $passed + $failed) { throw "TRX executed count $executed does not equal passed+failed ($($passed + $failed)): $TrxPath" }
    return @($State.Results | Where-Object { $_.Outcome -ne 'Passed' -and $_.Outcome -ne 'NotExecuted' } | ForEach-Object { $_.Name })
}

function Start-TestServices {
    # The COM+ partition scenario needs these services; containers can start them, while the Windows Firewall
    # and 'Server' services cannot run in a process-isolated container at all.
    foreach ($name in @('COMSysApp','MSDTC')) {
        if ((Get-Service -Name $name -ErrorAction SilentlyContinue).Status -ne 'Running') {
            try { Start-Service -Name $name -ErrorAction Stop; Write-Host "Test service started: $name" }
            catch { Write-Host "Test service could not be started: $name ($($_.Exception.Message))" }
        }
    }
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
                $symbols=@([pscustomobject]@{ file=[IO.Path]::GetFileName($symbol); sha256=(Get-FileHash $symbol -Algorithm SHA256).Hash; pdbs=@($pdbs) })
            } finally { $binaryZip.Dispose(); $symbolZip.Dispose() }
        }
        if (-not $ExpectedPublicPackages.ContainsKey($ReleaseTag)) { throw "No pinned public package list for $ReleaseTag; add the verified upstream publishable set to `$ExpectedPublicPackages" }
        $public = @($ExpectedPublicPackages[$ReleaseTag]) -contains $id
        [pscustomobject]@{ id=$id; file=$file.Name; sha256=(Get-FileHash $file.FullName -Algorithm SHA256).Hash; public=$public; symbols=$symbols }
    }
    if (-not ($packages | Where-Object id -eq 'wix') -or -not ($packages | Where-Object id -eq 'WixToolset.Sdk')) { throw 'CLI/SDK packages missing' }
    [pscustomobject]@{ tag=$ReleaseTag; source_sha=$Sha; version=$Version; packages=@($packages) } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $Folder 'release-manifest.json') -Encoding utf8
}

# MsiE2E fixtures that need Windows services a process-isolated container cannot start: Windows Firewall
# (mpssvc/BFE) and 'Server'/LanmanServer (SMB backed, needed for the ADSI machine-context assertions), plus
# the COM+ partitions scenario that COMSysApp+MSDTC mitigate. This list is the authority; any failure
# outside it breaks the build.
$AllowedContainerFailures = @(
    'WixToolsetTest.MsiE2E.FirewallExtensionTests.CanInstallAndUninstallFirewallRulesPackagedByDifferentModules',
    'WixToolsetTest.MsiE2E.FirewallExtensionTests.CanInstallAndUninstallFirewallRulesWithInterfaces',
    'WixToolsetTest.MsiE2E.FirewallExtensionTests.CanInstallAndUninstallFirewallRulesWithMinimalProperties',
    'WixToolsetTest.MsiE2E.FirewallExtensionTests.DisabledApplicationFirewallRuleIsEnabledAfterRepair',
    'WixToolsetTest.MsiE2E.FirewallExtensionTests.DisabledPortFirewallRuleIsEnabledAfterRepair',
    'WixToolsetTest.MsiE2E.FirewallExtensionTests.FirewallRulesUseFormattedStringProperties',
    'WixToolsetTest.MsiE2E.FirewallExtensionTests.FullSetOfScopeValuesCanBeUsed',
    'WixToolsetTest.MsiE2E.FirewallExtensionTests.MissingApplicationFirewallRuleIsAddedAfterRepair',
    'WixToolsetTest.MsiE2E.FirewallExtensionTests.MissingPortFirewallRuleIsAddedAfterRepair',
    'WixToolsetTest.MsiE2E.FirewallExtensionTests.ServiceNameIsPassedIntoNestedRules',
    'WixToolsetTest.MsiE2E.FirewallExtensionTests.SucceedWhenDoNothingFlagIsSet',
    'WixToolsetTest.MsiE2E.FirewallExtensionTests.SucceedWhenEnableOnlyFlagIsSet',
    'WixToolsetTest.MsiE2E.FirewallExtensionTests.SucceedWhenIgnoreOnFailureIsSet',
    'WixToolsetTest.MsiE2E.FirewallExtensionTests.SucceedWhenNoFlagIsSet',
    'WixToolsetTest.MsiE2E.FirewallExtensionTests.VarietyOfProtocolValuesCanBeUsed',
    'WixToolsetTest.MsiE2E.FirewallExtensionTests.VerifierSelfTest',
    'WixToolsetTest.MsiE2E.UtilExtensionGroupTests.CanAddCommentToExistingNonDomainGroup',
    'WixToolsetTest.MsiE2E.UtilExtensionGroupTests.CanChangeCommentOfExistingNonDomainGroup',
    'WixToolsetTest.MsiE2E.UtilExtensionGroupTests.CanCreateNewNonDomainGroupWithComment',
    'WixToolsetTest.MsiE2E.UtilExtensionGroupTests.CanDeleteCommentOfExistingNonDomainGroup',
    'WixToolsetTest.MsiE2E.UtilExtensionGroupTests.CanInstallAndUninstallNonDomainGroups',
    'WixToolsetTest.MsiE2E.UtilExtensionGroupTests.CanRepairCommentOfNewNonDomainGroup',
    'WixToolsetTest.MsiE2E.UtilExtensionGroupTests.CanRepairNonDomainGroups',
    'WixToolsetTest.MsiE2E.UtilExtensionGroupTests.CanRepairNonDomainGroupsWithCommandLineParameters',
    'WixToolsetTest.MsiE2E.UtilExtensionGroupTests.CanRollbackCommentOfExistingNonDomainGroup',
    'WixToolsetTest.MsiE2E.UtilExtensionGroupTests.CanRollbackNonDomainGroups',
    'WixToolsetTest.MsiE2E.UtilExtensionGroupTests.FailsIfNonDomainGroupExists',
    'WixToolsetTest.MsiE2E.UtilExtensionUserTests.CanAddCommentToExistingUser',
    'WixToolsetTest.MsiE2E.UtilExtensionUserTests.CanChangeCommentOfExistingUser',
    'WixToolsetTest.MsiE2E.UtilExtensionUserTests.CanCreateNewUserWithComment',
    'WixToolsetTest.MsiE2E.UtilExtensionUserTests.CanDeleteCommentOfExistingUser',
    'WixToolsetTest.MsiE2E.UtilExtensionUserTests.CanInstallAndUninstallUsers',
    'WixToolsetTest.MsiE2E.UtilExtensionUserTests.CanRepairCommentOfNewUser',
    'WixToolsetTest.MsiE2E.UtilExtensionUserTests.CanRepairUsers',
    'WixToolsetTest.MsiE2E.UtilExtensionUserTests.CanRepairUsersWithCommandLineParameters',
    'WixToolsetTest.MsiE2E.UtilExtensionUserTests.CanRollbackCommentOfExistingUser',
    'WixToolsetTest.MsiE2E.UtilExtensionUserTests.CanRollbackUsers',
    'WixToolsetTest.MsiE2E.UtilExtensionUserTests.FailsIfUserExists',
    'WixToolsetTest.MsiE2E.ComPlusExtensionTests.CanInstallAndUninstallWithPartitions'
)

# Pinned public package identities per release (the verified set upstream publishes to nuget.org). The build
# network has no route to nuget.org, so this list replaces the former flat-container lookup; an unpinned
# release fails closed and must be pinned before packaging.
$ExpectedPublicPackages = @{ 'v7.0.0' = @(
    'WixToolset.Bal.wixext'
    'WixToolset.BootstrapperApplicationApi'
    'WixToolset.BootstrapperApplications.wixext'
    'WixToolset.BootstrapperExtensionApi'
    'WixToolset.ComPlus.wixext'
    'WixToolset.DUtil'
    'WixToolset.Data'
    'WixToolset.Dependency.wixext'
    'WixToolset.DirectX.wixext'
    'WixToolset.Dtf.Compression'
    'WixToolset.Dtf.Compression.Cab'
    'WixToolset.Dtf.Compression.Zip'
    'WixToolset.Dtf.CustomAction'
    'WixToolset.Dtf.Resources'
    'WixToolset.Dtf.WindowsInstaller'
    'WixToolset.Dtf.WindowsInstaller.Linq'
    'WixToolset.Dtf.WindowsInstaller.Package'
    'WixToolset.Extensibility'
    'WixToolset.Firewall.wixext'
    'WixToolset.Http.wixext'
    'WixToolset.Iis.wixext'
    'WixToolset.Msmq.wixext'
    'WixToolset.Netfx.wixext'
    'WixToolset.PowerShell.wixext'
    'WixToolset.Sdk'
    'WixToolset.Sql.wixext'
    'WixToolset.UI.wixext'
    'WixToolset.Util.wixext'
    'WixToolset.Versioning'
    'WixToolset.VisualStudio.wixext'
    'WixToolset.WcaUtil'
    'WixToolset.WixStandardBootstrapperApplicationFunctionApi'
    'wix'
) }

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
    Set-UpstreamNuGetSource $source
    # NuGetAudit/EOL warning suppressions already live in the image's MSBuild.rsp (Install-BuildEnv.ps1).
    $env:RuntimeTestsEnabled='true'; $env:WixOfficialBuild='false'; $env:SignBuild='false'; $env:NUGET_XMLDOC_MODE='skip'
    Invoke-Native 'reg.exe' @('add','HKLM\Software\Policies\Microsoft\Windows\Installer','/t','REG_SZ','/v','Logging','/d','voicewarmupx','/f')
    Invoke-Native 'reg.exe' @('add','HKLM\Software\WOW6432Node\Policies\Microsoft\Windows\Installer','/t','REG_SZ','/v','Logging','/d','voicewarmupx','/f')
    # Upstream LongPathFixture passes msi.dll an 8.3 short name for files over MAX_PATH (LongPathUtil.CreateOrGetShortPath); container volumes create no aliases by default, so MSI database creation over MAX_PATH fails with 1631.
    Invoke-Native 'fsutil.exe' @('8dot3name','set','C:','0')
    Invoke-Native 'fsutil.exe' @('8dot3name','set','0')
    Invoke-Native 'reg.exe' @('add','HKLM\SYSTEM\CurrentControlSet\Control\FileSystem','/v','NtfsDisable8dot3NameCreation','/t','REG_DWORD','/d','0','/f')
    $aliasProbe=Join-Path $env:TEMP 'wix-8dot3-probe.txt'
    [IO.File]::WriteAllText($aliasProbe,'x')
    $shortAlias=((& cmd.exe /d /c "for %A in (`"$aliasProbe`") do @echo %~sA") -join '').Trim().Trim('"')
    if ($shortAlias -eq $aliasProbe -or $shortAlias -notmatch '~') { throw "Container creates no 8.3 short names; the upstream long-path MSI test would fail: $shortAlias" }
    Remove-Item $aliasProbe -Force
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
    Invoke-Upstream @('call src\setup\setup.cmd release')
    Start-TestServices
    # Every run is judged on its own evidence: complete, consistent, failure-free TRX files per stage.
    $testExit = Invoke-UpstreamResult @('call src\test\test.cmd release')
    $results = Join-Path $source 'build\logs\TestResults'
    $burnTrx = Join-Path $results 'WixToolsetTest.BurnE2E.trx'
    $msiTrx = Join-Path $results 'WixToolsetTest.MsiE2E.trx'
    $wixTrx = Join-Path $results 'WixToolsetTest.WixE2ETests.trx'
    $wixState = $null
    if ($testExit -ne 0) {
        # Windows containers cannot start the Windows Firewall and 'Server' services, so the MsiE2E fixtures
        # that need them are allowed to fail; any other failure still breaks the build.
        if (-not (Test-Path $burnTrx)) { throw 'Burn E2E results missing after the test chain aborted' }
        $burnState = Get-TrxState $burnTrx
        $burnFailed = @(Assert-TrxConsistent $burnState $burnTrx)
        if ($burnFailed.Count) { throw "Burn E2E failures are not container-limited: $($burnFailed -join '; ')" }
        if (-not (Test-Path $msiTrx)) { throw 'MSI E2E results missing; the chain aborted before the container-limited stage' }
        $msiState = Get-TrxState $msiTrx
        $msiFailed = @(Assert-TrxConsistent $msiState $msiTrx @('Failed','Completed'))
        if (-not $msiFailed.Count) { throw 'The test chain failed outside the container-limited MsiE2E stage; refusing to continue' }
        $unexpected = @($msiFailed | Where-Object { $_ -notin $AllowedContainerFailures })
        if ($unexpected.Count) { throw "Unexpected MSI E2E failures: $($unexpected -join '; ')" }
        # The upstream chain aborts at the MSI stage, so the tail suite has not run yet; this is its first run, not a retry.
        Invoke-Upstream @('cd /d src\test', "dotnet test wix -c Release --nologo -l `"trx;LogFileName=$wixTrx`"")
        $wixState = Get-TrxState $wixTrx
        $wixFailed = @(Assert-TrxConsistent $wixState $wixTrx)
        if ($wixFailed.Count) { throw "WixE2E failures are not container-limited: $($wixFailed -join '; ')" }
    } else {
        # A fully green chain is only accepted with its complete, consistent, failure-free result sets; the
        # chain itself runs the WixE2E tail, so that TRX is validated here too.
        foreach ($trx in @($burnTrx,$msiTrx,$wixTrx)) { if (-not (Test-Path $trx)) { throw "Missing test results for a green test chain: $trx" } }
        $burnState = Get-TrxState $burnTrx
        $burnFailed = @(Assert-TrxConsistent $burnState $burnTrx)
        if ($burnFailed.Count) { throw "Burn E2E failures: $($burnFailed -join '; ')" }
        $msiState = Get-TrxState $msiTrx
        $msiFailed = @(Assert-TrxConsistent $msiState $msiTrx)
        if ($msiFailed.Count) { throw "MSI E2E failures: $($msiFailed -join '; ')" }
        $wixState = Get-TrxState $wixTrx
        $wixFailed = @(Assert-TrxConsistent $wixState $wixTrx)
        if ($wixFailed.Count) { throw "WixE2E failures: $($wixFailed -join '; ')" }
    }
    Write-Host "test result counts: BurnE2E=$(@($burnState.Results).Count); MsiE2E=$(@($msiState.Results).Count); WixE2ETests=$(@($wixState.Results).Count)"
    Invoke-Upstream @('call src\internal\finalize.cmd release')
    $artifacts=Join-Path $source 'build/artifacts'
    Add-PortablePackages $artifacts $version
    Write-ReleaseManifest $artifacts $Tag $sha $version
    $allowed=@('src/internal/SetBuildNumber/SomeVerInfo.props.pp','src/internal/SetBuildNumber/Directory.Packages.props.pp','src/internal/SetBuildNumber/global.json.pp','nuget.config')
    $changed=@(& git.exe diff HEAD --name-only)
    # The three templates always change; nuget.config changes only when the substitution target differs from the upstream source, so three is legitimate.
    if ($LASTEXITCODE -ne 0 -or @($changed | Where-Object { $_ -notin $allowed }).Count -or $changed.Count -lt 3) { throw 'Unexpected upstream source modification' }
    # `git diff` never reports untracked paths, so the working tree is cross-checked too; only generated output may be untracked.
    $status=@(& git.exe status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw 'Upstream working tree status unavailable' }
    $foreign=@($status | Where-Object {
        $path=$_.Substring(3).Trim('"')
        if ($_ -match '^\?\? ') { $path -notmatch '^(build/|packages/|artifacts/)' } else { $path -notin $allowed }
    })
    if ($foreign.Count) { throw "Unexpected upstream working tree entries: $(($foreign | Select-Object -First 5) -join '; ')" }
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
