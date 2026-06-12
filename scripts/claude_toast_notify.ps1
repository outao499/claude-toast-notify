param(
    [string]$Title = "Claude Code",
    [string]$Message = "",
    [string]$Mode = "balloon",
    [string]$Event = "",
    [string]$PayloadFile = ""
)

# ── Init ──
$pluginRoot = $env:CLAUDE_PLUGIN_ROOT
if (-not $pluginRoot) { $pluginRoot = (Get-Item $PSScriptRoot).Parent.FullName }
$notifyDir = Join-Path $pluginRoot "notify"
if (-not (Test-Path $notifyDir)) { New-Item -ItemType Directory -Path $notifyDir -Force | Out-Null }
$logFile = Join-Path $notifyDir "claude_notify_debug.log"
$sessionsDir = Join-Path $notifyDir "sessions"
if (-not (Test-Path $sessionsDir)) { New-Item -ItemType Directory -Path $sessionsDir -Force | Out-Null }
try {
    Get-ChildItem -Path $sessionsDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
} catch {}

$termNames = @("WindowsTerminal", "wt", "wezterm", "wezterm-gui",
               "ConEmu64", "ConEmu", "OpenConsole", "conhost",
               "pwsh", "powershell", "cmd",
               "idea64", "idea", "jetbrains", "devecostudio64",
               "code", "Code",
               "hyper", "alacritty", "tabby", "mintty",
               "FluentTerminal", "MobaXterm", "putty", "kitty")

function Get-ShortHash {
    param([string]$Value)
    if (-not $Value) { $Value = "default" }
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))
        return ([BitConverter]::ToString($hash) -replace "-", "").Substring(0, 16).ToLowerInvariant()
    } catch { return "default" }
}

function Read-HookStdin {
    $input = ""
    if ($PayloadFile -and (Test-Path -LiteralPath $PayloadFile)) {
        try {
            $input = Get-Content -LiteralPath $PayloadFile -Raw -Encoding UTF8
            Remove-Item -LiteralPath $PayloadFile -Force -ErrorAction SilentlyContinue
        } catch {}
    } elseif ([Console]::IsInputRedirected) {
        $origEncoding = [Console]::InputEncoding
        [Console]::InputEncoding = [System.Text.Encoding]::UTF8
        try { $input = [Console]::In.ReadToEnd() } catch {}
        [Console]::InputEncoding = $origEncoding
    }
    return $input
}

function Resolve-SessionSource {
    param([string]$StdinInput)
    $source = ""
    if ($StdinInput -and $StdinInput.Length -gt 0) {
        try {
            $hookData = $StdinInput | ConvertFrom-Json
            if ($hookData) {
                if ($hookData.session_id) { $source = [string]$hookData.session_id }
                elseif ($hookData.transcript_path) { $source = [string]$hookData.transcript_path }
                elseif ($hookData.cwd) { $source = [string]$hookData.cwd }
            }
        } catch {}
    }
    if (-not $source -and $env:CLAUDE_SESSION_ID) { $source = $env:CLAUDE_SESSION_ID }
    if (-not $source) { $source = (Get-Location).Path }
    return $source
}

# ── Add-Type: all Win32 P/Invoke in one place ──
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public class Win32 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int dwProcessId);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
}
"@

# ── Window lookup helpers ──

