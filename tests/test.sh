#!/usr/bin/env bash
# PsiphonLinux Test Suite
# Validates the installer, manager CLI, default config and systemd unit.
# Everything that changes state runs against a throw-away sandbox copy of the
# manager (paths redirected, fake systemctl); it never touches /etc, /usr/bin
# or real services, and is safe to run on a machine that has Psiphon installed.
# SPDX-License-Identifier: MIT

set -Euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT

PASS=0
FAIL=0
SKIP=0

C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RESET="$(tput sgr0)"
  C_BOLD="$(tput bold)"
  C_RED="$(tput setaf 1)"
  C_GREEN="$(tput setaf 2)"
  C_YELLOW="$(tput setaf 3)"
  C_BLUE="$(tput setaf 4)"
  C_CYAN="$(tput setaf 6)"
fi

log_info()    { printf '%s[INFO]%s %s\n' "${C_BLUE}${C_BOLD}"   "${C_RESET}" "$*"; }
log_pass()    { printf '%s[PASS]%s %s\n' "${C_GREEN}${C_BOLD}"  "${C_RESET}" "$*"; PASS=$((PASS + 1)); }
log_fail()    { printf '%s[FAIL]%s %s\n' "${C_RED}${C_BOLD}"    "${C_RESET}" "$*"; FAIL=$((FAIL + 1)); }
log_skip()    { printf '%s[SKIP]%s %s\n' "${C_YELLOW}${C_BOLD}" "${C_RESET}" "$*"; SKIP=$((SKIP + 1)); }
log_section() { printf '\n%s=== %s ===%s\n' "${C_CYAN}${C_BOLD}" "$*" "${C_RESET}"; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then log_pass "$desc"; else log_fail "$desc"; fi
}

check_not() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then log_fail "$desc"; else log_pass "$desc"; fi
}

expect_eq() {
  if [[ "$2" == "$3" ]]; then
    log_pass "$1"
  else
    log_fail "$1 (expected '$2', got '$3')"
  fi
}

TMP="$(mktemp -d -t psiphon-test-XXXXXX)"
readonly TMP
trap 'rm -rf -- "$TMP"' EXIT

constant() {
  grep -E "^readonly $2=" "$ROOT/$1" | head -n 1 | cut -d'"' -f2
}

log_section "PsiphonLinux Test Suite"
log_info "Project root: $ROOT"

# ──────────────────────────────────────────────────────────────────────
# Syntax
# ──────────────────────────────────────────────────────────────────────
log_section "Syntax Validation"
for f in pinstaller.sh psiphon tests/test.sh; do
  check "bash -n $f" bash -n "$ROOT/$f"
done

# ──────────────────────────────────────────────────────────────────────
# Repository hygiene
# ──────────────────────────────────────────────────────────────────────
log_section "File Hygiene"
for f in pinstaller.sh psiphon tests/test.sh config/psiphon.config systemd/psiphon.service \
         README.md .github/workflows/tests.yml .github/workflows/update-psiphon-binary.yml; do
  if grep -q $'\r' "$ROOT/$f"; then log_fail "No CRLF line endings: $f"; else log_pass "No CRLF line endings: $f"; fi
  if [[ "$(head -c 3 "$ROOT/$f" | od -An -tx1 | tr -d ' \n')" == "efbbbf" ]]; then
    log_fail "No UTF-8 BOM: $f"
  else
    log_pass "No UTF-8 BOM: $f"
  fi
done

for f in pinstaller.sh psiphon tests/test.sh; do
  if head -n 1 "$ROOT/$f" | grep -Fxq '#!/usr/bin/env bash'; then log_pass "Shebang: $f"; else log_fail "Shebang: $f"; fi
  mode=""
  if have_cmd git && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
     && [[ -n "$(git -C "$ROOT" ls-files -- "$f")" ]]; then
    mode="$(git -C "$ROOT" ls-files -s -- "$f" | awk '{print $1}')"
    if [[ "$mode" == "100755" ]]; then
      log_pass "Executable in git index: $f"
    else
      log_skip "Not executable in git index ($mode): $f (fix: git update-index --chmod=+x $f)"
    fi
  elif [[ -x "$ROOT/$f" ]]; then
    log_pass "Executable bit: $f"
  else
    log_fail "Executable bit: $f"
  fi
done

