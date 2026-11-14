#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
readonly REPO_ROOT

readonly TRAEFIK_USER="traefik"
readonly TRAEFIK_CONFIG="/etc/traefik/traefik.yaml"
readonly TRAEFIK_DYNAMIC_DIR="/etc/traefik/config"
readonly TRAEFIK_ENV="/etc/traefik/env"
readonly TRAEFIK_BINARY="/usr/local/bin/traefik"
readonly TRAEFIK_UNIT="/etc/systemd/system/traefik.service"
readonly TRAEFIK_LOGROTATE="/etc/logrotate.d/traefik"
readonly LETSENCRYPT_LINK="/etc/traefik/letsencrypt"
readonly LETSENCRYPT_DIR="/data/traefik/letsencrypt"
readonly LOG_LINK="/var/log/traefik"
readonly LOG_DIR="/data/logs/traefik"
readonly CF_PLACEHOLDER="CF_DNS_API_TOKEN=<<INJECT_AT_DEPLOYMENT>>"

TMP_CONFIG=""
TMP_DIR=""
TRAEFIK_ARCH=""
TRAEFIK_VERSION=""
TRAEFIK_SHA256=""
TRAEFIK_REPOSITORY=""
TRAEFIK_ASSET=""

usage() {
  cat <<'USAGE'
Usage: 03-traefik.sh

Install or repair the Traefik edge router from a repository checkout.
The script is idempotent. It creates the service user, directories, symlinks,
environment file, reads locked release values from infra/manifest.lock.yaml, installs
the systemd unit and missing configuration, then verifies the release checksum
and starts the service.

Existing Traefik configuration files under /etc/traefik are preserved.
Delete a file or render it from infra/configs/traefik to replace it.

Environment:
  DOMAIN             Required when a Traefik configuration file is absent.
  ACME_EMAIL         Required when a Traefik configuration file is absent.
  CF_DNS_API_TOKEN   Cloudflare API token for the DNS challenge.
  CF_SECRET_OCID     OCI Vault secret OCID for CF_DNS_API_TOKEN.
USAGE
}

err() {
  printf 'ERROR: %s\n' "$*" >&2
}

cleanup() {
  if [[ -n "${TMP_CONFIG}" ]]; then
    rm -f -- "${TMP_CONFIG}"
  fi
  if [[ -n "${TMP_DIR}" ]]; then
    rm -rf -- "${TMP_DIR}"
  fi
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "run this script as root"
    exit 1
  fi
}

require_commands() {
  local command
  for command in install systemctl useradd groupadd getent chown chmod \
    curl sha256sum tar uname sed grep awk mktemp mountpoint sleep base64 \
    ln readlink rmdir find; do
    if ! command -v "${command}" >/dev/null 2>&1; then
      err "required command not found: ${command}"
      exit 1
    fi
  done
}

require_data_mount() {
  if ! mountpoint -q /data; then
    err "/data is not a mountpoint"
    exit 1
  fi
}

create_user() {
  if getent passwd "${TRAEFIK_USER}" >/dev/null 2>&1; then
    if ! getent group "${TRAEFIK_USER}" >/dev/null 2>&1; then
      groupadd --system "${TRAEFIK_USER}"
    fi
  else
    if ! getent group "${TRAEFIK_USER}" >/dev/null 2>&1; then
      groupadd --system "${TRAEFIK_USER}"
    fi
    useradd --system --gid "${TRAEFIK_USER}" \
      --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin \
      "${TRAEFIK_USER}"
  fi
}

ensure_dirs() {
  install -d -m 0750 -o "${TRAEFIK_USER}" -g "${TRAEFIK_USER}" \
    /etc/traefik "${TRAEFIK_DYNAMIC_DIR}" /data/traefik
  install -d -m 0700 -o "${TRAEFIK_USER}" -g "${TRAEFIK_USER}" \
    "${LETSENCRYPT_DIR}"
  install -d -m 0750 -o "${TRAEFIK_USER}" -g "${TRAEFIK_USER}" \
    "${LOG_DIR}"
}

