$EzPOSDir = Get-Location
$LogFile = Join-Path $EzPOSDir "AutoUpdateReleaseLog.txt"
$TmpDir = Join-Path $EzPOSDir (Get-Date -Format "yyyy-MM-dd")
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
New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null

# Prompt user for credentials
$Pfid = Read-Host "Enter PFID"
$Token = Read-Host "Enter Token"

# Fetch install links from API
$ApiBase = "https://p4kl7bcpyzjeakiedboq3xgw7q.apigateway.me-abudhabi-1.oci.customer-oci.com/installs"

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

# Download zip to tmp dir
$zipFileName = [System.Uri]::new($response.zipLink).Segments[-1]
Write-Log "Downloading $zipFileName"
Invoke-RestMethod -Uri $response.zipLink -OutFile (Join-Path $TmpDir $zipFileName)

# Download certificate and key to Certificate folder
$CertDir = Join-Path $TmpDir "Certificate"
New-Item -ItemType Directory -Path $CertDir -Force | Out-Null

foreach ($link in @($response.certLink, $response.keyLink)) {
    $fileName = [System.Uri]::new($link).Segments[-1]
    $destPath = Join-Path $CertDir $fileName
    Write-Log "Downloading $fileName"
    Invoke-RestMethod -Uri $link -OutFile $destPath
}

$ZipPath = Join-Path $TmpDir ([System.Uri]::new($response.zipLink).Segments[-1])

Write-Log "All files downloaded"

# Extract server.zip
Write-Log "Extracting server.zip"
Expand-Archive -Path $ZipPath -DestinationPath $TmpDir -Force
Write-Log "server.zip extracted"

# Allow local scripts to be run
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process

# Run the orchestrator
& "$ScriptsDir\main-prod.ps1"
