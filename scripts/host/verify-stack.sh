#!/usr/bin/env bash
# ==============================================================
# verify-stack.sh
# Post-deployment verification for the OCI Oracle Linux 9
# Secure Admin Stack.
#
# Covers:
#   - Boot volume expansion
#   - Cloud-init completion
#   - Block volume mount and symlinks
#   - Service health (Traefik, Authelia, wg-easy, Cockpit, PCP)
#   - TLS certificate issuance
#   - WireGuard interface
#   - SELinux status and AVC denials
#   - Journal persistence
#   - Firewall rules
#
# Usage:
#   sudo ./verify-stack.sh
#
# Exit code:
#   0 — all checks passed
#   1 — one or more checks failed
# ==============================================================

set -euo pipefail

# --------------------------------------------------------------
# Formatting
# --------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0
WARN=0

pass() { echo -e "  ${GREEN}✓${RESET} $1"; ((++PASS)); }
fail() { echo -e "  ${RED}✗${RESET} $1"; ((++FAIL)); }
warn() { echo -e "  ${YELLOW}!${RESET} $1"; ((++WARN)); }
header() { echo -e "\n${BOLD}$1${RESET}"; }

# --------------------------------------------------------------
# Root check
# --------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Error: this script must be run as root (use sudo)" >&2
  exit 1
fi

echo -e "${BOLD}"
echo "======================================================"
echo " OCI Secure Admin Stack — Verification"
echo "======================================================"
echo -e "${RESET}"

# --------------------------------------------------------------
# 1. Boot Volume Expansion
# --------------------------------------------------------------
header "1. Boot Volume Expansion"

ROOT_SIZE=$(df -BG / | awk 'NR==2 {print $2}' | tr -d 'G')
ROOT_USED=$(df -BG / | awk 'NR==2 {print $3}' | tr -d 'G')
ROOT_AVAIL=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')

echo "    Root filesystem: ${ROOT_SIZE}G total, ${ROOT_USED}G used, ${ROOT_AVAIL}G available"

if [[ "$ROOT_SIZE" -ge 28 ]]; then
  pass "Root filesystem is at least 28G (oci-growfs ran successfully or volume was pre-expanded)"
else
  warn "Root filesystem is ${ROOT_SIZE}G — oci-growfs may not have run or boot volume is undersized"
fi

# --------------------------------------------------------------
# 2. Cloud-Init Status
# --------------------------------------------------------------
header "2. Cloud-Init Status"

CI_STATUS=$(cloud-init status 2>/dev/null | awk '{print $2}')
if [[ "$CI_STATUS" == "done" ]]; then
  pass "cloud-init status: done"
else
  fail "cloud-init status: ${CI_STATUS} (expected: done)"
fi

ERROR_COUNT=$(grep -c -i "error\|failed\|exception" /var/log/cloud-init-output.log 2>/dev/null || true)
if [[ "$ERROR_COUNT" -eq 0 ]]; then
  pass "No errors found in cloud-init-output.log"
else
  warn "${ERROR_COUNT} error/failed/exception lines in cloud-init-output.log — review with:"
  warn "  sudo grep -i 'error\\|failed\\|exception' /var/log/cloud-init-output.log"
fi

# --------------------------------------------------------------
# 3. Block Volume and Symlinks
# --------------------------------------------------------------
header "3. Block Volume and Symlinks"

if mountpoint -q /data; then
  FSTYPE=$(findmnt -n -o FSTYPE /data)
  pass "Block volume mounted at /data (${FSTYPE})"
else
  fail "Block volume is NOT mounted at /data"
fi

for dir in \
  /data/traefik/letsencrypt \
  /data/authelia/config \
  /data/authelia/db \
  /data/logs/traefik \
  /data/containers/wg-easy; do
  if [[ -d "$dir" ]]; then
    pass "Directory exists: ${dir}"
  else
    fail "Missing directory: ${dir}"
  fi
done

for link in \
  "/etc/traefik/letsencrypt:/data/traefik/letsencrypt" \
  "/var/log/traefik:/data/logs/traefik"; do
  SRC="${link%%:*}"
  DST="${link##*:}"
  if [[ -L "$SRC" && "$(readlink -f "$SRC")" == "$DST" ]]; then
    pass "Symlink correct: ${SRC} → ${DST}"
  else
    fail "Symlink missing or incorrect: ${SRC} → ${DST}"
  fi
done

# --------------------------------------------------------------
# 4. Service Health
# --------------------------------------------------------------
header "4. Service Health"

SERVICES=(
  "traefik.service"
  "wg-easy.service"
  "cockpit.socket"
  "pmcd.service"
  "pmlogger.service"
  "auditd.service"
)

for svc in "${SERVICES[@]}"; do
  if systemctl is-active --quiet "$svc"; then
    pass "${svc} is active"
  else
    STATE=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
    fail "${svc} is ${STATE}"
  fi

  if systemctl is-enabled --quiet "$svc"; then
    pass "${svc} is enabled at boot"
  else
    STATE=$(systemctl is-enabled "$svc" 2>/dev/null || echo "unknown")
    fail "${svc} is not enabled at boot (${STATE})"
  fi