ensure_env() {
  local token="${CF_DNS_API_TOKEN:-}"

  if [[ -s "${TRAEFIK_ENV}" ]] \
    && grep -q '^CF_DNS_API_TOKEN=.' "${TRAEFIK_ENV}" \
    && ! grep -qxF "${CF_PLACEHOLDER}" "${TRAEFIK_ENV}"; then
    chown "${TRAEFIK_USER}:${TRAEFIK_USER}" "${TRAEFIK_ENV}"
    chmod 0600 "${TRAEFIK_ENV}"
    return 0
  fi

  if [[ -z "${token}" && -n "${CF_SECRET_OCID:-}" ]]; then
    if ! command -v oci >/dev/null 2>&1; then
      err "the OCI CLI is required to fetch CF_SECRET_OCID"
      exit 1
    fi
    token="$(
      oci secrets secret-bundle get \
        --secret-id "${CF_SECRET_OCID}" \
        --query "data.secretBundleContent.content" \
        --raw-output | base64 -d
    )"
  fi

  if [[ -z "${token}" ]]; then
    err "set CF_DNS_API_TOKEN or CF_SECRET_OCID"
    exit 1
  fi

  umask 077
  printf 'CF_DNS_API_TOKEN=%s\n' "${token}" > "${TRAEFIK_ENV}"
  chown "${TRAEFIK_USER}:${TRAEFIK_USER}" "${TRAEFIK_ENV}"
  chmod 0600 "${TRAEFIK_ENV}"
}

render_if_missing() {
  local source="$1"
  local target="$2"

  if [[ -f "${target}" ]]; then
    return 0
  fi

  TMP_CONFIG="$(mktemp)"
  sed -e "s|\${DOMAIN}|${DOMAIN}|g" \
    -e "s|\${ACME_EMAIL}|${ACME_EMAIL}|g" \
    "${source}" > "${TMP_CONFIG}"
  install -m 0644 -o "${TRAEFIK_USER}" -g "${TRAEFIK_USER}" \
    "${TMP_CONFIG}" "${target}"
  rm -f -- "${TMP_CONFIG}"
  TMP_CONFIG=""
}

ensure_config() {
  local missing=0
  local file

  for file in "${TRAEFIK_CONFIG}" "${TRAEFIK_DYNAMIC_DIR}/infra.yaml" \
    "${TRAEFIK_DYNAMIC_DIR}/cockpit.yaml"; do
    if [[ ! -f "${file}" ]]; then
      missing=1
    fi
  done

  if [[ "${missing}" -eq 1 ]]; then
    if [[ -z "${DOMAIN:-}" || -z "${ACME_EMAIL:-}" ]]; then
      err "DOMAIN and ACME_EMAIL are required when config is absent"
      exit 1
    fi
  fi

  render_if_missing "${REPO_ROOT}/infra/configs/traefik/traefik.yml" \
    "${TRAEFIK_CONFIG}"
  render_if_missing "${REPO_ROOT}/infra/configs/traefik/dynamic/infra.yml" \
    "${TRAEFIK_DYNAMIC_DIR}/infra.yaml"
  render_if_missing "${REPO_ROOT}/infra/configs/traefik/dynamic/cockpit.yml" \
    "${TRAEFIK_DYNAMIC_DIR}/cockpit.yaml"

  for file in "${TRAEFIK_CONFIG}" "${TRAEFIK_DYNAMIC_DIR}/infra.yaml" \
    "${TRAEFIK_DYNAMIC_DIR}/cockpit.yaml"; do
    if grep -q "\${" "${file}"; then
      err "${file} contains an unrendered placeholder"
      exit 1
    fi
    chown "${TRAEFIK_USER}:${TRAEFIK_USER}" "${file}"
    chmod 0644 "${file}"
  done
}

fix_ownership() {
  chown "${TRAEFIK_USER}:${TRAEFIK_USER}" /etc/traefik "${TRAEFIK_DYNAMIC_DIR}"
  chmod 0750 /etc/traefik "${TRAEFIK_DYNAMIC_DIR}"
  chown -R "${TRAEFIK_USER}:${TRAEFIK_USER}" /data/traefik "${LOG_DIR}"
  chmod 0750 /data/traefik "${LOG_DIR}"
  chmod 0700 "${LETSENCRYPT_DIR}"
}