# ──────────────────────────────────────────────────────────────────────
# Help and argument handling (side-effect free)
# ──────────────────────────────────────────────────────────────────────
log_section "Help & Argument Validation"
check "installer --help exits 0" bash "$ROOT/pinstaller.sh" --help
check "manager --help exits 0" bash "$ROOT/psiphon" --help
check "manager help (no args) exits 0" bash "$ROOT/psiphon"
check_not "installer rejects unknown option" bash "$ROOT/pinstaller.sh" --invalid-option-xyz
check_not "manager rejects unknown command" bash "$ROOT/psiphon" invalid-command-xyz
for cmd in region httpport socksport loglevel; do
  check_not "manager '$cmd' requires an argument" bash "$ROOT/psiphon" "$cmd"
done

if [[ $EUID -ne 0 ]]; then
  check_not "installer refuses to run without root" bash "$ROOT/pinstaller.sh" --no-systemd
else
  log_skip "installer root check (tests are running as root; not executing the installer)"
fi

# ──────────────────────────────────────────────────────────────────────
# Version / constant consistency
# ──────────────────────────────────────────────────────────────────────
log_section "Consistency"
iv="$(constant pinstaller.sh SCRIPT_VERSION)"
mv_="$(constant psiphon SCRIPT_VERSION)"
expect_eq "Installer version == manager version" "$iv" "$mv_"
if bash "$ROOT/pinstaller.sh" --help 2>/dev/null | grep -Fq "v$iv"; then log_pass "Installer help shows v$iv"; else log_fail "Installer help shows v$iv"; fi
if bash "$ROOT/psiphon" --help 2>/dev/null | grep -Fq "v$mv_"; then log_pass "Manager help shows v$mv_"; else log_fail "Manager help shows v$mv_"; fi

expect_eq "INSTALL_DIR matches" "$(constant pinstaller.sh INSTALL_DIR)" "$(constant psiphon INSTALL_DIR)"
expect_eq "STATE_DIR matches" "$(constant pinstaller.sh STATE_DIR)" "$(constant psiphon STATE_DIR)"
expect_eq "SERVICE_USER matches" "$(constant pinstaller.sh SERVICE_USER)" "$(constant psiphon SERVICE_USER)"
expect_eq "BINARY_NAME matches" "$(constant pinstaller.sh BINARY_NAME)" "$(constant psiphon BINARY_NAME)"
expect_eq "REPO matches" "$(constant pinstaller.sh REPO)" "$(constant psiphon REPO)"
expect_eq "BRANCH matches" "$(constant pinstaller.sh BRANCH)" "$(constant psiphon BRANCH)"

# ──────────────────────────────────────────────────────────────────────
# Default configuration
# ──────────────────────────────────────────────────────────────────────
log_section "Default Configuration"
CFG="$ROOT/config/psiphon.config"

if have_cmd jq; then
  check "Config is valid JSON" jq empty "$CFG"
  for key in LocalHttpProxyPort LocalSocksProxyPort EgressRegion LogLevel PropagationChannelId \
             SponsorId RemoteServerListSignaturePublicKey RemoteServerListUrl; do
    check "Config has key: $key" jq -e "has(\"$key\")" "$CFG"
  done
  expect_eq "LocalHttpProxyPort is a JSON number" "number" "$(jq -r '.LocalHttpProxyPort | type' "$CFG")"
  expect_eq "LocalSocksProxyPort is a JSON number" "number" "$(jq -r '.LocalSocksProxyPort | type' "$CFG")"
  for key in LocalHttpProxyPort LocalSocksProxyPort; do
    port="$(jq -r ".$key" "$CFG")"
    if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
      log_pass "$key in range ($port)"
    else
      log_fail "$key in range ($port)"
    fi
  done
else
  log_skip "jq not installed: config structure tests"
fi

BIN="$ROOT/binary/psiphon-tunnel-core-x86_64"
if [[ "$(uname -m)" == "x86_64" && -f "$BIN" ]]; then
  cp -- "$BIN" "$TMP/ptc"
  chmod 755 "$TMP/ptc"
  sed -E -e 's/("LocalHttpProxyPort": )8080/\148080/' -e 's/("LocalSocksProxyPort": )1080/\141080/' "$CFG" >"$TMP/ptc.config"
  mkdir -p "$TMP/ptc-data"
  out="$(timeout 6 "$TMP/ptc" -config "$TMP/ptc.config" -dataRootDirectory "$TMP/ptc-data" -formatNotices 2>&1 || true)"
  if grep -q 'ListeningSocksProxyPort' <<<"$out" && ! grep -q 'error processing configuration file' <<<"$out"; then
    log_pass "Real Psiphon binary accepts the default config"
  else
    log_fail "Real Psiphon binary accepts the default config"
    printf '%s\n' "$out" | head -n 5
  fi
