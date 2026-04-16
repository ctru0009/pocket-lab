# pocket-lab

pocket-lab is a small installer for push notifications from AI coding tools like Claude Code. It provides a Bash setup for Linux and macOS, plus a native pwsh setup for Windows Telegram notifications.

The main idea is simple: keep your development environment running on a machine that is always available, connect to it through Tailscale when you are away, and receive notifications through either ntfy or Telegram.

## Why this exists

If you leave your desk but still want to keep working, notifications make the workflow feel much more responsive. Instead of waiting until you return to your PC, you can approve, answer, or review prompts from your phone.

This project is meant to make that setup easy to install and easy to turn on or off.

## Features

- Supports Claude Code hook registration
- Supports a native Windows pwsh installer for Telegram
- Supports notification delivery through Telegram on Windows, Linux, and macOS
- Supports notification delivery through ntfy on Linux and macOS only
- Includes a `pocket-lab` CLI for `on`, `off`, `status`, and `flip`
- Can skip notifications when your desktop is online through Tailscale presence detection
- Can send notifications for task completion, input needed, and sub-agent completion
- OpenCode support is planned as a future improvement

## Does Telegram work?

Yes. Telegram is already supported in the installer and hook scripts.

### Telegram setup

Use Telegram if you want the simplest phone-side setup. Most people already have the app installed, and the installer only needs two core values:

- your bot token
- your chat ID

The flow is:

1. Open Telegram and talk to `@BotFather`.
2. Send `/newbot` and create a bot.
3. Copy the token BotFather gives you.
4. Send at least one message to your new bot so Telegram creates a chat thread.
5. Run the installer and paste the token when prompted.
6. Let the installer auto-detect your chat ID, or enter it manually if needed.

The script can also make task-complete notifications silent if you want the phone to stay quiet when Claude finishes a job. That is controlled by the optional silent-on-stop setting.

Telegram is a good choice if you want:

- one less app to install
- direct push notifications to your phone
- a setup that works well for both personal and group chats
- a provider that also works on Windows

### Telegram notes

- You must send the bot a first message before `getUpdates` can find the chat ID.
- If `curl` and `jq` are available, the installer can often auto-detect the chat ID for you.
- Silent notifications are useful when you want input-needed messages to make noise, but task-finished messages to stay quiet.

## ntfy setup

ntfy is the better fit if you want a lightweight topic-based setup or you already self-host services.

The installer will ask for:

- the ntfy server URL
- the ntfy topic name
- an optional auth token

The flow is:

1. Decide whether you want to use the public `ntfy.sh` service or your own ntfy server.
2. Pick a topic name. If you use the public service, make it hard to guess.
3. Add an auth token only if your server requires one.
4. Run the installer and paste those values when prompted.

If you use the public ntfy service, the main security rule is to choose a unique topic name that other people will not guess easily. If you self-host, you can point the installer at your own server URL instead.

ntfy is a good choice if you want:

- a simple publish/subscribe notification model
- self-hosting control
- a phone app that is easy to use for quick alerts
- a provider that is best used on Linux or macOS

### ntfy notes

- The default server is `https://ntfy.sh`.
- The topic is required, and it is effectively the destination channel for your notifications.
- If your ntfy server uses auth, the installer stores the token and the hook script sends it as a bearer token.
- A unique topic is important on public ntfy because anyone who knows the topic can subscribe to it.

## Installation

Before you run either installer, review the script first: [install.sh](install.sh) for Linux/macOS or [install.ps1](install.ps1) for Windows. It is a good idea to inspect the installer before running it.

### Linux and macOS

Run the Bash installer directly from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/ctru0009/pocket-lab/main/install.sh | bash
```

The Bash installer now requires `jq` on Linux and macOS. If it is not already installed, add it first with your package manager before running the installer.

If you cloned the repo locally, you can also run:

```bash
bash install.sh
```

To uninstall:

```bash
bash install.sh --uninstall
```

### Windows native pwsh

Use the native PowerShell installer from a Windows PowerShell 7 session. This is the Windows path for Telegram:

```powershell
pwsh -File .\install.ps1
```

Or run it directly from GitHub:

```powershell
irm https://raw.githubusercontent.com/ctru0009/pocket-lab/main/install.ps1 | iex
```

To uninstall:

```powershell
pwsh -File .\install.ps1 -Uninstall
```

The installers will:

- check the current platform
- prompt you for Telegram or ntfy where supported
- install the hook scripts into the local config folder
- register hooks with Claude Code when Claude is detected
- support pipe-based Bash installation from GitHub without the `BASH_SOURCE[0]` crash

Windows native support uses Telegram only. ntfy remains Linux and macOS only in this repo.

## Turning notifications on and off

Yes, that workflow makes sense, and it is already built in.

Use the command installed by the script:

```bash
pocket-lab on
pocket-lab off
pocket-lab status
pocket-lab flip
```

This is useful when:

- you are at your PC and do not want phone notifications
- you leave your desk and want them enabled again
- you want a quick toggle instead of editing config files

## Tailscale presence detection

This project also supports the idea of “only notify me when I am away.”

If you enable Tailscale presence detection during install, pocket-lab can check whether your desktop is online on your tailnet and skip notifications when it is already active. That fits the use case of an always-on machine plus a phone-first notification flow.

## How it works

The Bash installer writes a config file to `~/.config/pocket-lab/config` and installs two scripts:

- `notify.sh` handles hook events and sends the notification
- `toggle.sh` manages whether notifications are enabled

The Windows installer writes a PowerShell config file under `%LOCALAPPDATA%\pocket-lab\config.json` and installs PowerShell versions of those scripts.

Claude Code hook events such as `Notification`, `Stop`, and `SubagentStop` are mapped to the notification provider you chose.

## Supported tools

The installer checks for these tools in `PATH`:

- Claude Code

Claude Code hook registration is automatic when Claude is found. OpenCode support is planned for a future version once its hook flow is implemented.

## Recommended setup

For the most practical version of this project, I would recommend:

1. Use Telegram if the goal is the lowest-friction mobile setup.
2. Use ntfy if you want a self-hosted or more open notification path.
3. Keep Tailscale presence detection as an optional power-user feature.
4. Document the `on/off` toggle clearly, since that is the piece people will use most often day to day.

## Repository layout

```text
install.sh
install.ps1
hooks/
	notify.ps1
	toggle.ps1
	notify.sh
	toggle.sh
```

## Notes

- Telegram requires a bot token and chat ID.
- The Windows native path uses Telegram only.
- ntfy works well if you already run your own server or want a quick public topic-based setup, but it is limited to Linux and macOS here.
- Notifications are disabled by removing the `enabled` file; they are re-enabled by creating it again.
- The Bash path uses `jq` for config parsing and Telegram payload handling.