function Find-WtWindowByTitle {
    param([string[]]$Titles)
    if ($Titles.Count -eq 0) { return [IntPtr]::Zero }
    try {
        $wtProcs = Get-Process WindowsTerminal -ErrorAction SilentlyContinue
        if ($null -eq $wtProcs) { return [IntPtr]::Zero }
        $wtPids = @($wtProcs | ForEach-Object { $_.Id })
        $script:exactHwnd = [IntPtr]::Zero
        $script:fuzzyHwnd = [IntPtr]::Zero
        $callback = [Win32+EnumWindowsProc]{
            param($hWnd, $lParam)
            $procIdOut = [uint32]0
            [Win32]::GetWindowThreadProcessId($hWnd, [ref]$procIdOut) | Out-Null
            if ($wtPids -contains $procIdOut) {
                $title = New-Object System.Text.StringBuilder 512
                [Win32]::GetWindowText($hWnd, $title, 512) | Out-Null
                $winTitle = "$title"
                if ($winTitle.Length -eq 0) { return $true }
                foreach ($mt in $Titles) {
                    if ($winTitle -eq $mt) {
                        $script:exactHwnd = $hWnd
                        return $false
                    }
                }
                if ($script:fuzzyHwnd -eq [IntPtr]::Zero) {
                    foreach ($mt in $Titles) {
                        if ($mt.Length -gt 0 -and ($winTitle.Contains($mt) -or $mt.Contains($winTitle))) {
                            $script:fuzzyHwnd = $hWnd
                            break
                        }
                    }
                }
            }
            return $true
        }
        [Win32]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
        if ($script:exactHwnd -ne [IntPtr]::Zero) { return $script:exactHwnd }
        if ($script:fuzzyHwnd -ne [IntPtr]::Zero) { return $script:fuzzyHwnd }
    } catch {}
    return [IntPtr]::Zero
}

function Find-TerminalByProcess {
    $handle = [IntPtr]::Zero
    # GetConsoleWindow
    try {
        $handle = [Win32]::GetConsoleWindow()
        if ($handle -ne [IntPtr]::Zero) { return $handle }
    } catch {}
    # Walk parent chain
    $pidCursor = $global:pid
    $seen = @{}
    while ($pidCursor -gt 0 -and -not $seen.ContainsKey($pidCursor)) {
        $seen[$pidCursor] = $true
        try {
            $proc = Get-Process -Id $pidCursor -ErrorAction SilentlyContinue
            if ($null -ne $proc -and $proc.ProcessName -in $termNames -and $proc.MainWindowHandle -ne [IntPtr]::Zero) {
                return $proc.MainWindowHandle
            }
            $wmi = Get-WmiObject Win32_Process -Filter "ProcessId = $pidCursor" -ErrorAction SilentlyContinue
            if (-not $wmi) { break }
            $pidCursor = $wmi.ParentProcessId
        } catch { break }
    }
    # Global search
    foreach ($name in $termNames) {
        try {
            $proc = Get-Process -Name $name -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } |
                Sort-Object StartTime -Descending | Select-Object -First 1
            if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { return $proc.MainWindowHandle }
        } catch {}
    }
    return [IntPtr]::Zero
}

function Find-TerminalWindow {
    $consoleTitle = ""
    try { $consoleTitle = [Console]::Title } catch {}
    $handle = Find-WtWindowByTitle -Titles @($consoleTitle)
    if ($handle -ne [IntPtr]::Zero) { return $handle }
    return Find-TerminalByProcess
}

# ── save event: fast path, early exit ──
if ($Event -eq "save") {
    $stdinInput = Read-HookStdin
    $sessionSource = Resolve-SessionSource $stdinInput
    $sessionKey = Get-ShortHash -Value $sessionSource
    $sessionDir = Join-Path $sessionsDir $sessionKey
    if (-not (Test-Path $sessionDir)) { New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null }
    $instanceHandleFile = Join-Path $sessionDir "terminal_handle.txt"
    [DateTimeOffset]::Now.ToUnixTimeSeconds() | Out-File (Join-Path $sessionDir "start_time.txt") -Encoding ascii

    $consoleTitle = ""
    try { $consoleTitle = [Console]::Title } catch {}
    $handle = Find-WtWindowByTitle -Titles @($consoleTitle)
    if ($handle -eq [IntPtr]::Zero) { $handle = Find-TerminalByProcess }

    if ($handle -ne [IntPtr]::Zero) {
        $handle.ToInt64() | Out-File $instanceHandleFile -Encoding ascii
    }
    if ($consoleTitle) {
        $consoleTitle | Out-File (Join-Path $sessionDir "console_title.txt") -Encoding utf8
    }
    exit 0
}

