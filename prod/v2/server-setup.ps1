# Generic manifest-driven launcher (v2).
# Prompts for PFID + token, asks the install API for a manifest describing every
# file to download, where it goes, and what to run next, then executes it. The
# script itself is use-case agnostic - all layout knowledge comes from the API.

# Before any network call. Windows PowerShell 5.1 defaults to whatever the OS
# negotiates, and on an un-patched Windows box that still includes TLS 1.0/1.1 -
# which the API Gateway refuses, so the very first request fails with a connection
# error that reads like the box has no internet. Pinned rather than added to,
# because nothing this script talks to accepts anything older.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$SupportedManifestVersion = 1
$ApiBase = "https://p4kl7bcpyzjeakiedboq3xgw7q.apigateway.me-abudhabi-1.oci.customer-oci.com"

# Standard package skeleton created under every workDir, even when a given use
# case leaves some folders empty (entrypoint scripts may assume they exist).
$Skeleton = @("apps", "bak", "certs", "resources", "scripts", "scripts/common")

$EzPOSDir = Get-Location
$LogFile = Join-Path $EzPOSDir "releaseLog.txt"

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

# Compare a downloaded file against the digest the manifest carried.
#
# Only artifacts published under apps/<app>/versions/<v>/ have one: the API reads it out of that
# version's release.json, the provenance record CI wrote beside them. Certificates and scripts
# are minted from objects with no release record, so they arrive without a digest and are placed
# as before -- an absent `sha256` is "nothing to check", never "check passed".
#
# A mismatch deletes the file. Leaving it would let a rerun skip the download (the extract marker
# and the already-present check both key on the file being there) and quietly install the bytes
# that just failed verification.
function Test-FileChecksum {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Expected,
        [Parameter(Mandatory)][string]$Id
    )

    $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
    if ($actual -ieq $Expected) {
        Write-Log "verified $Id (sha256 $($actual.ToLower()))"
        return $true
    }

    Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue
    Write-Log "ERROR: checksum mismatch for $Id - expected $($Expected.ToLower()), got $($actual.ToLower())"
    return $false
}

# The MAC recorded against the token, so support can tie a console row to a machine.
#
# Deliberately the same selection and formatting as DbBackupService.GetMacAddress(): same API,
# same ordering, same exclusions, same upper-case hyphenated form. The service reports its MAC to
# check-version-server from the same box, and two different answers for one machine would make
# the console's rows impossible to line up.
function Get-PrimaryMacAddress {
    try {
        $up = @()
        foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($ni.OperationalStatus -ne 'Up') { continue }
            if ($ni.NetworkInterfaceType -eq 'Loopback') { continue }
            if ($ni.NetworkInterfaceType -eq 'Tunnel') { continue }

            # Virtual switches, VPN taps, Bluetooth PANs and Kaspersky's filter adapter all
            # present as ordinary interfaces, and all have a MAC that is not the machine's.
            $desc = ("$($ni.Description) $($ni.Name)").ToLower()
            if ($desc -match 'virtual|vpn|kaspersky|bluetooth') { continue }

            $up += $ni
        }

        # Ethernet first, then wireless, then anything left -- three plain passes rather than a
        # Sort-Object with hashtable expressions, which Windows PowerShell 5.1 will not parse
        # inside this pipeline. 5.1 is the only host a pharmacy box has, so it is the one that
        # has to be able to read this file.
        foreach ($wanted in @('Ethernet', 'Wireless80211', $null)) {
            foreach ($ni in $up) {
                if ($wanted -and $ni.NetworkInterfaceType -ne $wanted) { continue }

                $bytes = $ni.GetPhysicalAddress().GetAddressBytes()
                if ($bytes -and $bytes.Length -gt 0) {
                    $hex = @()
                    foreach ($b in $bytes) { $hex += $b.ToString('X2') }
                    return ($hex -join '-')
                }
            }
        }
    }
    catch {
        Write-Log "WARNING: could not read a MAC address: $($_.Exception.Message)"
    }
    return ""
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
        default { Write-Log "ERROR: API request failed - $($_.Exception.Message)" }
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

# Ensure the workDir + skeleton exist, but DON'T wipe it: keeping already-
# downloaded files lets a rerun after a partial failure skip work that already
# finished. To force a clean reinstall, delete the workDir before running.
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

# Completion markers for extracted archives live here (out of the content dirs).
$StateDir = Join-Path $WorkDir ".state"
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

foreach ($dir in $Skeleton) {
    New-Item -ItemType Directory -Path (Join-Path $WorkDir $dir) -Force | Out-Null
}
Write-Log "Ensured workDir and folder skeleton"

