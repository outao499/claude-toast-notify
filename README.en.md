# claude-toast-notify

[中文文档](./README.md)

Windows toast and permission popup notifications for [Claude Code](https://claude.ai).

Displays a popup when Claude Code requests tool permissions, and a toast balloon
when a task completes.

## Features

- **Permission popup** — centered window with tool name/args and a "确定" button
- **Task completion toast** — 5-second balloon in the bottom-right corner
- **Terminal activation** — click the notification to bring your terminal back to the foreground
- **Multisession isolation** — separate state tracking per Claude Code session
- **DPI-aware** — renders correctly on HiDPI displays
- **Zero external dependencies** — uses only built-in Windows APIs and WinForms

## Requirements

- Windows 10 / 11
- PowerShell 5.1+
- .NET Framework 4.5+ (WinForms and Drawing assemblies, preinstalled on Windows)
- [Claude Code](https://claude.ai)

## Installation

### Method 1: Install via GitHub (recommended)

Run these two commands inside Claude Code:

```
/plugin marketplace add outao499/claude-toast-notify
/plugin install claude-toast-notify@claude-toast-notify
```

Restart Claude Code and you're done.

### Method 2: One-click install script

Run this in PowerShell (as administrator):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -c "iex (Invoke-RestMethod https://raw.githubusercontent.com/outao499/claude-toast-notify/main/install.ps1)"
```

The script downloads the plugin and configures Claude Code automatically.

### Method 3: Manual install

Clone the repo, then inside Claude Code run:

```
/plugin marketplace add C:\path\to\claude-toast-notify
/plugin install claude-toast-notify@claude-toast-notify
```

## How It Works

Three [Claude Code hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) drive the notification flow:

| Hook event             | Trigger                          | Action                                  |
|------------------------|----------------------------------|-----------------------------------------|
| `UserPromptSubmit`     | User sends a message             | Save terminal handle + start time (silent) |
| `Stop`                 | Claude Code finishes a response  | Show toast balloon with elapsed time     |
| `PermissionRequest`    | Tool needs user approval         | Show centered permission popup           |

On the `PermissionRequest` popup or the balloon, clicking activates the terminal
window using a three-layer strategy: saved handle → process name search →
`GetConsoleWindow()`.

## Testing

```powershell
# Toast balloon
.\scripts\claude_toast_notify.ps1 -Mode balloon

# Permission popup (pipe a mock payload)
'{"tool_name":"Write","tool_input":{"file_path":"test.txt"}}' | .\scripts\claude_toast_notify.ps1 -Mode popup
```

## License

MIT