done

AUTHELIA_UID=$(id -u authelia 2>/dev/null || true)
if [[ -n "$AUTHELIA_UID" ]]; then
  if runuser -u authelia -- env XDG_RUNTIME_DIR="/run/user/${AUTHELIA_UID}" \
    systemctl --user is-active --quiet authelia.service; then
    pass "authelia.service is active (rootless user unit)"
  else
    STATE=$(runuser -u authelia -- env XDG_RUNTIME_DIR="/run/user/${AUTHELIA_UID}" \
      systemctl --user is-active authelia.service 2>/dev/null || echo "unknown")
    fail "authelia.service is ${STATE} (rootless user unit)"
  fi

  if runuser -u authelia -- env XDG_RUNTIME_DIR="/run/user/${AUTHELIA_UID}" \
    systemctl --user is-enabled --quiet authelia.service; then
    pass "authelia.service is enabled at boot (rootless user unit)"
  else
    STATE=$(runuser -u authelia -- env XDG_RUNTIME_DIR="/run/user/${AUTHELIA_UID}" \
      systemctl --user is-enabled authelia.service 2>/dev/null || echo "unknown")
    fail "authelia.service is not enabled at boot (${STATE})"
  fi

  LINGER=$(loginctl show-user authelia -p Linger --value 2>/dev/null || true)
  if [[ "$LINGER" == "yes" ]]; then
    pass "systemd lingering is enabled for authelia"
  else
    fail "systemd lingering is not enabled for authelia"
  fi

  SUBUID=$(awk -F: '$1 == "authelia" { print $2 ":" $3; exit }' /etc/subuid)
  if [[ "$SUBUID" == "400000:65536" ]]; then
    pass "authelia subordinate UID range is 400000:65536"
  else
    fail "authelia subordinate UID range is ${SUBUID:-missing} (expected 400000:65536)"
  fi

  if [[ -f "/etc/containers/systemd/users/${AUTHELIA_UID}/authelia.container" ]]; then
    pass "authelia Quadlet unit is installed under the user directory"
  else
    fail "authelia Quadlet unit is missing"
  fi
else
  fail "authelia user does not exist"
fi

if [[ -f /etc/containers/systemd/wg-easy.container ]]; then
  pass "wg-easy Quadlet unit is installed"
else
  fail "wg-easy Quadlet unit is missing"
fi

if [[ "$(stat -c %U /data/authelia 2>/dev/null || true)" == "authelia" ]]; then
  pass "/data/authelia is owned by authelia"
else
  fail "/data/authelia is not owned by authelia"
fi

if [[ "$(stat -c %u /data/containers/wg-easy 2>/dev/null || true)" == "300000" ]]; then
  pass "/data/containers/wg-easy is owned by host UID 300000"
else
  fail "/data/containers/wg-easy is not owned by host UID 300000"
fi

WG_IDMAP=$(podman inspect wg-easy --format '{{json .HostConfig.IDMappings}}' 2>/dev/null || true)
if [[ "$WG_IDMAP" == *"300000"* ]]; then
  pass "wg-easy container root maps to host UID 300000"
else
  fail "wg-easy user namespace mapping is missing"
fi

WG_CAPS=$(podman inspect wg-easy --format '{{json .HostConfig.CapAdd}}' 2>/dev/null || true)
if [[ "$WG_CAPS" == *"NET_ADMIN"* && "$WG_CAPS" == *"NET_RAW"* ]]; then
  pass "wg-easy has NET_ADMIN and NET_RAW"
else
  fail "wg-easy is missing NET_ADMIN or NET_RAW"
fi
if [[ "$WG_CAPS" == *"SYS_MODULE"* ]]; then
  fail "wg-easy has SYS_MODULE (it must not)"
else
  pass "wg-easy does not have SYS_MODULE"
fi

COCKPIT_BINDS=$(ss -ltnH 2>/dev/null | awk '$4 ~ /:9090$/ {print $4}' || true)
if [[ "$COCKPIT_BINDS" == "127.0.0.1:9090" ]]; then
  pass "Cockpit listens only on 127.0.0.1:9090"
else
  fail "Cockpit must listen only on 127.0.0.1:9090 (observed: ${COCKPIT_BINDS:-no listener})"
fi

# --------------------------------------------------------------
# 5. TLS Certificate Issuance
# --------------------------------------------------------------
header "5. TLS Certificates (acme.json)"

ACME_FILE="/data/traefik/letsencrypt/acme.json"

if [[ -f "$ACME_FILE" ]]; then
  ACME_SIZE=$(stat -c%s "$ACME_FILE")
  ACME_PERM=$(stat -c%a "$ACME_FILE")

  if [[ "$ACME_SIZE" -gt 1024 ]]; then
    pass "acme.json exists and is non-empty (${ACME_SIZE} bytes — certificates issued)"
  else
    warn "acme.json exists but is very small (${ACME_SIZE} bytes) — certificates may not yet be issued"
  fi

  if [[ "$ACME_PERM" == "600" ]]; then
    pass "acme.json permissions are 600"
  else
    fail "acme.json permissions are ${ACME_PERM} (expected 600)"
  fi
