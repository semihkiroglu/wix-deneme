#Requires -Version 5.1
<#
.SYNOPSIS
    Discovery (which upstream WiX releases still need building) and publish helper for the
    daily WiX -> internal BaGetter feed pipeline.

.DESCRIPTION
    Modes (exactly one):
      -Discover -StateDir <dir>      Query GitHub releases, filter stable numeric tags >= MinVersion,
                                     compare with the feed for every known local release-manifest.json
                                     and print one directive per version: "build|publish|skip <tag>".
      -Validate -ManifestDir <dir>   Validate release-manifest.json (tag <-> u.p.v.1 version, hashes,
                                     files) without touching the feed.
      <publish> -ManifestDir <dir>   Push the validated public packages (normal nupkg first, then the
                                     snupkg separately) and verify them by hash readback.

    Endpoints (push/flat-container/symbol) are taken from the feed's service index, never hard-coded.
    Push auth is the X-NuGet-ApiKey header; the key comes from -ApiKey or NUGET_API_KEY.
    Read auth is optional Basic (-FeedUser/-FeedPassword or WIX_FEED_USER/WIX_FEED_PASSWORD);
    no credentials are embedded here.
#>
param(
    [switch]$Discover,
    [switch]$Validate,
    [string]$ManifestDir = '',
    [string]$FeedUrl = '',
    [string]$ApiKey = '',
    [string]$StateDir = 'artifacts',
    [string]$GitHubRepository = 'wixtoolset/wix',
    [string]$GitHubApiBase = 'https://api.github.com',
    [string]$MinVersion = '7.0.0',
    [string]$FeedUser = '',
    [string]$FeedPassword = '',
    [string]$SymbolServerUrl = '',
    [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'

try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { }

function Get-Trimmed([string]$Value) {
    if ($null -eq $Value) { return '' }
    return $Value.Trim()
}

function Get-FeedAuth {
    param([string]$User, [string]$Password)
    $userValue = Get-Trimmed $User
    if (-not $userValue) { $userValue = Get-Trimmed $env:WIX_FEED_USER }
    $passwordValue = Get-Trimmed $Password
    if (-not $passwordValue) { $passwordValue = Get-Trimmed $env:WIX_FEED_PASSWORD }
    if (-not $userValue) { return $null }
    return [pscustomobject]@{ User = $userValue; Password = $passwordValue }
}

function Get-FeedHttpClient {
    if ($null -eq $script:FeedHttpClient) {
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            # PS 5.1 defaults to TLS 1.0 without this; internal feeds are TLS 1.2+.
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            [System.Net.ServicePointManager]::Expect100Continue = $false
        }
        $handler = New-Object System.Net.Http.HttpClientHandler
        # Feed credentials (X-NuGet-ApiKey / Basic) must never follow a redirect to another origin.
        $handler.AllowAutoRedirect = $false
        $client = New-Object System.Net.Http.HttpClient -ArgumentList $handler
        $client.Timeout = [TimeSpan]::FromMinutes(30)
        $script:FeedHttpClient = $client
    }
    return $script:FeedHttpClient
}

function Send-FeedRequest {
    param(
        [string]$Method,
        [string]$Uri,
        $Auth,
        [string]$ApiKey = '',
        [string]$BodyFile = '',
        [string]$ContentType = 'application/octet-stream',
        [string]$OutFile = '',
        [switch]$HeadersOnly,
        [switch]$ReadText,
        [hashtable]$ExtraHeaders
    )
    $client = Get-FeedHttpClient
    $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList ([System.Net.Http.HttpMethod]::new($Method.ToUpperInvariant()), $Uri)
    $content = $null
    try {
        if ($Auth) {
            $pair = $Auth.User + ':' + $Auth.Password
            $request.Headers.Add('Authorization', 'Basic ' + [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair)))
        }
        if ($ApiKey) { $request.Headers.Add('X-NuGet-ApiKey', $ApiKey) }
        if ($ExtraHeaders) { foreach ($key in $ExtraHeaders.Keys) { $request.Headers.Add([string]$key, [string]$ExtraHeaders[$key]) } }
        if ($BodyFile) {
            $stream = [System.IO.File]::OpenRead($BodyFile)
            $content = New-Object System.Net.Http.StreamContent -ArgumentList $stream
            $content.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue -ArgumentList $ContentType
            $request.Content = $content
        }
        $option = [System.Net.Http.HttpCompletionOption]::ResponseContentRead
        if ($HeadersOnly) { $option = [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead }
        try {
            $response = $client.SendAsync($request, $option).GetAwaiter().GetResult()
        } catch {
            $reason = $_.Exception
            if ($reason -is [System.AggregateException] -and $reason.InnerExceptions.Count -ge 1) { $reason = $reason.InnerExceptions[0] }
            throw "Feed request $Method $Uri failed: $($reason.Message)"
        }
        try {
            $status = [int]$response.StatusCode
            $text = ''
            if ($OutFile -and $status -eq 200) {
                $source = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $target = [System.IO.File]::Create($OutFile)
                try { $source.CopyTo($target) } finally { $target.Dispose(); $source.Dispose() }
            } elseif ($ReadText -and -not $HeadersOnly) {
                $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            }
            return [pscustomobject]@{ Status = $status; Text = $text }
        } finally { $response.Dispose() }
    } finally {
        if ($content) { $content.Dispose() }
        $request.Dispose()
    }
}

function Get-Sha256Hex([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try { $hash = $sha.ComputeHash($stream) } finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
}

function Assert-TrustedFeedEndpoint([string]$Url, [string]$FeedUrl, [string]$Purpose, [switch]$AllowSeparateHost) {
    # Feed credentials go to these endpoints verbatim; a compromised service index must not be able to point
    # them at another origin. Loopback HTTP is allowed for the local test feed only.
    if (-not $Url) { return }
    $uri = $null
    try { $uri = [uri]$Url } catch { throw "$Purpose endpoint is not a valid URI: $Url" }
    $feed = [uri]$FeedUrl
    $loopback = @('127.0.0.1','::1','localhost')
    $loopbackPair = $uri.Scheme -eq 'http' -and $feed.Scheme -eq 'http' -and ($uri.Host -in $loopback) -and ($feed.Host -in $loopback)
    if (-not $loopbackPair -and $uri.Scheme -ne 'https') { throw "$Purpose endpoint must be HTTPS: $Url" }
    if (-not $AllowSeparateHost -and ($uri.Host -ne $feed.Host -or $uri.Port -ne $feed.Port)) { throw "$Purpose endpoint '$Url' is outside the feed origin '$FeedUrl'" }
}

function Get-FeedResources {
    param([string]$FeedUrl, $Auth)
    # The configured feed URL itself carries the Basic credential; require HTTPS (loopback HTTP for the local test feed only).
    Assert-TrustedFeedEndpoint -Url $FeedUrl -FeedUrl $FeedUrl -Purpose 'Feed service index'
    $result = Send-FeedRequest -Method 'GET' -Uri $FeedUrl -Auth $Auth -ReadText
    if ($result.Status -eq 401) {
        throw "Feed service index $FeedUrl requires authentication (HTTP 401). Configure a Basic credential via -FeedUser/-FeedPassword or WIX_FEED_USER/WIX_FEED_PASSWORD; no credentials are embedded in this repository."
    }
    if ($result.Status -ne 200) { throw "Feed service index $FeedUrl returned HTTP $($result.Status)" }
    try { $index = ConvertFrom-Json $result.Text } catch { throw "Feed service index $FeedUrl is not valid JSON: $($_.Exception.Message)" }
    $byType = @{}
    foreach ($resource in @($index.resources)) {
        if (-not $resource) { continue }
        $id = [string]$resource.'@id'
        foreach ($type in @($resource.'@type')) { if ($type) { $byType[[string]$type] = $id } }
    }
    $publish = ''
    if ($byType.ContainsKey('PackagePublish/2.0.0')) { $publish = $byType['PackagePublish/2.0.0'] }
    if (-not $publish) { throw "Feed $FeedUrl does not advertise PackagePublish/2.0.0" }
    $flatContainer = ''
    if ($byType.ContainsKey('PackageBaseAddress/3.0.0')) { $flatContainer = $byType['PackageBaseAddress/3.0.0'] }
    if (-not $flatContainer) { throw "Feed $FeedUrl does not advertise PackageBaseAddress/3.0.0" }
    $symbolPublish = $null
    if ($byType.ContainsKey('SymbolPackagePublish/4.9.0')) { $symbolPublish = $byType['SymbolPackagePublish/4.9.0'] }
    # Only an explicitly advertised symbol server may be used; never derive one from a pattern.
    $symbolServer = $null
    foreach ($type in @($byType.Keys)) {
        if ($type -match '^(?i)(SymbolServer|SymbolPackageDownload)/') { $symbolServer = $byType[$type]; break }
    }
    if ($symbolServer) { $symbolServer = $symbolServer.TrimEnd('/') }
    Assert-TrustedFeedEndpoint -Url $publish -FeedUrl $FeedUrl -Purpose 'PackagePublish'
    Assert-TrustedFeedEndpoint -Url $flatContainer -FeedUrl $FeedUrl -Purpose 'PackageBaseAddress'
    Assert-TrustedFeedEndpoint -Url $symbolPublish -FeedUrl $FeedUrl -Purpose 'SymbolPackagePublish'
    Assert-TrustedFeedEndpoint -Url $symbolServer -FeedUrl $FeedUrl -Purpose 'SymbolServerBase' -AllowSeparateHost
    return [pscustomobject]@{
        FeedUrl              = $FeedUrl
        PackagePublish       = $publish
        PackageBaseAddress   = $flatContainer.TrimEnd('/')
        SymbolPackagePublish = $symbolPublish
        SymbolServerBase     = $symbolServer
    }
}

function Get-FlatContainerUri {
    param($Endpoints, [string]$Id, [string]$Version)
    $id = $Id.ToLowerInvariant()
    $version = $Version.ToLowerInvariant()
    return $Endpoints.PackageBaseAddress.TrimEnd('/') + '/' + $id + '/' + $version + '/' + $id + '.' + $version + '.nupkg'
}

function Test-FeedPackage {
    param($Endpoints, [string]$Id, [string]$Version, $Auth)
    $uri = Get-FlatContainerUri -Endpoints $Endpoints -Id $Id -Version $Version
    $status = (Send-FeedRequest -Method 'GET' -Uri $uri -Auth $Auth -HeadersOnly).Status
    if ($status -eq 200) { return $true }
    if ($status -eq 404) { return $false }
    throw "Feed probe $uri returned HTTP $status"
}

function Receive-FeedPackage {
    param($Endpoints, [string]$Id, [string]$Version, $Auth, [string]$WorkDir = '')
    $uri = Get-FlatContainerUri -Endpoints $Endpoints -Id $Id -Version $Version
    if (-not $WorkDir) { $WorkDir = [System.IO.Path]::GetTempPath() }
    $tmp = Join-Path $WorkDir ('feed-readback-' + [guid]::NewGuid().ToString('N') + '.nupkg')
    try {
        $status = (Send-FeedRequest -Method 'GET' -Uri $uri -Auth $Auth -OutFile $tmp).Status
        if ($status -eq 404) { return $null }
        if ($status -ne 200) { throw "Feed readback $uri returned HTTP $status" }
        return (Get-Sha256Hex $tmp)
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Publish-FeedFile {
    param($Endpoints, [string]$FilePath, [string]$Kind, [string]$ApiKey, $Auth)
    $uri = $Endpoints.PackagePublish
    if ($Kind -eq 'Symbol') {
        if (-not $Endpoints.SymbolPackagePublish) {
            throw "Feed $($Endpoints.FeedUrl) does not advertise SymbolPackagePublish/4.9.0; cannot push symbol package $(Split-Path -Leaf $FilePath)"
        }
        $uri = $Endpoints.SymbolPackagePublish
    }
    $status = (Send-FeedRequest -Method 'PUT' -Uri $uri -Auth $Auth -ApiKey $ApiKey -BodyFile $FilePath).Status
    if ($status -eq 409) { return 409 }
    if ($status -ne 200 -and $status -ne 201 -and $status -ne 202 -and $status -ne 204) {
        throw "Push of $(Split-Path -Leaf $FilePath) to $uri failed with HTTP $status"
    }
    return $status
}

function Assert-WixManifest {
    param([string]$ManifestDir)
    if (-not (Test-Path -LiteralPath $ManifestDir)) { throw "Manifest directory not found: $ManifestDir" }
    $dir = (Resolve-Path -LiteralPath $ManifestDir).Path
    $manifestPath = Join-Path $dir 'release-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw "release-manifest.json not found in $ManifestDir" }
    try { $manifest = ConvertFrom-Json ([System.IO.File]::ReadAllText($manifestPath)) } catch { throw "release-manifest.json is not valid JSON: $($_.Exception.Message)" }
    $tag = [string]$manifest.tag
    $version = [string]$manifest.version
    if ($tag -notmatch '^v\d+\.\d+\.\d+$') { throw "Manifest tag '$tag' is not a stable numeric release tag" }
    if ($version -notmatch '^\d+\.\d+\.\d+\.1$') { throw "Manifest version '$version' is not the internal u.p.v.1 version" }
    if ($tag.Substring(1) + '.1' -ne $version) { throw "Manifest tag/version mismatch: $tag vs $version" }
    if (([string]$manifest.source_sha) -notmatch '^[0-9a-fA-F]{40}$') { throw "Manifest source_sha is not a 40-char hex revision" }
    $packages = @($manifest.packages)
    if (-not $packages.Count) { throw "Manifest lists no packages: $manifestPath" }
    $public = @()
    foreach ($package in $packages) {
        if (-not $package) { continue }
        if (-not [bool]$package.public) { continue }
        $id = [string]$package.id
        $file = [string]$package.file
        if (-not $id -or -not $file) { throw "Manifest package entry without id/file in $manifestPath" }
        # 'public' is authoritative (the build probes the official feed per package); no id-prefix inference here.
        $full = Join-Path $dir $file
        if (-not (Test-Path -LiteralPath $full)) { throw "Package file '$file' for '$id' not found in $dir" }
        $actual = Get-Sha256Hex $full
        if ($actual -ne ([string]$package.sha256).ToLowerInvariant()) { throw "Package hash mismatch for '$id': manifest $($package.sha256), file $actual" }
        $symbols = @()
        foreach ($symbol in @($package.symbols)) {
            if (-not $symbol) { continue }
            $symbolFile = [string]$symbol.file
            if (-not $symbolFile) { continue }
            $symbolFull = Join-Path $dir $symbolFile
            if (-not (Test-Path -LiteralPath $symbolFull)) { throw "Symbol package '$symbolFile' for '$id' not found in $dir" }
            $symbolSha = [string]$symbol.sha256
            if (-not $symbolSha) { throw "Symbol package '$symbolFile' for '$id' has no sha256 in the manifest; rebuild the release manifest" }
            $actualSymbol = Get-Sha256Hex $symbolFull
            if ($actualSymbol -ne $symbolSha.ToLowerInvariant()) { throw "Symbol package hash mismatch for '$symbolFile': manifest $symbolSha, file $actualSymbol" }
            $symbols += [pscustomobject]@{ File = $symbolFile; FullPath = $symbolFull; Pdbs = @($symbol.pdbs) }
        }
        $public += [pscustomobject]@{ Id = $id; Version = $version; File = $file; FullPath = $full; Sha256 = $actual; Symbols = $symbols }
    }
    if (-not $public.Count) { throw "Manifest has no public packages: $manifestPath" }
    return [pscustomobject]@{ Dir = $dir; Tag = $tag; Version = $version; SourceSha = [string]$manifest.source_sha; PublicPackages = $public }
}

function Get-SsqpPdbUri {
    param([string]$BaseUrl, [string]$FileName, [string]$Key)
    $base = Get-Trimmed $BaseUrl
    $name = Get-Trimmed $FileName
    $blobKey = Get-Trimmed $Key
    if (-not $base) { throw "No symbol server endpoint is available (the feed index advertises none); refusing to invent a symbol URL" }
    if (-not $name -or -not $blobKey) { throw "Symbol readback needs both a PDB file name and its debug key" }
    return $base.TrimEnd('/') + '/' + $name + '/' + $blobKey + '/' + $name
}

function Publish-WixManifest {
    param([string]$ManifestDir, [string]$FeedUrl, [string]$ApiKey = '', $Auth, [string]$SymbolServerUrl = '', [string]$WorkDir = '')
    $manifest = Assert-WixManifest -ManifestDir $ManifestDir
    $receipt = Join-Path $manifest.Dir 'publish-complete.json'
    if (Test-Path -LiteralPath $receipt) { Remove-Item -LiteralPath $receipt -Force }
    $endpoints = Get-FeedResources -FeedUrl $FeedUrl -Auth $Auth
    if (-not $WorkDir) { $WorkDir = [System.IO.Path]::GetTempPath() }
    $symbolServer = Get-Trimmed $SymbolServerUrl
    if (-not $symbolServer -and $endpoints.SymbolServerBase) { $symbolServer = $endpoints.SymbolServerBase }
    if ($symbolServer) { Assert-TrustedFeedEndpoint -Url $symbolServer -FeedUrl $FeedUrl -Purpose 'Symbol server (-SymbolServerUrl)' -AllowSeparateHost }
    $summary = @()
    foreach ($package in $manifest.PublicPackages) {
        $packageStatus = 'pushed'
        $readback = Receive-FeedPackage -Endpoints $endpoints -Id $package.Id -Version $package.Version -Auth $Auth -WorkDir $WorkDir
        if ($null -ne $readback) {
            if ($readback -ne $package.Sha256) {
                throw "Feed already carries $($package.Id) $($package.Version) with different content: hash mismatch (feed $readback, local $($package.Sha256)); refusing to publish over it"
            }
            $packageStatus = 'exists'
        } else {
            $code = Publish-FeedFile -Endpoints $endpoints -FilePath $package.FullPath -Kind 'Package' -ApiKey $ApiKey -Auth $Auth
            $verified = Receive-FeedPackage -Endpoints $endpoints -Id $package.Id -Version $package.Version -Auth $Auth -WorkDir $WorkDir
            if ($null -eq $verified) {
                if ($code -eq 409) { throw "Push of $($package.Id) $($package.Version) reported a conflict (HTTP 409) but the package cannot be read back from the feed; refusing to treat the conflict as success" }
                throw "Pushed $($package.Id) $($package.Version) but the package cannot be read back from the feed"
            }
            if ($verified -ne $package.Sha256) { throw "Readback hash mismatch for $($package.Id) $($package.Version): feed $verified, local $($package.Sha256)" }
            if ($code -eq 409) { $packageStatus = 'exists' }
        }
        $symbolStatus = 'none'
        if ($package.Symbols.Count -gt 0) {
            $symbolStatus = 'pushed'
            foreach ($symbol in $package.Symbols) {
                $code = Publish-FeedFile -Endpoints $endpoints -FilePath $symbol.FullPath -Kind 'Symbol' -ApiKey $ApiKey -Auth $Auth
                if ($code -eq 409) {
                    # A conflicting symbol package is only acceptable when the conflict can be verified: the
                    # debug-key PDB readback below must confirm the remote symbols; without a symbol server
                    # endpoint the remote bytes cannot be checked, so the conflict becomes a failure.
                    if (-not $symbolServer) { throw "Symbol push for $($symbol.File) reported a conflict (HTTP 409) and no symbol server endpoint is available to verify the remote package" }
                    if ($symbolStatus -eq 'pushed') { $symbolStatus = 'exists' }
                }
                if ($symbolServer) {
                    foreach ($pdb in @($symbol.Pdbs)) {
                        if (-not $pdb) { continue }
                        $pdbUri = Get-SsqpPdbUri -BaseUrl $symbolServer -FileName ([string]$pdb.name) -Key ([string]$pdb.key)
                        $status = (Send-FeedRequest -Method 'GET' -Uri $pdbUri -Auth $Auth -HeadersOnly).Status
                        if ($status -ne 200) { throw "Symbol readback $pdbUri returned HTTP $status" }
                    }
                }
            }
            if (-not $symbolServer) { Write-Host "note: symbol readback skipped for $($package.Id) (no symbol server endpoint available)" }
        }
        $summary += [pscustomobject]@{ id = $package.Id; version = $package.Version; package = $packageStatus; symbols = $symbolStatus }
        Write-Host ("published {0} {1}: package={2} symbols={3}" -f $package.Id, $package.Version, $packageStatus, $symbolStatus)
    }
    $complete = @{ feed = $FeedUrl; manifest_sha256 = Get-Sha256Hex (Join-Path $manifest.Dir 'release-manifest.json') }
    [IO.File]::WriteAllText($receipt, (ConvertTo-Json $complete), [Text.UTF8Encoding]::new($false))
    return $summary
}

function Get-GitHubReleases {
    param([string]$Repository, [string]$ApiBase)
    $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'wix-jenkins-pipeline' }
    $token = Get-Trimmed $env:GITHUB_TOKEN
    if ($token) { $headers['Authorization'] = 'token ' + $token }
    $releases = @()
    $page = 1
    while ($page -le 5) {
        $uri = $ApiBase.TrimEnd('/') + '/repos/' + $Repository + '/releases?per_page=100&page=' + $page
        $response = Send-FeedRequest -Method 'GET' -Uri $uri -ReadText -ExtraHeaders $headers
        if ($response.Status -ne 200) { throw "GitHub releases API $uri returned HTTP $($response.Status)" }
        $pageItems = @(ConvertFrom-Json $response.Text | ForEach-Object { $_ })
        if (-not $pageItems.Count) { break }
        $releases += $pageItems
        if ($pageItems.Count -lt 100) { break }
        $page++
    }
    return $releases
}

function Select-WixStableReleaseTags {
    param($Releases, [string]$MinVersion = '7.0.0')
    $minimum = [version]$MinVersion
    $tags = @()
    foreach ($release in @($Releases)) {
        if (-not $release) { continue }
        if ($release.draft -eq $true) { continue }
        if ($release.prerelease -eq $true) { continue }
        $name = [string]$release.tag_name
        if ($name -notmatch '^v(\d+\.\d+\.\d+)$') { continue }
        $version = [version]$Matches[1]
        if ($version -lt $minimum) { continue }
        $tags += [pscustomobject]@{ Tag = $name; Version = $version }
    }
    return @($tags | Sort-Object -Property Version)
}

function Find-StateManifest {
    param([string]$StateDir, [string]$Tag)
    if (-not (Test-Path -LiteralPath $StateDir)) { return $null }
    $files = @(Get-ChildItem -LiteralPath $StateDir -Recurse -Filter 'release-manifest.json' -File -ErrorAction SilentlyContinue)
    foreach ($file in $files) {
        try { $manifest = ConvertFrom-Json ([System.IO.File]::ReadAllText($file.FullName)) } catch { continue }
        if ([string]$manifest.tag -eq $Tag) { return $file.FullName }
    }
    return $null
}

function Invoke-WixDiscovery {
    param(
        [string]$StateDir,
        [string]$FeedUrl,
        [string]$GitHubRepository = 'wixtoolset/wix',
        [string]$GitHubApiBase = 'https://api.github.com',
        [string]$MinVersion = '7.0.0',
        $Auth,
        [string]$OutFile = ''
    )
    $releases = Get-GitHubReleases -Repository $GitHubRepository -ApiBase $GitHubApiBase
    $candidates = @(Select-WixStableReleaseTags -Releases $releases -MinVersion $MinVersion)
    $endpoints = $null
    $decisions = @()
    foreach ($candidate in $candidates) {
        $action = 'build'
        $reason = 'no local manifest'
        $manifestPath = Find-StateManifest -StateDir $StateDir -Tag $candidate.Tag
        if ($manifestPath) {
            $manifest = $null
            try { $manifest = ConvertFrom-Json ([System.IO.File]::ReadAllText($manifestPath)) } catch { $manifest = $null }
            if ($null -eq $manifest) {
                $reason = 'local manifest unreadable'
            } else {
                $dir = Split-Path -Parent $manifestPath
                $public = @($manifest.packages | Where-Object { $_ -and [bool]$_.public })
                $missingFiles = @($public | Where-Object { -not (Test-Path -LiteralPath (Join-Path $dir ([string]$_.file))) })
                if (-not $public.Count) { $reason = 'local manifest lists no public packages' }
                elseif ($missingFiles.Count -gt 0) { $reason = 'local package files missing' }
                else {
                    if ($null -eq $endpoints) { $endpoints = Get-FeedResources -FeedUrl $FeedUrl -Auth $Auth }
                    $missing = @()
                    foreach ($package in $public) {
                        if (-not (Test-FeedPackage -Endpoints $endpoints -Id ([string]$package.id) -Version ([string]$manifest.version) -Auth $Auth)) {
                            $missing += [string]$package.id
                        }
                    }
                    if ($missing.Count -gt 0) {
                        $action = 'publish'
                        $reason = 'missing on feed: ' + ($missing -join ', ')
                    } else {
                        $complete = $null
                        try { $complete = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $dir 'publish-complete.json'))) } catch { }
                        # shortcut: the feed has no standard snupkg lookup; use the successful publish receipt.
                        if (@($public | Where-Object { $_.symbols }).Count -gt 0 -and
                            ($null -eq $complete -or $complete.feed -ne $FeedUrl -or $complete.manifest_sha256 -ne (Get-Sha256Hex $manifestPath))) {
                            $action = 'publish'
                            $reason = 'symbol publication not confirmed'
                        } else {
                            $action = 'skip'
                            $reason = 'fully published'
                        }
                    }
                }
            }
        }
        $decisions += [pscustomobject]@{ tag = $candidate.Tag; version = [string]$candidate.Version; action = $action; reason = $reason }
        Write-Host ("discovery {0}: {1} ({2})" -f $candidate.Tag, $action, $reason)
    }
    if ($OutFile) {
        $detail = [pscustomobject]@{
            generatedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            feed         = $FeedUrl
            repository   = $GitHubRepository
            minVersion   = $MinVersion
            decisions    = $decisions
        }
        [System.IO.File]::WriteAllText($OutFile, (ConvertTo-Json -InputObject $detail -Depth 6), [System.Text.UTF8Encoding]::new($false))
    }
    return $decisions
}

