#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
readonly REPO_ROOT

usage() {
  cat <<'USAGE'
Usage: 07-monitoring.sh <live|history|none>

Install or enable the selected local monitoring profile. The script expects
the configuration files staged by cloud-init under /etc/pcp, /etc/grafana,
and /etc/valkey. It does not write a Grafana password unless
GRAFANA_ADMIN_PASSWORD or GRAFANA_SECRET_OCID is provided.
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

write_grafana_env() {
  local env_file="/data/monitoring/grafana/env"
  local password="${GRAFANA_ADMIN_PASSWORD:-}"

  if [[ -s "${env_file}" ]]; then
    return 0
  fi

  if [[ -z "${password}" && -n "${GRAFANA_SECRET_OCID:-}" ]]; then
    if ! command -v oci >/dev/null 2>&1; then
      err "oci CLI is required to fetch GRAFANA_SECRET_OCID"
      exit 1
    fi
    password="$(oci secrets secret-bundle get \
      --secret-id "${GRAFANA_SECRET_OCID}" \
      --query "data.secretBundleContent.content" \
      --raw-output | base64 -d)"
  fi

  if [[ -z "${password}" ]]; then
    err "no Grafana password: set GRAFANA_ADMIN_PASSWORD or GRAFANA_SECRET_OCID"
    exit 1
  fi

  umask 077
  printf 'GF_SECURITY_ADMIN_PASSWORD=%s\n' "${password}" > "${env_file}"
  chown grafana:grafana "${env_file}"
  chmod 0600 "${env_file}"
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
  write_grafana_env
  systemctl daemon-reload
  systemctl enable --now grafana-server.service
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
