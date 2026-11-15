#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
readonly REPO_ROOT

readonly AUTHELIA_USER="authelia"
AUTHELIA_IMAGE=""
readonly AUTHELIA_SUBID_RANGE="400000-465535"
readonly RUNTIME_ENV_FILE="/run/authelia/env"
readonly SECRET_REF_DIR="/etc/secure-stack/secret-refs"
readonly AUTHELIA_SECRET_REF="${SECRET_REF_DIR}/authelia.env"
readonly AUTHELIA_SECRET_UNIT="/etc/systemd/system/stack-secrets-authelia.service"
readonly SECRET_HELPER="/usr/local/libexec/stack-secret-env"
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
lingering, directories, Vault secret reference, configuration, user database,
and Quadlet unit, then materializes the runtime secrets, validates, and starts
the service.

The runtime configuration at /data/authelia/config/configuration.yml is
preserved unless --update-config is given. The legacy file /data/authelia/env
is not modified.

Environment:
  DOMAIN                                  Required when /etc/authelia/configuration.yml is absent.
  ADMIN_EMAIL                             Required when users_database.yaml is absent.
  AUTHELIA_ADMIN_PASSWORD                 Admin password for first bootstrap.
  AUTHELIA_ADMIN_SECRET_OCID              OCI Vault secret OCID for the admin password.
  AUTHELIA_JWT_SECRET_OCID                OCI Vault secret OCID for the JWT secret.
  AUTHELIA_SESSION_SECRET_OCID            OCI Vault secret OCID for the session secret.
  AUTHELIA_STORAGE_ENCRYPTION_KEY_OCID    OCI Vault secret OCID for the storage encryption key.
                                          The three secret OCIDs are required when the reference file is absent.
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
    runuser podman curl sed grep awk cut mktemp mountpoint stat date sleep \
    base64 oci; do
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

install_secret_support() {
  install -d -m 0700 -o root -g root "${SECRET_REF_DIR}"
  install -D -m 0755 -o root -g root \
    "${REPO_ROOT}/infra/runtime/secrets/materialize.sh" "${SECRET_HELPER}"
  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/infra/configs/systemd/stack-secrets-authelia.service" \
    "${AUTHELIA_SECRET_UNIT}"
  if command -v restorecon >/dev/null 2>&1; then
    restorecon -F "${SECRET_HELPER}" "${AUTHELIA_SECRET_UNIT}"
  fi
}

ensure_secret_ref() {
  local jwt_ocid="${AUTHELIA_JWT_SECRET_OCID:-}"
  local session_ocid="${AUTHELIA_SESSION_SECRET_OCID:-}"
  local storage_ocid="${AUTHELIA_STORAGE_ENCRYPTION_KEY_OCID:-}"
  local key
  local ocid

  if [[ -n "${jwt_ocid}" || -n "${session_ocid}" || -n "${storage_ocid}" ]]; then
    if [[ -z "${jwt_ocid}" || -z "${session_ocid}" || -z "${storage_ocid}" ]]; then
      err "set all three Authelia secret OCIDs or none"
      exit 1
    fi
    for ocid in "${jwt_ocid}" "${session_ocid}" "${storage_ocid}"; do
      if [[ "${ocid}" != ocid1.* ]]; then
        err "Authelia secret OCIDs must use ocid1. form"
        exit 1
      fi
    done
    umask 077
    {
      printf '%s=%s\n' \
        "AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET" "${jwt_ocid}"
      printf 'AUTHELIA_SESSION_SECRET=%s\n' "${session_ocid}"
      printf 'AUTHELIA_STORAGE_ENCRYPTION_KEY=%s\n' "${storage_ocid}"
    } > "${AUTHELIA_SECRET_REF}"
  elif [[ ! -s "${AUTHELIA_SECRET_REF}" ]]; then
    err "set all three Authelia secret OCIDs or provide ${AUTHELIA_SECRET_REF}"
    exit 1
  fi

  chown root:root "${AUTHELIA_SECRET_REF}"
  chmod 0600 "${AUTHELIA_SECRET_REF}"

  for key in \
    AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET \
    AUTHELIA_SESSION_SECRET \
    AUTHELIA_STORAGE_ENCRYPTION_KEY; do
    if ! grep -q "^${key}=ocid1\." "${AUTHELIA_SECRET_REF}"; then
      err "${AUTHELIA_SECRET_REF} is missing an OCID for ${key}"
      exit 1
    fi
  done
}

materialize_secrets() {
  local key
  local owner
  local mode

  systemctl daemon-reload
  systemctl enable stack-secrets-authelia.service
  systemctl restart stack-secrets-authelia.service

  if [[ ! -s "${RUNTIME_ENV_FILE}" ]]; then
    err "runtime secret file is missing or empty: ${RUNTIME_ENV_FILE}"
    exit 1
  fi

  owner="$(stat -c '%U' "${RUNTIME_ENV_FILE}")"
  mode="$(stat -c '%a' "${RUNTIME_ENV_FILE}")"
  if [[ "${owner}" != "${AUTHELIA_USER}" || "${mode}" != "600" ]]; then
    err "${RUNTIME_ENV_FILE} must be owned by ${AUTHELIA_USER} with mode 600"
    exit 1
  fi
  if grep -q '=ocid1\.' "${RUNTIME_ENV_FILE}"; then
    err "${RUNTIME_ENV_FILE} contains an OCID instead of a value"
    exit 1
  fi

  for key in \
    AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET \
    AUTHELIA_SESSION_SECRET \
    AUTHELIA_STORAGE_ENCRYPTION_KEY; do
    if ! grep -q "^${key}=." "${RUNTIME_ENV_FILE}"; then
      err "${RUNTIME_ENV_FILE} is missing ${key}"
      exit 1
    fi
  done
}

