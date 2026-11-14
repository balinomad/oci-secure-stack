#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
readonly REPO_ROOT

readonly AUTHELIA_USER="authelia"
readonly AUTHELIA_IMAGE="authelia/authelia:4.39"
readonly AUTHELIA_SUBID_RANGE="400000-465535"
readonly ENV_FILE="/data/authelia/env"
readonly CONFIG_DIR="/data/authelia/config"
readonly DB_DIR="/data/authelia/db"
readonly STAGED_CONFIG="/etc/authelia/configuration.yml"
readonly STAGED_UNIT="/etc/authelia/authelia.container"
readonly RUNTIME_CONFIG="${CONFIG_DIR}/configuration.yml"
readonly USERS_FILE="${CONFIG_DIR}/users_database.yaml"

UPDATE_CONFIG=0
TMP_CONFIG=""

usage() {
  cat <<'USAGE'
Usage: 04-authelia.sh [--update-config]

Install or repair the rootless Authelia service from a repository checkout.
The script is idempotent. It creates the service user, subordinate ID range,
lingering, directories, environment file, configuration, user database, and
Quadlet unit, then validates and starts the service.

The runtime configuration at /data/authelia/config/configuration.yml is
preserved unless --update-config is given.

Environment:
  DOMAIN                       Required when /etc/authelia/configuration.yml is absent.
  ADMIN_EMAIL                  Required when users_database.yaml is absent.
  AUTHELIA_ADMIN_PASSWORD      Admin password for first bootstrap.
  AUTHELIA_ADMIN_SECRET_OCID   OCI Vault secret OCID for the admin password.
USAGE
}

err() {
  printf 'ERROR: %s\n' "$*" >&2
}

cleanup() {
  if [[ -n "${TMP_CONFIG}" ]]; then
    rm -f -- "${TMP_CONFIG}"
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
  for command in install systemctl loginctl useradd groupadd usermod getent \
    runuser podman curl openssl sed grep awk mktemp mountpoint date sleep base64; do
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

run_as_authelia() {
  local uid
  uid="$(id -u "${AUTHELIA_USER}")"
  runuser -u "${AUTHELIA_USER}" -- \
    env XDG_RUNTIME_DIR="/run/user/${uid}" "$@"
}

create_user() {
  if getent passwd "${AUTHELIA_USER}" >/dev/null 2>&1; then
    if ! getent group "${AUTHELIA_USER}" >/dev/null 2>&1; then
      groupadd --system "${AUTHELIA_USER}"
    fi
  else
    if ! getent group "${AUTHELIA_USER}" >/dev/null 2>&1; then
      groupadd --system "${AUTHELIA_USER}"
    fi
    useradd --system --gid "${AUTHELIA_USER}" \
      --home-dir "/home/${AUTHELIA_USER}" --shell /usr/sbin/nologin \
      "${AUTHELIA_USER}"
  fi

  install -d -m 0700 -o "${AUTHELIA_USER}" -g "${AUTHELIA_USER}" \
    "/home/${AUTHELIA_USER}"
}

enforce_subids() {
  local current_subuid
  local current_subgid

  current_subuid="$(
    awk -F: '$1 == "authelia" { print $2 ":" $3; exit }' /etc/subuid
  )"
  if [[ -z "${current_subuid}" ]]; then
    usermod --add-subuids "${AUTHELIA_SUBID_RANGE}" "${AUTHELIA_USER}"
  elif [[ "${current_subuid}" != "400000:65536" ]]; then
    err "authelia subordinate UID range is ${current_subuid}, expected 400000:65536"
    exit 1
  fi

  current_subgid="$(
    awk -F: '$1 == "authelia" { print $2 ":" $3; exit }' /etc/subgid
  )"
  if [[ -z "${current_subgid}" ]]; then
    usermod --add-subgids "${AUTHELIA_SUBID_RANGE}" "${AUTHELIA_USER}"
  elif [[ "${current_subgid}" != "400000:65536" ]]; then
    err "authelia subordinate GID range is ${current_subgid}, expected 400000:65536"
    exit 1
  fi
}

enable_linger() {
  local uid
  local linger
  local _i

  uid="$(id -u "${AUTHELIA_USER}")"
  linger="$(loginctl show-user "${AUTHELIA_USER}" -p Linger --value 2>/dev/null || true)"
  if [[ "${linger}" != "yes" ]]; then
    loginctl enable-linger "${AUTHELIA_USER}"
  fi

  systemctl start "user@${uid}.service" 2>/dev/null || true
  for (( _i = 0; _i < 60; _i++ )); do
    if [[ -d "/run/user/${uid}" ]]; then
      return 0
    fi
    sleep 1
  done

  err "user manager runtime directory /run/user/${uid} did not appear"
  exit 1
}

