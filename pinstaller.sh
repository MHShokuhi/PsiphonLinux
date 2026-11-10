#!/usr/bin/env bash
# PsiphonLinux Installer
# AMD64 only
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true
umask 022

# ──────────────────────────────────────────────────────────────────────
# Constants
# ──────────────────────────────────────────────────────────────────────

readonly SCRIPT_VERSION="1.0.2"
readonly REPO="MHShokuhi/PsiphonLinux"
readonly BRANCH="main"
readonly BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"

readonly BINARY_SUBDIR="binary"
readonly CONFIG_SUBDIR="config"
readonly SERVICE_SUBDIR="systemd"

readonly INSTALL_DIR="/etc/psiphon"
readonly STATE_DIR="/var/lib/psiphon"
readonly SERVICE_USER="psiphon"
readonly BINARY_NAME="psiphon-tunnel-core-x86_64"
readonly BINARY_PATH="${INSTALL_DIR}/${BINARY_NAME}"
readonly CONFIG_PATH="${INSTALL_DIR}/psiphon.config"
readonly CLI_PATH="/usr/bin/psiphon"
readonly SERVICE_PATH="/etc/systemd/system/psiphon.service"

readonly START_WAIT_SECS=15
readonly STABLE_SECS=5

readonly -a CURL_PROTO_OPTS=(--proto '=https' --proto-redir '=https' --tlsv1.2)
readonly -a CURL_OPTS=(--fail --location --silent --show-error --retry 3 --retry-delay 2 --retry-connrefused --connect-timeout 15)

# ──────────────────────────────────────────────────────────────────────
# Output helpers
# ──────────────────────────────────────────────────────────────────────

have_cmd() { command -v "$1" >/dev/null 2>&1; }

C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE=""
if [[ -t 1 ]] && have_cmd tput && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RESET="$(tput sgr0)"
  C_BOLD="$(tput bold)"
  C_RED="$(tput setaf 1)"
  C_GREEN="$(tput setaf 2)"
  C_YELLOW="$(tput setaf 3)"
  C_BLUE="$(tput setaf 4)"
fi

log_info()    { printf '%s[INFO]%s %s\n'  "${C_BLUE}${C_BOLD}"   "${C_RESET}" "$*"; }
log_warn()    { printf '%s[WARN]%s %s\n'  "${C_YELLOW}${C_BOLD}" "${C_RESET}" "$*" >&2; }
log_error()   { printf '%s[ERROR]%s %s\n' "${C_RED}${C_BOLD}"    "${C_RESET}" "$*" >&2; }
log_success() { printf '%s[OK]%s %s\n'    "${C_GREEN}${C_BOLD}"  "${C_RESET}" "$*"; }
log_debug() {
  if [[ "${PSIPHON_DEBUG:-0}" == "1" ]]; then
    printf '[DEBUG] %s\n' "$*" >&2
  fi
  return 0
}

die() { log_error "$*"; exit 1; }

# ──────────────────────────────────────────────────────────────────────
# State, cleanup and rollback
# ──────────────────────────────────────────────────────────────────────

TEMP_DIR=""
BACKUP_DIR=""
SYSTEMD_MODE="yes"
SERVICE_WAS_ACTIVE="no"

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
  return 0
}

restore_one() {
  local name="$1" target="$2" mode="$3"
  if [[ -f "$BACKUP_DIR/$name" ]]; then
    install -m "$mode" "$BACKUP_DIR/$name" "$target" 2>/dev/null || true
  elif [[ -f "$BACKUP_DIR/$name.absent" ]]; then
    rm -f -- "$target"
  fi
}

