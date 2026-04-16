[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$HookName = ''
)

$ErrorActionPreference = 'Stop'

$InstallRoot = Join-Path $env:LOCALAPPDATA 'pocket-lab'
$ConfigFile = Join-Path $InstallRoot 'config.json'
$EnabledFile = Join-Path $InstallRoot 'enabled'
$LogFile = Join-Path $InstallRoot 'notify.log'

function Write-Log {
  param(
    [string]$Level,
    [string]$Message
  )

  $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
  $logDir = Split-Path -Path $LogFile -Parent
  if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
  }
  Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Read-Config {
  if (-not (Test-Path $ConfigFile)) {
    return $null
  }

  return Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
}

function Read-HookInput {
  if (-not [Console]::IsInputRedirected) {
    return $null
  }

  $raw = [Console]::In.ReadToEnd()
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return $null
  }

  try {
    return $raw | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Get-ProjectName {
  param($InputObject)

  if ($null -ne $InputObject.cwd -and $InputObject.cwd) {
    return Split-Path -Path ([string]$InputObject.cwd) -Leaf
  }

  return ''
}

function Get-BuildTitle {
  param(
    $InputObject,
    [string]$ProjectName
  )

  if ($null -ne $InputObject.title -and $InputObject.title) {
    return [string]$InputObject.title
  }

  if ($ProjectName) {
    return "Pocket Lab ($ProjectName)"
  }

  return 'Pocket Lab'
}

function Get-BuildBody {
  param(
    [string]$Hook,
    $InputObject,
    [string]$ProjectName
  )

  $message = ''
  if ($null -ne $InputObject.message -and $InputObject.message) {
    $message = [string]$InputObject.message
  }

  switch ($Hook) {
    'Stop' {
      if ($message) { return "Done: $message" }
      if ($ProjectName) { return "Task complete in $ProjectName" } else { return 'Task complete' }
    }
    'Notification' {
      if ($message) { return "Input needed: $message" }
      if ($ProjectName) { return "Claude needs your input in $ProjectName" } else { return 'Claude needs your input' }
    }
    'SubagentStop' {
      if ($ProjectName) { return "Sub-task complete in $ProjectName" } else { return 'Sub-task complete' }
    }
    Default {
      if ($message) { return $message }
      if ($ProjectName) { return "Claude needs attention in $ProjectName" } else { return 'Claude needs attention' }
    }
  }
}

function Should-RateLimit {
  param(
    [string]$Provider,
    [string]$ProjectName,
    [int]$Seconds
  )

  $safeProject = ($ProjectName -replace '[^a-zA-Z0-9]', '_')
  $rateFile = Join-Path ([IO.Path]::GetTempPath()) "pocket-lab-rate-$Provider-$safeProject.txt"
  if (Test-Path $rateFile) {
    try {
      $last = [int64](Get-Content -Path $rateFile -Raw)
      $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
      if (($now - $last) -lt $Seconds) {
        return $true
      }
    } catch {
    }
  }

  [System.IO.File]::WriteAllText($rateFile, [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString())
  return $false
}

$inputObject = Read-HookInput
$projectName = Get-ProjectName -InputObject $inputObject

function Test-TailscalePresence {
  param($Config)

  if (-not $Config.TailscalePresence -or [string]::IsNullOrWhiteSpace([string]$Config.TailscaleDesktopName)) {
    return $false
  }

  if (-not (Get-Command tailscale -ErrorAction SilentlyContinue)) {
    Write-Log 'WARN' 'Tailscale presence enabled but tailscale CLI was not found.'
    return $false
  }

  try {
    $status = & tailscale status 2>$null
    if (-not $status) {
      return $false
    }

    $lines = $status | Select-String -Pattern [regex]::Escape([string]$Config.TailscaleDesktopName)
    if ($lines) {
      foreach ($line in $lines) {
        if ($line.Line -match '\b(active|-)$') {
          return $true
        }
      }
      return $false
    }
  } catch {
  }

  return $false
}

$config = Read-Config
if ($null -eq $config) {
  Write-Log 'ERROR' "Config file not found: $ConfigFile"
  exit 0
}

if (-not (Test-Path $EnabledFile)) {
  Write-Log 'INFO' 'Notifications disabled. Skipping.'
  exit 0
}

if ($config.NotificationProvider -ne 'telegram') {
  Write-Log 'ERROR' "Unsupported provider '$($config.NotificationProvider)'. This Windows installer supports Telegram only."
  exit 0
}

if ([string]::IsNullOrWhiteSpace([string]$config.TelegramBotToken) -or [string]::IsNullOrWhiteSpace([string]$config.TelegramChatId)) {
  Write-Log 'ERROR' 'Telegram bot token or chat ID is missing from config.'
  exit 0
}

if (Should-RateLimit -Provider 'telegram' -ProjectName $projectName -Seconds ([int]$config.RateLimitSecs)) {
  Write-Log 'INFO' "Rate limited - skipping (within $($config.RateLimitSecs)s window)"
  exit 0
}

if (Test-TailscalePresence -Config $config) {
  Write-Log 'INFO' "Desktop '$($config.TailscaleDesktopName)' is online. Skipping notification."
  exit 0
}

$title = Get-BuildTitle -InputObject $inputObject -ProjectName $projectName
$body = Get-BuildBody -Hook $HookName -InputObject $inputObject -ProjectName $projectName

$disableNotification = [bool]$config.TelegramSilent
if ($HookName -eq 'Stop' -and [bool]$config.TelegramSilentOnStop) {
  $disableNotification = $true
}

$payload = @{
  chat_id = [string]$config.TelegramChatId
  text = "<b>$([System.Net.WebUtility]::HtmlEncode($title))</b>`n$([System.Net.WebUtility]::HtmlEncode($body))"
  parse_mode = 'HTML'
  disable_notification = $disableNotification
} | ConvertTo-Json -Depth 5

try {
  $uri = "https://api.telegram.org/bot$([string]$config.TelegramBotToken)/sendMessage"
  $response = Invoke-RestMethod -Method Post -Uri $uri -ContentType 'application/json' -Body $payload -TimeoutSec 20
  if ($response.ok) {
    Write-Log 'INFO' "[telegram] Sent: [$title] $body"
  } else {
    Write-Log 'ERROR' "[telegram] API error: $($response | ConvertTo-Json -Depth 5)"
  }
} catch {
  Write-Log 'ERROR' "[telegram] Failed: $($_.Exception.Message)"
}
