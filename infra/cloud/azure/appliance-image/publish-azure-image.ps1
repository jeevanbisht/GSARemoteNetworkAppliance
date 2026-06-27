<#
.SYNOPSIS
  Publish the RNFleet appliance fixed VHD to Azure as a Gen2 image (managed image
  and/or an Azure Compute Gallery image version).

.DESCRIPTION
  Uploads the fixed VHD (from build-azure-appliance.ps1) to a storage account as a
  PAGE blob using the Azure CLI (no azcopy dependency), then creates a Gen2
  managed image from it. Optionally also creates an Azure Compute Gallery (SIG)
  image definition + version so the image can be replicated across regions and
  used at scale.

  Idempotent-ish: re-running reuses the resource group / storage account / gallery
  if they already exist. Uploading the same blob name overwrites it.

  Prereqs: Azure CLI (`az`) signed in (`az login`), and the VHD produced by
  build-azure-appliance.ps1.

.EXAMPLE
  .\publish-azure-image.ps1 -VhdPath ..\..\..\..\dist\golden-azure\rnfleet-appliance-azure.vhd `
      -Subscription 3b328940-6e2a-4b01-bcff-d2c8cfa0da1d -ResourceGroup RN1 -Location eastus2

.EXAMPLE
  # also publish into a Compute Gallery
  .\publish-azure-image.ps1 -VhdPath ...\rnfleet-appliance-azure.vhd -Gallery rnfleetGallery -ImageVersion 1.0.0
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$VhdPath,
  [string]$Subscription   = '3b328940-6e2a-4b01-bcff-d2c8cfa0da1d',
  [string]$ResourceGroup  = 'RN1',
  [string]$Location       = 'eastus2',
  [string]$StorageAccount,                                  # default derived below
  [string]$Container      = 'images',
  [string]$ImageName      = 'rnfleet-appliance-min',
  [string]$BlobName       = 'rnfleet-appliance-azure.vhd',
  # Optional Azure Compute Gallery publishing:
  [string]$Gallery,
  [string]$GalleryImageDef = 'rnfleet-appliance',
  [string]$Publisher       = 'RNFleet',
  [string]$Offer           = 'rnfleet-appliance',
  [string]$Sku             = 'min-gen2',
  [string]$ImageVersion    = '1.0.0'
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $VhdPath)) { throw "VHD not found: $VhdPath" }
$VhdPath = (Resolve-Path $VhdPath).Path
if (-not $StorageAccount) {
  # storage account names: 3-24 lowercase alnum, globally unique.
  $StorageAccount = ('rnfleetimg' + ($Subscription -replace '[^0-9a-f]','').Substring(0,8))
}

$script:AzExe = (Get-Command az -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
function Az {
  & $script:AzExe @args
  if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed (exit $LASTEXITCODE)" }
}

Write-Host "=== Subscription / resource group ===" -ForegroundColor Cyan
Az account set --subscription $Subscription
Az group create -n $ResourceGroup -l $Location -o none

Write-Host "=== Storage account: $StorageAccount ===" -ForegroundColor Cyan
$exists = (& $script:AzExe storage account show -n $StorageAccount -g $ResourceGroup -o tsv --query name 2>$null)
if (-not $exists) {
  Az storage account create -n $StorageAccount -g $ResourceGroup -l $Location `
    --sku Standard_LRS --kind StorageV2 -o none
}
$key = (& $script:AzExe storage account keys list -n $StorageAccount -g $ResourceGroup --query "[0].value" -o tsv)
Az storage container create -n $Container --account-name $StorageAccount --account-key $key -o none

$vhdBytes = (Get-Item $VhdPath).Length
Write-Host "=== Uploading PAGE blob ($([int]($vhdBytes/1MB)) MB) -> $Container/$BlobName ===" -ForegroundColor Cyan
Write-Host "    (this can take a while on a slow uplink; az uploads sparse pages)"
Az storage blob upload --account-name $StorageAccount --account-key $key `
  -c $Container -n $BlobName -f $VhdPath --type page --overwrite -o none
$blobUri = "https://$StorageAccount.blob.core.windows.net/$Container/$BlobName"
Write-Host "    blob: $blobUri"

Write-Host "=== Creating Gen2 managed image: $ImageName ===" -ForegroundColor Cyan
$imgExists = (& $script:AzExe image show -n $ImageName -g $ResourceGroup -o tsv --query name 2>$null)
if ($imgExists) {
  Write-Host "    image exists; deleting to recreate from new blob" -ForegroundColor Yellow
  Az image delete -n $ImageName -g $ResourceGroup -o none
}
Az image create -n $ImageName -g $ResourceGroup -l $Location `
  --os-type Linux --hyper-v-generation V2 --source $blobUri -o none
$imageId = (& $script:AzExe image show -n $ImageName -g $ResourceGroup --query id -o tsv)
Write-Host "    managed image id: $imageId" -ForegroundColor Green

if ($Gallery) {
  Write-Host "=== Azure Compute Gallery: $Gallery ===" -ForegroundColor Cyan
  $galExists = (& $script:AzExe sig show -r $Gallery -g $ResourceGroup -o tsv --query name 2>$null)
  if (-not $galExists) { Az sig create -r $Gallery -g $ResourceGroup -l $Location -o none }

  $defExists = (& $script:AzExe sig image-definition show -r $Gallery -g $ResourceGroup `
                  --gallery-image-definition $GalleryImageDef -o tsv --query name 2>$null)
  if (-not $defExists) {
    Az sig image-definition create -r $Gallery -g $ResourceGroup `
      --gallery-image-definition $GalleryImageDef `
      --publisher $Publisher --offer $Offer --sku $Sku `
      --os-type Linux --os-state Generalized --hyper-v-generation V2 -o none
  }
  Write-Host "=== Gallery image version $ImageVersion ===" -ForegroundColor Cyan
  Az sig image-version create -r $Gallery -g $ResourceGroup `
    --gallery-image-definition $GalleryImageDef --gallery-image-version $ImageVersion `
    --managed-image $imageId --target-regions $Location -o none
  $verId = (& $script:AzExe sig image-version show -r $Gallery -g $ResourceGroup `
              --gallery-image-definition $GalleryImageDef --gallery-image-version $ImageVersion `
              --query id -o tsv)
  Write-Host "    gallery image version id: $verId" -ForegroundColor Green
}

Write-Host ""
Write-Host "DONE. Create a test VM with:" -ForegroundColor Green
Write-Host "  .\create-azure-vm.ps1 -ImageId `"$imageId`" -ResourceGroup $ResourceGroup -Location $Location" -ForegroundColor Yellow
