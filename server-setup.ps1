$EzPOSDir = Get-Location
$LogFile = Join-Path $EzPOSDir "AutoUpdateReleaseLog.txt"
$TmpDir = Join-Path $EzPOSDir "tmp"
$ScriptsDir = Join-Path $TmpDir "scripts"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] server-setup: $Message"
    Add-Content -Path $LogFile -Value $entry
    Write-Host $entry
}

Write-Log "Script started"

# Create tmp and tmp/scripts directories
if (Test-Path $TmpDir) {
    Remove-Item -Path $TmpDir -Recurse -Force
}
New-Item -ItemType Directory -Path $ScriptsDir -Force | Out-Null

# TODO: Replace with actual API call to download scripts into tmp/
# Expected: API returns main.ps1 and scripts/*.ps1, saved to $TmpDir and $ScriptsDir
# $response = Invoke-RestMethod -Uri "https://api.example.com/deployment/scripts" ...
# Save main.ps1 → $TmpDir\main.ps1
# Save scripts/*.ps1 → $ScriptsDir\

Write-Log "All scripts downloaded"

# Run the orchestrator
& "$TmpDir\$ScriptsDir\main.ps1"