rollback() {
  local status=$?
  trap - EXIT
  if (( status != 0 )) && [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
    log_warn "Installation failed (exit $status). Restoring previous files..."
    if have_cmd systemctl && [[ -f "$BACKUP_DIR/service.absent" ]]; then
      systemctl disable --now psiphon.service 2>/dev/null || true
    fi
    restore_one binary  "$BINARY_PATH"  755
    restore_one config  "$CONFIG_PATH"  644
    restore_one cli     "$CLI_PATH"     755
    restore_one service "$SERVICE_PATH" 644
    if have_cmd systemctl; then
      systemctl daemon-reload 2>/dev/null || true
      if [[ "$SERVICE_WAS_ACTIVE" == "yes" ]]; then
        systemctl restart psiphon.service 2>/dev/null || true
      fi
    fi
  fi
  cleanup
  exit "$status"
}
trap rollback EXIT

# ──────────────────────────────────────────────────────────────────────
# Usage and argument parsing
# ──────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
PsiphonLinux Installer v${SCRIPT_VERSION}
Usage: sudo bash pinstaller.sh [OPTIONS]

Options:
  --systemd         Install and enable systemd service (default)
  --no-systemd      Install without systemd (manual/foreground only)
  --uninstall       Remove Psiphon completely (same as: sudo psiphon uninstall)
  -h, --help        Show this help

Environment:
  PSIPHON_DEBUG=1   Enable debug output
EOF
}

for arg in "$@"; do
  case "$arg" in
    --systemd)      SYSTEMD_MODE="yes" ;;
    --no-systemd)   SYSTEMD_MODE="no" ;;
    --uninstall)
      [[ -x "$CLI_PATH" ]] || die "Psiphon management command not found at $CLI_PATH. Nothing to uninstall."
      [[ -t 0 ]] || die "Uninstall needs a terminal for confirmation. Run: sudo psiphon uninstall"
      exec "$CLI_PATH" uninstall
      ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "Unknown option: $arg" ;;
  esac
done

# ──────────────────────────────────────────────────────────────────────
# Pre-flight checks
# ──────────────────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || die "Run this installer as root (sudo)."

case "$(uname -m)" in
  x86_64|amd64) ;;
  *) die "Unsupported architecture: $(uname -m). AMD64 (x86_64) required." ;;
esac

require_cmds() {
  local missing=() cmd
  for cmd in "$@"; do
    have_cmd "$cmd" || missing+=("$cmd")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "Missing required commands: ${missing[*]}"
}
require_cmds curl sha256sum readelf install jq awk grep mktemp useradd

if [[ "$SYSTEMD_MODE" == "yes" ]]; then
  have_cmd systemctl || die "systemctl not found. Use --no-systemd if appropriate."
  [[ -d /run/systemd/system ]] || die "Systemd is not running. Use --no-systemd."
fi

fetch() { # URL OUTPUT MAX_SECONDS
  curl "${CURL_OPTS[@]}" "${CURL_PROTO_OPTS[@]}" --max-time "$3" --output "$2" "$1"
}

# ──────────────────────────────────────────────────────────────────────
# Temp dir and backups
# ──────────────────────────────────────────────────────────────────────

TEMP_DIR="$(mktemp -d -t psiphon-install-XXXXXX)"
BACKUP_DIR="$TEMP_DIR/backup"
mkdir -p "$BACKUP_DIR"
log_debug "Temp dir: $TEMP_DIR"

log_info "Creating backups of existing files..."
backup_file() {
  local source="$1" name="$2"
  if [[ -f "$source" ]]; then
    cp -a -- "$source" "$BACKUP_DIR/$name"
    log_debug "Backed up $source"
  else
    : >"$BACKUP_DIR/$name.absent"
  fi
}
backup_file "$BINARY_PATH"  binary
backup_file "$CONFIG_PATH"  config
backup_file "$CLI_PATH"     cli
backup_file "$SERVICE_PATH" service

if have_cmd systemctl && systemctl is-active --quiet psiphon.service 2>/dev/null; then
  SERVICE_WAS_ACTIVE="yes"
fi

# ──────────────────────────────────────────────────────────────────────
# Download and verify the binary
# ──────────────────────────────────────────────────────────────────────

log_info "Downloading Psiphon AMD64 binary..."
fetch "$BASE_URL/${BINARY_SUBDIR}/${BINARY_NAME}" "$TEMP_DIR/$BINARY_NAME" 600 || die "Binary download failed."

