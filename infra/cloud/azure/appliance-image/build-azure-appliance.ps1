<#
.SYNOPSIS
  Build the Azure-flavored RNFleet appliance image (qcow2) and convert it to a
  fixed VHD ready to publish to Azure.

.DESCRIPTION
  Reuses the validated bare-metal builder (infra/bare-metal/golden-image/
  build-min-appliance.sh) and layers Azure provisioning on top via its
  provider-neutral hooks:
    EXTRA_INCLUDE   = cloud-init,walinuxagent   (added to the rootfs)
    EXTRA_CONFIGURE = azure-configure.sh        (enables agent + cloud-init)

  The result boots identically to the bare-metal/Hyper-V image; the Azure layer
  is inert off-Azure. Output goes to a SEPARATE dist dir so the validated
  Hyper-V artifacts are never clobbered.

  Requires Docker Desktop (Linux containers). No Azure credentials needed here —
  publishing is a separate step (publish-azure-image.ps1).

.EXAMPLE
  .\build-azure-appliance.ps1
  .\build-azure-appliance.ps1 -SkipBuild   # only re-convert an existing qcow2 to VHD
#>
[CmdletBinding()]
param(
  [string]$Repo    = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path,
  [string]$OutDir  = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path 'dist\golden-azure'),
  [string]$Qcow2   = 'rnfleet-appliance-min.qcow2',
  [string]$Vhd     = 'rnfleet-appliance-azure.vhd',
  [string]$Image   = 'debian:bookworm-slim',
  [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'

function Require-Docker {
  try { docker version --format '{{.Server.Version}}' | Out-Null }
  catch { throw "Docker is not available. Start Docker Desktop (Linux containers) and retry." }
}

Require-Docker
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$repoUnix = $Repo -replace '\\','/'
$outUnix  = $OutDir -replace '\\','/'

if (-not $SkipBuild) {
  Write-Host "=== Building Azure-flavored appliance qcow2 (this is the long step ~5-8 min) ===" -ForegroundColor Cyan
  docker run --rm --privileged `
    -e EXTRA_INCLUDE='cloud-init,waagent' `
    -e EXTRA_CONFIGURE='/repo/infra/cloud/azure/appliance-image/azure-configure.sh' `
    -v "${repoUnix}:/repo:ro" -v "${outUnix}:/out" `
    $Image bash /repo/infra/bare-metal/golden-image/build-min-appliance.sh
  if ($LASTEXITCODE -ne 0) { throw "appliance build failed (exit $LASTEXITCODE)" }
}

$qcow2Path = Join-Path $OutDir $Qcow2
if (-not (Test-Path $qcow2Path)) { throw "qcow2 not found: $qcow2Path (run without -SkipBuild first)" }

Write-Host "=== Converting qcow2 -> fixed Azure VHD ===" -ForegroundColor Cyan
docker run --rm -v "${repoUnix}:/repo:ro" -v "${outUnix}:/out" $Image `
  bash /repo/infra/cloud/azure/appliance-image/convert-to-azure-vhd.sh "/out/$Qcow2" "/out/$Vhd"
if ($LASTEXITCODE -ne 0) { throw "VHD conversion failed (exit $LASTEXITCODE)" }

$vhdPath = Join-Path $OutDir $Vhd
Write-Host ""
Write-Host "DONE. Azure VHD ready:" -ForegroundColor Green
Get-Item $vhdPath | Select-Object FullName, @{n='SizeMB';e={[int]($_.Length/1MB)}} | Format-List
Write-Host "Next: publish with .\publish-azure-image.ps1 -VhdPath `"$vhdPath`"" -ForegroundColor Yellow
