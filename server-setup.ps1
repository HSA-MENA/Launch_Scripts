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

# Prompt user for credentials
$Pfid = Read-Host "Enter PFID"
$Token = Read-Host "Enter Token"

# Fetch install links from API
$ApiBase = "https://avvxnj2l4urhi5a4aqgbilxkde.apigateway.me-abudhabi-1.oci.customer-oci.com/installs"

Write-Log "Fetching install links for pfid=$Pfid"

try {
    $response = Invoke-RestMethod -Uri "$ApiBase/?pfid=$Pfid&token=$Token" -Method Get
}
catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    if ($statusCode -eq 404) {
        Write-Log "ERROR: pfid/token combination not found (404)"
    }
    elseif ($statusCode -eq 400) {
        Write-Log "ERROR: Token has expired (400)"
    }
    else {
        Write-Log "ERROR: API request failed — $($_.Exception.Message)"
    }
    return
}

Write-Log "Install links received"

# Download server zip
$ZipPath = Join-Path $TmpDir "server.zip"
Write-Log "Downloading server.zip"
Invoke-RestMethod -Uri $response.zipLink -OutFile $ZipPath

# Download mTLS cert
$CertPath = Join-Path $TmpDir "mtls.cert.pem"
Write-Log "Downloading mTLS certificate"
Invoke-RestMethod -Uri $response.certLink -OutFile $CertPath

# Download mTLS key
$KeyPath = Join-Path $TmpDir "mtls.key.pem"
Write-Log "Downloading mTLS key"
Invoke-RestMethod -Uri $response.keyLink -OutFile $KeyPath

Write-Log "All files downloaded"

# Extract server.zip
Write-Log "Extracting server.zip"
Expand-Archive -Path $ZipPath -DestinationPath $TmpDir -Force
Write-Log "server.zip extracted"

# Run the orchestrator
& "$TmpDir\main.ps1"