# ── check event: light calculation first ──
if ($Event -eq "check") {
    $sessionSource = $env:CLAUDE_SESSION_ID
    if (-not $sessionSource) { $sessionSource = (Get-Location).Path }
    $sessionKey = Get-ShortHash -Value $sessionSource
    $instanceTimeFile = Join-Path (Join-Path $sessionsDir $sessionKey) "start_time.txt"
    if (Test-Path $instanceTimeFile) {
        $startTimeStr = (Get-Content $instanceTimeFile -Raw).Trim()
        $startTime = 0
        if (-not [long]::TryParse($startTimeStr, [ref]$startTime)) { exit 0 }
        $elapsed = [DateTimeOffset]::Now.ToUnixTimeSeconds() - $startTime
        $minutes = [math]::Floor($elapsed / 60)
        if ($elapsed -lt 15) { exit 0 }

        if ($elapsed -lt 180) {
            $Message = "任务已完成"
        } elseif ($elapsed -lt 900) {
            $Message = "长时间任务完成，耗时 " + $minutes + " 分钟"
        } else {
            $Message = "超长任务完成，耗时 " + $minutes + " 分钟"
        }
    } else { exit 0 }
}

# ── Heavy initialization (popup/balloon only) ──
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try { [Win32]::SetProcessDPIAware() | Out-Null } catch {}

$scale = 1.0
try {
    $graphics = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    if ($null -ne $graphics) {
        $dpiX = $graphics.DpiX
        if ($null -ne $dpiX -and $dpiX -gt 0) { $scale = $dpiX / 96.0 }
        $graphics.Dispose()
    }
} catch { $scale = 1.0 }

# ── Session key ──
$stdinInput = Read-HookStdin
$hookData = $null
$sessionSource = Resolve-SessionSource $stdinInput
if ($stdinInput -and $stdinInput.Length -gt 0) {
    try { $hookData = $stdinInput | ConvertFrom-Json } catch {}
}

$sessionKey = Get-ShortHash -Value $sessionSource
$sessionDir = Join-Path $sessionsDir $sessionKey
if (-not (Test-Path $sessionDir)) { New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null }
$instanceHandleFile = Join-Path $sessionDir "terminal_handle.txt"

# ── Log source detection ──
$source = "unknown"
$cmdPreview = ""
if ($Event -eq "check") { $source = "Stop" }
elseif ($null -ne $hookData) {
    try {
        $tn = if ($hookData.tool_name) { $hookData.tool_name } else { "" }
        $tc = if ($hookData.tool_input.command) { $hookData.tool_input.command } else { "" }
        if ($tc -and $tc.Length -gt 60) { $tc = $tc.Substring(0, 60) + "..." }
        $nt = if ($hookData.notification_type) { $hookData.notification_type } else { "" }
        $hen = if ($hookData.hook_event_name) { $hookData.hook_event_name } else { "" }
        if ($nt) { $source = "Notification($nt)" }
        elseif ($hen -eq "PermissionRequest" -or ($tn -and $tn -ne "AskUserQuestion")) { $source = "PermissionRequest" }
        else { $source = "PreToolUse" }
        $cmdPreview = " tool=$tn cmd=$tc"
    } catch {}
}

try { Add-Content -Path $logFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] session=$sessionKey src=$source Mode=$Mode Event=$Event$cmdPreview" -Encoding UTF8 } catch {}

