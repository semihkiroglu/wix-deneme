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