verify_storage_key() {
  local legacy_key
  local runtime_key

  if [[ ! -f /data/authelia/env ]]; then
    return 0
  fi
  if ! grep -q '^AUTHELIA_STORAGE_ENCRYPTION_KEY=' /data/authelia/env; then
    return 0
  fi

  legacy_key="$(grep -m1 '^AUTHELIA_STORAGE_ENCRYPTION_KEY=' \
    /data/authelia/env | cut -d= -f2-)"
  runtime_key="$(grep -m1 '^AUTHELIA_STORAGE_ENCRYPTION_KEY=' \
    "${RUNTIME_ENV_FILE}" | cut -d= -f2-)"

  if [[ -z "${legacy_key}" || -z "${runtime_key}" ]]; then
    err "cannot compare the Authelia storage encryption key"
    exit 1
  fi
  if [[ "${legacy_key}" != "${runtime_key}" ]]; then
    err "the Vault storage encryption key does not match /data/authelia/env"
    err "restore the Vault secret to the existing key, or re-encrypt the database first"
    exit 1
  fi
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

read_lock_image() {
  local lock="${REPO_ROOT}/infra/manifest.lock.yaml"
  local parsed
  local source_type
  local image
  local version
  local sha256

  if [[ ! -f "${lock}" ]]; then
    err "component lock not found: ${lock}"
    exit 1
  fi

  parsed="$(
    awk '
      $0 == "components:" { in_components = 1; next }
      in_components && $0 == "  authelia:" { in_authelia = 1; next }
      in_authelia && $0 ~ /^  [^ ]/ { exit }
      in_authelia && $1 == "source_type:" { source_type = $2 }
      in_authelia && $1 == "image:" { image = $2 }
      in_authelia && $1 == "version:" { version = $2 }
      in_authelia && $1 == "sha256:" { sha256 = $2 }
      END { print source_type, image, version, sha256 }
    ' "${lock}"
  )"
  read -r source_type image version sha256 <<< "${parsed}"

  if [[ "${source_type}" != "oci-image" ]]; then
    err "invalid Authelia source type in ${lock}"
    exit 1
  fi
  if [[ -z "${image}" || "${image}" == *"@"* || "${image}" =~ [[:space:]] ]]; then
    err "invalid Authelia image in ${lock}"
    exit 1
  fi
  if [[ ! "${version}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    err "invalid Authelia version in ${lock}"
    exit 1
  fi
  if [[ ! "${sha256}" =~ ^[0-9a-f]{64}$ ]]; then
    err "invalid Authelia digest in ${lock}"
    exit 1
  fi

  AUTHELIA_IMAGE="${image}:${version}@sha256:${sha256}"
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
  local gid
  local unit_dir

  uid="$(id -u "${AUTHELIA_USER}")"
  gid="$(id -g "${AUTHELIA_USER}")"
  unit_dir="/etc/containers/systemd/users/${uid}"

  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/infra/configs/podman/authelia.container" "${STAGED_UNIT}"
  install -D -m 0644 -o root -g root \
    "${REPO_ROOT}/infra/configs/podman/authelia.container" \
    "${unit_dir}/authelia.container"
  install -d -m 0755 "${unit_dir}/authelia.container.d"
  printf 'Image=%s\n' "${AUTHELIA_IMAGE}" \
    > "${unit_dir}/authelia.container.d/10-image.conf"
  chmod 0644 "${unit_dir}/authelia.container.d/10-image.conf"
  printf '[Container]\nEnvironment=PUID=%s\nEnvironment=PGID=%s\nEnvironment=UMASK=0077\n' \
    "${uid}" "${gid}" > "${unit_dir}/authelia.container.d/20-runtime.conf"
  chmod 0644 "${unit_dir}/authelia.container.d/20-runtime.conf"
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
  chmod 0600 "${RUNTIME_CONFIG}" "${USERS_FILE}"
}

validate_config() {
  local uid
  local gid

  uid="$(id -u "${AUTHELIA_USER}")"
  gid="$(id -g "${AUTHELIA_USER}")"
  run_as_authelia podman run --rm \
    --env-file "${RUNTIME_ENV_FILE}" \
    --env "PUID=${uid}" \
    --env "PGID=${gid}" \
    --env "UMASK=0077" \
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
  read_lock_image
  require_data_mount
  create_user
  enforce_subids
  enable_linger
  ensure_dirs
  ensure_image
  install_secret_support
  ensure_secret_ref
  install_config
  ensure_users_database
  install_unit
  stop_service
  materialize_secrets
  verify_storage_key
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
