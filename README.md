# PsiphonLinux

Installer and management CLI for Psiphon on Linux (AMD64/x86_64).

## Repository Structure

```
.
├── binary/                    # Psiphon binary & checksum
│   ├── psiphon-tunnel-core-x86_64
│   └── psiphon-tunnel-core-x86_64.sha256
├── config/                    # Default configuration
│   └── psiphon.config
├── systemd/                   # Systemd service unit
│   └── psiphon.service
├── tests/                     # Test suite (sandboxed, safe to run anywhere)
│   └── test.sh
├── .gitattributes             # Forces LF line endings
├── .github/workflows/         # CI/CD
│   ├── tests.yml
│   └── update-psiphon-binary.yml
├── pinstaller.sh              # Installer script
├── psiphon                    # Management CLI
└── README.md
```

## Prerequisites

- Linux system with **systemd** (for service management) or ability to run foreground
- **AMD64 (x86_64)** architecture only
- Root/sudo access
- `curl`, `jq`, `readelf` (binutils), `useradd`, `flock`, `setpriv` or `runuser` (util-linux), `systemd`
```bash
apt install curl jq binutils util-linux
```

## Features

- **Service management**: `start`, `stop`, `restart`, `status`, `enable`, `disable`, `logs`
- **Foreground mode**: `run` (for containers/debugging without systemd)
- **Configuration**: `region`, `httpport`, `socksport`, `loglevel`, `config` (view)
- **Maintenance**: `update` (verified binary from Psiphon-Labs), `version`, `ip`/`checkip`
- **Complete uninstall**: `uninstall`
- **Runs unprivileged**: the service (and `psiphon run`) use a dedicated `psiphon` system user, never root
- **Security-hardened systemd service**: no-new-privileges, private tmp/devices, `ProtectSystem=strict` (writable only: `/var/lib/psiphon`), restricted address families and namespaces
- **Verified updates**: mandatory SHA256 check, ELF64/AMD64 validation and a smoke test of the new binary *before* the running service is touched; automatic rollback if the new binary does not stay up
- **Safe config changes**: validated, written atomically, backed up (last 5 kept) and automatically reverted if the service no longer starts
- **All operations logged to systemd journal**
- The local HTTP/SOCKS proxies listen on `127.0.0.1` only (Psiphon's default)

## Installation

```bash
# With systemd service (default, recommended)
curl -fsSL https://raw.githubusercontent.com/MHShokuhi/PsiphonLinux/main/pinstaller.sh | sudo bash

# Without systemd (foreground-only, e.g. containers)
curl -fsSL https://raw.githubusercontent.com/MHShokuhi/PsiphonLinux/main/pinstaller.sh | sudo bash -s -- --no-systemd
```

This installs:
- Binary: `/etc/psiphon/psiphon-tunnel-core-x86_64`
- Config: `/etc/psiphon/psiphon.config`
- Manager CLI: `/usr/bin/psiphon`
- Systemd service: `/etc/systemd/system/psiphon.service` (if `--systemd`)

## Uninstalling

```bash
sudo psiphon uninstall
```

Removes binary, config (and backups), data in `/var/lib/psiphon`, the systemd service, the `psiphon` system user, and the CLI. Use `sudo psiphon uninstall -y` to skip the prompt.

## Usage

```bash
psiphon [command] [argument]
```

### Service Management

| Command | Description |
|---------|-------------|
| `start` | Start systemd service |
| `stop` | Stop systemd service |
| `restart` | Restart systemd service |
| `status` | Show detailed service status |
| `enable` | Enable auto-start at boot |
| `disable` | Disable auto-start |
| `run` | Run in foreground (blocks; Ctrl+C to stop) |
| `logs` | Follow systemd journal (`journalctl -fu psiphon`) |

### Configuration

| Command | Description | Example |
|---------|-------------|---------|
| `region CODE` | Change egress region | `sudo psiphon region DE` |
| `httpport PORT` | Change HTTP proxy port (default 40005) | `sudo psiphon httpport 40005` |
| `socksport PORT` | Change SOCKS proxy port (default 40004) | `sudo psiphon socksport 40004` |
| `loglevel LEVEL` | Change log level: debug/info/warn/error | `sudo psiphon loglevel debug` |
| `config` | Display current configuration (JSON) | `psiphon config` |

Valid regions: `AT AU BE BG CA CH CZ DE DK EE ES FI FR GB HR HU IE IN IT JP LV NL NO PL PT RO RS SE SG SK US`

Notes:
- Ports must be between 1 and 65535 and the HTTP and SOCKS ports must differ. They are stored as JSON numbers (Psiphon refuses to start if they are strings).
- Psiphon has no `LogLevel` option of its own. `loglevel debug` therefore also turns on `EmitDiagnosticNotices` (verbose output); any other level turns it off. View output with `sudo psiphon logs`.

### Maintenance

| Command | Description |
|---------|-------------|
| `update` | Download & verify latest binary from Psiphon-Labs |
| `version` | Show version, binary SHA256, service state |
| `ip` / `checkip` | Show exit IP through Psiphon SOCKS proxy |
| `uninstall` | Remove everything |

### Examples

```bash
# Start service
sudo psiphon start

# Check status
sudo psiphon status

# Change region to Germany
sudo psiphon region DE

# Change HTTP proxy port
sudo psiphon httpport 8081

# View current config
psiphon config

# Check exit IP
sudo psiphon ip

# Follow logs
sudo psiphon logs

# Update binary
sudo psiphon update

# Run without systemd (foreground)
sudo psiphon run
```

## Configuration File

Location: `/etc/psiphon/psiphon.config`

```json
{
  "LocalHttpProxyPort": 8080,
  "LocalSocksProxyPort": 1080,
  "EgressRegion": "US",
  "LogLevel": "info",
  "PropagationChannelId": "...",
  "SponsorId": "...",
  "RemoteServerListSignaturePublicKey": "...",
  "RemoteServerListUrl": "..."
}
```

- Only the first four keys are user-configurable via `psiphon` CLI
- The file must be plain UTF-8 JSON **without a BOM** (the installer normalises this; Psiphon's parser rejects a BOM)
- The rest are Psiphon internals (do not modify unless you know what you're doing)
- Changes via CLI are atomic (backup created, service restarted if running)

## Systemd Service Hardening

The installed service includes:

- `User=psiphon` / `StateDirectory=psiphon` (unprivileged; data in `/var/lib/psiphon`)
- `NoNewPrivileges=true`, `PrivateTmp=true`, `PrivateDevices=true`
- `ProtectSystem=strict`, `ProtectHome=true`, kernel/clock/hostname protections
- `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK`, `RestrictNamespaces=true`
- `CapabilityBoundingSet=CAP_NET_BIND_SERVICE` (only needed for ports <1024; remove both capability lines otherwise)
- `Restart=on-failure` with `RestartSec=5s`
- Resource limits: `LimitNOFILE=65536`

`MemoryDenyWriteExecute` is deliberately **not** set: the official binary is UPX-packed and needs to unpack itself in memory.

If a future Psiphon release needs more access, `sudo journalctl -u psiphon` shows the failure; relax the relevant line in `/etc/systemd/system/psiphon.service` and run `sudo systemctl daemon-reload && sudo systemctl restart psiphon`.

## Binary Updates

The `update` command:
1. Downloads the latest binary + SHA256 from **this repository** (kept in sync with the official Psiphon-Labs binary by a workflow) over HTTPS
2. Refuses to continue without a valid checksum; verifies SHA256
3. Validates ELF64 + AMD64 via `readelf` and smoke-tests the new binary (`-v`)
4. Exits early if you already have that exact binary
5. Only then stops the service (if running) and atomically swaps the binary
6. Restarts the service and requires it to stay up for several seconds
7. **Rolls back automatically** if the new binary does not stay up

Trust model: the checksum lives in the same repository as the binary, so it protects against corruption and partial downloads, not against a compromised repository. Review the repo (or pin to a commit) if that matters for you.

## GitHub Actions (for maintainers)

- **`.github/workflows/tests.yml`** — Runs on every push/PR: syntax, ShellCheck, then `tests/test.sh`
- **`.github/workflows/update-psiphon-binary.yml`** — Runs every 6 hours in a single job: fetches the official binary from Psiphon-Labs, validates it (size, ELF, runs `-v`), runs the full test suite against it, and only then commits to `binary/` if it changed. If `main` is branch-protected, allow `github-actions[bot]` to push or switch the workflow to open a pull request.

### Running the tests

```bash
bash tests/test.sh
```

The suite needs `jq` (and benefits from `shellcheck`, `systemd-analyze`, `readelf`). All state-changing checks run in a temporary sandbox with a fake `systemctl`; nothing outside the temp directory is touched, even if Psiphon is installed on the machine.

Make sure the scripts keep their executable bit in git:

```bash
git update-index --chmod=+x pinstaller.sh psiphon tests/test.sh
```

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Service keeps restarting | `sudo psiphon logs`; a config error shows as `error processing configuration file` |
| `psiphon ip` fails | Service must be running; the first connection can take a minute |
| Port already in use | `sudo psiphon httpport 8081` / `socksport 1081` |
| Upgrading from 1.0.x | Just re-run the installer; your config is kept (and repaired if it has a BOM or string ports). The service now runs as `psiphon`, not root |

## License

MIT — see [LICENSE](LICENSE).