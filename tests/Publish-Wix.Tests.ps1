#Requires -Version 5.1
<#
Functional boundary tests for Publish-Wix.ps1.
Runs on Windows PowerShell 5.1 and PowerShell 7 (no Pester dependency).

Every HTTP interaction is real: a mock BaGetter-style feed (HttpListener, child process via
Start-Job) serves the service index, flat-container reads and nuget push endpoints.
Endpoint paths are deliberately NON-standard so a hard-coded publisher fails these tests.

Usage: powershell -NoProfile -File tests/Publish-Wix.Tests.ps1     (exit 0 = green)
#>
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:Publisher = Join-Path $script:RepoRoot 'Publish-Wix.ps1'
$script:Passed = 0
$script:Failed = 0
$script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ('wix-publish-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $script:Work | Out-Null

Add-Type -AssemblyName System.IO.Compression
try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }
try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { }

function Assert-True($Condition, [string]$Message) {
  if ($Condition) { $script:Passed++; Write-Host "  ok   $Message" }
  else { $script:Failed++; Write-Host "  FAIL $Message" }
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
  $e = [string]$Expected; $a = [string]$Actual
  if ($e -ceq $a) { $script:Passed++; Write-Host "  ok   $Message" }
  else { $script:Failed++; Write-Host "  FAIL $Message`n         expected: [$e]`n         actual:   [$a]" }
}
function Assert-Throws([scriptblock]$Block, [string]$MessageContains, [string]$Message) {
  try { & $Block; $script:Failed++; Write-Host "  FAIL $Message (no error was thrown)" }
  catch {
    $text = [string]$_.Exception.Message
    if ($text.Contains($MessageContains)) { $script:Passed++; Write-Host "  ok   $Message" }
    else { $script:Failed++; Write-Host "  FAIL $Message`n         expected error containing: [$MessageContains]`n         actual: [$text]" }
  }
}

if (-not (Test-Path $script:Publisher)) {
  Write-Host "RED: $script:Publisher does not exist - implementation missing."
  exit 1
}
. $script:Publisher

# ---------------------------------------------------------------- mock feed server

$script:MockServer = @'
param([string]$ConfigPath)
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.IO.Compression
try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }
$config = ConvertFrom-Json ([System.IO.File]::ReadAllText($ConfigPath))
$state = [string]$config.stateDir
$store = Join-Path $state 'store'
New-Item -ItemType Directory -Force -Path $store | Out-Null
$logFile = Join-Path $state 'requests.log'

function Write-Req([string]$line) { Add-Content -Path $logFile -Value $line }

foreach ($p in @($config.preload)) {
  if (-not $p) { continue }
  $dest = Join-Path $store ([string]$p.relpath)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
  Copy-Item -LiteralPath ([string]$p.source) -Destination $dest -Force
}

