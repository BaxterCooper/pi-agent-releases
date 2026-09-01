# Pi Agent desktop releases

This public repository contains the release assets and update manifests for the Pi Agent desktop app.

## Install

The bootstrap performs all downloads over HTTPS and installs only for the current user. It does not require administrator privileges.

### macOS Apple Silicon

One-line install (latest published release):

```sh
curl -fsSL https://raw.githubusercontent.com/BaxterCooper/pi-agent-releases/main/install.sh | bash
```

The shell bootstrap is also available for inspection before execution:

```sh
curl -fsSL https://raw.githubusercontent.com/BaxterCooper/pi-agent-releases/main/install.sh -o install.sh
less install.sh
bash ./install.sh
```

Install an exact version (use a complete semantic version without the leading `v`):

```sh
bash ./install.sh install 1.2.3
```

### Windows x64

One-line install (latest published release):

```powershell
irm https://raw.githubusercontent.com/BaxterCooper/pi-agent-releases/main/install.ps1 | iex
```

That command intentionally executes the fetched bootstrap. To inspect it first, download it to a temporary file and run the reviewed file:

```powershell
$p = Join-Path $env:TEMP 'pi-agent-install.ps1'; try { Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/BaxterCooper/pi-agent-releases/main/install.ps1' -OutFile $p; notepad.exe $p; Read-Host 'After review, press Enter to install'; & $p } finally { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
```

Install an exact version from a checked-out or inspected script:

```powershell
powershell.exe -NoProfile -File .\install.ps1 install 1.2.3
```

## Status and uninstall

Status reads the installed bundle/registry version without contacting GitHub:

```sh
bash ./install.sh status                 # macOS
powershell.exe -NoProfile -File .\install.ps1 status  # Windows
```

Uninstall is likewise local:

```sh
bash ./install.sh uninstall              # macOS
powershell.exe -NoProfile -File .\install.ps1 uninstall  # Windows
```

The macOS bootstrap removes only `~/Applications/Pi Agent.app`, and refuses to remove it unless its readable bundle identity is `dev.baxter.pi-agent` with a semantic version. The Windows bootstrap invokes only the single exact `Pi Agent` uninstall entry registered for the current user; shell and script command registrations are refused.

## Supported platforms and paths

- **Windows:** AMD64/x64 only, using the NSIS `.exe` asset. x86, ARM64, and non-Windows systems fail closed. The NSIS install and uninstall registration stay in the current user's profile/HKCU; no elevation is requested.
- **macOS:** Apple Silicon ARM64 only, using the `_aarch64.dmg` asset. A process running under Rosetta is accepted only when macOS reports real ARM64 translation; Intel Macs are rejected. The app is staged, backed up, replaced, and verified under `~/Applications` on the same volume.
- **Other systems:** unsupported and rejected rather than falling back to another artifact.

## Release and integrity checks

`stable` and `latest` resolve GitHub's latest published, non-draft release. An exact `VERSION` resolves the `vVERSION` tag. The bootstrap requires exactly one platform installer (`*_x64-setup.exe` on Windows or `*_aarch64.dmg` on macOS) and exactly one sidecar whose name is `<installer-name>.sha256`.

The GitHub release API's declared installer size must equal the downloaded byte count. The sidecar must be byte-exact: 64 lowercase SHA-256 hexadecimal characters, two spaces, the exact installer asset name, and one final LF. A size or checksum mismatch stops before execution or installation. HTTPS redirects are restricted to HTTPS.

## Signing caveats

- Windows release installers are currently unsigned. Windows SmartScreen may require **More info** and **Run anyway**.
- macOS releases are currently ad-hoc signed and are not notarized. The first launch may be blocked; use **System Settings → Privacy & Security → Open Anyway** if you trust the reviewed release. The bootstrap never disables Gatekeeper or quarantine checks.

The managed Base distribution downloads this bootstrap and verifies its hash pin before invoking it; it does not pipe unpinned text from the network.