# ── Parse stdin for dynamic content ──
if ($stdinInput -and $stdinInput.Length -gt 0) {
    try {
        $data = $stdinInput | ConvertFrom-Json
        $toolName = $data.tool_name
        $toolInput = $data.tool_input
        $notificationType = $data.notification_type
        $permMode = if ($data.permission_mode) { $data.permission_mode } else { "" }

        if ($notificationType -and $notificationType -ne "permission_prompt") { exit 0 }
        if ($permMode -eq "bypassPermissions" -and $Mode -eq "popup") { exit 0 }

        $acceptEditsTools = @("Write", "Edit", "NotebookEdit")
        if ($permMode -eq "acceptEdits" -and $Mode -eq "popup" -and $toolName -in $acceptEditsTools) {
            $isProtected = $false
            $fp = ""
            if ($toolName -eq "NotebookEdit") {
                $fp = if ($null -ne $toolInput -and $toolInput.notebook_path) { $toolInput.notebook_path } else { "" }
            } else {
                $fp = if ($null -ne $toolInput -and $toolInput.file_path) { $toolInput.file_path } else { "" }
            }
            if ($fp) {
                foreach ($dir in @("\.git", "\.config[/\\]git", "\.vscode", "\.idea", "\.husky", "\.cargo", "\.devcontainer", "\.yarn", "\.mvn")) {
                    if ($fp -match $dir) { $isProtected = $true; break }
                }
                if ($fp -match '[/\\]\.claude(?![/\\](?:commands|agents|skills|worktrees)[/\\])') { $isProtected = $true }
                if (-not $isProtected) {
                    $fileName = Split-Path $fp -Leaf
                    foreach ($pf in @("\.gitconfig", "\.gitmodules", "\.bashrc", "\.bash_profile", "\.zshrc", "\.npmrc", "\.yarnrc", "Makefile", "Dockerfile", "docker-compose\.yml")) {
                        if ($fileName -match "^$pf$") { $isProtected = $true; break }
                    }
                }
            }
            if (-not $isProtected) { exit 0 }
        }

        if ($permMode -eq "acceptEdits" -and $Mode -eq "popup" -and $toolName -eq "Bash") {
            $cmd = if ($null -ne $toolInput -and $toolInput.command) { $toolInput.command } else { "" }
            if (($cmd -split '\s+')[0] -in @("mkdir", "touch", "cp")) { exit 0 }
        }

        if ($permMode -eq "plan" -and $Mode -eq "popup") { exit 0 }

        if ($toolName) {
            switch ($toolName) {
                "Bash" {
                    $cmd = if ($null -ne $toolInput -and $toolInput.command) { $toolInput.command } else { "" }
                    if ($null -ne $cmd -and $cmd.Length -gt 50) { $cmd = $cmd.Substring(0, 50) + "..." }
                    if ($Mode -eq "popup") { $Title = "Claude Code"; $Message = "需要权限 - Claude 想要执行: " + $cmd }
                    else { $Message = "Bash 命令已执行" }
                }
                { $_ -eq "Write" -or $_ -eq "Edit" } {
                    $fp = if ($null -ne $toolInput -and $toolInput.file_path) { $toolInput.file_path } else { "" }
                    $fn = if ($fp) { Split-Path $fp -Leaf } else { "" }
                    $action = if ($toolName -eq "Write") { "写入" } else { "编辑" }
                    if ($Mode -eq "popup") { $Title = "Claude Code"; $Message = "需要权限 - Claude 想要" + $action + ": " + $fn }
                    else { $Message = $fn + " " + $action + "完成" }
                }
                "WebFetch" {
                    $url = if ($null -ne $toolInput -and $toolInput.url) { $toolInput.url } else { "" }
                    if ($null -ne $url -and $url.Length -gt 50) { $url = $url.Substring(0, 50) + "..." }
                    if ($Mode -eq "popup") { $Title = "Claude Code"; $Message = "需要权限 - Claude 想要获取: " + $url }
                    else { $Message = "网页获取完成" }
                }
                "WebSearch" {
                    $query = if ($null -ne $toolInput -and $toolInput.query) { $toolInput.query } else { "" }
                    if ($null -ne $query -and $query.Length -gt 50) { $query = $query.Substring(0, 50) + "..." }
                    if ($Mode -eq "popup") { $Title = "Claude Code"; $Message = "需要权限 - Claude 想要搜索: " + $query }
                    else { $Message = "网页搜索完成" }
                }
                "Agent" {
                    $desc = if ($null -ne $toolInput -and $toolInput.description) { $toolInput.description } else { "" }
                    if ($null -ne $desc -and $desc.Length -gt 50) { $desc = $desc.Substring(0, 50) + "..." }
                    if ($Mode -eq "popup") { $Title = "Claude Code"; $Message = "需要权限 - Claude 想要启动代理: " + $desc }
                    else { $Message = "代理任务完成" }
                }
                "NotebookEdit" {
                    $fp = if ($null -ne $toolInput -and $toolInput.notebook_path) { $toolInput.notebook_path } else { "" }
                    $fn = if ($fp) { Split-Path $fp -Leaf } else { "" }
                    if ($Mode -eq "popup") { $Title = "Claude Code"; $Message = "需要权限 - Claude 想要编辑笔记本: " + $fn }
                    else { $Message = $fn + " 笔记本编辑完成" }
                }
                "AskUserQuestion" {
                    $question = ""
                    if ($null -ne $toolInput -and $toolInput.questions -and $toolInput.questions.Count -gt 0) {
                        $question = $toolInput.questions[0].question
                    }
                    if ($null -ne $question -and $question.Length -gt 50) { $question = $question.Substring(0, 50) + "..." }
                    $Title = "Claude Code"; $Message = "需要你的回答: " + $question
                }
                default {
                    if ($Mode -eq "popup") { $Title = "Claude Code"; $Message = "需要权限 - Claude 需要使用 " + $toolName }
                    else { $Message = $toolName + " 完成" }
                }
            }
        }
    } catch {
        if ($Mode -eq "popup") { $Title = "Claude Code"; $Message = "需要权限 - 需要你的操作" }
    }
}