function Get-ShaHex([byte[]]$Bytes) {
  $sha = [System.Security.Cryptography.SHA256]::Create().ComputeHash($Bytes)
  return ([System.BitConverter]::ToString($sha)).Replace('-', '').ToLowerInvariant()
}
function Get-PackageIdentity([byte[]]$Bytes) {
  $tmp = Join-Path $state ('tmp-' + [guid]::NewGuid().ToString('N') + '.nupkg')
  [System.IO.File]::WriteAllBytes($tmp, $Bytes)
  try {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($tmp)
    try {
      $entry = @($zip.Entries | Where-Object { $_.FullName -match '^[^/]+\.nuspec$' })[0]
      if (-not $entry) { return $null }
      $reader = New-Object System.IO.StreamReader($entry.Open())
      try { $xml = [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
      return @{ id = ([string]$xml.package.metadata.id).ToLowerInvariant(); version = ([string]$xml.package.metadata.version).ToLowerInvariant() }
    } finally { $zip.Dispose() }
  } catch { return $null } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}
function Find-HeaderEnd([byte[]]$Data) {
  for ($i = 3; $i -lt $Data.Length; $i++) {
    if ($Data[$i - 3] -eq 13 -and $Data[$i - 2] -eq 10 -and $Data[$i - 1] -eq 13 -and $Data[$i] -eq 10) { return $i - 3 }
  }
  return -1
}
function Get-ReasonPhrase([int]$Status) {
  switch ($Status) {
    200 { return 'OK' }
    201 { return 'Created' }
    400 { return 'Bad Request' }
    401 { return 'Unauthorized' }
    404 { return 'Not Found' }
    409 { return 'Conflict' }
    500 { return 'Internal Server Error' }
  }
  return 'Status'
}
function Send-Response($stream, [int]$status, [byte[]]$body, [string]$contentType) {
  if (-not $body) { $body = New-Object byte[] 0 }
  if (-not $contentType) { $contentType = 'application/octet-stream' }
  $head = 'HTTP/1.1 ' + $status + ' ' + (Get-ReasonPhrase $status) + "`r`nContent-Type: " + $contentType + "`r`nContent-Length: " + $body.Length + "`r`nConnection: close`r`n`r`n"
  $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
  $stream.Write($headBytes, 0, $headBytes.Length)
  if ($body.Length -gt 0) { $stream.Write($body, 0, $body.Length) }
  $stream.Flush()
}
function Get-Override($method, [string]$path, $counts) {
  $list = @($config.overrides)
  for ($i = 0; $i -lt $list.Count; $i++) {
    $o = $list[$i]
    if (-not $o) { continue }
    if ([string]$o.method -ne $method -or [string]$o.path -ne $path) { continue }
    $times = 0
    if ($o.PSObject.Properties['times']) { $times = [int]$o.times }
    $used = 0
    if ($counts.ContainsKey($i)) { $used = [int]$counts[$i] }
    if ($times -gt 0 -and $used -ge $times) { continue }
    $counts[$i] = $used + 1
    return $o
  }
  return $null
}

function Invoke-Route($method, [string]$path, [byte[]]$bytes) {
  $ov = Get-Override $method $path $overrideCounts
  if ($ov) { return @{ status = [int]$ov.status; body = [System.Text.Encoding]::UTF8.GetBytes('forced response'); type = 'text/plain' } }
  if ($method -eq 'GET' -and $path -eq '/v3/index.json') {
    return @{ status = 200; body = [System.IO.File]::ReadAllBytes((Join-Path $state 'index.json')); type = 'application/json' }
  }
  if ($method -eq 'GET' -and $path -eq [string]$config.releasesPath) {
    return @{ status = 200; body = [System.IO.File]::ReadAllBytes((Join-Path $state 'releases.json')); type = 'application/json' }
  }
  $symbolServerPath = ''
  if ($config.PSObject.Properties['symbolServerPath']) { $symbolServerPath = [string]$config.symbolServerPath }
  if ($method -eq 'GET' -and $symbolServerPath -and $path.StartsWith($symbolServerPath + '/')) {
    return @{ status = 200; body = [System.Text.Encoding]::UTF8.GetBytes('fake-pdb'); type = 'application/octet-stream' }
  }
  if ($method -eq 'PUT' -and ($path -eq [string]$config.packagePublishPath -or $path -eq [string]$config.symbolPublishPath)) {
    $id = Get-PackageIdentity $bytes
    if ($null -eq $id) { return @{ status = 400; body = [System.Text.Encoding]::UTF8.GetBytes('unreadable package'); type = 'text/plain' } }
    $ext = '.nupkg'
    if ($path -eq [string]$config.symbolPublishPath) { $ext = '.snupkg' }
    $rel = $id.id + '/' + $id.version + '/' + $id.id + '.' + $id.version + $ext
    $dest = Join-Path $store ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (Test-Path $dest) { return @{ status = 409; body = [System.Text.Encoding]::UTF8.GetBytes('already exists'); type = 'text/plain' } }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    [System.IO.File]::WriteAllBytes($dest, $bytes)
    return @{ status = 201; body = $null; type = $null }
  }
  if ($method -eq 'GET' -and $path -like '/v3-flatcontainer/*') {
    $rel = $path.Substring('/v3-flatcontainer/'.Length)
    $file = Join-Path $store ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (Test-Path $file) { return @{ status = 200; body = [System.IO.File]::ReadAllBytes($file); type = 'application/octet-stream' } }
    return @{ status = 404; body = [System.Text.Encoding]::UTF8.GetBytes('not found'); type = 'text/plain' }
  }
  return @{ status = 404; body = [System.Text.Encoding]::UTF8.GetBytes('unrouted'); type = 'text/plain' }
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, [int]$config.port)
$listener.Start()
[System.IO.File]::WriteAllText((Join-Path $state 'ready.txt'), 'READY')
$overrideCounts = @{}
Write-Req (@{ method = 'SERVER'; path = 'ready' } | ConvertTo-Json -Compress)

$stop = $false
while (-not $stop) {
  $client = $listener.AcceptTcpClient()
  try {
    $stream = $client.GetStream()
    $buffer = New-Object byte[] 65536
    $memory = New-Object System.IO.MemoryStream
    $headerEnd = -1
    while ($headerEnd -lt 0) {
      $read = $stream.Read($buffer, 0, $buffer.Length)
      if ($read -le 0) { break }
      $memory.Write($buffer, 0, $read)
      $headerEnd = Find-HeaderEnd $memory.ToArray()
    }
    if ($headerEnd -lt 0) { continue }
    $all = $memory.ToArray()
    $headerText = [System.Text.Encoding]::ASCII.GetString($all, 0, $headerEnd)
    $lines = @($headerText -split "`r`n")
    $requestParts = @($lines[0] -split ' ')
    $method = $requestParts[0]
    $path = $requestParts[1]
    if ($path.Contains('?')) { $path = $path.Substring(0, $path.IndexOf('?')) }
    $headers = @{}
    if ($lines.Count -gt 1) {
      foreach ($line in $lines[1..($lines.Count - 1)]) {
        $colon = $line.IndexOf(':')
        if ($colon -gt 0) { $headers[$line.Substring(0, $colon).Trim().ToLowerInvariant()] = $line.Substring($colon + 1).Trim() }
      }
    }
    $contentLength = 0
    if ($headers.ContainsKey('content-length')) { $contentLength = [int]$headers['content-length'] }
    if ($headers.ContainsKey('expect') -and $headers['expect'] -like '*100-continue*') {
      $continueBytes = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
      $stream.Write($continueBytes, 0, $continueBytes.Length)
      $stream.Flush()
    }
    $bodyStart = $headerEnd + 4
    while (($all.Length - $bodyStart) -lt $contentLength) {
      $read = $stream.Read($buffer, 0, $buffer.Length)
      if ($read -le 0) { break }
      $memory.Write($buffer, 0, $read)
      $all = $memory.ToArray()
    }
    $bytes = $null
    if ($contentLength -gt 0 -and $all.Length -ge ($bodyStart + $contentLength)) {
      $bytes = New-Object byte[] $contentLength
      [System.Array]::Copy($all, $bodyStart, $bytes, 0, $contentLength)
    }
    $sha = ''
    $byteCount = 0
    if ($bytes) { $sha = Get-ShaHex $bytes; $byteCount = $bytes.Length }
    if ($path -eq '/__stop') {
      Write-Req (@{ method = $method; path = $path; apikey = ''; bytes = $byteCount; sha256 = $sha; status = 200 } | ConvertTo-Json -Compress)
      Send-Response $stream 200 ([System.Text.Encoding]::UTF8.GetBytes('bye')) 'text/plain'
      $stop = $true
      continue
    }
    $route = Invoke-Route $method $path $bytes
    Write-Req (@{ method = $method; path = $path; apikey = [string]$headers['x-nuget-apikey']; bytes = $byteCount; sha256 = $sha; status = $route.status } | ConvertTo-Json -Compress)
    Send-Response $stream $route.status $route.body $route.type
  } finally {
    $client.Close()
  }
}
'@

$script:MockServerPath = Join-Path $script:Work 'mockfeed.ps1'
[System.IO.File]::WriteAllText($script:MockServerPath, $script:MockServer, [System.Text.UTF8Encoding]::new($false))

# ---------------------------------------------------------------- test helpers

function Get-FreePort {
  $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
  $l.Start()
  $port = $l.LocalEndpoint.Port
  $l.Stop()
  return $port
}

function New-TestPackage {
  param([string]$Dir, [string]$Id, [string]$Version, [string]$Kind = 'nupkg')
  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  $file = Join-Path $Dir ($Id + '.' + $Version + '.' + $Kind)
  $zip = [System.IO.Compression.ZipFile]::Open($file, [System.IO.Compression.ZipArchiveMode]::Create)
  try {
    $nuspec = '<?xml version="1.0" encoding="utf-8"?><package><metadata><id>' + $Id + '</id><version>' + $Version + '</version></metadata></package>'
    $entry = $zip.CreateEntry($Id + '.nuspec')
    $writer = New-Object System.IO.StreamWriter($entry.Open())
    $writer.Write($nuspec)
    $writer.Dispose()
    if ($Kind -eq 'snupkg') { $payload = [System.Text.Encoding]::UTF8.GetBytes('fake pdb body ' + $Id + ' ' + $Version) ; $name = 'lib/net8.0/' + $Id + '.pdb' }
    else { $payload = [System.Text.Encoding]::UTF8.GetBytes('fake dll body ' + $Id + ' ' + $Version); $name = 'lib/net8.0/' + $Id + '.dll' }
    $bin = $zip.CreateEntry($name)
    $stream = $bin.Open()
    $stream.Write($payload, 0, $payload.Length)
    $stream.Dispose()
  } finally { $zip.Dispose() }
  return $file
}

function New-TestManifest {
  param([string]$Dir, [string]$Tag, [string]$Version, $Packages)
  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  $manifest = [pscustomobject]@{
    tag        = $Tag
    source_sha = 'b8977d6f88e7b68e000bac226a2814f236770570'
    version    = $Version
    packages   = @($Packages)
  }
  [System.IO.File]::WriteAllText((Join-Path $Dir 'release-manifest.json'), (ConvertTo-Json -InputObject $manifest -Depth 10), [System.Text.UTF8Encoding]::new($false))
}

function Get-FileShaHex([string]$Path) {
  $sha = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.IO.File]::ReadAllBytes($Path))
  return ([System.BitConverter]::ToString($sha)).Replace('-', '').ToLowerInvariant()
}

