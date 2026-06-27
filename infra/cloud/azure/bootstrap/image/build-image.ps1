param(
  [string]$VarFile = ".\\variables.pkrvars.hcl"
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command packer -ErrorAction SilentlyContinue)) {
  throw "Packer is not installed. Install from https://developer.hashicorp.com/packer/downloads"
}

Set-Location $PSScriptRoot

if (-not (Test-Path $VarFile)) {
  throw "Var file not found: $VarFile. Copy variables.pkrvars.hcl.example to variables.pkrvars.hcl and edit values."
}

packer init .\ubuntu-appliance.pkr.hcl
packer build -var-file $VarFile .\ubuntu-appliance.pkr.hcl