else
  log_skip "Real-binary config test (needs x86_64 and binary/)"
fi

# ──────────────────────────────────────────────────────────────────────
# Binary artifacts in the repo
# ──────────────────────────────────────────────────────────────────────
log_section "Binary Artifacts"
if [[ -f "$BIN" ]]; then
  hdr="$(LC_ALL=C readelf -h "$BIN" 2>/dev/null || true)"
  if grep -Eq 'Class:[[:space:]]+ELF64' <<<"$hdr"; then log_pass "Binary is ELF64"; else log_fail "Binary is ELF64"; fi
  if grep -Eq 'Machine:[[:space:]]+(Advanced Micro Devices X86-64|AMD x86-64)' <<<"$hdr"; then log_pass "Binary is AMD64"; else log_fail "Binary is AMD64"; fi
  if [[ -f "$BIN.sha256" ]]; then
    if (cd "$ROOT/binary" && sha256sum -c psiphon-tunnel-core-x86_64.sha256 >/dev/null 2>&1); then
      log_pass "Binary checksum matches .sha256"
    else
      log_fail "Binary checksum matches .sha256"
    fi
  else
    log_fail "Checksum file exists"
  fi
else
  log_skip "binary/psiphon-tunnel-core-x86_64 not present"
fi

# ──────────────────────────────────────────────────────────────────────
# systemd unit
# ──────────────────────────────────────────────────────────────────────
log_section "Systemd Unit"
UNIT="$ROOT/systemd/psiphon.service"
for section in "[Unit]" "[Service]" "[Install]"; do
  check "Unit has section $section" grep -Fxq "$section" "$UNIT"
done
for directive in 'ExecStart=' 'Restart=' 'User=psiphon' 'Group=psiphon' 'StateDirectory=psiphon' \
                 'NoNewPrivileges=true' 'PrivateTmp=true' 'ProtectSystem=strict' 'ProtectHome=true' \
                 'CapabilityBoundingSet='; do
  check "Unit sets $directive" grep -q "^${directive}" "$UNIT"
done
check_not "Unit does not run as root" grep -Eq '^User=root' "$UNIT"
install_dir="$(constant pinstaller.sh INSTALL_DIR)"
state_dir="$(constant pinstaller.sh STATE_DIR)"
bin_name="$(constant pinstaller.sh BINARY_NAME)"
check "ExecStart matches installer paths" \
  grep -Fxq "ExecStart=${install_dir}/${bin_name} -config ${install_dir}/psiphon.config -dataRootDirectory ${state_dir} -formatNotices" "$UNIT"

if have_cmd systemd-analyze; then
  sed -e "s|^ExecStart=${install_dir}/${bin_name}|ExecStart=/bin/true|" \
      -e 's|^User=psiphon|User=root|' -e 's|^Group=psiphon|Group=root|' "$UNIT" >"$TMP/psiphon.service"
  if verify_out="$(systemd-analyze verify "$TMP/psiphon.service" 2>&1)"; then
    log_pass "systemd-analyze verify"
  else
    log_fail "systemd-analyze verify"
    printf '%s\n' "$verify_out" | head -n 5
  fi
else
  log_skip "systemd-analyze not available"
fi

# ──────────────────────────────────────────────────────────────────────
# Manager CLI behaviour (sandboxed)
# ──────────────────────────────────────────────────────────────────────
log_section "Manager CLI (sandbox)"

if ! have_cmd jq; then
  log_skip "jq not installed: sandbox tests"
