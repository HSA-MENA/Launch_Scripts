# Generic manifest-driven launcher (v2).
# Prompts for PFID + token, asks the install API for a manifest describing every
# file to download, where it goes, and what to run next, then executes it. The
# script itself is use-case agnostic — all layout knowledge comes from the API.

$SupportedManifestVersion = 1
$ApiBase = "https://p4kl7bcpyzjeakiedboq3xgw7q.apigateway.me-abudhabi-1.oci.customer-oci.com"

# Standard package skeleton created under every workDir, even when a given use
# case leaves some folders empty (entrypoint scripts may assume they exist).
$Skeleton = @("apps", "bak", "certs", "resources", "scripts", "scripts/common")

$EzPOSDir = Get-Location
$LogFile = Join-Path $EzPOSDir "AutoUpdateReleaseLog.txt"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] server-setup: $Message"
    Add-Content -Path $LogFile -Value $entry
    Write-Host $entry
}

# Reject anything that isn't a plain relative path contained within the workDir:
# no rooted paths, no drive letters, no `..` traversal. The API is trusted, but
# this runs on customer machines so we validate server-supplied paths anyway.
function Resolve-SafePath {
    param(
        [string]$Root,       # absolute path the result must stay within
        [string]$Relative    # server-supplied relative path
    )

    $clean = $Relative -replace '^[.][/\\]', ''   # strip a leading ./ or .\
    $clean = $clean -replace '/', '\'

    if ([string]::IsNullOrWhiteSpace($clean)) {
        return $Root
    }
    if ([System.IO.Path]::IsPathRooted($clean) -or $clean -match '(^|\\)\.\.(\\|$)') {
        throw "Unsafe path rejected: '$Relative'"
    }

    $combined = [System.IO.Path]::GetFullPath((Join-Path $Root $clean))
    $rootFull = [System.IO.Path]::GetFullPath($Root)
    if (-not $combined.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes workDir: '$Relative'"
    }
    return $combined
}

Write-Log "Script started"

# --- Prompt for credentials ---------------------------------------------------
$Pfid = Read-Host "Enter PFID"
$Token = Read-Host "Enter Token"

# --- Fetch the manifest -------------------------------------------------------
Write-Log "Fetching manifest for pfid=$Pfid"

try {
    $response = Invoke-RestMethod -Uri "$ApiBase/installs/v2?pfid=$Pfid&token=$Token" -Method Get
}
catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    switch ($statusCode) {
        400 { Write-Log "ERROR: Token has expired (400)" }
        404 { Write-Log "ERROR: pfid/token combination not found (404)" }
        422 { Write-Log "ERROR: No install manifest is configured for this token's use case (422)" }
        default { Write-Log "ERROR: API request failed — $($_.Exception.Message)" }
    }
    return
}

# --- Validate the manifest ----------------------------------------------------
if ($response.manifestVersion -ne $SupportedManifestVersion) {
    Write-Log "ERROR: Unsupported manifestVersion $($response.manifestVersion) (this launcher supports $SupportedManifestVersion). Please update the launcher."
    return
}

Write-Log "Manifest received: type=$($response.type), workDir=$($response.workDir)"

# --- Create the workDir + full skeleton ---------------------------------------
try {
    $WorkDir = Resolve-SafePath -Root $EzPOSDir -Relative $response.workDir
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    return
}

if (Test-Path $WorkDir) {
    Remove-Item -Path $WorkDir -Recurse -Force
}
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

foreach ($dir in $Skeleton) {
    New-Item -ItemType Directory -Path (Join-Path $WorkDir $dir) -Force | Out-Null
}
Write-Log "Created workDir and folder skeleton"

# --- Download (and extract) every file ----------------------------------------
# Everything must succeed before we run the entrypoint; abort on any failure.
foreach ($file in $response.files) {
    try {
        $destDir = Resolve-SafePath -Root $WorkDir -Relative $file.dest
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null

        if ($file.extract) {
            # Stage the archive inside its destination, expand it, then discard it.
            $archiveName = [System.Uri]::UnescapeDataString([System.Uri]::new($file.url).Segments[-1])
            $archivePath = Join-Path $destDir $archiveName
            Write-Log "Downloading $($file.id) -> $($file.dest) (extract)"
            Invoke-WebRequest -Uri $file.url -OutFile $archivePath -UseBasicParsing
            Expand-Archive -Path $archivePath -DestinationPath $destDir -Force
            Remove-Item -Path $archivePath -Force
        }
        else {
            $fileName = if ($file.PSObject.Properties['filename'] -and $file.filename) {
                $file.filename
            }
            else {
                [System.Uri]::UnescapeDataString([System.Uri]::new($file.url).Segments[-1])
            }
            $destPath = Join-Path $destDir $fileName
            Write-Log "Downloading $($file.id) -> $($file.dest)\$fileName"
            Invoke-WebRequest -Uri $file.url -OutFile $destPath -UseBasicParsing
        }
    }
    catch {
        Write-Log "ERROR: Failed to download/extract '$($file.id)' — $($_.Exception.Message). Aborting before entrypoint."
        return
    }
}

Write-Log "All files downloaded and placed"

# --- Run the entrypoint (if the manifest provides one) ------------------------
# A manifest may omit the entrypoint for use cases where staff perform manual
# steps and launch the next script themselves. In that case we stage the files
# and stop cleanly.
if (-not ($response.entrypoint -and $response.entrypoint.path)) {
    Write-Log "No entrypoint in manifest — files staged under $($response.workDir). Manual steps required; run the appropriate script yourself when ready."
    return
}

# --- Run the entrypoint -------------------------------------------------------
try {
    $EntrypointPath = Resolve-SafePath -Root $WorkDir -Relative $response.entrypoint.path
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    return
}

if (-not (Test-Path $EntrypointPath)) {
    Write-Log "ERROR: Entrypoint not found at $($response.entrypoint.path)"
    return
}

$EntrypointArgs = @()
if ($response.entrypoint.args) {
    $EntrypointArgs = $response.entrypoint.args
}

# Allow local (downloaded) scripts to run for this process only.
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process

Write-Log "Running entrypoint $($response.entrypoint.path)"
& $EntrypointPath @EntrypointArgs
