<!-- README-VERIFIED: 2b8c8c3 -->

# Launch Scripts

The bootstrap step of every customer install. A single PowerShell script that staff run on the
target machine: it prompts for a PFID and token, asks the install API what to download, builds the
package folder structure, fetches the files, and hands off to the entrypoint script.

Deliberately a **public repo with no sensitive details** — it is fetched onto customer machines, so
it holds no credentials and no use-case knowledge. Execution requires a valid ID and token, which
gate everything else. All layout and content decisions come from the API at run time.

> No manifest file exists in this repo, so the staleness stamp above is the git short SHA rather
> than a version number.

## Where it sits

```
staff run server-setup.ps1
        │  GET /installs (v1) or /installs/v2 (v2), with pfid + token
        ▼
  websocket_service ──▶ validates the token, returns file list / manifest
        │
        ▼
  OCI Object Storage ──▶ scripts, apps, backups, certs downloaded
        │
        ▼
  entrypoint script from Release_Scripts runs the actual install
```

The API is [`Remote/websocket_service`](../../Remote/websocket_service) (`installs_controller.js`);
the scripts it points at are [`Release_Scripts`](../Release_Scripts).

## Source layout

Four scripts — two versions × two environments. qa and prod are identical apart from the API
gateway hostname.

| Path | Version | Environment |
|---|---|---|
| `qa/server-setup.ps1` | v1 | QA |
| `prod/server-setup.ps1` | v1 | Production |
| `qa/v2/server-setup.ps1` | v2 | QA |
| `prod/v2/server-setup.ps1` | v2 | Production |

### v1 vs v2

**v1** calls `GET /installs?pfid=&token=` and receives a fixed set of links (`zipLink`,
`certLink`, `keyLink`). The folder layout is hardcoded in the script — it creates a date-stamped
temp directory with a `scripts` subfolder. It supports only the one original use case.

**v2** calls `GET /installs/v2?pfid=&token=` and receives a **manifest** describing every file, its
destination, whether to extract it, and what to run afterwards. The script is entirely use-case
agnostic; adding a new install type needs no change here, only a new manifest template
server-side. It pins `$SupportedManifestVersion = 1` and refuses a manifest it does not understand.

v2 creates the standard package skeleton under the manifest's `workDir` — `apps`, `bak`, `certs`,
`resources`, `scripts`, `scripts/common` — even where a use case leaves some empty, because
entrypoint scripts assume they exist.

Prefer v2 for anything new. The manifest contract is documented in the "Installs V2 Flow" section
of [`Remote/websocket_service`](../../Remote/websocket_service)'s README.

### What v2 does beyond downloading

**TLS 1.2 is pinned** on the first executable line. Windows PowerShell 5.1 otherwise takes the OS
default, and on an un-patched box that still offers TLS 1.0/1.1, which the API Gateway refuses —
so the very first request fails with a connection error that reads like the machine has no
internet.

**Downloads are verified against the published digest.** A manifest entry may carry `sha256`,
which the API reads out of that version's `release.json` — the provenance record CI wrote beside
the artifacts. The launcher hashes the file and compares case-insensitively:

- Archives are checked **before** `Expand-Archive`, so an archive that does not match is never
  unpacked and cannot put a single file on the box.
- Plain files are checked while still named `.partial`, so a file that fails never reaches the
  name a rerun would treat as already present.
- A mismatch **deletes the file**, logs `checksum mismatch for <id>` with both digests, and aborts
  before the entrypoint. Deleting matters: leaving it would let a rerun skip the download and
  quietly install the bytes that just failed.
- Entries without `sha256` — certificates, scripts, anything not published under
  `apps/<app>/versions/<v>/` — are placed exactly as before. An absent digest means "nothing to
  check", never "check passed".

**The token is consumed** once every file has landed and before the entrypoint runs:
`PUT /installs/{pfid}/{token}` with the machine's primary MAC. The MAC is selected and formatted
the same way `DbBackupService` does it, so the console shows one MAC per box rather than two.

A failure here is logged as a warning and the install continues — this is bookkeeping for the
console, and a pharmacy install must never fail because a status update did not land.

> **Rerunning after this point.** The token no longer resolves, so re-running `server-setup.ps1`
> gets a `404`. That is deliberate: the token's job was to authorise the downloads, and they are
> done. Recover a failed install by running the entrypoint directly out of the staging folder:
>
> ```powershell
> cd <workDir>\scripts
> .\main.ps1 -Pfid <PFID> -Environment <qa|prod>    # arguments as the manifest supplied them
> ```
>
> To start over from scratch, delete the `workDir` and issue a new token.

## Security note

v2 validates every server-supplied path before using it (`Resolve-SafePath`): no rooted paths, no
drive letters, no `..` traversal, and the resolved path must stay inside `workDir`. The API is
trusted, but this runs with privilege on customer machines, so paths are checked anyway. Preserve
that check in any edit.

## Local execution

Requires Windows, PowerShell, and a valid PFID + token issued through the Admin Console
([`Remote/EzPOS_Admin_Console`](../../Remote/EzPOS_Admin_Console) → Tokens).

```powershell
cd <target install directory>
.\server-setup.ps1
# prompts: Enter PFID / Enter Token
```

Run it from the directory that should become the install root — both versions derive their paths
from `Get-Location`.

Logging: v1 writes `AutoUpdateReleaseLog.txt`, v2 writes `releaseLog.txt`, both in the working
directory and both timestamped.

## Testing

No automated tests. Verify against QA with a freshly-issued token; tokens are single-use and
short-lived, so each run needs a new one — and since v2 now consumes the token itself, a rerun
needs a new one too.

Both v2 scripts must stay **byte-identical apart from `$ApiBase`**. That is the only intended
difference, and it is worth checking before opening a PR:

```powershell
diff qa\v2\server-setup.ps1 prod\v2\server-setup.ps1
```

**Keep the `.ps1` files ASCII.** They are delivered with `irm | iex`, which decodes UTF-8 over
HTTP, but a copy saved to disk has no BOM — and Windows PowerShell 5.1 then reads it in the ANSI
codepage, where a UTF-8 em dash becomes a curly quote that the parser treats as a **string
terminator**. The file stops parsing partway through, with errors pointing nowhere near the real
cause. Check with:

```powershell
$e = $null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\qa\v2\server-setup.ps1).Path, [ref]$null, [ref]$e)
$e   # must be empty, under Windows PowerShell 5.1 specifically
```