else
  fail "acme.json not found at ${ACME_FILE}"
fi

# --------------------------------------------------------------
# 6. WireGuard
# --------------------------------------------------------------
header "6. WireGuard (via wg-easy)"

if podman exec wg-easy wg show wg0 &>/dev/null; then
  PEER_COUNT=$(podman exec wg-easy wg show wg0 peers 2>/dev/null | wc -l)
  pass "WireGuard interface wg0 is up inside the wg-easy container"
  if [[ "$PEER_COUNT" -gt 0 ]]; then
    pass "${PEER_COUNT} peer(s) configured"
  else
    warn "No peers configured — add the first peer via wg-easy UI (see guide Section 10.1)"
  fi
else
  fail "WireGuard interface wg0 is not up"
fi

if [[ -f /data/containers/wg-easy/env ]]; then
  pass "wg-easy env file exists at /data/containers/wg-easy/env"
  # Warn if INIT credentials are still present — they should be removed after first boot
  if grep -q "INIT_PASSWORD=" /data/containers/wg-easy/env 2>/dev/null; then
    warn "INIT_PASSWORD still present in wg-easy env — consider removing after confirming login works"
  fi
else
  fail "wg-easy env file missing at /data/containers/wg-easy/env"
fi

# --------------------------------------------------------------
# 7. SELinux
# --------------------------------------------------------------
header "7. SELinux"

SELINUX_STATUS=$(getenforce 2>/dev/null || echo "unknown")
if [[ "$SELINUX_STATUS" == "Enforcing" ]]; then
  pass "SELinux is Enforcing"
else
  fail "SELinux is ${SELINUX_STATUS} (expected Enforcing)"
fi

AVC_COUNT=$(ausearch -m avc -ts recent 2>/dev/null | grep -c "traefik" || true)
if [[ "$AVC_COUNT" -eq 0 ]]; then
  pass "No recent SELinux AVC denials for Traefik"
else
  fail "${AVC_COUNT} recent AVC denial(s) for Traefik — run: sudo ausearch -m avc -ts recent | grep traefik"
fi

# --------------------------------------------------------------
# 8. Journal Persistence
# --------------------------------------------------------------
header "8. Journal Persistence"

if [[ -d /var/log/journal ]]; then
  JOURNAL_SIZE=$(journalctl --disk-usage 2>/dev/null | awk '{print $7, $8}')
  pass "Persistent journal directory exists (/var/log/journal)"
  echo "    Journal disk usage: ${JOURNAL_SIZE}"
else
  fail "/var/log/journal does not exist — journal is not persistent"
fi

# --------------------------------------------------------------
# 9. Firewall Rules
# --------------------------------------------------------------
header "9. Firewall Rules"

for svc in http https; do
  if firewall-cmd --query-service="$svc" --permanent &>/dev/null; then
    pass "firewalld: ${svc} permitted"
  else
    fail "firewalld: ${svc} not permitted"
  fi
done

if firewall-cmd --query-port=51820/udp --permanent &>/dev/null; then
  pass "firewalld: UDP 51820 (WireGuard) permitted"
else
  fail "firewalld: UDP 51820 not permitted"
fi

if firewall-cmd --query-service=cockpit --permanent &>/dev/null || \
  firewall-cmd --query-port=9090/tcp --permanent &>/dev/null || \
  firewall-cmd --list-rich-rules --permanent 2>/dev/null | grep -q 'cockpit'; then
  fail "firewalld: direct Cockpit access is permitted; Cockpit must be reached through Traefik and Authelia"
else
  pass "firewalld: no direct Cockpit access"
fi

# Port 8082 (metrics) should NOT be open externally
if firewall-cmd --query-port=8082/tcp --permanent &>/dev/null; then
  fail "firewalld: port 8082 (metrics) is open externally — this should be internal only"
else
  pass "firewalld: port 8082 (metrics) is correctly not exposed externally"
fi

# --------------------------------------------------------------
# Summary
# --------------------------------------------------------------
echo -e "\n${BOLD}======================================================"
echo " Summary"
echo -e "======================================================${RESET}"
echo -e "  ${GREEN}Passed: ${PASS}${RESET}"
[[ "$WARN" -gt 0 ]] && echo -e "  ${YELLOW}Warnings: ${WARN}${RESET}"
[[ "$FAIL" -gt 0 ]] && echo -e "  ${RED}Failed: ${FAIL}${RESET}"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  echo -e "${RED}One or more checks failed. Review the output above.${RESET}"
  echo "For detailed system-unit logs: sudo journalctl -u <service-name> -n 50"
  echo "For Authelia user-unit logs: sudo journalctl _UID=<authelia-uid> -n 50"
  echo "For cloud-init output: sudo cat /var/log/cloud-init-output.log"
  exit 1
else
  if [[ "$WARN" -gt 0 ]]; then
    echo -e "${YELLOW}All checks passed with warnings. Review warnings above.${RESET}"
  else
    echo -e "${GREEN}All checks passed.${RESET}"
  fi
  exit 0
fi