else
  SB="$TMP/sb"
  mkdir -p "$SB/etc" "$SB/var" "$SB/bin" "$SB/stub" "$SB/fixtures/binary"
  SANDBOX_OK=yes

  sandbox_sed() {
    if ! grep -Eq "$1" "$ROOT/psiphon"; then
      log_fail "Sandbox setup: pattern not found in psiphon: $1"
      SANDBOX_OK=no
    fi
  }
  sandbox_sed '^readonly INSTALL_DIR='
  sandbox_sed '^readonly STATE_DIR='
  sandbox_sed '^readonly SERVICE_USER='
  sandbox_sed '^readonly SERVICE_FILE='
  sandbox_sed '^readonly CLI_PATH='
  sandbox_sed '^readonly LOCK_FILE='
  sandbox_sed '^readonly BASE_URL='
  sandbox_sed '^readonly START_WAIT_SECS='
  sandbox_sed '^readonly STABLE_SECS='
  sandbox_sed '^readonly -a CURL_PROTO_OPTS='
  sandbox_sed '^is_root\(\)'

  sed -e "s|^readonly INSTALL_DIR=.*|readonly INSTALL_DIR=\"$SB/etc\"|" \
      -e "s|^readonly STATE_DIR=.*|readonly STATE_DIR=\"$SB/var\"|" \
      -e 's|^readonly SERVICE_USER=.*|readonly SERVICE_USER="psiphon-sandbox-none"|' \
      -e "s|^readonly SERVICE_FILE=.*|readonly SERVICE_FILE=\"$SB/psiphon.service\"|" \
      -e "s|^readonly CLI_PATH=.*|readonly CLI_PATH=\"$SB/psiphon-cli\"|" \
      -e "s|^readonly LOCK_FILE=.*|readonly LOCK_FILE=\"$SB/lock\"|" \
      -e "s|^readonly BASE_URL=.*|readonly BASE_URL=\"file://$SB/fixtures\"|" \
      -e 's|^readonly START_WAIT_SECS=.*|readonly START_WAIT_SECS=4|' \
      -e 's|^readonly STABLE_SECS=.*|readonly STABLE_SECS=1|' \
      -e "s|^readonly -a CURL_PROTO_OPTS=.*|readonly -a CURL_PROTO_OPTS=()|" \
      -e 's|^is_root() .*|is_root() { true; }|' \
      "$ROOT/psiphon" >"$SB/psiphon.sh"

  cat >"$SB/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STUB_DIR/calls.log"
cmd="${1:-}"
case "$cmd" in
  is-active) [[ "$(cat "$STUB_DIR/state" 2>/dev/null)" == "active" ]] ;;
  start|restart)
    if [[ -f "$STUB_DIR/fail_restart" ]] && [[ "$cmd" == "restart" ]]; then
      echo inactive >"$STUB_DIR/state"
    elif [[ -f "$STUB_DIR/fail_sha" && "$(sha256sum "$STUB_BIN" | cut -d' ' -f1)" == "$(cat "$STUB_DIR/fail_sha")" ]]; then
      echo inactive >"$STUB_DIR/state"
    else
      echo active >"$STUB_DIR/state"
    fi
    ;;
  stop) echo inactive >"$STUB_DIR/state" ;;
  *) exit 0 ;;
