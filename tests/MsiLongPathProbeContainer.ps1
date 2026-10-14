# Reproduce upstream LongPathFixture's database create path inside the disposable container:
# Database.Create -> LongPathUtil.CreateOrGetShortPath -> GetShortPathNameW -> MsiOpenDatabaseW(CreateDirect).
$ErrorActionPreference = 'Stop'
Write-Host "PROBE_HOST=$env:COMPUTERNAME"

Write-Host '--- registry state ---'
foreach ($name in @('LongPathsEnabled', 'NtfsDisable8dot3NameCreation')) {
    $value = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name $name -ErrorAction SilentlyContinue).$name
    Write-Host "REG $name=$value"
}
& fsutil 8dot3name query C:

Add-Type -Namespace Probe -Name Kernel -MemberDefinition '[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern uint GetShortPathName(string lpszLongPath, System.Text.StringBuilder lpszShortPath, uint cchBuffer);'

function Get-ShortPath([string]$Path) {
    $buffer = New-Object System.Text.StringBuilder 600
    $length = [Probe.Kernel]::GetShortPathName($Path, $buffer, 600)
    [pscustomobject]@{ Result = $length; Value = $buffer.ToString() }
}

function New-LongDir {
    $dir = Join-Path $env:TEMP ('.WIXPROBE ' + [guid]::NewGuid().ToString('N'))
    while ($dir.Length -lt 500) { $dir = Join-Path $dir ('a' * 100) }
    $dir = Join-Path $dir 'bin'
    try { [IO.Directory]::CreateDirectory($dir) | Out-Null } catch { [IO.Directory]::CreateDirectory('\\?\' + $dir) | Out-Null }
    return $dir
}

function Write-LongFile([string]$Path) {
    try { [IO.File]::WriteAllText($Path, 'x') } catch { [IO.File]::WriteAllText('\\?\' + $Path, 'x') }
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
Write-LongFile $short
$shortLookup = Get-ShortPath ('\\?\' + $short)
Write-Host "SHORT_LOOKUP result=$($shortLookup.Result) value=$($shortLookup.Value)"
Try-CreateDatabase $short 'short'

Write-Host '--- long path with current 8dot3 state ---'
$longDir = New-LongDir
$longFile = Join-Path $longDir 'test.msi'
Write-LongFile $longFile
$longLookup = Get-ShortPath ('\\?\' + $longFile)
Write-Host "LONG_LOOKUP result=$($longLookup.Result) length=$($longLookup.Value.Length) value=$($longLookup.Value)"
Try-CreateDatabase $longLookup.Value 'long-as-upstream'
Try-CreateDatabase $longFile 'long-raw'
Try-CreateDatabase ('\\?\' + $longFile) 'long-prefixed'

Write-Host '--- enable 8dot3 and retry with fresh files ---'
try { & fsutil 8dot3name set C: 0; Write-Host "FSUTIL_SET_VOLUME exit=$LASTEXITCODE" } catch { Write-Host "FSUTIL_SET_VOLUME_FAIL $($_.Exception.Message)" }
try { & fsutil 8dot3name set 0; Write-Host "FSUTIL_SET_GLOBAL exit=$LASTEXITCODE" } catch { Write-Host "FSUTIL_SET_GLOBAL_FAIL $($_.Exception.Message)" }
& reg add 'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem' /v NtfsDisable8dot3NameCreation /t REG_DWORD /d 0 /f
Write-Host "REG_ADD exit=$LASTEXITCODE"
& fsutil 8dot3name query C:

$after = Join-Path $env:TEMP 'wixprobe-after.msi'
Write-LongFile $after
$afterLookup = Get-ShortPath ('\\?\' + $after)
Write-Host "AFTER_LOOKUP result=$($afterLookup.Result) value=$($afterLookup.Value)"
Try-CreateDatabase $afterLookup.Value 'after-enable-short'

$longAfter = Join-Path $longDir 'test2.msi'
Write-LongFile $longAfter
$longAfterLookup = Get-ShortPath ('\\?\' + $longAfter)
Write-Host "LONG_AFTER_LOOKUP result=$($longAfterLookup.Result) length=$($longAfterLookup.Value.Length) value=$($longAfterLookup.Value)"
Try-CreateDatabase $longAfterLookup.Value 'after-enable-long'

Write-Host 'PROBE_DONE'
exit 0
