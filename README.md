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

Prefer v2 for anything new. The manifest contract is documented in
[`Remote/websocket_service`](../../Remote/websocket_service) — `manifest-contract-readme.md` and the
"Installs V2 Flow" section of its README.

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
short-lived, so each run needs a new one. Install evidence is captured in
[`Testing/autoUpdateInstall`](../../Testing/autoUpdateInstall).