log_info "Downloading checksum..."
fetch "$BASE_URL/${BINARY_SUBDIR}/${BINARY_NAME}.sha256" "$TEMP_DIR/binary.sha256" 30 \
  || die "Checksum download failed. Refusing to install an unverified binary."

EXPECTED_HASH="$(awk 'NR==1 {print tolower($1)}' "$TEMP_DIR/binary.sha256")"
[[ "$EXPECTED_HASH" =~ ^[a-f0-9]{64}$ ]] || die "Invalid SHA256 file."

log_info "Verifying SHA256..."
ACTUAL_HASH="$(sha256sum "$TEMP_DIR/$BINARY_NAME" | awk '{print $1}')"
[[ "$ACTUAL_HASH" == "$EXPECTED_HASH" ]] || die "Binary checksum mismatch."

log_info "Verifying ELF format..."
LC_ALL=C readelf -h "$TEMP_DIR/$BINARY_NAME" >"$TEMP_DIR/elf-header" 2>/dev/null || die "Binary is not a valid ELF file."
grep -Eq 'Class:[[:space:]]+ELF64' "$TEMP_DIR/elf-header" || die "Binary is not ELF64."
grep -Eq 'Machine:[[:space:]]+(Advanced Micro Devices X86-64|AMD x86-64)' "$TEMP_DIR/elf-header" || die "Binary is not AMD64."

chmod 755 "$TEMP_DIR/$BINARY_NAME"

# ──────────────────────────────────────────────────────────────────────
# Download the management script
# ──────────────────────────────────────────────────────────────────────

log_info "Downloading management script..."
fetch "$BASE_URL/psiphon" "$TEMP_DIR/psiphon" 30 || die "Management script download failed."

head -n 1 "$TEMP_DIR/psiphon" | grep -Fxq '#!/usr/bin/env bash' || die "Management script has an unexpected header."
bash -n "$TEMP_DIR/psiphon" || die "Management script syntax validation failed."
grep -Fq "readonly SCRIPT_VERSION=\"${SCRIPT_VERSION}\"" "$TEMP_DIR/psiphon" \
  || log_warn "Downloaded script version differs from installer (expected ${SCRIPT_VERSION}); CDN cache may be stale."

chmod 755 "$TEMP_DIR/psiphon"

# ──────────────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────

log_info "Checking configuration..."
if [[ ! -f "$CONFIG_PATH" ]]; then
  log_info "No existing config. Downloading default..."
  fetch "$BASE_URL/${CONFIG_SUBDIR}/psiphon.config" "$TEMP_DIR/psiphon.config.raw" 30 || die "Default config download failed."
else
  log_info "Existing configuration detected. Preserving it."
  cp -- "$CONFIG_PATH" "$TEMP_DIR/psiphon.config.raw"
fi

if [[ "$(head -c 3 "$TEMP_DIR/psiphon.config.raw" | od -An -tx1 | tr -d ' \n')" == "efbbbf" ]]; then
  tail -c +4 "$TEMP_DIR/psiphon.config.raw" >"$TEMP_DIR/psiphon.config.nobom"
else
  cp -- "$TEMP_DIR/psiphon.config.raw" "$TEMP_DIR/psiphon.config.nobom"
fi
tr -d '\r' <"$TEMP_DIR/psiphon.config.nobom" >"$TEMP_DIR/psiphon.config.lf"

jq -e 'type == "object"' "$TEMP_DIR/psiphon.config.lf" >/dev/null 2>&1 || die "Invalid JSON configuration."
jq 'with_entries(
      if (.key == "LocalHttpProxyPort" or .key == "LocalSocksProxyPort") and (.value | type) == "string"
      then .value |= tonumber
      else .
      end)' "$TEMP_DIR/psiphon.config.lf" >"$TEMP_DIR/psiphon.config" || die "Configuration contains a non-numeric proxy port."

# ──────────────────────────────────────────────────────────────────────
# Systemd unit (check systemd/psiphon.service in the repo)
# ──────────────────────────────────────────────────────────────────────