function Start-MockFeed {
  param([hashtable]$Options = @{}, [switch]$NoSymbolPublish)
  $port = Get-FreePort
  $state = Join-Path $script:Work ('feed-' + $port)
  New-Item -ItemType Directory -Force -Path $state | Out-Null
  $resources = @(
    [pscustomobject]@{ '@id' = "http://127.0.0.1:$port/v3-flatcontainer"; '@type' = @('PackageBaseAddress/3.0.0') },
    [pscustomobject]@{ '@id' = "http://127.0.0.1:$port/custom/push/pkg"; '@type' = 'PackagePublish/2.0.0' }
  )
  if (-not $NoSymbolPublish) {
    $resources += [pscustomobject]@{ '@id' = "http://127.0.0.1:$port/custom/push/sym"; '@type' = 'SymbolPackagePublish/4.9.0' }
  }
  if ($Options.SymbolServer) {
    $resources += [pscustomobject]@{ '@id' = "http://127.0.0.1:$port/symbols"; '@type' = 'SymbolServer/1.0.0' }
  }
  if ($Options.IndexOverride) { $resources = $Options.IndexOverride }
  $index = [pscustomobject]@{ version = '3.0.0'; resources = $resources }
  [System.IO.File]::WriteAllText((Join-Path $state 'index.json'), (ConvertTo-Json -InputObject $index -Depth 10), [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText((Join-Path $state 'releases.json'), ($Options.ReleasesJson), [System.Text.UTF8Encoding]::new($false))
  $preload = @()
  foreach ($p in @($Options.Preload)) { if ($p) { $preload += $p } }
  $overrides = @()
  foreach ($o in @($Options.Overrides)) { if ($o) { $overrides += $o } }
  $config = [pscustomobject]@{
    port               = $port
    stateDir           = $state
    packagePublishPath = '/custom/push/pkg'
    symbolPublishPath  = '/custom/push/sym'
    releasesPath       = '/repos/wixtoolset/wix/releases'
    preload            = $preload
    overrides          = $overrides
  }
  if ($Options.SymbolServer) { $config | Add-Member -NotePropertyName symbolServerPath -NotePropertyValue '/symbols' }
  $configPath = Join-Path $state 'config.json'
  [System.IO.File]::WriteAllText($configPath, (ConvertTo-Json -InputObject $config -Depth 10), [System.Text.UTF8Encoding]::new($false))
  $job = Start-Job -FilePath $script:MockServerPath -ArgumentList $configPath
  $ready = Join-Path $state 'ready.txt'
  $deadline = (Get-Date).AddSeconds(30)
  while (-not (Test-Path $ready)) {
    if ((Get-Date) -gt $deadline) { throw "mock feed did not become ready: $state" }
    Start-Sleep -Milliseconds 100
  }
  return [pscustomobject]@{ Port = $port; State = $state; BaseUrl = "http://127.0.0.1:$port"; IndexUrl = "http://127.0.0.1:$port/v3/index.json"; Job = $job }
}

function Stop-MockFeed($Feed) {
  if ($null -eq $Feed) { return }
  try { (New-Object System.Net.Http.HttpClient).GetStringAsync("$($Feed.BaseUrl)/__stop").Result | Out-Null } catch { }
  try { Stop-Job $Feed.Job -ErrorAction SilentlyContinue } catch { }
  try { Remove-Job $Feed.Job -Force -ErrorAction SilentlyContinue } catch { }
}

function Get-RequestLog($Feed) {
  $logPath = Join-Path $Feed.State 'requests.log'
  if (-not (Test-Path $logPath)) { return @() }
  $entries = @()
  foreach ($line in @(Get-Content -Path $logPath)) {
    if ($line.Trim()) { $entries += (ConvertFrom-Json -InputObject $line) }
  }
  return $entries
}

function Get-PutLog($Feed) { return @(Get-RequestLog $Feed | Where-Object { $_.method -eq 'PUT' }) }

function New-ReleasesJson([string[]]$Tags) {
  $items = @()
  foreach ($t in $Tags) { $items += [pscustomobject]@{ tag_name = $t; draft = $false; prerelease = $false } }
  return (ConvertTo-Json -InputObject $items -Depth 5)
}

$script:BasicReleases = New-ReleasesJson @('v7.0.0')
$script:MultiReleases = New-ReleasesJson @('v7.1.0', 'v7.0.1', 'v6.0.2', 'v7.0.0', 'v8.1.0', 'v7.0.0.1')

# ---------------------------------------------------------------- scenarios

Write-Host ''
Write-Host '== release tag selection =='
$closed = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$closed.Start()
$closedPort = $closed.LocalEndpoint.Port
$closed.Stop()
Assert-Throws { Send-FeedRequest -Method GET -Uri "http://127.0.0.1:$closedPort/" } 'failed:' 'transport failure throws its real cause rather than HTTP 0'
$selection = @(Select-WixStableReleaseTags -Releases (ConvertFrom-Json (New-ReleasesJson @('v7.1.0', 'v7.0.1', 'v6.0.2', 'v7.0.0', 'v7.0.0-rc.2', 'v8.1.0', 'v8.0.0', 'v7.0.0.1'))) -MinVersion '7.0.0')
$draft = @(ConvertFrom-Json (New-ReleasesJson @('v9.0.0')) | ForEach-Object { $_ })
$draft[0].draft = $true
$selectionWithDraft = @(Select-WixStableReleaseTags -Releases (@($draft) + @(ConvertFrom-Json (New-ReleasesJson @('v7.0.0-rc.1', 'v7.0.0')) | ForEach-Object { $_ })) -MinVersion '7.0.0')
Assert-Equal 'v7.0.0,v7.0.1,v7.1.0,v8.0.0,v8.1.0' (($selection | ForEach-Object { $_.Tag }) -join ',') 'stable numeric tags >= 7.0.0, prerelease/4-part/draft/older excluded, ascending'
Assert-Equal 'v7.0.0' (($selectionWithDraft | ForEach-Object { $_.Tag }) -join ',') 'draft and prerelease releases are excluded'
$selVersions = @($selection | ForEach-Object { [string]$_.Version })
Assert-Equal '7.0.0,7.0.1,7.1.0,8.0.0,8.1.0' ($selVersions -join ',') 'parsed versions are numeric semver'

Write-Host ''
Write-Host '== feed index resolution =='
$feed = Start-MockFeed -Options @{ ReleasesJson = $script:BasicReleases }
try {
  $ep = Get-FeedResources -FeedUrl $feed.IndexUrl
  Assert-Equal "$($feed.BaseUrl)/custom/push/pkg" $ep.PackagePublish 'PackagePublish taken from index (non-standard path)'
  Assert-Equal "$($feed.BaseUrl)/custom/push/sym" $ep.SymbolPackagePublish 'SymbolPackagePublish taken from index'
  Assert-Equal "$($feed.BaseUrl)/v3-flatcontainer" $ep.PackageBaseAddress 'PackageBaseAddress taken from index (@type array form)'
  $brokenFeed = Start-MockFeed -Options @{ ReleasesJson = $script:BasicReleases; IndexOverride = @([pscustomobject]@{ '@id' = 'http://127.0.0.1:1/x'; '@type' = 'PackageBaseAddress/3.0.0' }) }
  try {
    Assert-Throws { Get-FeedResources -FeedUrl $brokenFeed.IndexUrl } 'PackagePublish' 'index without PackagePublish is fatal'
  } finally { Stop-MockFeed $brokenFeed }
  $unauthFeed = Start-MockFeed -Options @{ ReleasesJson = $script:BasicReleases; Overrides = @([pscustomobject]@{ method = 'GET'; path = '/v3/index.json'; status = 401 }) }
  try {
    Assert-Throws { Get-FeedResources -FeedUrl $unauthFeed.IndexUrl } 'uthenticat' 'HTTP 401 on the feed index is a clear fatal error'
  } finally { Stop-MockFeed $unauthFeed }
} finally { Stop-MockFeed $feed }

Write-Host ''
Write-Host '== package existence probe =='
$pkgDir = Join-Path $script:Work 'pkgs'
$sdkPkg = New-TestPackage -Dir $pkgDir -Id 'WixToolset.Sdk' -Version '7.0.0.1'
$feed = Start-MockFeed -Options @{ ReleasesJson = $script:BasicReleases; Preload = @([pscustomobject]@{ relpath = 'wixtoolset.sdk/7.0.0.1/wixtoolset.sdk.7.0.0.1.nupkg'; source = $sdkPkg }) }
try {
  $ep = Get-FeedResources -FeedUrl $feed.IndexUrl
  Assert-True (Test-FeedPackage -Endpoints $ep -Id 'WixToolset.Sdk' -Version '7.0.0.1') 'existing package reported present (HTTP 200)'
  Assert-True (-not (Test-FeedPackage -Endpoints $ep -Id 'WixToolset.Wix' -Version '7.0.0.1')) 'missing package reported absent (HTTP 404)'
  $badFeed = Start-MockFeed -Options @{ ReleasesJson = $script:BasicReleases; Overrides = @([pscustomobject]@{ method = 'GET'; path = '/v3-flatcontainer/wixtoolset.wix/7.0.0.1/wixtoolset.wix.7.0.0.1.nupkg'; status = 500 }) }
  try {
    $badEp = Get-FeedResources -FeedUrl $badFeed.IndexUrl
    Assert-Throws { Test-FeedPackage -Endpoints $badEp -Id 'WixToolset.Wix' -Version '7.0.0.1' } '500' 'unexpected status (500) is fatal, not treated as missing'
  } finally { Stop-MockFeed $badFeed }
} finally { Stop-MockFeed $feed }

Write-Host ''
Write-Host '== manifest validation =='
$badDir = Join-Path $script:Work 'bad-manifest'
New-TestManifest -Dir $badDir -Tag 'v7.0.0' -Version '7.0.1.1' -Packages @()
Assert-Throws { Assert-WixManifest -ManifestDir $badDir } 'mismatch' 'manifest tag/version mismatch (7.0.0.2 vs v7.0.0) is fatal'
$missingDir = Join-Path $script:Work 'missing-file'
New-TestManifest -Dir $missingDir -Tag 'v7.0.0' -Version '7.0.0.1' -Packages @([pscustomobject]@{ id = 'WixToolset.Sdk'; file = 'WixToolset.Sdk.7.0.0.1.nupkg'; sha256 = ('a' * 64); public = $true; symbols = @() })
Assert-Throws { Assert-WixManifest -ManifestDir $missingDir } 'not found' 'listed package file missing on disk is fatal'
$shaDir = Join-Path $script:Work 'sha-mismatch'
New-TestManifest -Dir $shaDir -Tag 'v7.0.0' -Version '7.0.0.1' -Packages @([pscustomobject]@{ id = 'WixToolset.Sdk'; file = 'WixToolset.Sdk.7.0.0.1.nupkg'; sha256 = ('b' * 64); public = $true; symbols = @() })
Copy-Item $sdkPkg (Join-Path $shaDir 'WixToolset.Sdk.7.0.0.1.nupkg')
Assert-Throws { Assert-WixManifest -ManifestDir $shaDir } 'hash' 'manifest sha256 that does not match the file is fatal'
$internalDir = Join-Path $script:Work 'flag-authority'
$flagSdk = New-TestPackage -Dir $internalDir -Id 'WixToolset.Sdk' -Version '7.0.0.1'
$flagCore = New-TestPackage -Dir $internalDir -Id 'WixToolset.Core' -Version '7.0.0.1'
New-TestManifest -Dir $internalDir -Tag 'v7.0.0' -Version '7.0.0.1' -Packages @(
  [pscustomobject]@{ id = 'WixToolset.Sdk'; file = 'WixToolset.Sdk.7.0.0.1.nupkg'; sha256 = (Get-FileShaHex $flagSdk); public = $true; symbols = @() },
  [pscustomobject]@{ id = 'WixToolset.Core'; file = 'WixToolset.Core.7.0.0.1.nupkg'; sha256 = (Get-FileShaHex $flagCore); public = $false; symbols = @() }
)
$flagSelection = Assert-WixManifest -ManifestDir $internalDir
Assert-Equal 1 @($flagSelection.PublicPackages).Count 'the manifest public flag alone selects what is published (no id-prefix inference)'
Assert-Equal 'WixToolset.Sdk' ([string]@($flagSelection.PublicPackages)[0].Id) 'an id that looks official but is flagged public=false stays unpublished'

Write-Host ''
Write-Host '== publish: happy path, order, idempotency =='
$goodDir = Join-Path $script:Work 'good'
$sdkNupkg = New-TestPackage -Dir $goodDir -Id 'WixToolset.Sdk' -Version '7.0.0.1'
$sdkSnupkg = New-TestPackage -Dir $goodDir -Id 'WixToolset.Sdk' -Version '7.0.0.1' -Kind 'snupkg'
$cliNupkg = New-TestPackage -Dir $goodDir -Id 'wix' -Version '7.0.0.1'
$internalNupkg = New-TestPackage -Dir $goodDir -Id 'WixInternal.Contracts' -Version '7.0.0.1'
$coreNupkg = New-TestPackage -Dir $goodDir -Id 'WixToolset.Core' -Version '7.0.0.1'
New-TestManifest -Dir $goodDir -Tag 'v7.0.0' -Version '7.0.0.1' -Packages @(
  [pscustomobject]@{ id = 'WixToolset.Sdk'; file = 'WixToolset.Sdk.7.0.0.1.nupkg'; sha256 = (Get-FileShaHex $sdkNupkg); public = $true; symbols = @([pscustomobject]@{ file = 'WixToolset.Sdk.7.0.0.1.snupkg'; pdbs = @([pscustomobject]@{ name = 'WixToolset.Sdk.pdb'; key = 'aabbccdd'; sha256 = ('d' * 64) }) }) },
  [pscustomobject]@{ id = 'wix'; file = 'wix.7.0.0.1.nupkg'; sha256 = (Get-FileShaHex $cliNupkg); public = $true; symbols = @() },
  [pscustomobject]@{ id = 'WixInternal.Contracts'; file = 'WixInternal.Contracts.7.0.0.1.nupkg'; sha256 = (Get-FileShaHex $internalNupkg); public = $false; symbols = @() },
  [pscustomobject]@{ id = 'WixToolset.Core'; file = 'WixToolset.Core.7.0.0.1.nupkg'; sha256 = (Get-FileShaHex $coreNupkg); public = $false; symbols = @() }
)
$feed = Start-MockFeed -Options @{ ReleasesJson = $script:BasicReleases }
try {
  $summary = @(Publish-WixManifest -ManifestDir $goodDir -FeedUrl $feed.IndexUrl -ApiKey 'test-key-123')
  $puts = @(Get-PutLog $feed)
  Assert-Equal 3 $puts.Count 'only public packages pushed: Sdk nupkg + Sdk snupkg + wix nupkg (public=false excluded)'
  Assert-Equal 0 @($puts | Where-Object { $_.sha256 -eq (Get-FileShaHex $internalNupkg) }).Count 'the non-public WixInternal package is never pushed'
  Assert-Equal 0 @($puts | Where-Object { $_.sha256 -eq (Get-FileShaHex $coreNupkg) }).Count 'a WixToolset.* package flagged public=false (no official v7 package) is never pushed'
  Assert-Equal '/custom/push/pkg' $puts[0].path 'normal nupkg pushed first to the index-provided push endpoint'
  Assert-Equal (Get-FileShaHex $sdkNupkg) $puts[0].sha256 'pushed normal package bytes are the manifest file bytes'
  Assert-Equal '/custom/push/sym' $puts[1].path 'snupkg pushed explicitly to the symbol endpoint'
  Assert-Equal (Get-FileShaHex $sdkSnupkg) $puts[1].sha256 'pushed symbol package bytes are the manifest file bytes'
  Assert-Equal (Get-FileShaHex $cliNupkg) $puts[2].sha256 'remaining public package pushed as well'
  Assert-Equal 201 ([int]$puts[0].status) 'fresh package push accepted with HTTP 201'
  Assert-Equal 'test-key-123' $puts[0].apikey 'X-NuGet-ApiKey header sent on push'
  $gets = @(Get-RequestLog $feed | Where-Object { $_.method -eq 'GET' -and $_.path -like '/v3-flatcontainer/*' })
  Assert-True ($gets.Count -ge 2) 'published packages are read back from the flat container'
  Assert-Equal 'pushed' ([string]($summary | Where-Object { $_.id -eq 'WixToolset.Sdk' }).package) 'summary reports WixToolset.Sdk as pushed'
  Assert-Equal 'pushed' ([string]($summary | Where-Object { $_.id -eq 'WixToolset.Sdk' }).symbols) 'summary reports symbols as pushed'

  $beforeSecondRun = @(Get-PutLog $feed).Count
  $summary2 = @(Publish-WixManifest -ManifestDir $goodDir -FeedUrl $feed.IndexUrl -ApiKey 'test-key-123')
  $newPuts = @(Get-PutLog $feed | Select-Object -Skip $beforeSecondRun)
  Assert-Equal 0 @($newPuts | Where-Object { [int]$_.status -lt 300 }).Count 'second run accepts no new push (idempotent)'
  Assert-Equal 1 $newPuts.Count 'second run re-attempts only the snupkg (explicit symbol push is not skipped after a conflict)'
  Assert-Equal '/custom/push/sym' ([string]$newPuts[0].path) 'the re-attempted push is the symbol package'
  Assert-Equal 409 ([int]$newPuts[0].status) 'symbol re-attempt answers 409 and is treated as already present'
  Assert-Equal 'exists' ([string]($summary2 | Where-Object { $_.id -eq 'WixToolset.Sdk' }).package) 'second run verifies the existing package by hash and reports exists'
} finally { Stop-MockFeed $feed }

Write-Host ''
Write-Host '== publish: partial retry and hash guard =='
$partialDir = Join-Path $script:Work 'partial'
$sdkNupkg2 = New-TestPackage -Dir $partialDir -Id 'WixToolset.Sdk' -Version '7.0.0.1'
$wixNupkg2 = New-TestPackage -Dir $partialDir -Id 'wix' -Version '7.0.0.1'
New-TestManifest -Dir $partialDir -Tag 'v7.0.0' -Version '7.0.0.1' -Packages @(
  [pscustomobject]@{ id = 'WixToolset.Sdk'; file = 'WixToolset.Sdk.7.0.0.1.nupkg'; sha256 = (Get-FileShaHex $sdkNupkg2); public = $true; symbols = @() },
  [pscustomobject]@{ id = 'wix'; file = 'wix.7.0.0.1.nupkg'; sha256 = (Get-FileShaHex $wixNupkg2); public = $true; symbols = @() }
)
$feed = Start-MockFeed -Options @{ ReleasesJson = $script:BasicReleases; Preload = @([pscustomobject]@{ relpath = 'wixtoolset.sdk/7.0.0.1/wixtoolset.sdk.7.0.0.1.nupkg'; source = $sdkNupkg2 }) }
try {
  $summary = @(Publish-WixManifest -ManifestDir $partialDir -FeedUrl $feed.IndexUrl -ApiKey 'k')
  $puts = @(Get-PutLog $feed)
  Assert-Equal 1 $puts.Count 'partial publication: only the missing package is pushed'
  Assert-Equal (Get-FileShaHex $wixNupkg2) $puts[0].sha256 'the pushed package is the one that was missing'
  Assert-Equal 'exists' ([string]($summary | Where-Object { $_.id -eq 'WixToolset.Sdk' }).package) 'already published package verified, not re-pushed'
} finally { Stop-MockFeed $feed }

$mismatchDir = Join-Path $script:Work 'mismatch'
$otherBytes = Join-Path $mismatchDir 'other.bin'
New-Item -ItemType Directory -Force -Path $mismatchDir | Out-Null
[System.IO.File]::WriteAllBytes($otherBytes, [System.Text.Encoding]::UTF8.GetBytes('different bytes than the manifest package'))
$sdkNupkg3 = New-TestPackage -Dir $mismatchDir -Id 'WixToolset.Sdk' -Version '7.0.0.1'
New-TestManifest -Dir $mismatchDir -Tag 'v7.0.0' -Version '7.0.0.1' -Packages @(
  [pscustomobject]@{ id = 'WixToolset.Sdk'; file = 'WixToolset.Sdk.7.0.0.1.nupkg'; sha256 = (Get-FileShaHex $sdkNupkg3); public = $true; symbols = @() }
)
$feed = Start-MockFeed -Options @{ ReleasesJson = $script:BasicReleases; Preload = @([pscustomobject]@{ relpath = 'wixtoolset.sdk/7.0.0.1/wixtoolset.sdk.7.0.0.1.nupkg'; source = $otherBytes }) }
try {
  Assert-Throws { Publish-WixManifest -ManifestDir $mismatchDir -FeedUrl $feed.IndexUrl -ApiKey 'k' } 'mismatch' 'existing feed package with different bytes is fatal (no metadata fallback)'
  Assert-Equal 0 @(Get-PutLog $feed).Count 'no push attempted when the conflicting package is detected'
} finally { Stop-MockFeed $feed }

Write-Host ''
Write-Host '== publish: conflict (409) handling =='
$conflictDir = Join-Path $script:Work 'conflict'
$sdkNupkg4 = New-TestPackage -Dir $conflictDir -Id 'WixToolset.Sdk' -Version '7.0.0.1'
New-TestManifest -Dir $conflictDir -Tag 'v7.0.0' -Version '7.0.0.1' -Packages @(
  [pscustomobject]@{ id = 'WixToolset.Sdk'; file = 'WixToolset.Sdk.7.0.0.1.nupkg'; sha256 = (Get-FileShaHex $sdkNupkg4); public = $true; symbols = @() }
)
$feed = Start-MockFeed -Options @{ ReleasesJson = $script:BasicReleases; Overrides = @([pscustomobject]@{ method = 'PUT'; path = '/custom/push/pkg'; status = 409 }) }
try {
  Assert-Throws { Publish-WixManifest -ManifestDir $conflictDir -FeedUrl $feed.IndexUrl -ApiKey 'k' } 'read back' 'push conflict without readable/hash-matching content is fatal, never a blind pass'
} finally { Stop-MockFeed $feed }

$feed = Start-MockFeed -Options @{ ReleasesJson = $script:BasicReleases; Preload = @([pscustomobject]@{ relpath = 'wixtoolset.sdk/7.0.0.1/wixtoolset.sdk.7.0.0.1.nupkg'; source = $sdkNupkg4 }); Overrides = @(
  [pscustomobject]@{ method = 'GET'; path = '/v3-flatcontainer/wixtoolset.sdk/7.0.0.1/wixtoolset.sdk.7.0.0.1.nupkg'; status = 404; times = 1 },
  [pscustomobject]@{ method = 'PUT'; path = '/custom/push/pkg'; status = 409; times = 1 }
) }
try {
  $summary = @(Publish-WixManifest -ManifestDir $conflictDir -FeedUrl $feed.IndexUrl -ApiKey 'k')
  Assert-Equal 'exists' ([string]$summary[0].package) 'push conflict followed by hash-matching readback is accepted as already published'
  Assert-Equal 1 @(Get-PutLog $feed).Count 'conflict path pushes exactly once'
} finally { Stop-MockFeed $feed }

Write-Host ''
Write-Host '== publish: symbol endpoint requirements and SSQP readback =='
$feedNoSymbol = Start-MockFeed -Options @{ ReleasesJson = $script:BasicReleases } -NoSymbolPublish
try {
  $ep = Get-FeedResources -FeedUrl $feedNoSymbol.IndexUrl
  Assert-True ($null -eq $ep.SymbolPackagePublish) 'feed without SymbolPackagePublish resolves to $null'
  Assert-Throws { Publish-WixManifest -ManifestDir $goodDir -FeedUrl $feedNoSymbol.IndexUrl -ApiKey 'k' } 'ymbol' 'manifest with snupkg against a feed without symbol support is fatal'
} finally { Stop-MockFeed $feedNoSymbol }

$feedSymbol = Start-MockFeed -Options @{ ReleasesJson = $script:BasicReleases; SymbolServer = $true }
try {
  $summary = @(Publish-WixManifest -ManifestDir $goodDir -FeedUrl $feedSymbol.IndexUrl -ApiKey 'k')
  $ssqp = @(Get-RequestLog $feedSymbol | Where-Object { $_.method -eq 'GET' -and $_.path -like '/symbols/*' })
  Assert-Equal 1 $ssqp.Count 'pdb readback uses the SSQP route derived from the advertised symbol server'
  Assert-Equal '/symbols/WixToolset.Sdk.pdb/aabbccdd/WixToolset.Sdk.pdb' ([string]$ssqp[0].path) 'SSQP route is <server>/<name>/<key>/<name>'
  Assert-Equal 'pushed' ([string]($summary | Where-Object { $_.id -eq 'WixToolset.Sdk' }).symbols) 'symbols verified through SSQP readback'
} finally { Stop-MockFeed $feedSymbol }

Assert-Equal 'http://feed/symbols/A.pdb/KEY1/A.pdb' (Get-SsqpPdbUri -BaseUrl 'http://feed/symbols/' -FileName 'A.pdb' -Key 'KEY1') 'SSQP URL builder joins base/name/key/name'
Assert-Throws { Get-SsqpPdbUri -BaseUrl '' -FileName 'A.pdb' -Key 'KEY1' } 'ymbol' 'SSQP URL builder refuses an empty symbol server base (no invented URL)'

$feed = Start-MockFeed -Options @{ ReleasesJson = $script:BasicReleases; Preload = @(
  [pscustomobject]@{ relpath = 'wixtoolset.sdk/7.0.0.1/wixtoolset.sdk.7.0.0.1.nupkg'; source = $sdkNupkg },
  [pscustomobject]@{ relpath = 'wix/7.0.0.1/wix.7.0.0.1.nupkg'; source = $cliNupkg }
); Overrides = @([pscustomobject]@{ method = 'PUT'; path = '/custom/push/sym'; status = 500; times = 1 }) }
try {
  Assert-Throws { Publish-WixManifest -ManifestDir $goodDir -FeedUrl $feed.IndexUrl -ApiKey 'k' } '500' 'failed symbol push is a publication failure even when all nupkgs exist'
  $decisions = @(Invoke-WixDiscovery -StateDir $goodDir -FeedUrl $feed.IndexUrl -GitHubApiBase $feed.BaseUrl)
  Assert-Equal 'publish' ([string]$decisions[0].action) 'symbol-only failure is retried without rebuilding'
  $null = Publish-WixManifest -ManifestDir $goodDir -FeedUrl $feed.IndexUrl -ApiKey 'k'
  $decisions = @(Invoke-WixDiscovery -StateDir $goodDir -FeedUrl $feed.IndexUrl -GitHubApiBase $feed.BaseUrl)
  Assert-Equal 'skip' ([string]$decisions[0].action) 'completed packages and symbols are skipped on the next discovery'
} finally { Stop-MockFeed $feed }

Write-Host ''
Write-Host '== discovery =='
$stateRoot = Join-Path $script:Work 'state'
$stateV700 = Join-Path $stateRoot 'v7.0.0'
New-TestManifest -Dir $stateV700 -Tag 'v7.0.0' -Version '7.0.0.1' -Packages @(
  [pscustomobject]@{ id = 'WixToolset.Sdk'; file = 'WixToolset.Sdk.7.0.0.1.nupkg'; sha256 = (Get-FileShaHex $sdkNupkg2); public = $true; symbols = @() },
  [pscustomobject]@{ id = 'wix'; file = 'wix.7.0.0.1.nupkg'; sha256 = (Get-FileShaHex $wixNupkg2); public = $true; symbols = @() }
)
Copy-Item $sdkNupkg2 (Join-Path $stateV700 'WixToolset.Sdk.7.0.0.1.nupkg')
Copy-Item $wixNupkg2 (Join-Path $stateV700 'wix.7.0.0.1.nupkg')

# Only the SDK is on the feed -> NOT complete -> publish (partial state must not be skipped).
$feed = Start-MockFeed -Options @{ ReleasesJson = $script:BasicReleases; Preload = @([pscustomobject]@{ relpath = 'wixtoolset.sdk/7.0.0.1/wixtoolset.sdk.7.0.0.1.nupkg'; source = $sdkNupkg2 }) }
try {
  $decisions = @(Invoke-WixDiscovery -StateDir $stateRoot -FeedUrl $feed.IndexUrl -GitHubRepository 'wixtoolset/wix' -GitHubApiBase $feed.BaseUrl -MinVersion '7.0.0')
  Assert-Equal 1 $decisions.Count 'one candidate release evaluated'
  Assert-Equal 'v7.0.0' ([string]$decisions[0].tag) 'candidate tag parsed from the releases API'
  Assert-Equal 'publish' ([string]$decisions[0].action) 'partially published version (SDK present, wix missing) needs publish, not skip'
} finally { Stop-MockFeed $feed }

# Empty state dir -> unknown package list -> build.
$emptyState = Join-Path $script:Work 'state-empty'
New-Item -ItemType Directory -Force -Path $emptyState | Out-Null
$feed = Start-MockFeed -Options @{ ReleasesJson = $script:BasicReleases }
try {
  $decisions = @(Invoke-WixDiscovery -StateDir $emptyState -FeedUrl $feed.IndexUrl -GitHubRepository 'wixtoolset/wix' -GitHubApiBase $feed.BaseUrl -MinVersion '7.0.0')
  Assert-Equal 'build' ([string]$decisions[0].action) 'version without a known local manifest is built'
  Assert-Equal 0 @(Get-RequestLog $feed | Where-Object { $_.method -eq 'GET' -and $_.path -like '/v3-flatcontainer/*' }).Count 'no feed probing when no manifest is known'
} finally { Stop-MockFeed $feed }

# Everything published -> skip.
$feed = Start-MockFeed -Options @{ ReleasesJson = $script:BasicReleases; Preload = @(
  [pscustomobject]@{ relpath = 'wixtoolset.sdk/7.0.0.1/wixtoolset.sdk.7.0.0.1.nupkg'; source = $sdkNupkg2 },
  [pscustomobject]@{ relpath = 'wix/7.0.0.1/wix.7.0.0.1.nupkg'; source = $wixNupkg2 }
) }
try {
  $decisions = @(Invoke-WixDiscovery -StateDir $stateRoot -FeedUrl $feed.IndexUrl -GitHubRepository 'wixtoolset/wix' -GitHubApiBase $feed.BaseUrl -MinVersion '7.0.0')
  Assert-Equal 'skip' ([string]$decisions[0].action) 'fully published version is skipped (no rebuild, no image)'
} finally { Stop-MockFeed $feed }

# Manifest without the package files -> rebuild.
$staleState = Join-Path $script:Work 'state-stale'
New-TestManifest -Dir (Join-Path $staleState 'v7.0.0') -Tag 'v7.0.0' -Version '7.0.0.1' -Packages @(
  [pscustomobject]@{ id = 'WixToolset.Sdk'; file = 'WixToolset.Sdk.7.0.0.1.nupkg'; sha256 = ('e' * 64); public = $true; symbols = @() }
)
$feed = Start-MockFeed -Options @{ ReleasesJson = $script:BasicReleases }
try {
  $decisions = @(Invoke-WixDiscovery -StateDir $staleState -FeedUrl $feed.IndexUrl -GitHubRepository 'wixtoolset/wix' -GitHubApiBase $feed.BaseUrl -MinVersion '7.0.0')
  Assert-Equal 'build' ([string]$decisions[0].action) 'manifest without its package files triggers a rebuild'
} finally { Stop-MockFeed $feed }

# Ordering across multiple releases (ascending, all missing versions).
$feed = Start-MockFeed -Options @{ ReleasesJson = $script:MultiReleases }
try {
  $decisions = @(Invoke-WixDiscovery -StateDir $emptyState -FeedUrl $feed.IndexUrl -GitHubRepository 'wixtoolset/wix' -GitHubApiBase $feed.BaseUrl -MinVersion '7.0.0')
  Assert-Equal 'v7.0.0,v7.0.1,v7.1.0,v8.1.0' (($decisions | ForEach-Object { $_.tag }) -join ',') 'all missing versions listed ascending (v6.0.2 and v7.0.0.1 excluded)'
} finally { Stop-MockFeed $feed }

Write-Host ''
Write-Host '== discovery CLI contract (what the Jenkinsfile consumes) =='
$feed = Start-MockFeed -Options @{ ReleasesJson = $script:BasicReleases; Preload = @([pscustomobject]@{ relpath = 'wixtoolset.sdk/7.0.0.1/wixtoolset.sdk.7.0.0.1.nupkg'; source = $sdkNupkg2 }) }
try {
  $hostExe = (Get-Process -Id $PID).Path
  $lines = @(& $hostExe -NoProfile -File $script:Publisher -Discover -FeedUrl $feed.IndexUrl -StateDir $stateRoot -GitHubApiBase $feed.BaseUrl -MinVersion '7.0.0' 2>&1 | ForEach-Object { [string]$_ })
  $code = $LASTEXITCODE
  Assert-Equal 0 $code 'discovery CLI exits 0'
  Assert-True ($lines -contains 'publish v7.0.0') 'CLI prints "publish <tag>" for a partially published version'
  $lines = @(& $hostExe -NoProfile -File $script:Publisher -Discover -FeedUrl $feed.IndexUrl -StateDir $emptyState -GitHubApiBase $feed.BaseUrl -MinVersion '7.0.0' 2>&1 | ForEach-Object { [string]$_ })
  Assert-Equal 0 $LASTEXITCODE 'discovery CLI exits 0 with nothing known'
  Assert-True ($lines -contains 'build v7.0.0') 'CLI prints "build <tag>" for a new version'
} finally { Stop-MockFeed $feed }

Write-Host ''
Write-Host '== CLI contract: validate and publish (exact Jenkinsfile invocations) =='
$hostExe = (Get-Process -Id $PID).Path
$lines = @(& $hostExe -NoProfile -File $script:Publisher -Validate -ManifestDir $goodDir 2>&1 | ForEach-Object { [string]$_ })
Assert-Equal 0 $LASTEXITCODE 'validate CLI exits 0 for a good manifest'
Assert-True (([string]::Join("`n", $lines)).Contains('validated')) 'validate CLI reports the validated manifest'
$previousPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue' # this child is expected to write stderr and exit 1
try {
  $lines = @(& $hostExe -NoProfile -File $script:Publisher -Validate -ManifestDir $shaDir 2>&1 | ForEach-Object { [string]$_ })
  $validationExit = $LASTEXITCODE
} finally { $ErrorActionPreference = $previousPreference }
Assert-Equal 1 $validationExit 'validate CLI exits 1 for a manifest whose hash does not match'
Assert-True (([string]::Join("`n", $lines)).Contains('failed')) 'validate CLI reports the failure reason'

$feed = Start-MockFeed -Options @{ ReleasesJson = $script:BasicReleases }
try {
  $env:NUGET_API_KEY = 'env-key-99'
  $lines = @(& $hostExe -NoProfile -File $script:Publisher -FeedUrl $feed.IndexUrl -ManifestDir $goodDir 2>&1 | ForEach-Object { [string]$_ })
  Assert-Equal 0 $LASTEXITCODE 'publish CLI exits 0'
  $cliPuts = @(Get-PutLog $feed)
  Assert-Equal 3 $cliPuts.Count 'publish CLI pushed all public packages (nupkg + snupkg + nupkg)'
  Assert-Equal 'env-key-99' ([string]$cliPuts[0].apikey) 'publish CLI takes the API key from the NUGET_API_KEY environment variable'
} finally {
  $env:NUGET_API_KEY = $null
  Stop-MockFeed $feed
}

Write-Host ''
if ($script:Failed -eq 0) {
  Write-Host "GREEN: $script:Passed assertions passed."
  exit 0
}
Write-Host "RED: $script:Failed of $($script:Passed + $script:Failed) assertions failed."
exit 1