esac
STUB
  chmod 755 "$SB/bin/systemctl"

  sb() {
    PATH="$SB/bin:$PATH" STUB_DIR="$SB/stub" STUB_BIN="$SB/etc/psiphon-tunnel-core-x86_64" \
      bash "$SB/psiphon.sh" "$@"
  }
  cfg_get() { jq -r ".$1" "$SB/etc/psiphon.config"; }
  calls() { cat "$SB/stub/calls.log" 2>/dev/null || true; }
  sha_of() { sha256sum "$1" | awk '{print $1}'; }

  if [[ "$SANDBOX_OK" == "yes" ]]; then
    # --- config subcommands -------------------------------------------------
    check_not "config without a config file fails cleanly" sb config
    cp -- "$CFG" "$SB/etc/psiphon.config"

    check "config prints JSON" sb config
    check "region de -> accepted" sb region de
    expect_eq "region stored upper-case" "DE" "$(cfg_get EgressRegion)"
    ls "$SB"/etc/psiphon.config.bak.* >/dev/null 2>&1 && log_pass "Backup created on change" || log_fail "Backup created on change"

    before="$(sha_of "$SB/etc/psiphon.config")"
    check_not "region XX -> rejected" sb region XX
    expect_eq "Rejected region leaves config untouched" "$before" "$(sha_of "$SB/etc/psiphon.config")"

    check "httpport 8081 -> accepted" sb httpport 8081
    expect_eq "httpport value" "8081" "$(cfg_get LocalHttpProxyPort)"
    expect_eq "httpport stored as JSON number (not string)" "number" "$(jq -r '.LocalHttpProxyPort | type' "$SB/etc/psiphon.config")"
    check "socksport 0010 -> accepted (no octal surprise)" sb socksport 0010
    expect_eq "socksport 0010 -> 10" "10" "$(cfg_get LocalSocksProxyPort)"
    expect_eq "socksport stored as JSON number" "number" "$(jq -r '.LocalSocksProxyPort | type' "$SB/etc/psiphon.config")"
    for bad in 0 65536 70000 abc -5 "" "8 0" 1e3; do
      check_not "port '$bad' rejected" sb httpport "$bad"
    done
    check_not "equal HTTP/SOCKS ports rejected" sb socksport 8081
    expect_eq "HTTP port unchanged after rejections" "8081" "$(cfg_get LocalHttpProxyPort)"

    check "loglevel DEBUG -> accepted" sb loglevel DEBUG
    expect_eq "loglevel stored lower-case" "debug" "$(cfg_get LogLevel)"
    expect_eq "debug enables EmitDiagnosticNotices" "true" "$(cfg_get EmitDiagnosticNotices)"
    check "loglevel info -> accepted" sb loglevel info
    expect_eq "info disables EmitDiagnosticNotices" "false" "$(cfg_get EmitDiagnosticNotices)"
    check_not "loglevel verbose -> rejected" sb loglevel verbose

    check "Config is still valid JSON after changes" jq empty "$SB/etc/psiphon.config"
    expect_eq "Untouched keys preserved (PropagationChannelId)" "FFFFFFFFFFFFFFFF" "$(cfg_get PropagationChannelId)"

    for n in 1 2 3 4 5 6 7 8; do : >"$SB/etc/psiphon.config.bak.2000010${n}-000000"; done
    check "Another change succeeds" sb region FR
    n_baks="$(find "$SB/etc" -maxdepth 1 -name 'psiphon.config.bak.*' | wc -l | tr -d ' ')"
    if (( n_baks <= 5 )); then log_pass "Old backups pruned (kept $n_baks)"; else log_fail "Old backups pruned (kept $n_baks)"; fi

    # --- service interaction ------------------------------------------------
    : >"$SB/psiphon.service"
    echo active >"$SB/stub/state"
    : >"$SB/stub/calls.log"
    check "Config change with running service succeeds" sb region NL
    if calls | grep -Fq 'restart psiphon.service'; then log_pass "Service restarted after config change"; else log_fail "Service restarted after config change"; fi

    expect_eq "Region before failed restart" "NL" "$(cfg_get EgressRegion)"
    : >"$SB/stub/fail_restart"
    check_not "Config change that breaks the service fails" sb region SE
    expect_eq "Broken config change was reverted" "NL" "$(cfg_get EgressRegion)"
    rm -f "$SB/stub/fail_restart"
    echo active >"$SB/stub/state"

    # --- ip / version without a binary --------------------------------------
    check_not "ip fails cleanly without a binary" sb ip
    check_not "version fails cleanly without a binary" sb version

    # --- update -------------------------------------------------------------
    if [[ "$(uname -m)" == "x86_64" && -x /bin/true && -x /bin/false ]] && have_cmd readelf; then
      INSTALLED="$SB/etc/psiphon-tunnel-core-x86_64"
      FIXDIR="$SB/fixtures/binary"
      NAME="psiphon-tunnel-core-x86_64"
      make_fixture() {
        cp -- "$1" "$FIXDIR/$NAME"
        printf '%s  %s\n' "${2:-$(sha_of "$1")}" "$NAME" >"$FIXDIR/$NAME.sha256"
      }
      reset_installed() { cp -- /bin/false "$INSTALLED"; chmod 755 "$INSTALLED"; }
      rm -f "$SB/psiphon.service" "$SB/stub/fail_sha"
      echo inactive >"$SB/stub/state"

      reset_installed
      make_fixture /bin/true
      check "update installs a verified new binary" sb update
      expect_eq "Installed binary now equals fixture" "$(sha_of /bin/true)" "$(sha_of "$INSTALLED")"
      [[ ! -e "$INSTALLED.new" ]] && log_pass "No staged file left behind" || log_fail "No staged file left behind"
      out="$(sb update 2>&1 || true)"
      if grep -Fq 'Already up to date' <<<"$out"; then log_pass "update is a no-op when already current"; else log_fail "update is a no-op when already current"; fi

      reset_installed; old="$(sha_of "$INSTALLED")"
      make_fixture /bin/true "$(printf '0%.0s' {1..64})"
      check_not "update rejects checksum mismatch" sb update
      expect_eq "Binary untouched after checksum mismatch" "$old" "$(sha_of "$INSTALLED")"

      make_fixture /bin/true
      rm -f "$FIXDIR/$NAME.sha256"
      check_not "update refuses to run without a checksum file" sb update
      expect_eq "Binary untouched when checksum missing" "$old" "$(sha_of "$INSTALLED")"

      printf '#!/bin/sh\necho not an elf\n' >"$TMP/script.sh"
      make_fixture "$TMP/script.sh"
      check_not "update rejects a non-ELF payload" sb update
      expect_eq "Binary untouched after non-ELF payload" "$old" "$(sha_of "$INSTALLED")"

      make_fixture /bin/false
      cp -- /bin/true "$INSTALLED"
      old="$(sha_of "$INSTALLED")"
      check_not "update rejects a binary that fails its smoke test" sb update
      expect_eq "Binary untouched after failed smoke test" "$old" "$(sha_of "$INSTALLED")"
      [[ ! -e "$INSTALLED.new" ]] && log_pass "Staged file removed after failed smoke test" || log_fail "Staged file removed after failed smoke test"

      : >"$SB/psiphon.service"
      reset_installed; old="$(sha_of "$INSTALLED")"
      make_fixture /bin/true
      echo active >"$SB/stub/state"; : >"$SB/stub/calls.log"
      check "update with running service succeeds" sb update
      expect_eq "Service active after update" "active" "$(cat "$SB/stub/state")"
      if calls | grep -Fq 'stop psiphon.service' && calls | grep -Fq 'start psiphon.service'; then
        log_pass "Service stopped and started around update"
      else
        log_fail "Service stopped and started around update"
      fi

      reset_installed; old="$(sha_of "$INSTALLED")"
      sha_of /bin/true >"$SB/stub/fail_sha"
      echo active >"$SB/stub/state"
      check_not "update fails when the new binary will not run as a service" sb update
      expect_eq "Previous binary restored after failed start" "$old" "$(sha_of "$INSTALLED")"
      expect_eq "Service running again after rollback" "active" "$(cat "$SB/stub/state")"
      rm -f "$SB/stub/fail_sha"
    else
      log_skip "update tests need x86_64 Linux with readelf, /bin/true and /bin/false"
    fi

    # --- uninstall ----------------------------------------------------------
    : >"$SB/psiphon-cli"; : >"$INSTALLED" 2>/dev/null || true
    check "uninstall -y succeeds" sb uninstall -y
    [[ ! -e "$SB/etc/psiphon.config" && ! -e "$SB/psiphon-cli" && ! -e "$SB/var" && ! -e "$SB/psiphon.service" ]] \
      && log_pass "uninstall removed config, CLI, data and unit" || log_fail "uninstall removed config, CLI, data and unit"
  fi
