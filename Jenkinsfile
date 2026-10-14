// Daily stable WiX (>= 7.0.0) build and push to the internal BaGetter feed.
// Discovery decides per upstream release tag what to do: build (new/incomplete),
// publish (partial-publication retry, no rebuild) or skip (already complete).

def slug(String value) {
  return (value ?: '').toLowerCase().replaceAll('[^a-z0-9_.-]+', '-').replaceAll('^[-.]+', '').replaceAll('[-.]+$', '')
}
def isNotEmpty(String value) { return value != null && value.trim() != '' }
def render(String template, Map values) {
  def result = template
  values.each { key, value -> result = result.replace("__${key}__", String.valueOf(value).replace("'", "''")) }
  return result
}
def publishEnabled() {
  def raw = env.PUBLISH
  if (raw == null || raw == '') { raw = params.PUBLISH }
  if (raw == null) { return true }
  return !'false'.equalsIgnoreCase(String.valueOf(raw).trim())
}

pipeline {
  agent { label 'windows1' }
  options { skipDefaultCheckout(true); disableConcurrentBuilds(); timeout(time: 120, unit: 'MINUTES') }
  parameters {
    booleanParam(name: 'PUBLISH', defaultValue: true, description: 'Push the built packages and symbols to the internal NuGet feed')
  }
  triggers { cron('TZ=Europe/Istanbul\nH 3 * * *') }
  stages {
    stage('Checkout') {
      steps {
        script {
          // The disposable smoke test provides its checkout; production always refreshes SCM.
          if (!env.WIX_PIPELINE_SOURCE) {
            echo 'Refreshing the SCM checkout.'
            checkout scm
          } else {
            echo 'Using the existing workspace checkout.'
          }
        }
      }
    }
    stage('Discover') {
      steps {
        script {
          def output = powershell(returnStdout: true, script: render('''
$ErrorActionPreference = 'Stop'
$feed = $env:FEED_URL
if (-not $feed) { $feed = '__FEED__' }
& (Join-Path '__WS__' 'Publish-Wix.ps1') -Discover -FeedUrl $feed -StateDir (Join-Path '__WS__' 'artifacts') -OutFile (Join-Path '__WS__' 'discovery.json')
exit $LASTEXITCODE
''', [WS: pwd(), FEED: 'https://nuget.example.internal/v3/index.json']))
          echo output
          def toBuild = [], toPublish = []
          output.readLines().each { line ->
            if (line.startsWith('build ')) { toBuild.add(line.substring(6).trim()) }
            else if (line.startsWith('publish ')) { toPublish.add(line.substring(8).trim()) }
          }
          env.TAGS_TO_BUILD = toBuild.join(',')
          env.TAGS_TO_PUBLISH = toPublish.join(',')
          echo "discovery result: build=[${env.TAGS_TO_BUILD}] publish=[${env.TAGS_TO_PUBLISH}]"
        }
      }
    }
    stage('Build') {
      when { expression { isNotEmpty(env.TAGS_TO_BUILD) } }
      steps {
        script {
          def suffix = slug(env.BUILD_TAG ?: "build-${env.BUILD_NUMBER}")
          def built = []
          for (String tag in env.TAGS_TO_BUILD.split(',')) {
            def current = tag.trim()
            if (current) {
              built.add(current)
              def image = "wix-ctech:${suffix}-${slug(current)}"
              def container = "wix-${suffix}-${slug(current)}"
              env.IMAGES = ((env.IMAGES ?: '') + ',' + image).split(',').findAll { it }.join(',')
              env.CONTAINERS = ((env.CONTAINERS ?: '') + ',' + container).split(',').findAll { it }.join(',')
              echo "Building ${current} (image ${image})"
              powershell(script: render('''
$ErrorActionPreference = 'Stop'
$ws = '__WS__'
$tag = '__TAG__'
$image = '__IMAGE__'
$container = '__CONTAINER__'
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
$outDir = Join-Path $ws ('artifacts\\' + $tag)
if (Test-Path -LiteralPath $outDir) { Get-ChildItem -LiteralPath $outDir -Force | Remove-Item -Recurse -Force }
$logDir = Join-Path $ws 'logs'
New-Item -ItemType Directory -Force -Path $outDir, $logDir | Out-Null
Write-Host "Windows host build $build -> $base"
docker build --force-rm -m 4GB --build-arg "BASE_IMAGE=$base" -f (Join-Path $ws 'Dockerfile') -t $image $ws
if ($LASTEXITCODE -ne 0) { throw "docker build for $tag failed with $LASTEXITCODE" }
docker create --storage-opt size=120GB --name $container -v "${outDir}:C:\\output" $image -Tag $tag -Output 'C:\\output' | Out-Null
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
''', [WS: pwd(), TAG: current, IMAGE: image, CONTAINER: container]))
            }
          }
          def publish = []
          ((env.TAGS_TO_PUBLISH ?: '') + ',' + built.join(',')).split(',').each { item ->
            def value = item.trim()
            if (value && !publish.contains(value)) { publish.add(value) }
          }
          env.TAGS_TO_PUBLISH = publish.join(',')

        }
      }
    }
    stage('Publish') {
      when { expression { publishEnabled() && isNotEmpty(env.TAGS_TO_PUBLISH) } }
      steps {
        withCredentials([string(credentialsId: 'nuget-push-api-key', variable: 'NUGET_API_KEY')]) {
          script {
            for (String tag in env.TAGS_TO_PUBLISH.split(',')) {
              def current = tag.trim()
              if (current) {
                echo "Publishing ${current}"
                powershell(script: render('''
$ErrorActionPreference = 'Stop'
$feed = $env:FEED_URL
if (-not $feed) { $feed = '__FEED__' }
& (Join-Path '__WS__' 'Publish-Wix.ps1') -FeedUrl $feed -ManifestDir (Join-Path '__WS__' ('artifacts\\' + '__TAG__'))
if ($LASTEXITCODE -ne 0) { throw "publishing __TAG__ failed with $LASTEXITCODE" }
''', [WS: pwd(), TAG: current, FEED: 'https://nuget.example.internal/v3/index.json']))
              }
            }
          }
        }
      }
    }
  }
  post {
    always {
      script {
        // Archive before any cleanup; the workspace itself is never deleted (discovery state + harness).
        if (fileExists('discovery.json')) { archiveArtifacts artifacts: 'discovery.json', allowEmptyArchive: true, fingerprint: false }
        if (fileExists('logs')) { archiveArtifacts artifacts: 'logs/**', allowEmptyArchive: true, fingerprint: false }
        if (fileExists('artifacts')) { archiveArtifacts artifacts: 'artifacts/**', allowEmptyArchive: true, fingerprint: false }
      }
    }
    cleanup {
      script {
        // Remove only this build's own images; never a global docker prune on the shared agent.
        def images = (env.IMAGES ?: '').split(',').collect { it.trim() }.findAll { it }
        def containers = (env.CONTAINERS ?: '').split(',').collect { it.trim() }.findAll { it }
        if (containers || images) {
          powershell(script: '''
$ErrorActionPreference = 'Stop'
$existingContainers = @(docker ps -a --format '{{.Names}}')
if ($LASTEXITCODE -ne 0) { throw 'Container cleanup inventory failed' }
foreach ($name in ($env:CONTAINERS -split ',' | Where-Object { $_ })) {
  if ($name -in $existingContainers) {
    docker rm -f $name
    if ($LASTEXITCODE -ne 0) { throw "Container cleanup failed: $name" }
  }
}
$existingImages = @(docker images --format '{{.Repository}}:{{.Tag}}')
if ($LASTEXITCODE -ne 0) { throw 'Image cleanup inventory failed' }
foreach ($name in ($env:IMAGES -split ',' | Where-Object { $_ })) {
  if ($name -in $existingImages) {
    docker rmi $name
    if ($LASTEXITCODE -ne 0) { throw "Image cleanup failed: $name" }
  }
}
''')
        }
      }
    }
  }
}
