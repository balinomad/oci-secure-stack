#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd -P)"
readonly REPO_ROOT

readonly ALERTING_USER="alerting"
readonly ENV_FILE="/data/monitoring/alerting/env"
readonly STATE_DIR="/var/lib/stack-alerting"

usage() {
  cat <<'USAGE'
Usage: 08-alerting.sh

Install or update the alert delivery components from a repository checkout.
The script is idempotent. It creates the alerting service user, installs the
runtime script, pmie rules, systemd units, and timers, and preserves an
existing /data/monitoring/alerting/env file.

Environment:
  ALERT_WEBHOOK_URL            Direct webhook URL for first setup.
  ALERT_WEBHOOK_SECRET_OCID    OCI Vault secret OCID for the webhook URL.
  ALERT_HEARTBEAT_URL          Direct heartbeat URL for first setup.
  ALERT_HEARTBEAT_SECRET_OCID  OCI Vault secret OCID for the heartbeat URL.
USAGE
}

err() {
  printf 'ERROR: %s\n' "$*" >&2
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "run this script as root"
    exit 1
  fi
}

require_commands() {
  local command
  for command in install systemctl systemd-tmpfiles useradd groupadd getent runuser jq curl pmie; do
    if ! command -v "${command}" >/dev/null 2>&1; then
      err "required command not found: ${command}"
      exit 1
    fi
  done
}

create_user() {
  if getent passwd "${ALERTING_USER}" >/dev/null 2>&1; then
    if ! getent group "${ALERTING_USER}" >/dev/null 2>&1; then
      groupadd --system "${ALERTING_USER}"
    fi
    return 0
  fi
  if ! getent group "${ALERTING_USER}" >/dev/null 2>&1; then
    groupadd --system "${ALERTING_USER}"
  fi
  useradd --system --gid "${ALERTING_USER}" --no-create-home --home-dir "${STATE_DIR}" \
    --shell /usr/sbin/nologin "${ALERTING_USER}"
}

fetch_secret() {
  local secret_id="$1"

  if ! command -v oci >/dev/null 2>&1; then
    err "the OCI CLI is required to fetch ${secret_id}"
    exit 1
  fi

  oci secrets secret-bundle get \
    --secret-id "${secret_id}" \
    --query "data.secretBundleContent.content" \
    --raw-output | base64 -d
}

write_env() {
  local webhook_url="${ALERT_WEBHOOK_URL:-}"
  local heartbeat_url="${ALERT_HEARTBEAT_URL:-}"

  if [[ -s "${ENV_FILE}" ]]; then
    return 0
  fi

  if [[ -z "${webhook_url}" && -n "${ALERT_WEBHOOK_SECRET_OCID:-}" ]]; then
    webhook_url="$(fetch_secret "${ALERT_WEBHOOK_SECRET_OCID}")"
  fi
  if [[ -z "${heartbeat_url}" && -n "${ALERT_HEARTBEAT_SECRET_OCID:-}" ]]; then
    heartbeat_url="$(fetch_secret "${ALERT_HEARTBEAT_SECRET_OCID}")"
  fi

  if [[ -z "${webhook_url}" ]]; then
    err "set ALERT_WEBHOOK_URL or ALERT_WEBHOOK_SECRET_OCID"
    exit 1
  fi
  if [[ -z "${heartbeat_url}" ]]; then
    err "set ALERT_HEARTBEAT_URL or ALERT_HEARTBEAT_SECRET_OCID"
    exit 1
  fi
  if [[ "${webhook_url}" != https://* ]]; then
    err "the webhook URL must use HTTPS"
    exit 1
  fi
  if [[ "${heartbeat_url}" != https://* ]]; then
    err "the heartbeat URL must use HTTPS"
    exit 1
  fi

  install -d -m 0750 -o "${ALERTING_USER}" -g "${ALERTING_USER}" \
    /data/monitoring/alerting
  umask 077
  {
    printf 'ALERT_WEBHOOK_URL=%q\n' "${webhook_url}"
    printf 'ALERT_HEARTBEAT_URL=%q\n' "${heartbeat_url}"
  } > "${ENV_FILE}"
  chown "${ALERTING_USER}:${ALERTING_USER}" "${ENV_FILE}"
  chmod 0600 "${ENV_FILE}"
}

install_runtime() {
  install -D -m 0755 -o root -g root \
    "${REPO_ROOT}/configs/alerting/alerting.sh" \
    /usr/local/libexec/stack-alerting
  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/configs/alerting/services.list" \
    /etc/pcp/alerting/services.list
  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/configs/pcp/pmie/stack-alerts.pmie" \
    /etc/pcp/pmie/stack-alerts.pmie
  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/configs/systemd/pcp-alerting.conf" \
    /etc/tmpfiles.d/pcp-alerting.conf

  if command -v restorecon >/dev/null 2>&1; then
    restorecon -F \
      /usr/local/libexec/stack-alerting \
      /etc/pcp/alerting/services.list \
      /etc/pcp/pmie/stack-alerts.pmie
  fi
}

install_units() {
  local source

  for source in \
    pcp-alert-pmie.service \
    pcp-alert-notify@.service \
    pcp-service-check.service \
    pcp-service-check.timer \
    pcp-cert-check.service \
    pcp-cert-check.timer \
    pcp-heartbeat.service \
    pcp-heartbeat.timer; do
    install -D -m 0644 -o root -g root \
      "${REPO_ROOT}/configs/systemd/${source}" \
      "/etc/systemd/system/${source}"
  done

  for source in \
    traefik.service.d/onfailure.conf \
    wg-easy.service.d/onfailure.conf \
    pmcd.service.d/onfailure.conf \
    pmlogger.service.d/onfailure.conf \
    pmproxy.service.d/onfailure.conf \
    grafana-server.service.d/onfailure.conf \
    valkey.service.d/onfailure.conf; do
    install -D -m 0644 -o root -g root \
      "${REPO_ROOT}/configs/systemd/${source}" \
      "/etc/systemd/system/${source}"
  done
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  require_root
  require_commands
  create_user
  write_env
  install_runtime
  install_units

  systemd-tmpfiles --create /etc/tmpfiles.d/pcp-alerting.conf
  systemctl daemon-reload

  if ! runuser -u "${ALERTING_USER}" -- \
    pmie -C -c /etc/pcp/pmie/stack-alerts.pmie; then
    err "pmie rejected /etc/pcp/pmie/stack-alerts.pmie"
    exit 1
  fi

  systemctl enable --now \
    pcp-alert-pmie.service \
    pcp-service-check.timer \
    pcp-cert-check.timer \
    pcp-heartbeat.timer
  systemctl restart \
    pcp-alert-pmie.service \
    pcp-service-check.timer \
    pcp-cert-check.timer \
    pcp-heartbeat.timer

  printf 'Alert delivery installed.\n'
  printf 'Run a test: sudo systemctl start pcp-alert-notify@test.service\n'
}

main "$@"