ensure_dirs() {
  install -d -m 0700 -o "${AUTHELIA_USER}" -g "${AUTHELIA_USER}" \
    /data/authelia "${CONFIG_DIR}" "${DB_DIR}"
}

ensure_env() {
  local uid
  local gid
  local key
  local value

  uid="$(id -u "${AUTHELIA_USER}")"
  gid="$(id -g "${AUTHELIA_USER}")"
  umask 077

  if [[ ! -f "${ENV_FILE}" ]]; then
    {
      printf 'AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET=%s\n' \
        "$(openssl rand -hex 32)"
      printf 'AUTHELIA_SESSION_SECRET=%s\n' "$(openssl rand -hex 32)"
      printf 'AUTHELIA_STORAGE_ENCRYPTION_KEY=%s\n' "$(openssl rand -hex 32)"
    } > "${ENV_FILE}"
  fi

  for key in \
    AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET \
    AUTHELIA_SESSION_SECRET \
    AUTHELIA_STORAGE_ENCRYPTION_KEY; do
    if ! grep -q "^${key}=." "${ENV_FILE}"; then
      value="$(openssl rand -hex 32)"
      printf '%s=%s\n' "${key}" "${value}" >> "${ENV_FILE}"
    fi
  done

  if ! grep -q '^PUID=' "${ENV_FILE}"; then
    printf 'PUID=%s\n' "${uid}" >> "${ENV_FILE}"
  fi
  if ! grep -q '^PGID=' "${ENV_FILE}"; then
    printf 'PGID=%s\n' "${gid}" >> "${ENV_FILE}"
  fi
  if ! grep -q '^UMASK=' "${ENV_FILE}"; then
    printf 'UMASK=0077\n' >> "${ENV_FILE}"
  fi

  chown "${AUTHELIA_USER}:${AUTHELIA_USER}" "${ENV_FILE}"
  chmod 0600 "${ENV_FILE}"
}

install_config() {
  install -d -m 0700 -o root -g root /etc/authelia

  if [[ ! -f "${STAGED_CONFIG}" ]]; then
    if [[ -z "${DOMAIN:-}" ]]; then
      err "DOMAIN is required when ${STAGED_CONFIG} is absent"
      exit 1
    fi
    TMP_CONFIG="$(mktemp)"
    sed "s|\${DOMAIN}|${DOMAIN}|g" \
      "${REPO_ROOT}/infra/configs/authelia/configuration.yml" > "${TMP_CONFIG}"
    install -m 0600 -o root -g root "${TMP_CONFIG}" "${STAGED_CONFIG}"
  fi

  chown root:root "${STAGED_CONFIG}"
  chmod 0600 "${STAGED_CONFIG}"

  if grep -q "\${DOMAIN}" "${STAGED_CONFIG}"; then
    err "${STAGED_CONFIG} contains an unrendered \${DOMAIN}"
    exit 1
  fi

  if [[ ! -f "${RUNTIME_CONFIG}" ]]; then
    install -m 0600 -o "${AUTHELIA_USER}" -g "${AUTHELIA_USER}" \
      "${STAGED_CONFIG}" "${RUNTIME_CONFIG}"
  elif [[ "${UPDATE_CONFIG}" -eq 1 ]]; then
    cp -a "${RUNTIME_CONFIG}" \
      "${RUNTIME_CONFIG}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    install -m 0600 -o "${AUTHELIA_USER}" -g "${AUTHELIA_USER}" \
      "${STAGED_CONFIG}" "${RUNTIME_CONFIG}"
  fi
}

ensure_image() {
  if ! run_as_authelia podman image exists "${AUTHELIA_IMAGE}"; then
    run_as_authelia podman pull "${AUTHELIA_IMAGE}"
  fi
}

fetch_admin_password() {
  local password="${AUTHELIA_ADMIN_PASSWORD:-}"

  if [[ -z "${password}" && -f /run/authelia-bootstrap.tmp ]]; then
    password="$(cat /run/authelia-bootstrap.tmp)"
    rm -f /run/authelia-bootstrap.tmp
  fi
  if [[ -z "${password}" && -n "${AUTHELIA_ADMIN_SECRET_OCID:-}" ]]; then
    if ! command -v oci >/dev/null 2>&1; then
      err "the OCI CLI is required to fetch AUTHELIA_ADMIN_SECRET_OCID"
      exit 1
    fi
    password="$(
      oci secrets secret-bundle get \
        --secret-id "${AUTHELIA_ADMIN_SECRET_OCID}" \
        --query "data.secretBundleContent.content" \
        --raw-output | base64 -d
    )"
  fi

  if [[ -z "${password}" ]]; then
    err "set AUTHELIA_ADMIN_PASSWORD or AUTHELIA_ADMIN_SECRET_OCID"
    exit 1
  fi

  printf '%s\n' "${password}"
}