install_files() {
  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/infra/configs/traefik/logrotate.conf" "${TRAEFIK_LOGROTATE}"
  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/infra/configs/systemd/traefik.service" "${TRAEFIK_UNIT}"
}

read_release() {
  local lock="${REPO_ROOT}/infra/manifest.lock.yaml"
  local parsed
  local architecture
  local source_type
  local repository
  local asset
  local version
  local sha256

  if [[ ! -f "${lock}" ]]; then
    err "release lock not found: ${lock}"
    exit 1
  fi

  parsed="$(
    awk '
      $1 == "architecture:" { architecture = $2 }
      $0 == "components:" { in_components = 1; next }
      in_components && $0 == "  traefik:" { in_traefik = 1; next }
      in_traefik && $0 ~ /^  [^ ]/ { exit }
      in_traefik && $1 == "source_type:" { source_type = $2 }
      in_traefik && $1 == "repository:" { repository = $2 }
      in_traefik && $1 == "asset:" { asset = $2 }
      in_traefik && $1 == "version:" { version = $2 }
      in_traefik && $1 == "sha256:" { sha256 = $2 }
      END { print architecture, source_type, repository, asset, version, sha256 }
    ' "${lock}"
  )"

  if [[ -z "${parsed}" ]]; then
    err "release lock has no Traefik entry: ${lock}"
    exit 1
  fi

  read -r architecture source_type repository asset version sha256 <<< "${parsed}"

  if [[ "${architecture}" != "amd64" && "${architecture}" != "arm64" ]]; then
    err "invalid architecture in ${lock}"
    exit 1
  fi
  if [[ "${source_type}" != "github-release" ]]; then
    err "invalid Traefik source type in ${lock}"
    exit 1
  fi
  if [[ ! "${repository}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    err "invalid Traefik repository in ${lock}"
    exit 1
  fi
  if [[ -z "${asset}" || "${asset}" == */* || "${asset}" =~ [[:space:]] ]]; then
    err "invalid Traefik asset in ${lock}"
    exit 1
  fi
  if [[ ! "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    err "invalid Traefik version in ${lock}"
    exit 1
  fi
  if [[ ! "${sha256}" =~ ^[0-9a-f]{64}$ ]]; then
    err "invalid Traefik checksum in ${lock}"
    exit 1
  fi

  TRAEFIK_ARCH="${architecture}"
  TRAEFIK_VERSION="${version}"
  TRAEFIK_SHA256="${sha256}"
  TRAEFIK_REPOSITORY="${repository}"
  TRAEFIK_ASSET="${asset}"
}

install_binary() {
  local version="${TRAEFIK_VERSION#v}"
  local host_arch
  local archive

  if [[ -x "${TRAEFIK_BINARY}" ]] \
    && "${TRAEFIK_BINARY}" version 2>/dev/null \
      | grep -q "Version:[[:space:]]*${version}"; then
    printf 'Traefik %s is already installed.\n' "${version}"
    return 0
  fi

  case "$(uname -m)" in
    x86_64)
      host_arch="amd64"
      ;;
    aarch64)
      host_arch="arm64"
      ;;
    *)
      err "unsupported architecture: $(uname -m)"
      exit 1
      ;;
  esac
  if [[ "${host_arch}" != "${TRAEFIK_ARCH}" ]]; then
    err "lock architecture ${TRAEFIK_ARCH} does not match host architecture ${host_arch}"
    exit 1
  fi

  TMP_DIR="$(mktemp -d)"
  archive="${TMP_DIR}/traefik.tar.gz"
  curl -fsSL --connect-timeout 10 --max-time 300 \
    "https://github.com/${TRAEFIK_REPOSITORY}/releases/download/${TRAEFIK_VERSION}/${TRAEFIK_ASSET}" \
    -o "${archive}"
  printf '%s  %s\n' "${TRAEFIK_SHA256}" "${archive}" | sha256sum -c -
  tar -xzf "${archive}" -C "${TMP_DIR}" traefik
  install -m 0755 -o root -g root "${TMP_DIR}/traefik" "${TRAEFIK_BINARY}"
  printf 'Installed Traefik %s.\n' "${version}"
}

ensure_symlink() {
  local target="$1"
  local link="$2"

  if [[ -L "${link}" ]]; then
    if [[ "$(readlink "${link}")" == "${target}" ]]; then
      return 0
    fi
    rm -f -- "${link}"
  elif [[ -d "${link}" ]]; then
    if [[ -n "$(find "${link}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
      err "${link} is a non-empty directory; move data to ${target}"
      exit 1
    fi
    rmdir -- "${link}"
  elif [[ -e "${link}" ]]; then
    err "${link} exists and is not a directory or symlink"
    exit 1
  fi

  ln -s "${target}" "${link}"
}

ensure_symlinks() {
  ensure_symlink "${LETSENCRYPT_DIR}" "${LETSENCRYPT_LINK}"
  ensure_symlink "${LOG_DIR}" "${LOG_LINK}"
}

configure_selinux() {
  if command -v semanage >/dev/null 2>&1; then
    semanage fcontext -m -t bin_t "${TRAEFIK_BINARY}" 2>/dev/null \
      || semanage fcontext -a -t bin_t "${TRAEFIK_BINARY}"
    semanage fcontext -m -t etc_t "/etc/traefik(/.*)?" 2>/dev/null \
      || semanage fcontext -a -t etc_t "/etc/traefik(/.*)?"
    semanage fcontext -m -t var_log_t "/data/logs/traefik(/.*)?" 2>/dev/null \
      || semanage fcontext -a -t var_log_t "/data/logs/traefik(/.*)?"
    semanage port -a -t http_port_t -p tcp 8082 2>/dev/null \
      || semanage port -m -t http_port_t -p tcp 8082
  fi
  if command -v restorecon >/dev/null 2>&1; then
    restorecon -RF "${TRAEFIK_BINARY}" /etc/traefik "${LOG_DIR}"
  fi
}

configure_firewall() {
  local changed=0
  local service

  if ! command -v firewall-cmd >/dev/null 2>&1; then
    err "firewalld is required to open ports 80 and 443"
    exit 1
  fi
  if ! firewall-cmd --state >/dev/null 2>&1; then
    err "firewalld is not running"
    exit 1
  fi

  for service in http https; do
    if ! firewall-cmd --permanent --query-service="${service}" \
      >/dev/null 2>&1; then
      firewall-cmd --permanent --add-service="${service}" >/dev/null
      changed=1
    fi
  done
  if [[ "${changed}" -eq 1 ]]; then
    firewall-cmd --reload >/dev/null
  fi
}

start_service() {
  systemctl daemon-reload
  systemctl enable "${TRAEFIK_UNIT##*/}"
  systemctl restart "${TRAEFIK_UNIT##*/}"
}

check_health() {
  local code
  local _i

  for (( _i = 0; _i < 60; _i++ )); do
    if curl --noproxy '*' -fsS --max-time 2 \
      http://127.0.0.1:8080/ping >/dev/null 2>&1 \
      && curl --noproxy '*' -fsS --max-time 2 \
        http://127.0.0.1:8082/metrics >/dev/null 2>&1; then
      code="$(
        curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' \
          --max-time 2 http://127.0.0.1/ || true
      )"
      if [[ "${code}" != "301" ]]; then
        err "expected HTTP 301 redirect, got ${code:-no response}"
        exit 1
      fi
      printf 'Traefik is healthy.\n'
      return 0
    fi
    sleep 2
  done

  err "Traefik did not become healthy"
  printf 'Inspect: journalctl -u traefik.service -n 100\n' >&2
  exit 1
}

main() {
  local arg

  for arg in "$@"; do
    case "${arg}" in
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        exit 1
        ;;
    esac
  done

  require_root
  require_commands
  require_data_mount
  create_user
  ensure_dirs
  ensure_env
  ensure_config
  fix_ownership
  install_files
  read_release
  install_binary
  ensure_symlinks
  configure_selinux
  configure_firewall
  start_service
  check_health

  printf 'Traefik installed or updated.\n'
}

trap cleanup EXIT
main "$@"