if [[ "$SYSTEMD_MODE" == "yes" ]]; then
  log_info "Downloading systemd unit..."
  fetch "$BASE_URL/${SERVICE_SUBDIR}/psiphon.service" "$TEMP_DIR/psiphon.service" 30 || die "Service unit download failed."
  tr -d '\r' <"$TEMP_DIR/psiphon.service" >"$TEMP_DIR/psiphon.service.lf"
  grep -q "^ExecStart=${BINARY_PATH} " "$TEMP_DIR/psiphon.service.lf" || die "Service unit has an unexpected ExecStart."
  grep -Fxq "User=${SERVICE_USER}" "$TEMP_DIR/psiphon.service.lf" || die "Service unit does not run as '${SERVICE_USER}'."
fi

# ──────────────────────────────────────────────────────────────────────
# Install files
# ──────────────────────────────────────────────────────────────────────

log_info "Preparing service user and directories..."
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
  NOLOGIN="$(command -v nologin || true)"
  [[ -n "$NOLOGIN" ]] || NOLOGIN="/bin/false"
  useradd --system --user-group --no-create-home --home-dir "$STATE_DIR" --shell "$NOLOGIN" "$SERVICE_USER"
fi
install -d -m 755 "$INSTALL_DIR"
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 750 "$STATE_DIR"

install_atomic() { 
  install -m "$1" "$2" "$3.tmp.$$"
  mv -f -- "$3.tmp.$$" "$3"
}

log_info "Installing files..."
install_atomic 755 "$TEMP_DIR/$BINARY_NAME" "$BINARY_PATH"
install_atomic 644 "$TEMP_DIR/psiphon.config" "$CONFIG_PATH"
install_atomic 755 "$TEMP_DIR/psiphon" "$CLI_PATH"

# ──────────────────────────────────────────────────────────────────────
# Systemd service
# ──────────────────────────────────────────────────────────────────────

if [[ "$SYSTEMD_MODE" == "yes" ]]; then
  log_info "Installing systemd service..."
  install_atomic 644 "$TEMP_DIR/psiphon.service.lf" "$SERVICE_PATH"

  systemctl daemon-reload
  systemctl enable psiphon.service
  log_info "Starting Psiphon service..."
  systemctl restart psiphon.service

  waited=0
  stable=0
  while (( waited < START_WAIT_SECS )); do
    if systemctl is-active --quiet psiphon.service; then
      stable=$((stable + 1))
      (( stable < STABLE_SECS )) || break
    else
      stable=0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  if (( stable < STABLE_SECS )); then
    log_error "Psiphon service failed to start."
    systemctl status psiphon.service --no-pager || true
    journalctl -u psiphon.service -n 50 --no-pager || true
    die "Service startup failed. Check logs above."
  fi
else
  log_info "Installing without systemd..."
  if have_cmd systemctl && [[ -f "$SERVICE_PATH" ]]; then
    systemctl disable --now psiphon.service 2>/dev/null || true
    rm -f -- "$SERVICE_PATH"
    systemctl daemon-reload 2>/dev/null || true
  fi
fi

# ──────────────────────────────────────────────────────────────────────
# Success
# ──────────────────────────────────────────────────────────────────────

BACKUP_DIR=""
cleanup

log_success "Installation completed successfully."
echo
echo "Binary:        $BINARY_PATH"
echo "Configuration: $CONFIG_PATH"
echo "Data:          $STATE_DIR"
echo "Command:       $CLI_PATH"
echo "Runs as:       $SERVICE_USER (unprivileged)"
if [[ "$SYSTEMD_MODE" == "yes" ]]; then
  echo "Systemd:       enabled (auto-start on boot)"
  echo
  echo "Manage with:"
  echo "  sudo psiphon status"
  echo "  sudo psiphon logs"
  echo "  sudo psiphon restart"
  echo "  sudo psiphon update"
  echo "  sudo psiphon region DE"
else
  echo "Systemd:       disabled"
  echo
  echo "Run manually with:"
  echo "  sudo psiphon run"
fi
