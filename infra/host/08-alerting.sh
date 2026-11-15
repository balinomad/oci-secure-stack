#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
readonly REPO_ROOT

readonly ALERTING_USER="alerting"
readonly ALERTING_RUNTIME_ENV="/run/monitoring/alerting/env"
readonly STATE_DIR="/var/lib/stack-alerting"
readonly SECRET_REF_DIR="/etc/secure-stack/secret-refs"
readonly ALERTING_SECRET_REF="${SECRET_REF_DIR}/alerting.env"
readonly SECRET_HELPER="/usr/local/libexec/stack-secret-env"
readonly SECRET_TMPFILES="/etc/tmpfiles.d/stack-secrets.conf"

usage() {
  cat <<'USAGE'
Usage: 08-alerting.sh

Install or update the alert delivery components from a repository checkout.
The script is idempotent. It creates the alerting service user, installs the
runtime script, pmie rules, systemd units, and timers.

The alert URLs are fetched from OCI Vault by stack-secrets-alerting.service and
written to /run/monitoring/alerting/env. The reference file contains the secret
OCIDs only. Set both OCIDs to create or rotate the reference file. An existing
reference file is preserved when neither OCID is set.

Environment:
  ALERT_WEBHOOK_SECRET_OCID    OCI Vault secret OCID for the webhook URL.
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

install_secret_support() {
  install -d -m 0700 -o root -g root "${SECRET_REF_DIR}"
  install -D -m 0755 -o root -g root \
    "${REPO_ROOT}/infra/runtime/secrets/materialize.sh" "${SECRET_HELPER}"
  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/infra/configs/systemd/stack-secrets.conf" \
    "${SECRET_TMPFILES}"
  if command -v restorecon >/dev/null 2>&1; then
    restorecon -F "${SECRET_HELPER}" "${SECRET_TMPFILES}"
  fi
}

ensure_secret_ref() {
  local webhook_ocid="${ALERT_WEBHOOK_SECRET_OCID:-}"
  local heartbeat_ocid="${ALERT_HEARTBEAT_SECRET_OCID:-}"

  if [[ -n "${webhook_ocid}" && -z "${heartbeat_ocid}" ]] \
    || [[ -z "${webhook_ocid}" && -n "${heartbeat_ocid}" ]]; then
    err "set both ALERT_WEBHOOK_SECRET_OCID and ALERT_HEARTBEAT_SECRET_OCID"
    exit 1
  fi

  if [[ -n "${webhook_ocid}" ]]; then
    if [[ "${webhook_ocid}" != ocid1.* ]]; then
      err "ALERT_WEBHOOK_SECRET_OCID must be an OCI Vault secret OCID"
      exit 1
    fi
    if [[ "${heartbeat_ocid}" != ocid1.* ]]; then
      err "ALERT_HEARTBEAT_SECRET_OCID must be an OCI Vault secret OCID"
      exit 1
    fi
    umask 077
    {
      printf 'ALERT_WEBHOOK_URL=%s\n' "${webhook_ocid}"
      printf 'ALERT_HEARTBEAT_URL=%s\n' "${heartbeat_ocid}"
    } > "${ALERTING_SECRET_REF}"
  elif [[ ! -s "${ALERTING_SECRET_REF}" ]]; then
    err "set both alert secret OCIDs or provide ${ALERTING_SECRET_REF}"
    exit 1
  fi

  chown root:root "${ALERTING_SECRET_REF}"
  chmod 0600 "${ALERTING_SECRET_REF}"
}

validate_runtime_env() {
  local key
  local value
  local webhook_url=""
  local heartbeat_url=""

  if [[ ! -r "${ALERTING_RUNTIME_ENV}" ]]; then
    err "cannot read ${ALERTING_RUNTIME_ENV}"
    exit 1
  fi

  while IFS='=' read -r key value || [[ -n "${key}" ]]; do
    case "${key}" in
      ALERT_WEBHOOK_URL)
        webhook_url="${value}"
        ;;
      ALERT_HEARTBEAT_URL)
        heartbeat_url="${value}"
        ;;
    esac
  done < "${ALERTING_RUNTIME_ENV}"

  if [[ "${webhook_url}" != https://* ]]; then
    err "the webhook URL must use HTTPS"
    exit 1
  fi
  if [[ "${heartbeat_url}" != https://* ]]; then
    err "the heartbeat URL must use HTTPS"
    exit 1
  fi
}

install_runtime() {
  install -D -m 0755 -o root -g root \
    "${REPO_ROOT}/infra/runtime/alerting/alerting.sh" \
    /usr/local/libexec/stack-alerting
  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/infra/configs/alerting/services.list" \
    /etc/pcp/alerting/services.list
  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/infra/configs/pcp/pmie/stack-alerts.pmie" \
    /etc/pcp/pmie/stack-alerts.pmie
  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/infra/configs/systemd/pcp-alerting.conf" \
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
    stack-secrets-alerting.service \
    pcp-alert-pmie.service \
    pcp-alert-notify@.service \
    pcp-service-check.service \
    pcp-service-check.timer \
    pcp-cert-check.service \
    pcp-cert-check.timer \
    pcp-heartbeat.service \
    pcp-heartbeat.timer; do
    install -D -m 0644 -o root -g root \
      "${REPO_ROOT}/infra/configs/systemd/${source}" \
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
      "${REPO_ROOT}/infra/configs/systemd/${source}" \
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
  install_secret_support
  ensure_secret_ref
  install_runtime
  install_units

  systemd-tmpfiles --create /etc/tmpfiles.d/stack-secrets.conf \
    /etc/tmpfiles.d/pcp-alerting.conf
  systemctl daemon-reload
  systemctl enable stack-secrets-alerting.service
  systemctl restart stack-secrets-alerting.service
  validate_runtime_env

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
