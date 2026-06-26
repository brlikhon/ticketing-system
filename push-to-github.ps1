# =============================================================
#  QueueStorm — commit & push to GitHub
#  Run from PowerShell:  .\push-to-github.ps1
#  Requires: Git for Windows installed (https://git-scm.com/download/win)
# =============================================================

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $repoRoot

Write-Host "[1/6] Checking git..." -ForegroundColor Cyan
git --version | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Git not found. Install from https://git-scm.com/download/win then re-run." -ForegroundColor Red
    exit 1
}

Write-Host "[2/6] Configuring git identity..." -ForegroundColor Cyan
git config user.name  "brlikhon"
git config user.email "brlikhon@users.noreply.github.com"

Write-Host "[3/6] Initializing repo (if needed)..." -ForegroundColor Cyan
if (-not (Test-Path ".git")) {
    git init -b main
}
git remote remove origin 2>$null
git remote add origin https://github.com/brlikhon/ticketing-system.git

Write-Host "[4/6] Staging files..." -ForegroundColor Cyan
git add -A
git status --short | Select-Object -First 30

Write-Host "[5/6] Committing..." -ForegroundColor Cyan
git commit -m "QueueStorm Investigator — backend + UI + one-shot VM deploy" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Nothing to commit (or commit failed). Continuing to push..." -ForegroundColor Yellow
}

Write-Host "[6/6] Pushing to GitHub..." -ForegroundColor Cyan
git push -u origin main --force

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "✓ Pushed successfully" -ForegroundColor Green
    Write-Host "  Repo: https://github.com/brlikhon/ticketing-system" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "  1. SSH into your VM"
    Write-Host "  2. git clone https://github.com/brlikhon/ticketing-system.git"
    Write-Host "  3. cd ticketing-system/queuestorm"
    Write-Host "  4. cp .env.example .env && nano .env   # set AISA_API_KEY"
    Write-Host "  5. sudo bash deploy.sh"
    Write-Host ""
    Write-Host "Point ticket.brlikhon.engineer -> <VM-PUBLIC-IP> in your DNS first." -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host "✗ Push failed." -ForegroundColor Red
    Write-Host "  Most likely: GitHub repo doesn't exist yet, or auth failed." -ForegroundColor Red
    Write-Host "  Create it: https://github.com/new  (name: ticketing-system, no README init)" -ForegroundColor Red
    Write-Host "  Auth: use a PAT (https://github.com/settings/tokens/new) — not your password." -ForegroundColor Red
    Write-Host "  After fixing, re-run: .\push-to-github.ps1" -ForegroundColor Red
}