if (-not $Message) {
    if ($Mode -eq "popup") { $Title = "Claude Code"; $Message = "需要权限 - 需要你的操作" }
    else { $Message = "任务已完成" }
}

if ($Mode -eq "balloon" -and $Message.Length -gt 60) {
    $Message = $Message.Substring(0, [math]::Min(57, $Message.Length)) + "..."
}

# ── Mutex ──
$mutex = $null
$mutexOwned = $false
try {
    $mutexName = "Global\ClaudeCodeNotification_$($env:USERNAME)"
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    if (-not $mutex.WaitOne(3000)) { exit 0 }
    $mutexOwned = $true
} catch { $mutex = $null }

# ── Activate terminal ──
function Activate-Terminal {
    param([string]$HandleFile)

    $handle = [IntPtr]::Zero
    $activeHandleFile = if ($HandleFile) { $HandleFile } else { $instanceHandleFile }

    # Collect titles: live (most up-to-date) + saved (fallback if title drifted)
    $matchTitles = @()
    $liveTitle = ""
    try { $liveTitle = [Console]::Title } catch {}
    if ($liveTitle) { $matchTitles += $liveTitle }
    $activeSessionDir = if ($HandleFile) { Split-Path $HandleFile -Parent } else { $sessionDir }
    $titleFile = Join-Path $activeSessionDir "console_title.txt"
    if (Test-Path $titleFile) {
        try {
            $savedTitle = (Get-Content $titleFile -Raw).Trim()
            if ($savedTitle -and $savedTitle -ne $liveTitle) { $matchTitles += $savedTitle }
        } catch {}
    }

    $handle = Find-WtWindowByTitle -Titles $matchTitles

    # Fallback: saved handle
    if ($handle -eq [IntPtr]::Zero -and (Test-Path $activeHandleFile)) {
        try {
            $handleStr = (Get-Content $activeHandleFile -Raw).Trim()
            $savedHandle = [long]0
            if ([long]::TryParse($handleStr, [ref]$savedHandle) -and $savedHandle -gt 0) {
                $handle = [IntPtr]$savedHandle
            }
        } catch {}
    }
    if ($handle -eq [IntPtr]::Zero) { $handle = Find-TerminalWindow }
    if ($handle -ne [IntPtr]::Zero) {
        try {
            $isMinimized = [Win32]::IsIconic($handle)
            if ($isMinimized) { [Win32]::ShowWindow($handle, 9) | Out-Null }

            $procId = [uint32]0
            [Win32]::GetWindowThreadProcessId($handle, [ref]$procId) | Out-Null
            $fgHandle = [Win32]::GetForegroundWindow()
            $fgProcId = [uint32]0
            $fgThreadId = [Win32]::GetWindowThreadProcessId($fgHandle, [ref]$fgProcId)
            $curThreadId = [Win32]::GetCurrentThreadId()
            $attached = $false
            if ($fgThreadId -ne 0 -and $fgThreadId -ne $curThreadId) {
                try { $attached = [Win32]::AttachThreadInput($curThreadId, $fgThreadId, $true) } catch {}
            }
            try {
                $wshell = New-Object -ComObject WScript.Shell
                $wshell.SendKeys("%")
            } catch {}

            [Win32]::SetForegroundWindow($handle) | Out-Null
            try { $wshell = New-Object -ComObject WScript.Shell; $wshell.AppActivate($procId) | Out-Null } catch {}
            [Win32]::ShowWindow($handle, 5) | Out-Null

            if ($attached) {
                try { [Win32]::AttachThreadInput($curThreadId, $fgThreadId, $false) | Out-Null } catch {}
            }
        } catch {}
    }
}

