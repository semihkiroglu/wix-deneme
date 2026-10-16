// Daily stable WiX (>= 7.0.0) build and push to the internal BaGetter feed.
// Discovery decides per upstream release tag what to do: build (new/incomplete),
// publish (partial-publication retry, no rebuild) or skip (already complete).
// PowerShell lives in repository scripts; this file only orchestrates.

def slug(String value) {
  return (value ?: '').toLowerCase().replaceAll('[^a-z0-9_.-]+', '-').replaceAll('^[-.]+', '').replaceAll('[-.]+$', '')
}
def isNotEmpty(String value) { return value != null && value.trim() != '' }
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
          // The disposable smoke harness pre-stages the workspace, where 'scm' does not exist; production always refreshes SCM.
          if (!env.WIX_PIPELINE_SOURCE) {
            echo 'Refreshing the SCM checkout.'
            checkout scm
          } else {
            echo 'Using the existing workspace checkout.'
          }
          // Each run archives only its own logs; clear the persistent logs directory up front.
          powershell(script: "Remove-Item -LiteralPath (Join-Path (Get-Location) 'logs') -Recurse -Force -ErrorAction SilentlyContinue")
        }
      }
    }
    stage('Discover') {
      steps {
        script {
          if (!isNotEmpty(env.FEED_URL)) { error 'FEED_URL is required: the internal feed endpoint must be configured' }
          def output = powershell(returnStdout: true, script: '$ErrorActionPreference = "Stop"; & (Join-Path $env:WORKSPACE "Publish-Wix.ps1") -Discover -FeedUrl $env:FEED_URL -StateDir (Join-Path $env:WORKSPACE "artifacts") -OutFile (Join-Path $env:WORKSPACE "discovery.json"); exit $LASTEXITCODE')
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
              withEnv(["WIX_TAG=${current}", "WIX_IMAGE=${image}", "WIX_CONTAINER=${container}"]) {
                powershell(script: '& (Join-Path $env:WORKSPACE "Run-TagBuild.ps1")')
              }
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
                withEnv(["WIX_TAG=${current}"]) {
                  powershell(script: '$ErrorActionPreference = "Stop"; & (Join-Path $env:WORKSPACE "Publish-Wix.ps1") -FeedUrl $env:FEED_URL -ManifestDir (Join-Path (Join-Path $env:WORKSPACE "artifacts") $env:WIX_TAG); if ($LASTEXITCODE -ne 0) { throw "publishing $env:WIX_TAG failed with $LASTEXITCODE" }')
                }
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
        // Remove only this build's own containers and images; never a global docker prune on the shared agent.
        if (isNotEmpty(env.IMAGES) || isNotEmpty(env.CONTAINERS)) {
          powershell(script: '& (Join-Path $env:WORKSPACE "Clear-TagRun.ps1")')
        }
      }
    }
  }
}