fi

# ──────────────────────────────────────────────────────────────────────
# Static analysis
# ──────────────────────────────────────────────────────────────────────
log_section "Static Analysis"
if have_cmd shellcheck; then
  for f in pinstaller.sh psiphon tests/test.sh; do
    if sc_out="$(shellcheck --severity=error -x "$ROOT/$f" 2>&1)"; then
      log_pass "ShellCheck (errors): $f"
    else
      log_fail "ShellCheck (errors): $f"
      printf '%s\n' "$sc_out" | head -n 20
    fi
  done
else
  log_skip "shellcheck not installed"
fi

if python3 -c 'import yaml' >/dev/null 2>&1; then
  for f in .github/workflows/tests.yml .github/workflows/update-psiphon-binary.yml; do
    check "Valid YAML: $f" python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$ROOT/$f"
  done
else
  log_skip "PyYAML not installed: workflow YAML check"
fi

# ──────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────
log_section "Test Summary"
printf '  %s%d passed%s\n'  "${C_GREEN}${C_BOLD}"  "$PASS" "${C_RESET}"
printf '  %s%d failed%s\n'  "${C_RED}${C_BOLD}"    "$FAIL" "${C_RESET}"
printf '  %s%d skipped%s\n' "${C_YELLOW}${C_BOLD}" "$SKIP" "${C_RESET}"
echo

if (( FAIL > 0 )); then
  exit 1
fi
exit 0
