param([string]$Source = (Split-Path $PSScriptRoot -Parent), [string]$Evidence = (Join-Path $env:RUNNER_TEMP 'jenkins-evidence'))
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Source=(Resolve-Path $Source).Path
New-Item -ItemType Directory -Force $Evidence | Out-Null
$jenkinsHome=Join-Path $env:RUNNER_TEMP 'wix-jenkins-home'
$workspace=Join-Path $jenkinsHome 'workspace/wix-docker'
$init=Join-Path $jenkinsHome 'init.groovy.d'
New-Item -ItemType Directory -Force $workspace,$init | Out-Null
foreach ($file in @('Jenkinsfile','Dockerfile','.dockerignore','Install-BuildEnv.ps1','VswhereBootstrap.cs','Build-Wix.ps1','Publish-Wix.ps1')) {
    Copy-Item (Join-Path $Source $file) -Destination $workspace
}
$war=Join-Path $jenkinsHome 'jenkins.war'
$version='2.580.1'
$url="https://get.jenkins.io/war-stable/$version/jenkins.war"
Invoke-WebRequest $url -OutFile $war
Invoke-WebRequest "$url.sha256" -OutFile "$war.sha256"
$expected=(Get-Content "$war.sha256" -Raw).Trim().Split(' ')[0]
if ((Get-FileHash $war -Algorithm SHA256).Hash -ne $expected) { throw 'Jenkins WAR checksum mismatch' }
$manager=Join-Path $jenkinsHome 'jenkins-plugin-manager.jar'
Invoke-WebRequest 'https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/2.15.0/jenkins-plugin-manager-2.15.0.jar' -OutFile $manager
Invoke-WebRequest 'https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/2.15.0/jenkins-plugin-manager-2.15.0.jar.sha256' -OutFile "$manager.sha256"
$managerSha=(Get-Content "$manager.sha256" -Raw).Trim().Split(' ')[0]
if ((Get-FileHash $manager -Algorithm SHA256).Hash -ne $managerSha) { throw 'Plugin manager checksum mismatch' }
& java -jar $manager --war $war --plugin-download-directory (Join-Path $jenkinsHome 'plugins') --plugins pipeline-model-definition workflow-durable-task-step workflow-basic-steps workflow-job workflow-cps git credentials-binding
if ($LASTEXITCODE -ne 0) { throw 'Jenkins pipeline plugin installation failed' }
$groovy=@'
import jenkins.model.Jenkins
import hudson.model.*
import hudson.security.AuthorizationStrategy
import hudson.security.SecurityRealm
import org.jenkinsci.plugins.workflow.job.WorkflowJob
import org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition

def j=Jenkins.get()
j.setNumExecutors(1)
j.setLabelString('windows1')
j.setSecurityRealm(SecurityRealm.NO_AUTHENTICATION)
j.setAuthorizationStrategy(AuthorizationStrategy.UNSECURED)
j.save()
def job=j.createProject(WorkflowJob,'wix-docker')
job.setDefinition(new CpsFlowDefinition(new File(System.getenv('WIX_SMOKE_JENKINSFILE')).getText('UTF-8'),true))
job.addProperty(new ParametersDefinitionProperty(new BooleanParameterDefinition('PUBLISH',false,'Smoke test never publishes')))
job.save()
job.scheduleBuild2(0,new ParametersAction(new BooleanParameterValue('PUBLISH',false)))
'@
[IO.File]::WriteAllText((Join-Path $init 'create-wix-job.groovy'),$groovy)
$env:JENKINS_HOME=$jenkinsHome
$env:WIX_SMOKE_JENKINSFILE=Join-Path $workspace 'Jenkinsfile'
$env:WIX_PIPELINE_SOURCE=$workspace
$stdout=Join-Path $Evidence 'jenkins-server.log'; $stderr=Join-Path $Evidence 'jenkins-server-error.log'
$server=Start-Process 'java' -ArgumentList @('-Djenkins.install.runSetupWizard=false','-jar',"`"$war`"",'--httpPort=8081','--httpListenAddress=127.0.0.1') -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
$base='http://127.0.0.1:8081'
$build=$null
$consoleOffset=0
$startupDeadline=[DateTime]::UtcNow.AddMinutes(5)
try {
    $deadline=[DateTime]::UtcNow.AddHours(4)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($server.HasExited) { throw "Jenkins exited with code $($server.ExitCode)" }
        try { $build=Invoke-RestMethod "$base/job/wix-docker/1/api/json" -TimeoutSec 15 } catch { $build=$null }
        try {
            $console=[string](Invoke-WebRequest "$base/job/wix-docker/1/consoleText" -TimeoutSec 15).Content
            if ($console.Length -gt $consoleOffset) { Write-Host $console.Substring($consoleOffset); $consoleOffset=$console.Length }
        } catch { }
        if ($null -eq $build -and [DateTime]::UtcNow -gt $startupDeadline) { throw 'Jenkins job did not start; see jenkins-server-error.log' }
        if ($null -ne $build -and -not $build.building -and $build.result) { break }
        Start-Sleep -Seconds 15
    }
    if ($null -eq $build -or $build.building) { throw 'Jenkins build did not finish within the smoke-test deadline' }
    $build | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $Evidence 'jenkins-build.json') -Encoding utf8
    Invoke-WebRequest "$base/job/wix-docker/1/consoleText" -OutFile (Join-Path $Evidence 'jenkins-build.log')
    $archive=Join-Path $Evidence 'artifacts'; New-Item -ItemType Directory -Force $archive | Out-Null
    foreach ($artifact in $build.artifacts) {
        $path=Join-Path $archive $artifact.relativePath
        if (-not ([IO.Path]::GetFullPath($path).StartsWith([IO.Path]::GetFullPath($archive)+[IO.Path]::DirectorySeparatorChar))) { throw 'Unsafe Jenkins artifact path' }
        New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
        $encoded=($artifact.relativePath.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
        Invoke-WebRequest "$base/job/wix-docker/1/artifact/$encoded" -OutFile $path
    }
    $packages=@(Get-ChildItem $archive -Recurse -Filter '*.nupkg' -File)
    $symbols=@(Get-ChildItem $archive -Recurse -Filter '*.snupkg' -File)
    $additional=@(Get-ChildItem $archive -Recurse -Filter 'WixAdditionalTools.exe' -File)
    Write-Host "REAL_JENKINS_RESULT: $($build.result); archived NuGet=$($packages.Count), symbols=$($symbols.Count), Additional Tools=$($additional.Count)"
    if ($build.result -ne 'SUCCESS') { throw "Jenkins build failed: $($build.result); see archived console and runtime logs" }
    if (-not $packages.Count -or -not $symbols.Count -or -not $additional.Count) { throw 'Jenkins succeeded without the required artifact payload' }
    Write-Host 'JENKINS_DOCKER_WIX_ARTIFACT_SMOKE: PASS'
} finally {
    if ($null -eq $build) {
        try { Invoke-WebRequest "$base/job/wix-docker/1/consoleText" -OutFile (Join-Path $Evidence 'jenkins-build.log') -TimeoutSec 15 } catch { Write-Warning 'Jenkins console unavailable' }
    }
    if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force }
}
