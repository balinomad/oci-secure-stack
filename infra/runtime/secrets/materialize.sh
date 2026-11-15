#!/usr/bin/env bash
set -euo pipefail

readonly RUNTIME_ROOT="/run"
readonly REFERENCE_ROOT="/etc/secure-stack/secret-refs"
readonly MODE_PATTERN='^0[0-7]{3}$'
readonly OWNER_PATTERN='^[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+$'
readonly KEY_PATTERN='^[A-Z_][A-Z0-9_]*$'
readonly OCID_PATTERN='^ocid1\.'

SPEC=""
OUTPUT=""
OWNER=""
MODE="0600"
OPTIONAL=0
TMP_FILE=""

usage() {
  cat <<'USAGE'
Usage: stack-secret-env --spec PATH --output PATH --owner USER:GROUP [OPTIONS]

Fetch OCI Vault secret values named in a reference file and write a runtime
environment file. The reference file contains KEY=OCID pairs only. The
output must be below /run.

Options:
  --spec PATH        Reference file below /etc/secure-stack/secret-refs.
  --output PATH      Runtime environment file below /run.
  --owner USER:GROUP Owner of the runtime file.
  --mode MODE        Runtime file mode. Default: 0600.
  --optional         Exit 0 when the reference file is absent.
  -h, --help         Show this help.
USAGE
}

err() {
  printf 'ERROR: %s\n' "$*" >&2
}

cleanup() {
  if [[ -n "${TMP_FILE}" ]]; then
    rm -f -- "${TMP_FILE}"
  fi
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "run this command as root"
    exit 1
  fi
}

require_value() {
  local option="$1"
  local count="$2"

  if (( count < 2 )); then
    err "${option} requires a value"
    exit 2
  fi
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --spec)
        require_value "$1" "$#"
        SPEC="$2"
        shift 2
        ;;
      --output)
        require_value "$1" "$#"
        OUTPUT="$2"
        shift 2
        ;;
      --owner)
        require_value "$1" "$#"
        OWNER="$2"
        shift 2
        ;;
      --mode)
        require_value "$1" "$#"
        MODE="$2"
        shift 2
        ;;
      --optional)
        OPTIONAL=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        err "unknown argument: $1"
        usage >&2
        exit 2
        ;;
    esac
  done
}

validate_args() {
  if [[ -z "${SPEC}" || -z "${OUTPUT}" || -z "${OWNER}" ]]; then
    usage >&2
    exit 2
  fi
  if [[ "${SPEC}" != "${REFERENCE_ROOT}/"* ]]; then
    err "spec must be below ${REFERENCE_ROOT}"
    exit 1
  fi
  if [[ "${SPEC}" == *..* ]]; then
    err "spec must not contain a parent path component"
    exit 1
  fi
  if [[ "${OUTPUT}" != "${RUNTIME_ROOT}/"* ]]; then
    err "output must be below ${RUNTIME_ROOT}"
    exit 1
  fi
  if [[ "${OUTPUT}" == *..* ]]; then
    err "output must not contain a parent path component"
    exit 1
  fi
  if [[ ! "${OWNER}" =~ ${OWNER_PATTERN} ]]; then
    err "owner must use USER:GROUP form"
    exit 1
  fi
  if [[ ! "${MODE}" =~ ${MODE_PATTERN} ]]; then
    err "mode must be four octal digits"
    exit 1
  fi
}

validate_spec_file() {
  local spec_mode

  if [[ ! -f "${SPEC}" ]]; then
    err "reference file not found: ${SPEC}"
    return 1
  fi
  if [[ ! -s "${SPEC}" ]]; then
    err "reference file is empty: ${SPEC}"
    return 1
  fi
  if [[ "$(stat -c '%u' "${SPEC}")" != "0" ]]; then
    err "reference file must be owned by root: ${SPEC}"
    return 1
  fi

  spec_mode="$(stat -c '%a' "${SPEC}")"
  if (( (8#${spec_mode} & 8#077) != 0 )); then
    err "reference file must not be group or other accessible: ${SPEC}"
    return 1
  fi

  return 0
}

fetch_secret() {
  local secret_id="$1"
  local value

  if ! command -v oci >/dev/null 2>&1; then
    err "the OCI CLI is required to resolve Vault secrets"
    return 1
  fi

  if ! value="$(
    OCI_CLI_AUTH=instance_principal \
      oci secrets secret-bundle get \
        --secret-id "${secret_id}" \
        --query "data.secretBundleContent.content" \
        --raw-output \
      | base64 -d
  )"; then
    return 1
  fi

  printf '%s' "${value}"
}

write_runtime_env() {
  local output_dir
  local parent_dir
  local group
  local key
  local reference
  local value
  local line
  declare -A seen=()

  output_dir="$(dirname -- "${OUTPUT}")"
  parent_dir="$(dirname -- "${output_dir}")"
  group="${OWNER#*:}"

  install -d -m 0755 -o root -g root "${parent_dir}"
  install -d -m 0750 -o root -g "${group}" "${output_dir}"

  TMP_FILE="$(mktemp "${output_dir}/.env.XXXXXX")"
  chmod 0600 "${TMP_FILE}"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ -z "${line}" || "${line}" == \#* ]]; then
      continue
    fi
    if [[ "${line}" != *=* ]]; then
      err "invalid reference line in ${SPEC}"
      exit 1
    fi

    key="${line%%=*}"
    reference="${line#*=}"

    if [[ ! "${key}" =~ ${KEY_PATTERN} ]]; then
      err "invalid reference key in ${SPEC}: ${key}"
      exit 1
    fi
    if [[ ! "${reference}" =~ ${OCID_PATTERN} ]]; then
      err "reference for ${key} is not an OCI Vault secret OCID"
      exit 1
    fi
    if [[ -n "${seen[${key}]:-}" ]]; then
      err "duplicate reference key in ${SPEC}: ${key}"
      exit 1
    fi
    seen["${key}"]=1

    if ! value="$(fetch_secret "${reference}")"; then
      err "failed to fetch the Vault secret for ${key}"
      exit 1
    fi
    if [[ -z "${value}" ]]; then
      err "Vault returned an empty secret for ${key}"
      exit 1
    fi
    if [[ "${value}" == *$'\n'* ]]; then
      err "Vault secret for ${key} contains a newline"
      exit 1
    fi

    printf '%s=%s\n' "${key}" "${value}" >> "${TMP_FILE}"
  done < "${SPEC}"

  if [[ ! -s "${TMP_FILE}" ]]; then
    err "reference file produced no runtime values: ${SPEC}"
    exit 1
  fi

  chown "${OWNER}" "${TMP_FILE}"
  chmod "${MODE}" "${TMP_FILE}"
  mv -f -- "${TMP_FILE}" "${OUTPUT}"
  TMP_FILE=""
}

main() {
  parse_args "$@"
  require_root
  validate_args

  if [[ ! -f "${SPEC}" ]]; then
    if (( OPTIONAL == 1 )); then
      printf 'Optional reference file absent: %s\n' "${SPEC}"
      exit 0
    fi
    err "reference file not found: ${SPEC}"
    exit 1
  fi

  validate_spec_file
  write_runtime_env
}

trap cleanup EXIT
main "$@"