# --- Download (and extract) every file ----------------------------------------
# Everything must succeed before we run the entrypoint; abort on any failure.
foreach ($file in $response.files) {
    try {
        $destDir = Resolve-SafePath -Root $WorkDir -Relative $file.dest
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null

        if ($file.extract) {
            # A marker is written only after a successful expand, so a completed
            # extraction is skipped on rerun while a failed/partial one (no
            # marker) is retried.
            $marker = Join-Path $StateDir "$($file.id).extracted"
            if (Test-Path $marker) {
                Write-Log "Skipping $($file.id) -> $($file.dest) (already extracted)"
                continue
            }
            # Stage the archive inside its destination, expand it, then discard it.
            $archiveName = [System.Uri]::UnescapeDataString([System.Uri]::new($file.url).Segments[-1])
            $archivePath = Join-Path $destDir $archiveName
            Write-Log "Downloading $($file.id) -> $($file.dest) (extract)"
            Invoke-WebRequest -Uri $file.url -OutFile $archivePath -UseBasicParsing

            # Checked BEFORE expanding: an archive that does not match is never unpacked, so a
            # corrupted or substituted download cannot put a single file on the box.
            if ($file.PSObject.Properties['sha256'] -and $file.sha256) {
                if (-not (Test-FileChecksum -Path $archivePath -Expected $file.sha256 -Id $file.id)) {
                    Write-Log "Aborting before entrypoint."
                    return
                }
            }

            Expand-Archive -Path $archivePath -DestinationPath $destDir -Force
            Remove-Item -Path $archivePath -Force
            New-Item -ItemType File -Path $marker -Force | Out-Null
        }
        else {
            $fileName = if ($file.PSObject.Properties['filename'] -and $file.filename) {
                $file.filename
            }
            else {
                [System.Uri]::UnescapeDataString([System.Uri]::new($file.url).Segments[-1])
            }
            $destPath = Join-Path $destDir $fileName
            if (Test-Path $destPath) {
                Write-Log "Skipping $($file.id) -> $($file.dest)\$fileName (already present)"
                continue
            }
            # Download to a temp file and rename on success, so an interrupted
            # download never leaves a truncated file that a rerun would skip.
            $tempPath = "$destPath.partial"
            Write-Log "Downloading $($file.id) -> $($file.dest)\$fileName"
            Invoke-WebRequest -Uri $file.url -OutFile $tempPath -UseBasicParsing

            # Checked while it is still .partial, so a file that fails never reaches the name a
            # rerun would treat as already present.
            if ($file.PSObject.Properties['sha256'] -and $file.sha256) {
                if (-not (Test-FileChecksum -Path $tempPath -Expected $file.sha256 -Id $file.id)) {
                    Write-Log "Aborting before entrypoint."
                    return
                }
            }

            Move-Item -Path $tempPath -Destination $destPath -Force
        }
    }
    catch {
        Write-Log "ERROR: Failed to download/extract '$($file.id)' - $($_.Exception.Message). Aborting before entrypoint."
        return
    }
}

Write-Log "All files downloaded and placed"

# --- Consume the token --------------------------------------------------------
# Here, and not later: the token's job is to authorise these downloads, and they are done. A
# failed entrypoint is recovered by re-running scripts\main.ps1 out of the staging folder, not by
# downloading everything again -- so holding the token open for that would protect nothing.
#
# **After this point the token no longer resolves.** A rerun of THIS script gets a 404. Re-run
# the entrypoint directly instead; see the README.
#
# A failure here is a warning, never fatal. This is bookkeeping for the console, and a pharmacy
# install must not fail because a status update did not land.
try {
    $mac = Get-PrimaryMacAddress
    $body = @{ MAC = $mac } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Put -Uri "$ApiBase/installs/$Pfid/$Token" `
        -ContentType "application/json" -Body $body | Out-Null
    Write-Log "token marked used (MAC $mac)"
}
catch {
    Write-Log "WARNING: could not mark the token used - $($_.Exception.Message). The install continues; mark it in the Admin Console by hand."
}

# --- Run the entrypoint (if the manifest provides one) ------------------------
# A manifest may omit the entrypoint for use cases where staff perform manual
# steps and launch the next script themselves. In that case we stage the files
# and stop cleanly.
if (-not ($response.entrypoint -and $response.entrypoint.path)) {
    Write-Log "No entrypoint in manifest - files staged under $($response.workDir). Manual steps required; run the appropriate script yourself when ready."
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

# The manifest sends args as a flat list: "-Name", "value", "-Switch", ... Splatting that ARRAY
# binds every element positionally -- "-Pfid" is just a string there, not a parameter name, so
# the pfid landed in -Environment. A HASHTABLE splat binds by name, so fold the list into one.
$EntrypointNamed = @{}
$EntrypointPositional = @()
if ($response.entrypoint.args) {
    $rawArgs = @($response.entrypoint.args)
    for ($i = 0; $i -lt $rawArgs.Count; $i++) {
        $a = [string]$rawArgs[$i]
        if ($a -match '^-([A-Za-z]\w*)$') {
            $name = $Matches[1]
            $next = if ($i + 1 -lt $rawArgs.Count) { [string]$rawArgs[$i + 1] } else { $null }
            if ($null -ne $next -and $next -notmatch '^-[A-Za-z]\w*$') {
                $EntrypointNamed[$name] = $next
                $i++
            } else {
                $EntrypointNamed[$name] = $true   # a bare switch
            }
        } else {
            $EntrypointPositional += $a
        }
    }
}

# Allow local (downloaded) scripts to run for this process only.
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process

Write-Log "Running entrypoint $($response.entrypoint.path)"
& $EntrypointPath @EntrypointNamed @EntrypointPositional
