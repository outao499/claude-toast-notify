param(
    [string]$InstallDir = "$env:USERPROFILE\.claude\plugins\marketplaces\claude-toast-notify"
)

$ErrorActionPreference = "Stop"

Write-Host "== Claude Toast Notify Installer ==" -ForegroundColor Cyan
Write-Host ""

# ── Check prerequisites ──
$claudeSettings = "$env:USERPROFILE\.claude\settings.json"
if (-not (Test-Path $claudeSettings)) {
    Write-Host "[!] Claude Code not found: missing $claudeSettings" -ForegroundColor Yellow
    Write-Host "    Install Claude Code first, then run this script again." -ForegroundColor Yellow
    exit 1
}

# ── Download plugin ──
if (Test-Path $InstallDir) {
    Write-Host "[*] Updating existing installation at $InstallDir" -ForegroundColor Yellow
    & git -C $InstallDir pull --ff-only
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[!] Git pull failed, will re-clone" -ForegroundColor Yellow
        Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Path $InstallDir)) {
    Write-Host "[*] Downloading claude-toast-notify..." -ForegroundColor Green
    $parent = Split-Path $InstallDir -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    & git clone https://github.com/outao499/claude-toast-notify.git $InstallDir
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[!] Failed to clone repository" -ForegroundColor Red
        exit 1
    }
}

# ── Register marketplace in settings.json ──
Write-Host "[*] Registering marketplace in Claude Code settings..." -ForegroundColor Green
$settings = Get-Content $claudeSettings -Raw -Encoding UTF8
if (-not $settings) { $settings = "{}" }

$json = $settings | ConvertFrom-Json
if (-not $json.extraKnownMarketplaces) {
    $json | Add-Member -NotePropertyName "extraKnownMarketplaces" -NotePropertyValue @{} -Force
}

$marketplaceKey = "claude-toast-notify-marketplace"
$json.extraKnownMarketplaces | Add-Member -NotePropertyName $marketplaceKey -NotePropertyValue @{
    source = @{
        path = $InstallDir
        source = "directory"
    }
} -Force

$json | ConvertTo-Json -Depth 10 | Set-Content $claudeSettings -Encoding UTF8

Write-Host ""
Write-Host "== Install complete! ==" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Restart Claude Code"
Write-Host "  2. Run inside Claude Code:"
Write-Host "     /plugin install claude-toast-notify@claude-toast-notify-marketplace"
Write-Host ""
Write-Host "Or install from GitHub directly (inside Claude Code):"
Write-Host "     /plugin marketplace add outao499/claude-toast-notify"
Write-Host "     /plugin install claude-toast-notify@claude-toast-notify"
