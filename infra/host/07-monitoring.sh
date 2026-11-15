#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
readonly REPO_ROOT

readonly SECRET_REF_DIR="/etc/secure-stack/secret-refs"
readonly GRAFANA_SECRET_REF="${SECRET_REF_DIR}/grafana.env"
readonly GRAFANA_SECRET_UNIT="/etc/systemd/system/stack-secrets-grafana.service"
readonly SECRET_HELPER="/usr/local/libexec/stack-secret-env"
readonly SECRET_TMPFILES="/etc/tmpfiles.d/stack-secrets.conf"

usage() {
  cat <<'USAGE'
Usage: 07-monitoring.sh <live|history|none>

Install or enable the selected local monitoring profile. The script expects
the configuration files staged by cloud-init under /etc/pcp, /etc/grafana,
and /etc/valkey.

The Grafana admin password is fetched from OCI Vault by
stack-secrets-grafana.service and written to /run/monitoring/grafana/env.
The reference file contains the secret OCID only. Set GRAFANA_SECRET_OCID
when the reference file is absent.
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

install_secret_support() {
  install -d -m 0700 -o root -g root "${SECRET_REF_DIR}"
  install -D -m 0755 -o root -g root \
    "${REPO_ROOT}/infra/runtime/secrets/materialize.sh" "${SECRET_HELPER}"
  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/infra/configs/systemd/stack-secrets.conf" \
    "${SECRET_TMPFILES}"
  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/infra/configs/systemd/stack-secrets-grafana.service" \
    "${GRAFANA_SECRET_UNIT}"
  systemd-tmpfiles --create "${SECRET_TMPFILES}"
  if command -v restorecon >/dev/null 2>&1; then
    restorecon -F "${SECRET_HELPER}" "${GRAFANA_SECRET_UNIT}" \
      "${SECRET_TMPFILES}"
  fi
}

ensure_grafana_secret_ref() {
  if [[ -n "${GRAFANA_SECRET_OCID:-}" ]]; then
    if [[ "${GRAFANA_SECRET_OCID}" != ocid1.* ]]; then
      err "GRAFANA_SECRET_OCID must be an OCI Vault secret OCID"
      exit 1
    fi
    umask 077
    printf 'GF_SECURITY_ADMIN_PASSWORD=%s\n' "${GRAFANA_SECRET_OCID}" \
      > "${GRAFANA_SECRET_REF}"
  elif [[ ! -s "${GRAFANA_SECRET_REF}" ]]; then
    err "set GRAFANA_SECRET_OCID or provide ${GRAFANA_SECRET_REF}"
    exit 1
  fi

  chown root:root "${GRAFANA_SECRET_REF}"
  chmod 0600 "${GRAFANA_SECRET_REF}"
}

install_pcp() {
  dnf install -y pcp pcp-zeroconf pcp-pmda-podman pcp-pmda-openmetrics
  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/infra/configs/pcp/pmproxy.env" /etc/sysconfig/pmproxy
  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/infra/configs/pcp/openmetrics/traefik.url" /etc/pcp/openmetrics/traefik.url
  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/infra/configs/systemd/pcp-openmetrics.conf" \
    /etc/tmpfiles.d/pcp-openmetrics.conf
  systemctl enable --now pmcd.service pmlogger.service pmproxy.service podman.socket

  if [[ -x /var/lib/pcp/pmdas/podman/Install ]]; then
    (cd /var/lib/pcp/pmdas/podman && ./Install)
  fi
  if [[ -x /var/lib/pcp/pmdas/openmetrics/Install ]]; then
    (cd /var/lib/pcp/pmdas/openmetrics && ./Install)
  fi

  systemd-tmpfiles --create /etc/tmpfiles.d/pcp-openmetrics.conf
  systemctl enable --now pmie.service 2>/dev/null || true
  systemctl restart pmcd.service pmproxy.service
}

install_grafana() {
  dnf install -y grafana grafana-pcp
  install -d -m 0750 -o grafana -g grafana /data/monitoring/grafana
  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/infra/configs/grafana/grafana.ini" /etc/grafana/grafana.ini
  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/infra/configs/grafana/provisioning/datasources/pcp.yml" \
    /etc/grafana/provisioning/datasources/pcp.yml
  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/infra/configs/grafana/provisioning/dashboards/stack.yml" \
    /etc/grafana/provisioning/dashboards/stack.yml
  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/infra/configs/grafana/dashboards/stack-overview.json" \
    /etc/grafana/dashboards/stack-overview.json
  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/infra/configs/systemd/grafana-server.service.d/env.conf" \
    /etc/systemd/system/grafana-server.service.d/env.conf
  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/infra/configs/systemd/grafana-server.service.d/data.conf" \
    /etc/systemd/system/grafana-server.service.d/data.conf
  install_secret_support
  ensure_grafana_secret_ref
  systemctl daemon-reload
  systemctl enable stack-secrets-grafana.service grafana-server.service
  systemctl restart stack-secrets-grafana.service
  systemctl restart grafana-server.service
}

install_valkey() {
  dnf install -y valkey
  install -d -m 0750 -o valkey -g valkey /data/monitoring/valkey
  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/infra/configs/valkey/valkey.conf" /etc/valkey/valkey.conf
  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/infra/configs/systemd/valkey.service.d/data.conf" \
    /etc/systemd/system/valkey.service.d/data.conf
  systemctl daemon-reload
  systemctl enable --now valkey.service
  systemctl restart pmproxy.service
}

main() {
  local profile="${1:-}"

  if [[ "${profile}" == "-h" || "${profile}" == "--help" ]]; then
    usage
    exit 0
  fi
  if [[ "${profile}" != "live" && "${profile}" != "history" && "${profile}" != "none" ]]; then
    usage >&2
    exit 1
  fi

  require_root
  install_pcp

  case "${profile}" in
    live)
      install_grafana
      ;;
    history)
      install_grafana
      install_valkey
      ;;
    none)
      printf 'Monitoring profile none: PCP is active, Grafana and Valkey are not installed.\n'
      ;;
  esac

  printf 'Monitoring profile %s applied.\n' "${profile}"
}

main "$@"
