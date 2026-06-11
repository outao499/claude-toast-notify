# claude-toast-notify

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

1. Clone or download this repository:

   ```powershell
   git clone https://github.com/YOUR_USERNAME/claude-toast-notify.git
   ```

2. Add the plugin to Claude Code's `settings.json`:

   ```json
   "extraKnownMarketplaces": {
     "claude-toast-notify": {
       "source": {
         "path": "C:\\path\\to\\claude-toast-notify",
         "source": "directory"
       }
     }
   }
   ```

3. Restart Claude Code. The plugin will be installed automatically from the local marketplace.

   > Or simply copy `scripts/claude_toast_notify.ps1` and `hooks/hooks.json` into your own Claude Code plugin structure.

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
