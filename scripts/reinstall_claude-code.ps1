# reinstall-claude-code.ps1
$ErrorActionPreference = "Stop"

Write-Host "[1] Désinstallation npm globale…"
try {
    npm uninstall -g @anthropic-ai/claude-code | Out-Null
} catch {}

Write-Host "[2] Nettoyage du cache npm…"
try {
    npm cache clean --force | Out-Null
} catch {}

Write-Host "[3] Suppression des restes…"
$npmGlobal = npm prefix -g
$modulePath = Join-Path $npmGlobal "node_modules\@anthropic-ai\claude-code"
$binPath1   = Join-Path $npmGlobal "claude.ps1"
$binPath2   = Join-Path $npmGlobal "claude.cmd"

if (Test-Path $modulePath) {
    Remove-Item -Recurse -Force $modulePath
}

if (Test-Path $binPath1) {
    Remove-Item -Force $binPath1
}

if (Test-Path $binPath2) {
    Remove-Item -Force $binPath2
}

Write-Host "[4] Vérification Node/npm…"
node -v
npm -v

Write-Host "[5] Réinstallation propre de Claude Code…"
npm install -g @anthropic-ai/claude-code@latest

Write-Host "[6] Vérification installation…"
try {
    claude --version
} catch {
    Write-Warning "Claude non détecté dans le PATH"
}