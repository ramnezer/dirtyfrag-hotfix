#!/usr/bin/env bash
set -Eeuo pipefail

MITIGATION_FILE="/etc/modprobe.d/dirtyfrag.conf"
MODULES=("esp4" "esp6" "rxrpc")

# Module aliases that may trigger autoloading through kernel subsystems.
declare -A MODULE_ALIASES=(
  ["esp4"]="xfrm-type-2-50"
  ["esp6"]="xfrm-type-10-50"
  ["rxrpc"]="net-pf-33"
)

usage() {
  cat <<USAGE
dirtyfrag-hotfix.sh - temporary defensive mitigation for DirtyFrag-style Linux LPE

Usage:
  sudo ./dirtyfrag-hotfix.sh probe-load
  sudo ./dirtyfrag-hotfix.sh apply
  ./dirtyfrag-hotfix.sh status
  ./dirtyfrag-hotfix.sh check
  sudo ./dirtyfrag-hotfix.sh drop-caches
  sudo ./dirtyfrag-hotfix.sh undo

Commands:
  probe-load   Try real module loads and verify target modules stay unloaded
  apply        Install modprobe rules that block esp4, esp6, and rxrpc
  status       Show mitigation file, runtime module state, and modprobe dry-run output
  check        Run a safe non-exploit mitigation check
  drop-caches  Drop Linux page cache after mitigation, useful if exploitation is suspected
  undo         Remove the mitigation file

Important:
  This is not a kernel patch.
  The real fix is an official patched vendor kernel plus reboot.
USAGE
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: this command must run as root. Use sudo." >&2
    exit 1
  fi
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

module_loaded() {
  local module="$1"
  lsmod | awk '{print $1}' | grep -qx "$module"
}

show_module_state() {
  local module="$1"
  echo "--- ${module} ---"

  if module_loaded "$module"; then
    echo "runtime: loaded"
  else
    echo "runtime: not loaded"
  fi

  if modinfo "$module" >/dev/null 2>&1; then
    echo "modinfo: available as loadable module"
    modinfo "$module" 2>/dev/null | sed -n '1,8p'
  else
    echo "modinfo: not available; module may be unavailable or built into the kernel"
  fi

  echo "modprobe direct dry-run:"
  modprobe -n -v "$module" 2>&1 || true

  local alias="${MODULE_ALIASES[$module]}"
  echo "modprobe alias dry-run (${alias}):"
  modprobe -n -v "$alias" 2>&1 || true

  echo
}

write_mitigation_file() {
  local tmp
  tmp="$(mktemp)"

  cat > "$tmp" <<'RULES'
# DirtyFrag temporary mitigation
#
# This file blocks vulnerable kernel modules from being loaded.
# It is a defensive workaround only, not a kernel patch.
#
# Remove this file only after installing and booting an official fixed vendor kernel.

install esp4 /bin/false
blacklist esp4

install esp6 /bin/false
blacklist esp6

install rxrpc /bin/false
blacklist rxrpc
RULES

  if [[ -e "$MITIGATION_FILE" ]]; then
    local backup="${MITIGATION_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$MITIGATION_FILE" "$backup"
    echo "[+] Existing mitigation file backed up to: $backup"
  fi

  install -m 0644 -o root -g root "$tmp" "$MITIGATION_FILE"
  rm -f "$tmp"

  echo "[+] Wrote mitigation file: $MITIGATION_FILE"
}

unload_modules() {
  local module

  for module in "${MODULES[@]}"; do
    if module_loaded "$module"; then
      echo "[+] Attempting to unload ${module}"
      if modprobe -r "$module" 2>/dev/null; then
        echo "[+] Unloaded ${module}"
      elif rmmod "$module" 2>/dev/null; then
        echo "[+] Unloaded ${module} with rmmod"
      else
        echo "[!] WARNING: ${module} is still loaded. A reboot may be required."
      fi
    else
      echo "[+] ${module} is not currently loaded"
    fi
  done
}

rebuild_initramfs_if_supported() {
  if have_cmd update-initramfs; then
    echo "[+] Rebuilding initramfs with update-initramfs"
    if update-initramfs -u; then
      echo "[+] initramfs updated"
    else
      echo "[!] WARNING: update-initramfs failed"
    fi
  elif have_cmd dracut; then
    echo "[+] Rebuilding initramfs with dracut"
    if dracut -f; then
      echo "[+] initramfs updated"
    else
      echo "[!] WARNING: dracut failed"
    fi
  else
    echo "[!] No supported initramfs tool found; skipping initramfs rebuild"
  fi
}

has_blacklist_rule() {
  local module="$1"

  [[ -f "$MITIGATION_FILE" ]] || return 1
  grep -Eq "^[[:space:]]*blacklist[[:space:]]+${module}([[:space:]]|$)" "$MITIGATION_FILE"
}

is_direct_blocked_by_install() {
  local module="$1"
  local output

  output="$(modprobe -n -v "$module" 2>&1 || true)"

  grep -Eq '(^|[[:space:]])install[[:space:]]+(/usr)?/bin/false([[:space:]]|$)' <<< "$output"
}

is_alias_suppressed_or_blocked() {
  local module="$1"
  local alias="$2"
  local output
  local compact_output

  output="$(modprobe -n -v "$alias" 2>&1 || true)"
  compact_output="$(tr -d '[:space:]' <<< "$output")"

  # Some systems show the install override even through the alias path.
  if grep -Eq '(^|[[:space:]])install[[:space:]]+(/usr)?/bin/false([[:space:]]|$)' <<< "$output"; then
    return 0
  fi

  # On Ubuntu/Mint, an alias blocked by blacklist can produce empty dry-run output.
  # This is acceptable only if the module has both:
  # 1. a blacklist rule for alias suppression
  # 2. an install /bin/false rule for direct-load suppression
  if [[ -z "$compact_output" ]] && has_blacklist_rule "$module" && is_direct_blocked_by_install "$module"; then
    return 0
  fi

  return 1
}

cmd_apply() {
  need_root

  echo "[+] Applying DirtyFrag temporary mitigation"
  write_mitigation_file
  unload_modules
  rebuild_initramfs_if_supported

  echo
  echo "[+] Apply completed"
  echo "[+] Run: ./dirtyfrag-hotfix.sh status"
  echo "[+] Run: ./dirtyfrag-hotfix.sh check"
  echo
  echo "[!] If any target module remains loaded, reboot and check again."
}

cmd_status() {
  echo "===== DirtyFrag hotfix status ====="
  echo "Date: $(date -Is)"
  echo "Kernel: $(uname -r)"
  echo

  echo "===== Mitigation file ====="
  if [[ -f "$MITIGATION_FILE" ]]; then
    echo "present: yes"
    echo "path: $MITIGATION_FILE"
    echo
    sed -n '1,120p' "$MITIGATION_FILE"
  else
    echo "present: no"
  fi

  echo
  echo "===== Module state ====="
  local module
  for module in "${MODULES[@]}"; do
    show_module_state "$module"
  done

  echo "===== Namespace / AppArmor context ====="
  sysctl kernel.unprivileged_userns_clone 2>/dev/null || true
  sysctl user.max_user_namespaces 2>/dev/null || true
  aa-status 2>/dev/null | sed -n '1,20p' || true
}

cmd_check() {
  echo "===== DirtyFrag safe check ====="

  local failed=0
  local module
  local alias

  if [[ ! -f "$MITIGATION_FILE" ]]; then
    echo "FAIL: mitigation file is missing: $MITIGATION_FILE"
    failed=1
  else
    echo "OK: mitigation file exists"
  fi

  for module in "${MODULES[@]}"; do
    alias="${MODULE_ALIASES[$module]}"

    if module_loaded "$module"; then
      echo "FAIL: ${module} is currently loaded"
      failed=1
    else
      echo "OK: ${module} is not loaded"
    fi

    if is_direct_blocked_by_install "$module"; then
      echo "OK: direct modprobe for ${module} is blocked by install /bin/false"
    else
      echo "FAIL: direct modprobe for ${module} is not blocked by install /bin/false"
      failed=1
    fi

    if is_alias_suppressed_or_blocked "$module" "$alias"; then
      echo "OK: alias autoload path ${alias} for ${module} is suppressed or blocked"
    else
      echo "FAIL: alias autoload path ${alias} for ${module} is not suppressed or blocked"
      failed=1
    fi
  done

  echo
  if [[ "$failed" -eq 0 ]]; then
    echo "RESULT: protected-by-mitigation"
    echo "NOTE: this is still a temporary mitigation, not a kernel patch."
  else
    echo "RESULT: not-protected-or-incomplete"
    echo "ACTION: review status output, then reboot if modules remain loaded."
    exit 1
  fi
}

cmd_drop_caches() {
  need_root

  echo "[+] Syncing filesystem buffers"
  sync

  echo "[+] Dropping Linux page cache"
  echo 3 > /proc/sys/vm/drop_caches

  echo "[+] Done"
}

cmd_probe_load() {
  need_root

  echo "===== DirtyFrag runtime load probe ====="
  echo "Date: $(date -Is)"
  echo "Kernel: $(uname -r)"
  echo

  echo "===== Before probe ====="
  for module in esp4 esp6 rxrpc xfrm_algo udp_tunnel ip6_udp_tunnel krb5; do
    if module_loaded "$module"; then
      echo "loaded: ${module}"
    else
      echo "not loaded: ${module}"
    fi
  done

  echo
  echo "===== Direct load probe ====="

  local failed=0
  local module

  for module in "${MODULES[@]}"; do
    echo
    echo "--- trying direct load: ${module} ---"

    set +e
    modprobe -v "$module"
    local rc=$?
    set -e

    echo "exit_code=${rc}"

    if module_loaded "$module"; then
      echo "FAIL: ${module} loaded"
      failed=1
    else
      echo "OK: ${module} did not load"
    fi
  done

  echo
  echo "===== Alias load probe ====="

  local alias

  for module in "${MODULES[@]}"; do
    alias="${MODULE_ALIASES[$module]}"

    echo
    echo "--- trying alias load with blacklist: ${alias} (${module}) ---"

    set +e
    modprobe -b -v "$alias"
    local rc=$?
    set -e

    echo "exit_code=${rc}"

    if module_loaded "$module"; then
      echo "FAIL: ${module} loaded through alias ${alias}"
      failed=1
    else
      echo "OK: ${module} did not load through alias ${alias}"
    fi
  done

  echo
  echo "===== After probe ====="
  for module in esp4 esp6 rxrpc xfrm_algo udp_tunnel ip6_udp_tunnel krb5; do
    if module_loaded "$module"; then
      echo "loaded: ${module}"
    else
      echo "not loaded: ${module}"
    fi
  done

  echo
  echo "===== Final safe check ====="

  if ! cmd_check; then
    failed=1
  fi

  echo
  if [[ "$failed" -eq 0 ]]; then
    echo "RESULT: runtime-load-probe-passed"
    echo "NOTE: dependencies may load during probing; target modules must remain unloaded."
  else
    echo "RESULT: runtime-load-probe-failed"
    exit 1
  fi
}

cmd_undo() {
  need_root

  if [[ -f "$MITIGATION_FILE" ]]; then
    rm -f "$MITIGATION_FILE"
    echo "[+] Removed: $MITIGATION_FILE"
  else
    echo "[+] Mitigation file was already absent"
  fi

  rebuild_initramfs_if_supported

  echo
  echo "[!] Undo completed."
  echo "[!] Reboot before assuming module behavior has returned to normal."
}

main() {
  local cmd="${1:-}"

  case "$cmd" in
    apply) cmd_apply ;;
    status) cmd_status ;;
    check) cmd_check ;;
    probe-load) cmd_probe_load ;;
    drop-caches) cmd_drop_caches ;;
    undo) cmd_undo ;;
    -h|--help|help|"") usage ;;
    *)
      echo "ERROR: unknown command: $cmd" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