# ---------------------------------------------------------------- entry point (skipped when dot-sourced)

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $auth = Get-FeedAuth -User $FeedUser -Password $FeedPassword
        if (($Discover -or ($ManifestDir -and -not $Validate)) -and -not (Get-Trimmed $FeedUrl)) {
            throw '-Discover and publish require -FeedUrl (the Jenkins job forwards FEED_URL)'
        }
        if ($Discover) {
            $decisions = @(Invoke-WixDiscovery -StateDir $StateDir -FeedUrl $FeedUrl -GitHubRepository $GitHubRepository -GitHubApiBase $GitHubApiBase -MinVersion $MinVersion -Auth $auth -OutFile $OutFile)
            Write-Output ('# discovery feed ' + $FeedUrl + ' min ' + $MinVersion)
            foreach ($decision in $decisions) { Write-Output ($decision.action + ' ' + $decision.tag) }
            exit 0
        }
        if ($Validate) {
            if (-not $ManifestDir) { throw '-Validate requires -ManifestDir' }
            $manifest = Assert-WixManifest -ManifestDir $ManifestDir
            Write-Host ("validated {0} {1}: {2} public package(s)" -f $manifest.Tag, $manifest.Version, $manifest.PublicPackages.Count)
            exit 0
        }
        if ($ManifestDir) {
            $key = Get-Trimmed $ApiKey
            if (-not $key) { $key = Get-Trimmed $env:NUGET_API_KEY }
            if (-not $key) { throw 'No push API key: pass -ApiKey or set NUGET_API_KEY (Jenkins credential nuget-push-api-key)' }
            $published = @(Publish-WixManifest -ManifestDir $ManifestDir -FeedUrl $FeedUrl -ApiKey $key -Auth $auth -SymbolServerUrl $SymbolServerUrl)
            Write-Host ("publish complete: {0} package(s) from {1}" -f $published.Count, $ManifestDir)
            exit 0
        }
        Write-Host 'Usage: Publish-Wix.ps1 -Discover -StateDir <dir> | -Validate -ManifestDir <dir> | -ManifestDir <dir> (publish)'
        exit 2
    } catch {
        [Console]::Error.WriteLine('Publish-Wix.ps1 failed: ' + $_.Exception.Message)
        exit 1
    }
}