# ── Show notification ──
function Show-Notify {
    $screen = $null
    try {
        $cursor = [System.Windows.Forms.Cursor]::Position
        if ($null -ne $cursor) {
            $s = [System.Windows.Forms.Screen]::FromPoint($cursor)
            if ($null -ne $s) { $screen = $s.WorkingArea }
        }
    } catch {}
    if ($null -eq $screen) {
        try {
            $primary = [System.Windows.Forms.Screen]::PrimaryScreen
            if ($null -ne $primary) { $screen = $primary.WorkingArea }
        } catch {}
    }
    if ($null -eq $screen) { $screen = New-Object System.Drawing.Rectangle(0, 0, 1920, 1080) }

    $w = [int](340 * $scale); $h = [int](94 * $scale); $gap = [int](16 * $scale)
    $r = [int](16 * $scale); $padX = [int](16 * $scale)

    $shadow = New-Object System.Windows.Forms.Form
    $shadow.Size = New-Object System.Drawing.Size(($w + 8), ($h + 8))
    $shadow.StartPosition = "Manual"
    $shadow.Location = New-Object System.Drawing.Point(($screen.Right - $w - $gap - 4), ($screen.Top + $gap + 10))
    $shadow.FormBorderStyle = "None"
    $shadow.BackColor = [System.Drawing.Color]::FromArgb(0, 0, 0)
    $shadow.TopMost = $true; $shadow.ShowInTaskbar = $false; $shadow.Opacity = 0.15

    $sp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $sp.AddArc(0, 8, $r, $r, 180, 90); $sp.AddArc(($w - $r + 8), 8, $r, $r, 270, 90)
    $sp.AddArc(($w - $r + 8), ($h - $r + 8), $r, $r, 0, 90); $sp.AddArc(0, ($h - $r + 8), $r, $r, 90, 90)
    $sp.CloseFigure(); $shadow.Region = New-Object System.Drawing.Region($sp)

    $f = New-Object System.Windows.Forms.Form
    $f.Size = New-Object System.Drawing.Size($w, $h)
    $f.StartPosition = "Manual"
    $f.Location = New-Object System.Drawing.Point(($screen.Right - $w - $gap), ($screen.Top + $gap + 10))
    $f.FormBorderStyle = "None"
    $f.BackColor = [System.Drawing.Color]::FromArgb(242, 242, 247)
    $f.TopMost = $true; $f.ShowInTaskbar = $false

    $fp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $fp.AddArc(0, 8, $r, $r, 180, 90); $fp.AddArc(($w - $r), 8, $r, $r, 270, 90)
    $fp.AddArc(($w - $r), ($h - $r), $r, $r, 0, 90); $fp.AddArc(0, ($h - $r), $r, $r, 90, 90)
    $fp.CloseFigure(); $f.Region = New-Object System.Drawing.Region($fp)

    $fontSize = [int](11 * $scale); $msgFontSize = [int](9 * $scale)

    $appLb = New-Object System.Windows.Forms.Label
    $appLb.Text = $Title; $appLb.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", $fontSize, [System.Drawing.FontStyle]::Bold)
    $appLb.ForeColor = [System.Drawing.Color]::FromArgb(0, 0, 0)
    $appLb.BackColor = [System.Drawing.Color]::FromArgb(242, 242, 247)
    $appLb.AutoSize = $false; $appLb.UseCompatibleTextRendering = $true
    $appLb.Location = New-Object System.Drawing.Point($padX, [int](8 * $scale))
    $appLb.Size = New-Object System.Drawing.Size([int](270 * $scale), [int](44 * $scale))
    $appLb.TextAlign = "MiddleLeft"; $appLb.Cursor = [System.Windows.Forms.Cursors]::Hand
    $script:activateAfterClose = $false
    $appLb.Add_Click({ $script:balloonClosed = $true; $script:activateAfterClose = $true })
    $f.Controls.Add($appLb)

    $msgLb = New-Object System.Windows.Forms.Label
    $msgLb.Text = $Message; $msgLb.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", $msgFontSize)
    $msgLb.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 100)
    $msgLb.BackColor = [System.Drawing.Color]::FromArgb(242, 242, 247)
    $msgLb.Location = New-Object System.Drawing.Point($padX, [int](52 * $scale))
    $msgLb.Size = New-Object System.Drawing.Size([int](270 * $scale), [int](36 * $scale))
    $msgLb.TextAlign = "TopLeft"; $msgLb.Cursor = [System.Windows.Forms.Cursors]::Hand
    $msgLb.Add_Click({ $script:balloonClosed = $true; $script:activateAfterClose = $true })
    $f.Controls.Add($msgLb)

    $closeLb = New-Object System.Windows.Forms.Label
    $closeLb.Text = [char]0x00D7; $closeLb.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", [int](14 * $scale))
    $closeLb.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 180)
    $closeLb.BackColor = [System.Drawing.Color]::FromArgb(242, 242, 247)
    $closeLb.Location = New-Object System.Drawing.Point([int](300 * $scale), [int](10 * $scale))
    $closeLb.Size = New-Object System.Drawing.Size([int](28 * $scale), [int](36 * $scale))
    $closeLb.TextAlign = "MiddleCenter"; $closeLb.Cursor = [System.Windows.Forms.Cursors]::Hand
    $closeLb.Add_Click({ $script:balloonClosed = $true })
    $f.Controls.Add($closeLb)

    $f.Add_Click({ $script:balloonClosed = $true; $script:activateAfterClose = $true })

    $script:balloonClosed = $false
    $tm = New-Object System.Windows.Forms.Timer
    $tm.Interval = 5000
    $tm.Add_Tick({ $tm.Stop(); $script:balloonClosed = $true })

    $shadow.Show(); $f.Show(); $tm.Start()
    while (-not $script:balloonClosed) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
    $tm.Stop(); $tm.Dispose()
    if (-not $f.IsDisposed) { $f.Close() }
    if (-not $shadow.IsDisposed) { $shadow.Close() }
    $f.Dispose(); $shadow.Dispose()
    if ($script:activateAfterClose) { Activate-Terminal }
}

