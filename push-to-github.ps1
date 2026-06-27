# =============================================================
#  QueueStorm — commit & push to GitHub
#  Run from PowerShell:  .\push-to-github.ps1
#
#  Auth options (in priority order):
#    1. $env:GITHUB_TOKEN  environment variable (PAT, no prompt)
#    2. Windows Credential Manager (after first successful auth)
#
#  Requires: Git for Windows (https://git-scm.com/download/win)
# =============================================================

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $repoRoot

Write-Host "[1/7] Checking git..." -ForegroundColor Cyan
$git = (Get-Command git -ErrorAction SilentlyContinue)
if (-not $git) {
    Write-Host "Git not found." -ForegroundColor Red
    Write-Host "Install: https://git-scm.com/download/win (restart PowerShell after)" -ForegroundColor Yellow
    exit 1
}
git --version | Out-Host

Write-Host "[2/7] Configuring git identity..." -ForegroundColor Cyan
git config user.name  "brlikhon"
git config user.email "brlikhon@users.noreply.github.com"

Write-Host "[3/7] Initializing repo (if needed)..." -ForegroundColor Cyan
if (-not (Test-Path ".git")) {
    git init -b main | Out-Null
}
git remote remove origin 2>$null
git remote add origin https://github.com/brlikhon/ticketing-system.git

Write-Host "[4/7] Staging files..." -ForegroundColor Cyan
git add -A
$staged = git status --short
if ([string]::IsNullOrWhiteSpace($staged)) {
    Write-Host "Nothing to commit (working tree clean)." -ForegroundColor Yellow
} else {
    Write-Host "Staged:" -ForegroundColor DarkGray
    $staged -split "`n" | Select-Object -First 40 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}

Write-Host "[5/7] Committing..." -ForegroundColor Cyan
$commitMsg = "QueueStorm Investigator — backend + UI + one-shot VM deploy with SSL"
$commitOk = $true
git commit -m $commitMsg 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "No new changes to commit (everything already committed)." -ForegroundColor Yellow
    $commitOk = $false
} else {
    Write-Host "Committed: $commitMsg" -ForegroundColor Green
}

Write-Host "[6/7] Pushing to GitHub..." -ForegroundColor Cyan

# If GITHUB_TOKEN is set, embed it in the URL for this push only (won't be saved)
if ($env:GITHUB_TOKEN) {
    $tokenUrl = "https://brlikhon:$($env:GITHUB_TOKEN)@github.com/brlikhon/ticketing-system.git"
    Write-Host "Using GITHUB_TOKEN from environment (non-interactive)." -ForegroundColor DarkGray
    git push $tokenUrl main --force 2>&1 | Out-Null
    $pushExit = $LASTEXITCODE
} else {
    Write-Host "No GITHUB_TOKEN set; will prompt for credentials." -ForegroundColor DarkGray
    Write-Host "Tip: set `$env:GITHUB_TOKEN = 'ghp_...'  before running for non-interactive auth." -ForegroundColor DarkGray
    git push -u origin main --force 2>&1 | Out-Null
    $pushExit = $LASTEXITCODE
}

Write-Host "[7/7] Verifying..." -ForegroundColor Cyan
if ($pushExit -eq 0) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "  PUSH SUCCESSFUL" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "  Repo:  https://github.com/brlikhon/ticketing-system" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "  1. SSH into your VM"
    Write-Host "  2. git clone https://github.com/brlikhon/ticketing-system.git"
    Write-Host "  3. cd ticketing-system/queuestorm"
    Write-Host "  4. cp .env.example .env && nano .env   # set AISA_API_KEY"
    Write-Host "  5. sudo bash ../deploy.sh"
    Write-Host ""
    Write-Host "Point ticket.brlikhon.engineer -> <VM-PUBLIC-IP> in your DNS first." -ForegroundColor Yellow
    exit 0
} else {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host "  PUSH FAILED" -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host "Common causes:" -ForegroundColor Yellow
    Write-Host "  - GitHub repo doesn't exist yet"
    Write-Host "    -> create at https://github.com/new  (name: ticketing-system)"
    Write-Host ""
    Write-Host "  - Auth failed (password no longer accepted)"
    Write-Host "    -> create a PAT: https://github.com/settings/tokens/new"
    Write-Host "    -> set `$env:GITHUB_TOKEN = 'ghp_...'  and re-run"
    Write-Host ""
    Write-Host "  - Remote branch protection / permissions"
    Write-Host "    -> make sure you're pushing to your own repo (brlikhon/ticketing-system)"
    Write-Host "============================================================" -ForegroundColor Red
    exit 1
}