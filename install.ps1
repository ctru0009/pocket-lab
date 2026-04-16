[CmdletBinding()]
param(
  [switch]$Uninstall,
  [switch]$Yes,
  [switch]$Help
)

$ErrorActionPreference = 'Stop'

$RepoUrl = 'https://raw.githubusercontent.com/ctru0009/pocket-lab/main'
$InstallRoot = Join-Path $env:LOCALAPPDATA 'pocket-lab'
$HookDir = Join-Path $InstallRoot 'hooks'
$BinDir = Join-Path $InstallRoot 'bin'
$ConfigFile = Join-Path $InstallRoot 'config.json'
$EnabledFile = Join-Path $InstallRoot 'enabled'
$LogFile = Join-Path $InstallRoot 'notify.log'
$NotifyHook = Join-Path $HookDir 'notify.ps1'
$ToggleScript = Join-Path $HookDir 'toggle.ps1'
$CommandShim = Join-Path $BinDir 'pocket-lab.cmd'
$CommandEntry = Join-Path $BinDir 'pocket-lab.ps1'
$ClaudeSettings = Join-Path $HOME '.claude\settings.json'
$PSScriptDir = $PSScriptRoot

function Write-Info { param([string]$Message) Write-Host "[INFO]  $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "[OK]    $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[WARN]  $Message" -ForegroundColor Yellow }
function Write-ErrorLine { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }
function Throw-Fatal { param([string]$Message) Write-ErrorLine $Message; throw $Message }

function Show-Help {
  Write-Host 'Usage: pwsh .\install.ps1 [--uninstall] [--yes] [--help]'
  Write-Host ''
  Write-Host '  --uninstall   Remove pocket-lab from this machine'
  Write-Host '  --yes         Skip confirmation prompts'
  Write-Host '  --help        Show this help'
}

if ($Help) {
  Show-Help
  exit 0
}

if (-not $IsWindows) {
  Throw-Fatal 'This installer is for Windows only. Use install.sh on Linux or macOS.'
}

function Prompt-Value {
  param(
    [string]$Message,
    [string]$Default = '',
    [switch]$Required
  )

  if ($Yes -and $Default) {
    return $Default
  }

  while ($true) {
    $suffix = if ($Default) { " [$Default]" } else { '' }
    $value = Read-Host "$Message$suffix"
    if (-not $value -and $Default) { return $Default }
    if ($value) { return $value }
    if ($Required) { Write-Warn 'This value is required.' }
  }
}

function Prompt-ChoiceYesNo {
  param(
    [string]$Message,
    [bool]$Default = $false
  )

  if ($Yes) { return $Default }

  $prompt = if ($Default) { '[Y/n]' } else { '[y/N]' }
  $answer = Read-Host "$Message $prompt"
  if (-not $answer) { return $Default }
  return ($answer -match '^(y|yes)$')
}

function Ensure-Directory {
  param([string]$Path)
  if (-not (Test-Path $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Get-LocalOrRemoteFile {
  param(
    [string]$RelativePath,
    [string]$Destination
  )

  $LocalPath = Join-Path $PSScriptDir $RelativePath
  Ensure-Directory (Split-Path $Destination -Parent)

  if (Test-Path $LocalPath) {
    Copy-Item -Path $LocalPath -Destination $Destination -Force
    Write-Info "Copied $RelativePath from local repo."
    return
  }

  $Uri = "$RepoUrl/$RelativePath"
  Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing
  Write-Info "Downloaded $RelativePath."
}

function Save-Config {
  param([hashtable]$Data)
  $Data | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigFile -Encoding UTF8
  [System.IO.File]::WriteAllText($EnabledFile, '', [System.Text.UTF8Encoding]::new($false))
  Set-Content -Path $LogFile -Value '' -Encoding UTF8 -ErrorAction SilentlyContinue
  Write-Success "Config written to $ConfigFile"
}

function Load-Config {
  if (-not (Test-Path $ConfigFile)) {
    return $null
  }

  return Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
}

function Get-ChatIdFromUpdates {
  param([string]$BotToken)

  try {
    $uri = "https://api.telegram.org/bot$BotToken/getUpdates"
    $response = Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec 15
    if ($response.result -and $response.result.Count -gt 0) {
      $last = $response.result[-1]
      if ($last.message -and $last.message.chat -and $last.message.chat.id) {
        return [string]$last.message.chat.id
      }
    }
  } catch {
    return $null
  }

  return $null
}

function Get-TelegramErrorDetails {
  param([System.Management.Automation.ErrorRecord]$ErrorRecord)

  $response = $ErrorRecord.Exception.Response
  if ($null -eq $response) {
    return $ErrorRecord.Exception.Message
  }

  try {
    $stream = $response.GetResponseStream()
    if ($null -eq $stream) {
      return $ErrorRecord.Exception.Message
    }

    $reader = New-Object System.IO.StreamReader($stream)
    $raw = $reader.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) {
      return $ErrorRecord.Exception.Message
    }

    $json = $raw | ConvertFrom-Json
    if ($json.description) {
      return [string]$json.description
    }
  } catch {
  }

  return $ErrorRecord.Exception.Message
}

function Install-BinShim {
  Ensure-Directory $BinDir
  @"
@echo off
setlocal
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0pocket-lab.ps1" %*
exit /b %errorlevel%
"@ | Set-Content -Path $CommandShim -Encoding ASCII

  @"
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]`$Args
)
& pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$ToggleScript`" @Args
exit `$LASTEXITCODE
"@ | Set-Content -Path $CommandEntry -Encoding UTF8

  if ($env:Path -notlike "*$BinDir*") {
    $newUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ([string]::IsNullOrWhiteSpace($newUserPath)) {
      $newUserPath = $BinDir
    } else {
      $newUserPath = "$BinDir;$newUserPath"
    }
    [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
    $env:Path = "$BinDir;$env:Path"
    Write-Info "Added $BinDir to your user PATH."
  }

  Write-Success 'pocket-lab command installed.'
}

function Register-ClaudeHooks {
  param(
    [hashtable]$Config,
    [string]$NotifyHookPath
  )

  Ensure-Directory (Split-Path $ClaudeSettings -Parent)

  $hookCommandBase = 'pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $NotifyHookPath

  $hookMap = @{}
  if ($Config.NotifyOnNotification) {
    $hookMap.Notification = @(@{
      matcher = ''
      hooks = @(@{ type = 'command'; command = "$hookCommandBase Notification" })
    })
  }
  if ($Config.NotifyOnStop) {
    $hookMap.Stop = @(@{
      matcher = ''
      hooks = @(@{ type = 'command'; command = "$hookCommandBase Stop" })
    })
  }
  if ($Config.NotifyOnSubagent) {
    $hookMap.SubagentStop = @(@{
      matcher = ''
      hooks = @(@{ type = 'command'; command = "$hookCommandBase SubagentStop" })
    })
  }

  $existing = if (Test-Path $ClaudeSettings) { Get-Content -Path $ClaudeSettings -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
  if (-not $existing.PSObject.Properties.Name.Contains('hooks')) {
    $existing | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
  }

  foreach ($entry in $hookMap.GetEnumerator()) {
    $existing.hooks | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force
  }

  $existing | ConvertTo-Json -Depth 20 | Set-Content -Path $ClaudeSettings -Encoding UTF8
  Write-Success "Claude Code hooks registered in $ClaudeSettings"
}

function Send-TestNotification {
  param([pscustomobject]$Config)

  $title = 'Pocket Lab'
  $body = 'Pocket Lab is installed and working. Your AI notifications are ready.'
  $disableNotification = $false
  if ($Config.TelegramSilent) { $disableNotification = $true }

  $payload = @{
    chat_id = $Config.TelegramChatId
    text = "<b>$([System.Net.WebUtility]::HtmlEncode($title))</b>`n$([System.Net.WebUtility]::HtmlEncode($body))"
    parse_mode = 'HTML'
    disable_notification = $disableNotification
  } | ConvertTo-Json -Depth 5

  try {
    $uri = "https://api.telegram.org/bot$($Config.TelegramBotToken)/sendMessage"
    $response = Invoke-RestMethod -Method Post -Uri $uri -ContentType 'application/json' -Body $payload -TimeoutSec 20
    if ($response.ok) {
      Write-Success "Test notification sent via Telegram to chat ID $($Config.TelegramChatId)"
      Write-Host '  Check your phone - you should see a notification now.'
    } else {
      Write-Warn 'Telegram test notification did not return ok=true.'
    }
  } catch {
    $details = Get-TelegramErrorDetails -ErrorRecord $_
    Write-Warn "Telegram test failed: $details"
    if ($details -match 'forbidden|blocked|not enough rights') {
      Write-Host '  Fix: open the bot in Telegram, send it /start again, and make sure the bot is not blocked.'
      Write-Host '  If you are sending to a group, add the bot to that group and verify the chat ID matches the group chat.'
    }
  }
}

function Remove-Hooks {
  if (-not (Test-Path $ClaudeSettings)) {
    return
  }

  try {
    $existing = Get-Content -Path $ClaudeSettings -Raw | ConvertFrom-Json
    if ($existing.hooks) {
      foreach ($key in 'Notification', 'Stop', 'SubagentStop') {
        if ($existing.hooks.PSObject.Properties.Name -contains $key) {
          $existing.hooks.PSObject.Properties.Remove($key)
        }
      }
      if ($existing.hooks.PSObject.Properties.Count -eq 0) {
        $existing.PSObject.Properties.Remove('hooks')
      }
      $existing | ConvertTo-Json -Depth 20 | Set-Content -Path $ClaudeSettings -Encoding UTF8
      Write-Success 'Removed pocket-lab hooks from Claude Code settings.'
    }
  } catch {
    Write-Warn "Could not update Claude Code settings automatically: $($_.Exception.Message)"
  }
}

if ($Uninstall) {
  Write-Host ''
  Write-Host 'Uninstalling pocket-lab...' -ForegroundColor Yellow
  Remove-Hooks
  Remove-Item -Path $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -Path $CommandShim, $CommandEntry -Force -ErrorAction SilentlyContinue
  Write-Success 'pocket-lab uninstalled.'
  exit 0
}

Write-Host ''
Write-Host '  ==============================='
Write-Host '  pocket-lab Windows installer'
Write-Host '  Native pwsh + Telegram support'
Write-Host '  ==============================='
Write-Host ''

Write-Info 'This Windows installer supports Telegram only.'
Write-Info 'Run this from pwsh on Windows, not WSL.'

Ensure-Directory $InstallRoot
Ensure-Directory $HookDir
Ensure-Directory $BinDir

Write-Host ''
Write-Host 'Telegram setup:'
Write-Host '  1. Create a bot with @BotFather.'
Write-Host '  2. Send the bot a first message.'
Write-Host '  3. Paste the bot token and chat ID when prompted.'
Write-Host ''

$telegramBotToken = Prompt-Value -Message 'Paste your Telegram bot token' -Required
Write-Host ''
Write-Host 'Trying to auto-detect your chat ID from Telegram updates...'
$telegramChatId = Get-ChatIdFromUpdates -BotToken $telegramBotToken
if (-not $telegramChatId) {
  Write-Warn 'Could not auto-detect chat ID.'
  Write-Host 'Open https://api.telegram.org/bot<TOKEN>/getUpdates in your browser and look for message.chat.id.'
  $telegramChatId = Prompt-Value -Message 'Enter your Telegram chat ID' -Required
} else {
  Write-Success "Auto-detected chat ID: $telegramChatId"
}

$telegramSilentOnStop = Prompt-ChoiceYesNo -Message 'Send task-complete notifications silently' -Default $false

Write-Host ''
$enablePresence = Prompt-ChoiceYesNo -Message 'Enable Tailscale presence detection on Windows' -Default $false
$desktopName = ''
if ($enablePresence) {
  $desktopName = Prompt-Value -Message 'Desktop Tailscale hostname' -Required
}

Write-Host ''
$notifyOnStop = Prompt-ChoiceYesNo -Message 'Notify when task finishes (Stop hook)' -Default $true
$notifyOnNotification = Prompt-ChoiceYesNo -Message 'Notify when Claude needs input (Notification hook)' -Default $true
$notifyOnSubagent = Prompt-ChoiceYesNo -Message 'Notify on sub-agent completion (SubagentStop hook)' -Default $false

$config = @{
  NotificationProvider = 'telegram'
  TelegramBotToken = $telegramBotToken
  TelegramChatId = $telegramChatId
  TelegramSilent = $false
  TelegramSilentOnStop = [bool]$telegramSilentOnStop
  TailscalePresence = [bool]$enablePresence
  TailscaleDesktopName = $desktopName
  RateLimitSecs = 10
  LogFile = $LogFile
  NotifyEnabledFile = $EnabledFile
  NotifyOnStop = [bool]$notifyOnStop
  NotifyOnNotification = [bool]$notifyOnNotification
  NotifyOnSubagent = [bool]$notifyOnSubagent
}

Save-Config -Data $config

Get-LocalOrRemoteFile -RelativePath 'hooks/notify.ps1' -Destination $NotifyHook
Get-LocalOrRemoteFile -RelativePath 'hooks/toggle.ps1' -Destination $ToggleScript
Install-BinShim
Register-ClaudeHooks -Config $config -NotifyHookPath $NotifyHook

if (Prompt-ChoiceYesNo -Message 'Send a test Telegram notification' -Default $true) {
  Send-TestNotification -Config ([pscustomobject]$config)
}

Write-Host ''
Write-Success 'Installation complete.'
Write-Host "  Config:      $ConfigFile"
Write-Host "  Hook script: $NotifyHook"
Write-Host "  Toggle:      $ToggleScript"
Write-Host "  Command:     $CommandShim"
Write-Host "  Logs:        $LogFile"
Write-Host ''
Write-Host 'Use `pocket-lab on`, `pocket-lab off`, `pocket-lab status`, or `pocket-lab flip` from pwsh.'