function Show-Popup {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title
    $f.Size = New-Object System.Drawing.Size([int](460 * $scale), [int](220 * $scale))
    $f.StartPosition = "CenterScreen"
    $f.FormBorderStyle = "None"
    $f.BackColor = [System.Drawing.Color]::FromArgb(242, 242, 247)
    $f.TopMost = $true

    $r = [int](12 * $scale); $pw = [int](460 * $scale); $ph = [int](220 * $scale); $padX = [int](24 * $scale)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc(0, 0, $r, $r, 180, 90); $p.AddArc(($pw - $r), 0, $r, $r, 270, 90)
    $p.AddArc(($pw - $r), ($ph - $r), $r, $r, 0, 90); $p.AddArc(0, ($ph - $r), $r, $r, 90, 90)
    $p.CloseFigure(); $f.Region = New-Object System.Drawing.Region($p)

    $closeLb = New-Object System.Windows.Forms.Label
    $closeLb.Text = [char]0x00D7; $closeLb.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", [int](14 * $scale))
    $closeLb.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 180)
    $closeLb.BackColor = [System.Drawing.Color]::FromArgb(242, 242, 247)
    $closeLb.Location = New-Object System.Drawing.Point([int](410 * $scale), [int](10 * $scale))
    $closeLb.Size = New-Object System.Drawing.Size([int](30 * $scale), [int](30 * $scale))
    $closeLb.TextAlign = "MiddleCenter"; $closeLb.Cursor = [System.Windows.Forms.Cursors]::Hand
    $closeLb.Add_Click({ $f.Close() })
    $f.Controls.Add($closeLb)

    $lb1 = New-Object System.Windows.Forms.Label
    $lb1.Text = $Title; $lb1.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", [int](14 * $scale), [System.Drawing.FontStyle]::Bold)
    $lb1.ForeColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $lb1.BackColor = [System.Drawing.Color]::FromArgb(242, 242, 247)
    $lb1.AutoSize = $false; $lb1.UseCompatibleTextRendering = $true
    $lb1.Location = New-Object System.Drawing.Point($padX, [int](16 * $scale))
    $lb1.Size = New-Object System.Drawing.Size(($pw - $padX * 2 - [int](40 * $scale)), [int](48 * $scale))
    $lb1.TextAlign = "MiddleLeft"
    $f.Controls.Add($lb1)

    $lb2 = New-Object System.Windows.Forms.Label
    $lb2.Text = $Message; $lb2.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", [int](10 * $scale))
    $lb2.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 100)
    $lb2.BackColor = [System.Drawing.Color]::FromArgb(242, 242, 247)
    $lb2.Location = New-Object System.Drawing.Point($padX, [int](68 * $scale))
    $lb2.Size = New-Object System.Drawing.Size(($pw - $padX * 2), [int](90 * $scale))
    $lb2.TextAlign = "TopLeft"
    $f.Controls.Add($lb2)

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = "确定"
    $btn.Size = New-Object System.Drawing.Size([int](80 * $scale), [int](32 * $scale))
    $btn.Location = New-Object System.Drawing.Point(($pw - [int](116 * $scale)), ($ph - [int](60 * $scale)))
    $btn.FlatStyle = "Flat"; $btn.BackColor = [System.Drawing.Color]::FromArgb(59, 130, 246)
    $btn.ForeColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
    $btn.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", [int](10 * $scale), [System.Drawing.FontStyle]::Bold)
    $btn.FlatAppearance.BorderSize = 0; $btn.Cursor = [System.Windows.Forms.Cursors]::Hand

    $br = [int](6 * $scale); $bw = [int](80 * $scale); $bh = [int](32 * $scale)
    $bp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $bp.AddArc(0, 0, $br, $br, 180, 90); $bp.AddArc(($bw - $br), 0, $br, $br, 270, 90)
    $bp.AddArc(($bw - $br), ($bh - $br), $br, $br, 0, 90); $bp.AddArc(0, ($bh - $br), $br, $br, 90, 90)
    $bp.CloseFigure(); $btn.Region = New-Object System.Drawing.Region($bp)

    $btn.Add_Click({ $script:popupActivate = $true; $f.Close() })
    $f.Controls.Add($btn)

    $f.ShowDialog() | Out-Null
    $f.Dispose()
    if ($script:popupActivate) { Activate-Terminal }
}

try {
    if ($Mode -eq "popup") { Show-Popup } else { Show-Notify }
} finally {
    if ($mutexOwned) { try { $mutex.ReleaseMutex() } catch {} }
}