ensure_users_database() {
  local password
  local password_hash
  local email="${ADMIN_EMAIL:-}"

  if [[ -f "${USERS_FILE}" ]]; then
    return 0
  fi
  if [[ -z "${email}" ]]; then
    err "ADMIN_EMAIL is required when ${USERS_FILE} is absent"
    exit 1
  fi

  password="$(fetch_admin_password)"
  password_hash="$(
    run_as_authelia podman run --rm "${AUTHELIA_IMAGE}" \
      authelia crypto hash generate argon2 --password "${password}" \
      | awk '/^Digest:/ { print $2 }'
  )"
  if [[ -z "${password_hash}" ]]; then
    err "failed to generate the Authelia admin password hash"
    exit 1
  fi

  umask 077
  {
    printf 'users:\n'
    printf '  admin:\n'
    printf '    displayname: "Admin"\n'
    printf '    password: "%s"\n' "${password_hash}"
    printf '    email: "%s"\n' "${email}"
    printf '    groups:\n'
    printf '      - admins\n'
  } > "${USERS_FILE}"
  chown "${AUTHELIA_USER}:${AUTHELIA_USER}" "${USERS_FILE}"
  chmod 0600 "${USERS_FILE}"
}

stop_service() {
  run_as_authelia systemctl --user stop authelia.service >/dev/null 2>&1 || true
}

migrate_database() {
  local legacy
  local suffix
  local source
  local target="${DB_DIR}/authelia.sqlite3"

  for legacy in db.sqlite3 storage.sqlite storage.sqlite3; do
    if [[ ! -f "${DB_DIR}/${legacy}" ]]; then
      continue
    fi
    if [[ -e "${target}" ]]; then
      err "both ${DB_DIR}/${legacy} and ${target} exist; resolve manually"
      exit 1
    fi
    for suffix in "" "-wal" "-shm"; do
      source="${DB_DIR}/${legacy}${suffix}"
      if [[ -f "${source}" ]]; then
        mv "${source}" "${target}${suffix}"
      fi
    done
    printf 'Migrated %s to %s\n' "${DB_DIR}/${legacy}" "${target}"
  done
}

install_unit() {
  local uid
  local unit_dir

  uid="$(id -u "${AUTHELIA_USER}")"
  unit_dir="/etc/containers/systemd/users/${uid}"

  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/infra/configs/podman/authelia.container" "${STAGED_UNIT}"
  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/infra/configs/podman/authelia.container" \
    "${unit_dir}/authelia.container"
}

configure_selinux() {
  if command -v semanage >/dev/null 2>&1; then
    semanage fcontext -m -t container_file_t "/data/authelia(/.*)?" 2>/dev/null \
      || semanage fcontext -a -t container_file_t "/data/authelia(/.*)?"
  fi
  if command -v restorecon >/dev/null 2>&1; then
    restorecon -RF /data/authelia
  fi
}

fix_ownership() {
  chown -R "${AUTHELIA_USER}:${AUTHELIA_USER}" /data/authelia
  chmod 0700 /data/authelia "${CONFIG_DIR}" "${DB_DIR}"
  chmod 0600 "${ENV_FILE}" "${RUNTIME_CONFIG}" "${USERS_FILE}"
}

validate_config() {
  run_as_authelia podman run --rm \
    --env-file "${ENV_FILE}" \
    -v "${CONFIG_DIR}:/config:Z" \
    -v "${DB_DIR}:/data:Z" \
    "${AUTHELIA_IMAGE}" \
    authelia validate-config --config /config/configuration.yml
}

start_service() {
  systemctl daemon-reload
  run_as_authelia systemctl --user daemon-reload
  run_as_authelia systemctl --user enable authelia.service
  run_as_authelia systemctl --user restart authelia.service
}

check_health() {
  local _i

  for (( _i = 0; _i < 60; _i++ )); do
    if curl -fsS --max-time 2 http://127.0.0.1:9091/api/health \
      >/dev/null 2>&1; then
      printf 'Authelia is healthy.\n'
      return 0
    fi
    sleep 2
  done

  err "Authelia did not become healthy"
  printf 'Inspect: sudo journalctl _UID=%s -n 100\n' "$(id -u "${AUTHELIA_USER}")" >&2
  exit 1
}

main() {
  local arg

  for arg in "$@"; do
    case "${arg}" in
      --update-config)
        UPDATE_CONFIG=1
        ;;
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
  enforce_subids
  enable_linger
  ensure_dirs
  ensure_image
  ensure_env
  install_config
  ensure_users_database
  install_unit
  stop_service
  migrate_database
  configure_selinux
  fix_ownership
  validate_config
  start_service
  check_health

  printf 'Authelia installed or updated.\n'
}

trap cleanup EXIT
main "$@"
