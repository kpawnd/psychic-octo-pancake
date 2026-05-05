#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TASK_NAME      = 'SteamCMD - Lab Game Updater'
$UPDATER_SCRIPT = 'C:\SteamCMD\Update-Games.ps1'
$UPDATE_RUNSCRIPT = 'C:\SteamCMD\scripts\update_all_games.txt'

function Write-Step ([string]$msg) { Write-Host "> $msg" -ForegroundColor Yellow }
function Write-OK   ([string]$msg) { Write-Host "[OK]   $msg" -ForegroundColor Green }
function Write-Info ([string]$msg) { Write-Host "[INFO] $msg" -ForegroundColor Gray }
function Write-Warn ([string]$msg) { Write-Host "[WARN] $msg" -ForegroundColor DarkYellow }

Write-Step 'Removing SteamCMD auto-update service'

# Scheduled task
Write-Info "Checking scheduled task: '$TASK_NAME'"
$task = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
if ($task) {
    Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false
    Write-OK "Scheduled task removed: '$TASK_NAME'"
} else {
    Write-Info "Scheduled task not found - already removed or never registered."
}

# Updater script
Write-Info "Checking: $UPDATER_SCRIPT"
if (Test-Path $UPDATER_SCRIPT) {
    Remove-Item $UPDATER_SCRIPT -Force
    Write-OK "Deleted: $UPDATER_SCRIPT"
} else {
    Write-Info "Not found: $UPDATER_SCRIPT"
}

# Update runscript
Write-Info "Checking: $UPDATE_RUNSCRIPT"
if (Test-Path $UPDATE_RUNSCRIPT) {
    Remove-Item $UPDATE_RUNSCRIPT -Force
    Write-OK "Deleted: $UPDATE_RUNSCRIPT"
} else {
    Write-Info "Not found: $UPDATE_RUNSCRIPT"
}

Write-OK 'Cleanup complete.'
