[CmdletBinding()]
param(
  [ValidateSet("plan", "apply")]
  [string] $Action = "plan",

  [Parameter(Mandatory = $true)]
  [string] $HcpOrganization,

  [string] $Workspace = "valheim-server-infra"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$terraformRoot = Join-Path $repoRoot "terraform"
$terraformCommand = Get-Command terraform -ErrorAction SilentlyContinue

if ($null -eq $terraformCommand) {
  throw "Terraform was not found in PATH. Open a new PowerShell session and try again."
}

$terraform = $terraformCommand.Source
$tfvarsPath = Join-Path $terraformRoot "terraform.tfvars"

if (-not (Test-Path -LiteralPath $tfvarsPath)) {
  throw "Missing terraform/terraform.tfvars. Copy terraform.tfvars.example and fill in the Clouding values first."
}

function Read-SecretValue {
  param([Parameter(Mandatory = $true)][string] $Prompt)

  $secureValue = Read-Host -Prompt $Prompt -AsSecureString
  $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureValue)

  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
  }
  finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
  }
}

function Invoke-Terraform {
  param([Parameter(Mandatory = $true)][string[]] $Arguments)

  & $terraform @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Terraform failed with exit code $LASTEXITCODE."
  }
}

$cloudingTokenWasSetByScript = $false
$hcpTokenWasSetByScript = $false

try {
  if ([string]::IsNullOrWhiteSpace($env:CLOUDING_TOKEN)) {
    $env:CLOUDING_TOKEN = Read-SecretValue "Clouding.io API token"
    $cloudingTokenWasSetByScript = $true
  }

  if ([string]::IsNullOrWhiteSpace($env:TF_TOKEN_app_terraform_io)) {
    $env:TF_TOKEN_app_terraform_io = Read-SecretValue "HCP Terraform API token"
    $hcpTokenWasSetByScript = $true
  }

  Push-Location $repoRoot
  try {
    Invoke-Terraform @("-chdir=terraform", "fmt", "-check", "-recursive")
    Invoke-Terraform @(
      "-chdir=terraform",
      "init",
      "-input=false",
      "-lockfile=readonly",
      "-backend-config=organization=$HcpOrganization",
      "-backend-config=workspaces.name=$Workspace"
    )
    Invoke-Terraform @("-chdir=terraform", "validate", "-no-color")
    Invoke-Terraform @(
      "-chdir=terraform",
      "plan",
      "-input=false",
      "-var-file=terraform.tfvars",
      "-out=valheim.tfplan",
      "-no-color"
    )

    if ($Action -eq "apply") {
      Invoke-Terraform @(
        "-chdir=terraform",
        "apply",
        "-input=false",
        "-auto-approve",
        "valheim.tfplan"
      )
    }
  }
  finally {
    Pop-Location
  }
}
finally {
  if ($cloudingTokenWasSetByScript) {
    Remove-Item Env:CLOUDING_TOKEN -ErrorAction SilentlyContinue
  }

  if ($hcpTokenWasSetByScript) {
    Remove-Item Env:TF_TOKEN_app_terraform_io -ErrorAction SilentlyContinue
  }
}
