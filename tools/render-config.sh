#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
readonly REPO_ROOT
readonly MANIFEST="${REPO_ROOT}/infra/manifest.yaml"
readonly TEMPLATE="${REPO_ROOT}/infra/cloud-init/cloud-config.example.yaml"
readonly TMP_DIR="${REPO_ROOT}/tmp"
readonly BEGIN_MARKER='  # BEGIN GENERATED CONFIG FILES'
readonly END_MARKER='  # END GENERATED CONFIG FILES'
readonly -a SUPPORTED_FORMATS=(yaml json ini systemd quadlet text)
readonly -a STAGING_ROOTS=(infra/configs infra/runtime)

declare -a STAGED_ROWS=()
CHECK_ONLY=0
OUTPUT_PATH=""
HELP_ONLY=0
TMP_BLOCK=""
TMP_RENDER=""

err() {
  printf '[%s] ERROR: %s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "$*" >&2
}

on_error() {
  err "line ${1}: command failed with status ${2}"
}

cleanup() {
  if [[ -n "${TMP_BLOCK}" ]]; then
    rm -f -- "${TMP_BLOCK}"
  fi
  if [[ -n "${TMP_RENDER}" ]]; then
    rm -f -- "${TMP_RENDER}"
  fi
}

usage() {
  cat <<'EOF'
Usage: render-config.sh [--check] [--output PATH]

Render the enabled staged files from infra/manifest.yaml into the cloud-config
template. The result goes to standard output unless --output is set.

Options:
  --check          Validate the manifest and sources, then print a summary.
  --output PATH    Write the rendered cloud-config to PATH.
  -h, --help       Show this help.
EOF
}

check_dependencies() {
  local tool
  for tool in yq awk mktemp; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      err "required command not found: ${tool}"
      return 1
    fi
  done

  if ! yq --version 2>/dev/null | grep -q 'version v4'; then
    err "yq v4 or later is required"
    return 1
  fi
}

staged_entries() {
  local query
  query='.files[] | select(.enabled == true and .stage == true)'
  query="${query} | [.source, .target, .owner, .mode, .format]"
  query="${query} | @tsv"
  yq -r "${query}" "${MANIFEST}"
}

validate_manifest() {
  local missing_stage
  local duplicate_targets

  if [[ ! -f "${MANIFEST}" ]]; then
    err "manifest not found: ${MANIFEST}"
    return 1
  fi
  if [[ ! -f "${TEMPLATE}" ]]; then
    err "template not found: ${TEMPLATE}"
    return 1
  fi

  missing_stage="$(
    yq -r '[.files[] | select(has("stage") | not)] | length' "${MANIFEST}"
  )"
  if [[ "${missing_stage}" != "0" ]]; then
    err "manifest entries are missing the stage field"
    return 1
  fi

  duplicate_targets=$(staged_entries | cut -f2 | sort | uniq -d)
  if [[ -n "${duplicate_targets}" ]]; then
    err "duplicate staged targets: ${duplicate_targets}"
    return 1
  fi

  if [[ "$(grep -c -- "${BEGIN_MARKER}" "${TEMPLATE}")" != "1" ]]; then
    err "template must contain exactly one begin marker: ${BEGIN_MARKER}"
    return 1
  fi
  if [[ "$(grep -c -- "${END_MARKER}" "${TEMPLATE}")" != "1" ]]; then
    err "template must contain exactly one end marker: ${END_MARKER}"
    return 1
  fi
}

