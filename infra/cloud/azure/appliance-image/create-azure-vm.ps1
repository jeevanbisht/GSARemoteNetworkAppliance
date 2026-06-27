<#
.SYNOPSIS
  Create a test Azure VM from the RNFleet appliance Gen2 image.

.DESCRIPTION
  Spins up a Gen2 VM from the managed image (or gallery image version) produced by
  publish-azure-image.ps1, with boot diagnostics enabled so the first-boot wizard
  is visible in the Azure Serial Console (ttyS0). Optionally injects an
  enrollment.conf via cloud-init custom-data for fully unattended enrollment.

  Because the image ships cloud-init + walinuxagent, Azure provisioning completes
  normally and creates the admin user you specify here (the appliance's own
  `rnfleet` console user still exists for serial-console use).

  Prereqs: Azure CLI signed in; an image created by publish-azure-image.ps1.

.EXAMPLE
  .\create-azure-vm.ps1 -ImageId "/subscriptions/.../images/rnfleet-appliance-min" `
      -ResourceGroup RN1 -Location eastus2 -VmName rnfleet-appl-01

.EXAMPLE
  # unattended enrollment via custom-data
  .\create-azure-vm.ps1 -ImageId <id> -EnrollmentConf .\enrollment.conf
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$ImageId,
  [string]$Subscription  = '3b328940-6e2a-4b01-bcff-d2c8cfa0da1d',
  [string]$ResourceGroup = 'RN1',
  [string]$Location      = 'eastus2',
  [string]$VmName        = 'rnfleet-appl-01',
  [string]$VmSize        = 'Standard_B2s',
  [string]$AdminUser     = 'azureuser',
  [string]$SshKeyPath    = "$HOME\.ssh\id_rsa.pub",
  [string]$EnrollmentConf,        # optional path to an enrollment.conf to pre-seed
  [switch]$NoPublicIp
)
$ErrorActionPreference = 'Stop'

$script:AzExe = (Get-Command az -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
function Az {
  & $script:AzExe @args
  if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed (exit $LASTEXITCODE)" }
}

Az account set --subscription $Subscription
Az group create -n $ResourceGroup -l $Location -o none

# Build cloud-init custom-data that drops /etc/rnfleet/enrollment.conf (unattended).
$customDataArg = @()
$tmpCloudInit = $null
if ($EnrollmentConf) {
  if (-not (Test-Path $EnrollmentConf)) { throw "EnrollmentConf not found: $EnrollmentConf" }
  $confText = (Get-Content -Raw $EnrollmentConf)
  $indented = ($confText -split "`r?`n" | ForEach-Object { '      ' + $_ }) -join "`n"
  $tmpCloudInit = Join-Path $env:TEMP 'rnfleet-cloud-init.yaml'
  @"
#cloud-config
write_files:
  - path: /etc/rnfleet/enrollment.conf
    permissions: '0600'
    owner: root:root
    content: |
$indented
"@ | Set-Content -Path $tmpCloudInit -Encoding ascii
  $customDataArg = @('--custom-data', $tmpCloudInit)
  Write-Host "Pre-seeding enrollment.conf via cloud-init custom-data" -ForegroundColor Cyan
}

$pubIpArg = if ($NoPublicIp) { @('--public-ip-address','') } else { @() }

Write-Host "=== Creating Gen2 VM $VmName from image ===" -ForegroundColor Cyan
$sshArgs = @()
if (Test-Path $SshKeyPath) {
  $sshArgs = @('--ssh-key-values', $SshKeyPath)
} else {
  Write-Host "No SSH public key at $SshKeyPath; az will generate one." -ForegroundColor Yellow
  $sshArgs = @('--generate-ssh-keys')
}

Az vm create -n $VmName -g $ResourceGroup -l $Location `
  --image $ImageId --size $VmSize `
  --admin-username $AdminUser `
  --nsg-rule SSH `
  --os-disk-name "$VmName-osdisk" `
  @sshArgs @customDataArg @pubIpArg -o table

Write-Host "=== Enabling boot diagnostics (Serial Console / ttyS0) ===" -ForegroundColor Cyan
Az vm boot-diagnostics enable -n $VmName -g $ResourceGroup -o none

if ($tmpCloudInit) { Remove-Item $tmpCloudInit -Force -ErrorAction SilentlyContinue }

Write-Host ""
Write-Host "DONE." -ForegroundColor Green
Write-Host "  Watch first-boot wizard:  az serial-console connect -n $VmName -g $ResourceGroup" -ForegroundColor Yellow
Write-Host "  Boot log:                 az vm boot-diagnostics get-boot-log -n $VmName -g $ResourceGroup" -ForegroundColor Yellow
if (-not $EnrollmentConf) {
  Write-Host "  (No pre-seed: enroll interactively on the serial console with 'sudo rnfleet-setup',"
  Write-Host "   or re-run with -EnrollmentConf <file> for unattended enrollment.)"
}
