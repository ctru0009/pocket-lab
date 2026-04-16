[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Action = 'status'
)

$ErrorActionPreference = 'Stop'

$InstallRoot = Join-Path $env:LOCALAPPDATA 'pocket-lab'
$ConfigFile = Join-Path $InstallRoot 'config.json'
$EnabledFile = Join-Path $InstallRoot 'enabled'

function Ensure-InstallRoot {
  if (-not (Test-Path $InstallRoot)) {
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
  }
}

function Read-Config {
  if (Test-Path $ConfigFile) {
    return Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
  }
  return $null
}

$config = Read-Config
if ($null -eq $config) {
  Write-Host 'Pocket Lab config not found. Run install.ps1 first.'
  exit 1
}

function Test-Enabled {
  return Test-Path $EnabledFile
}

switch ($Action.ToLowerInvariant()) {
  'on' {
    Ensure-InstallRoot
    New-Item -ItemType File -Path $EnabledFile -Force | Out-Null
    Write-Host 'Pocket Lab notifications ON'
  }
  'enable' {
    Ensure-InstallRoot
    New-Item -ItemType File -Path $EnabledFile -Force | Out-Null
    Write-Host 'Pocket Lab notifications ON'
  }
  'off' {
    Remove-Item -Path $EnabledFile -Force -ErrorAction SilentlyContinue
    Write-Host 'Pocket Lab notifications OFF'
  }
  'disable' {
    Remove-Item -Path $EnabledFile -Force -ErrorAction SilentlyContinue
    Write-Host 'Pocket Lab notifications OFF'
  }
  'flip' {
    if (Test-Enabled) {
      Remove-Item -Path $EnabledFile -Force -ErrorAction SilentlyContinue
      Write-Host 'Pocket Lab notifications OFF'
    } else {
      Ensure-InstallRoot
      New-Item -ItemType File -Path $EnabledFile -Force | Out-Null
      Write-Host 'Pocket Lab notifications ON'
    }
  }
  'toggle' {
    if (Test-Enabled) {
      Remove-Item -Path $EnabledFile -Force -ErrorAction SilentlyContinue
      Write-Host 'Pocket Lab notifications OFF'
    } else {
      Ensure-InstallRoot
      New-Item -ItemType File -Path $EnabledFile -Force | Out-Null
      Write-Host 'Pocket Lab notifications ON'
    }
  }
  'status' {
    if (Test-Enabled) {
      Write-Host 'Pocket Lab notifications are ON'
    } else {
      Write-Host 'Pocket Lab notifications are OFF'
    }
  }
  default {
    Write-Host 'Usage: pocket-lab {on|off|flip|status}'
    exit 1
  }
}
