<#
.SYNOPSIS
  Build the RNFleet bare-metal appliance ISO on Windows using Docker.

.DESCRIPTION
  Remastering an Ubuntu ISO needs Linux tooling (xorriso, p7zip). This wrapper
  runs build-appliance-iso.sh inside an ubuntu:24.04 container with the repo,
  an output folder, and an ISO cache mounted in. The result is a hands-off
  RNFleet appliance installer ISO you can write to USB or attach to a VM.

.PARAMETER OutDir
  Host folder for the finished ISO (and ISO download cache). Default: <repo>\..\dist

.PARAMETER SrcIso
  Optional path to an Ubuntu 24.04 Server ISO already on disk (skips the ~3 GB
  download). Mounted into the container.

.EXAMPLE
  .\build-appliance-iso.ps1
.EXAMPLE
  .\build-appliance-iso.ps1 -OutDir D:\images -SrcIso D:\iso\ubuntu-24.04.2-live-server-amd64.iso
#>
param(
  [string]$OutDir,
  [string]$SrcIso,
  [string]$EnrollmentConf
)

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot
# repo root = infra\bare-metal\iso -> up 3
$repoRoot = (Resolve-Path (Join-Path $scriptDir "..\..\..")).Path
if (-not $OutDir) { $OutDir = (Join-Path (Split-Path $repoRoot -Parent) "dist") }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$cacheDir = Join-Path $OutDir "iso-cache"
New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

# --- Ensure Docker is up ---------------------------------------------------
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw "Docker is not installed. Install Docker Desktop: https://www.docker.com/products/docker-desktop/"
}
function Test-Docker { try { docker info 2>$null | Out-Null; return ($LASTEXITCODE -eq 0) } catch { return $false } }
if (-not (Test-Docker)) {
  $dd = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
  if (Test-Path $dd) { Write-Host "Starting Docker Desktop..."; Start-Process $dd }
  $deadline = (Get-Date).AddMinutes(3)
  while (-not (Test-Docker) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
  if (-not (Test-Docker)) { throw "Docker daemon not reachable. Start Docker Desktop and retry." }
}

# --- Build args ------------------------------------------------------------
$envArgs = @("-e", "OUT_ISO=/out/rnfleet-appliance-ubuntu-2404.iso", "-e", "ISO_CACHE=/isocache")
$mounts  = @(
  "-v", "${repoRoot}:/repo",
  "-v", "${OutDir}:/out",
  "-v", "${cacheDir}:/isocache"
)
if ($SrcIso) {
  if (-not (Test-Path $SrcIso)) { throw "SrcIso not found: $SrcIso" }
  $srcFull = (Resolve-Path $SrcIso).Path
  $mounts += @("-v", "${srcFull}:/srciso.iso:ro")
  $envArgs += @("-e", "SRC_ISO=/srciso.iso")
}
if ($EnrollmentConf) {
  if (-not (Test-Path $EnrollmentConf)) { throw "EnrollmentConf not found: $EnrollmentConf" }
  $ecFull = (Resolve-Path $EnrollmentConf).Path
  $mounts += @("-v", "${ecFull}:/enrollment.conf:ro")
  $envArgs += @("-e", "ENROLLMENT_CONF=/enrollment.conf")
}

Write-Host "Repo:    $repoRoot"
Write-Host "Output:  $OutDir"
Write-Host "Building RNFleet appliance ISO in container (this can take 10-20 min)..."

docker run --rm @mounts @envArgs ubuntu:24.04 `
  bash /repo/infra/bare-metal/iso/build-appliance-iso.sh

if ($LASTEXITCODE -ne 0) { throw "ISO build failed (exit $LASTEXITCODE)." }

$out = Join-Path $OutDir "rnfleet-appliance-ubuntu-2404.iso"
Write-Host ""
Write-Host "DONE -> $out"
if (Test-Path $out) { Get-Item $out | Select-Object Name, @{n='SizeGB';e={[math]::Round($_.Length/1GB,2)}} | Format-Table -AutoSize }
