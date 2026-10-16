# Reproduce upstream LongPathFixture's database create path inside the disposable container, with 8.3
# short names enabled first (the state Build-Wix.ps1 arranges before the upstream test suite runs):
# Database.Create -> LongPathUtil.CreateOrGetShortPath -> GetShortPathNameW -> MsiOpenDatabaseW(CreateDirect).
$ErrorActionPreference = 'Stop'
Write-Host "PROBE_HOST=$env:COMPUTERNAME"

Write-Host '--- registry state ---'
foreach ($name in @('LongPathsEnabled', 'NtfsDisable8dot3NameCreation')) {
    $value = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name $name -ErrorAction SilentlyContinue).$name
    Write-Host "REG $name=$value"
}
& fsutil 8dot3name query C:

Write-Host '--- enable 8.3 short names (as Build-Wix.ps1 does) ---'
& fsutil 8dot3name set C: 0; Write-Host "FSUTIL_SET_VOLUME exit=$LASTEXITCODE"
& fsutil 8dot3name set 0; Write-Host "FSUTIL_SET_GLOBAL exit=$LASTEXITCODE"
& reg add 'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem' /v NtfsDisable8dot3NameCreation /t REG_DWORD /d 0 /f
Write-Host "REG_ADD exit=$LASTEXITCODE"
& fsutil 8dot3name query C:

Add-Type -Namespace Probe -Name Kernel -MemberDefinition '[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern uint GetShortPathName(string lpszLongPath, System.Text.StringBuilder lpszShortPath, uint cchBuffer);'

function Get-ShortPath([string]$Path) {
    $buffer = New-Object System.Text.StringBuilder 600
    $length = [Probe.Kernel]::GetShortPathName($Path, $buffer, 600)
    [pscustomobject]@{ Result = $length; Value = $buffer.ToString() }
}

$installer = New-Object -ComObject WindowsInstaller.Installer
function Try-CreateDatabase([string]$Path, [string]$Label) {
    try {
        $db = $installer.OpenDatabase($Path, 4) # OpenDatabase.CreateDirect
        $db.Commit() | Out-Null
        Write-Host "COM_CREATE_OK $Label length=$($Path.Length)"
    } catch {
        Write-Host "COM_CREATE_FAIL $Label length=$($Path.Length) hresult=$('{0:X8}' -f $_.Exception.HResult) message=$($_.Exception.Message)"
    }
}

Write-Host '--- control: short path ---'
$short = Join-Path $env:TEMP 'wixprobe-short.msi'
[IO.File]::WriteAllText($short, 'x')
$shortLookup = Get-ShortPath ('\\?\' + $short)
Write-Host "SHORT_LOOKUP result=$($shortLookup.Result) value=$($shortLookup.Value)"
Try-CreateDatabase $short 'short'

Write-Host '--- fresh long chain created after the enable ---'
$longDir = Join-Path $env:TEMP ('.WIXPROBE ' + [guid]::NewGuid().ToString('N'))
while ($longDir.Length -lt 500) { $longDir = Join-Path $longDir ('a' * 100) }
$longDir = Join-Path $longDir 'bin'
[IO.Directory]::CreateDirectory($longDir) | Out-Null
$longFile = Join-Path $longDir 'test.msi'
[IO.File]::WriteAllText($longFile, 'x')
$longLookup = Get-ShortPath ('\\?\' + $longFile)
Write-Host "LONG_LOOKUP result=$($longLookup.Result) length=$($longLookup.Value.Length) value=$($longLookup.Value)"
Try-CreateDatabase $longLookup.Value 'long-as-upstream'
Try-CreateDatabase $longFile 'long-raw'
Try-CreateDatabase ('\\?\' + $longFile) 'long-prefixed'

Write-Host 'PROBE_DONE'
exit 0