load_staged_entries() {
  local row
  STAGED_ROWS=()
  while IFS= read -r row; do
    if [[ -n "${row}" ]]; then
      STAGED_ROWS+=("${row}")
    fi
  done < <(staged_entries)

  if (( ${#STAGED_ROWS[@]} == 0 )); then
    err "no enabled staged entries in the manifest"
    return 1
  fi
}

is_supported_format() {
  local format="$1"
  local candidate
  for candidate in "${SUPPORTED_FORMATS[@]}"; do
    if [[ "${format}" == "${candidate}" ]]; then
      return 0
    fi
  done
  return 1
}

is_staged_source() {
  local source_real="$1"
  local root
  for root in "${STAGING_ROOTS[@]}"; do
    if [[ "${source_real}" == "${REPO_ROOT}/${root}/"* ]]; then
      return 0
    fi
  done
  return 1
}

is_executable_mode() {
  local mode="$1"
  (( (8#${mode} & 8#111) != 0 ))
}

render_entry() {
  local source="$1"
  local target="$2"
  local owner="$3"
  local mode="$4"
  local format="$5"
  local source_abs
  local source_real

  source_abs="${REPO_ROOT}/${source}"
  if [[ ! -f "${source_abs}" ]]; then
    err "source file not found: ${source}"
    return 1
  fi
  if [[ ! -s "${source_abs}" ]]; then
    err "source file is empty: ${source}"
    return 1
  fi

  source_real="$(
    cd -- "$(dirname -- "${source_abs}")" && pwd -P
  )/$(basename -- "${source_abs}")"
  if ! is_staged_source "${source_real}"; then
    err "source file is outside infra/configs/ and infra/runtime/: ${source}"
    return 1
  fi

  if [[ "${target}" != /* ]]; then
    err "target is not an absolute path: ${target}"
    return 1
  fi
  if [[ "${target}" == *".."* ]]; then
    err "target contains a parent path component: ${target}"
    return 1
  fi
  if [[ -z "${owner}" || "${owner}" == "null" ]]; then
    err "target has no owner: ${target}"
    return 1
  fi
  if [[ ! "${mode}" =~ ^[0-7]{4}$ ]]; then
    err "target has an invalid mode: ${target}"
    return 1
  fi
  if ! is_supported_format "${format}"; then
    err "target has an unsupported format: ${target}"
    return 1
  fi
  if is_executable_mode "${mode}" \
    && [[ "${source_real}" != "${REPO_ROOT}/infra/runtime/"* ]]; then
    err "executable staged source must be under infra/runtime/: ${source}"
    return 1
  fi

  printf '  - path: %s\n' "${target}"
  printf '    owner: %s\n' "${owner}"
  printf '    permissions: "%s"\n' "${mode}"
  printf '    content: |\n'
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ -z "${line}" ]]; then
      printf '\n'
    else
      printf '      %s\n' "${line}"
    fi
  done < "${source_real}"
  printf '\n'
}

render_all() {
  local row
  local source
  local target
  local owner
  local mode
  local format

  : > "${TMP_BLOCK}"
  for row in "${STAGED_ROWS[@]}"; do
    IFS=$'\t' read -r source target owner mode format <<< "${row}"
    render_entry "${source}" "${target}" "${owner}" "${mode}" "${format}" \
      >> "${TMP_BLOCK}"
  done
}

render_template() {
  awk -v block="${TMP_BLOCK}" '
    /^  # BEGIN GENERATED CONFIG FILES$/ {
      print
      while ((getline line < block) > 0) {
        print line
      }
      close(block)
      in_block = 1
      next
    }
    /^  # END GENERATED CONFIG FILES$/ {
      in_block = 0
      print
      next
    }
    !in_block { print }
  ' "${TEMPLATE}"
}

validate_render() {
  if ! yq e '.' "${TMP_RENDER}" >/dev/null 2>&1; then
    err "rendered cloud-config is not valid YAML"
    return 1
  fi
}

render_output() {
  local output="$1"
  if [[ -n "${output}" ]]; then
    if [[ "${output}" -ef "${TEMPLATE}" ]]; then
      err "output must not overwrite the cloud-config template"
      return 1
    fi
    if [[ "${output}" -ef "${MANIFEST}" ]]; then
      err "output must not overwrite the configuration manifest"
      return 1
    fi
    cp -- "${TMP_RENDER}" "${output}"
  else
    cat -- "${TMP_RENDER}"
  fi
}

parse_args() {
  CHECK_ONLY=0
  OUTPUT_PATH=""
  HELP_ONLY=0

  while (( $# > 0 )); do
    case "$1" in
      --check)
        CHECK_ONLY=1
        shift
        ;;
      --output)
        if (( $# < 2 )); then
          err "--output requires a path"
          return 2
        fi
        OUTPUT_PATH="$2"
        shift 2
        ;;
      -h|--help)
        HELP_ONLY=1
        shift
        ;;
      *)
        err "unknown argument: $1"
        usage >&2
        return 2
        ;;
    esac
  done
}

main() {
  parse_args "$@" || return $?
  if (( HELP_ONLY == 1 )); then
    usage
    return 0
  fi

  check_dependencies
  validate_manifest
  load_staged_entries

  mkdir -p -- "${TMP_DIR}"
  TMP_BLOCK="$(mktemp "${TMP_DIR}/render-config-block.XXXXXX")"
  TMP_RENDER="$(mktemp "${TMP_DIR}/render-config-output.XXXXXX")"

  render_all
  render_template > "${TMP_RENDER}"
  validate_render

  if (( CHECK_ONLY == 1 )); then
    printf 'manifest ok: %s staged entries\n' "${#STAGED_ROWS[@]}"
    return 0
  fi

  render_output "${OUTPUT_PATH}"
}

trap cleanup EXIT
trap 'on_error "${LINENO}" "$?"' ERR

main "$@"
