# Removes only this build's own containers and images; never a global docker prune on the shared agent.
# Invoked by the Jenkinsfile cleanup stage with IMAGES/CONTAINERS set by the Build stage.
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
