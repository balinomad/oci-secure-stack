#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
readonly REPO_ROOT
readonly MANIFEST="${REPO_ROOT}/infra/manifest.yaml"
readonly SCHEMA="${REPO_ROOT}/infra/manifest.schema.json"
readonly LOCK="${REPO_ROOT}/infra/manifest.lock.yaml"
readonly TEMPLATE="${REPO_ROOT}/infra/cloud-init/cloud-config.template.yaml"
readonly TMP_DIR="${REPO_ROOT}/tmp"
readonly BEGIN_FILES_MARKER='  # BEGIN GENERATED CONFIG FILES'
readonly END_FILES_MARKER='  # END GENERATED CONFIG FILES'
readonly BEGIN_RELEASE_MARKER='    # BEGIN GENERATED TRAEFIK RELEASE'
readonly END_RELEASE_MARKER='    # END GENERATED TRAEFIK RELEASE'
readonly BEGIN_ARCH_MARKER='    # BEGIN GENERATED TARGET ARCHITECTURE'
readonly END_ARCH_MARKER='    # END GENERATED TARGET ARCHITECTURE'
readonly BEGIN_IMAGES_MARKER='    # BEGIN GENERATED LOCKED IMAGES'
readonly END_IMAGES_MARKER='    # END GENERATED LOCKED IMAGES'
readonly -a SOURCE_ROOTS=(infra/configs infra/runtime)

declare -a FILE_ROWS=()
CHECK_ONLY=0
OUTPUT_PATH=""
HELP_ONLY=0
TMP_BLOCK=""
TMP_RELEASE_BLOCK=""
TMP_ARCH_BLOCK=""
TMP_IMAGES_BLOCK=""
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
  if [[ -n "${TMP_RELEASE_BLOCK}" ]]; then
    rm -f -- "${TMP_RELEASE_BLOCK}"
  fi
  if [[ -n "${TMP_ARCH_BLOCK}" ]]; then
    rm -f -- "${TMP_ARCH_BLOCK}"
  fi
  if [[ -n "${TMP_IMAGES_BLOCK}" ]]; then
    rm -f -- "${TMP_IMAGES_BLOCK}"
  fi
  if [[ -n "${TMP_RENDER}" ]]; then
    rm -f -- "${TMP_RENDER}"
  fi
}

usage() {
  cat <<'EOF'
Usage: render-config.sh [--check] [--output PATH]

Render the files from infra/manifest.yaml and the resolved component lock
from infra/manifest.lock.yaml into the cloud-config template.
The result goes to standard output unless --output is set.

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

file_entries() {
  local query
  query=".components | to_entries[] | .key as \$component"
  query="${query} | .value.files[]"
  query="${query} | [\$component, .source, .target, .owner, .mode]"
  query="${query} | @tsv"
  yq -r "${query}" "${MANIFEST}"
}

validate_release_lock() {
  local constraint
  local architecture
  local manifest_architecture
  local source_type
  local repository
  local asset
  local version
  local sha256

  if [[ ! -f "${LOCK}" ]]; then
    err "release lock not found: ${LOCK}"
    return 1
  fi

  constraint="$(yq -r '.components.traefik.version // ""' "${MANIFEST}")"
  architecture="$(yq -r '.architecture // ""' "${LOCK}")"
  manifest_architecture="$(yq -r '.architecture // ""' "${MANIFEST}")"
  source_type="$(yq -r '.components.traefik.source_type // ""' "${LOCK}")"
  repository="$(yq -r '.components.traefik.repository // ""' "${LOCK}")"
  asset="$(yq -r '.components.traefik.asset // ""' "${LOCK}")"
  version="$(yq -r '.components.traefik.version // ""' "${LOCK}")"
  sha256="$(yq -r '.components.traefik.sha256 // ""' "${LOCK}")"

  if [[ -z "${constraint}" ]]; then
    err "manifest has no Traefik version constraint"
    return 1
  fi
  if [[ "${architecture}" != "amd64" && "${architecture}" != "arm64" ]]; then
    err "release lock has an invalid architecture"
    return 1
  fi
  if [[ "${architecture}" != "${manifest_architecture}" ]]; then
    err "release lock architecture does not match the manifest"
    return 1
  fi
  if [[ "${source_type}" != "github-release" ]]; then
    err "release lock has an invalid Traefik source type"
    return 1
  fi
  if [[ ! "${repository}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    err "release lock has an invalid Traefik repository"
    return 1
  fi
  if [[ ! "${asset}" =~ ^[A-Za-z0-9._+-]+$ ]]; then
    err "release lock has an invalid Traefik asset"
    return 1
  fi
  if [[ ! "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    err "release lock has an invalid Traefik version"
    return 1
  fi
  if [[ ! "${sha256}" =~ ^[0-9a-f]{64}$ ]]; then
    err "release lock has an invalid Traefik checksum"
    return 1
  fi
}

validate_manifest() {
  local duplicate_targets

  if [[ ! -f "${MANIFEST}" ]]; then
    err "manifest not found: ${MANIFEST}"
    return 1
  fi
  if [[ ! -f "${TEMPLATE}" ]]; then
    err "template not found: ${TEMPLATE}"
    return 1
  fi
  if ! "${SCRIPT_DIR}/validate-manifest.sh" \
    --manifest "${MANIFEST}" --schema "${SCHEMA}" >&2; then
    err "manifest schema validation failed"
    return 1
  fi
  if ! validate_release_lock; then
    return 1
  fi

  duplicate_targets=$(file_entries | cut -f3 | sort | uniq -d)
  if [[ -n "${duplicate_targets}" ]]; then
    err "duplicate targets: ${duplicate_targets}"
    return 1
  fi

  if [[ "$(grep -c -- "${BEGIN_FILES_MARKER}" "${TEMPLATE}")" != "1" ]]; then
    err "template must contain exactly one begin marker: ${BEGIN_FILES_MARKER}"
    return 1
  fi
  if [[ "$(grep -c -- "${END_FILES_MARKER}" "${TEMPLATE}")" != "1" ]]; then
    err "template must contain exactly one end marker: ${END_FILES_MARKER}"
    return 1
  fi
  if [[ "$(grep -c -- "${BEGIN_RELEASE_MARKER}" "${TEMPLATE}")" != "1" ]]; then
    err "template must contain exactly one begin marker: ${BEGIN_RELEASE_MARKER}"
    return 1
  fi
  if [[ "$(grep -c -- "${END_RELEASE_MARKER}" "${TEMPLATE}")" != "1" ]]; then
    err "template must contain exactly one end marker: ${END_RELEASE_MARKER}"
    return 1
  fi
  if [[ "$(grep -c -- "${BEGIN_ARCH_MARKER}" "${TEMPLATE}")" != "1" ]]; then
    err "template must contain exactly one begin marker: ${BEGIN_ARCH_MARKER}"
    return 1
  fi
  if [[ "$(grep -c -- "${END_ARCH_MARKER}" "${TEMPLATE}")" != "1" ]]; then
    err "template must contain exactly one end marker: ${END_ARCH_MARKER}"
    return 1
  fi
  if [[ "$(grep -c -- "${BEGIN_IMAGES_MARKER}" "${TEMPLATE}")" != "1" ]]; then
    err "template must contain exactly one begin marker: ${BEGIN_IMAGES_MARKER}"
    return 1
  fi
  if [[ "$(grep -c -- "${END_IMAGES_MARKER}" "${TEMPLATE}")" != "1" ]]; then
    err "template must contain exactly one end marker: ${END_IMAGES_MARKER}"
    return 1
  fi
}

load_file_entries() {
  local row
  FILE_ROWS=()
  while IFS= read -r row; do
    if [[ -n "${row}" ]]; then
      FILE_ROWS+=("${row}")
    fi
  done < <(file_entries)

  if (( ${#FILE_ROWS[@]} == 0 )); then
    err "no files in the manifest"
    return 1
  fi
}

is_allowed_source() {
  local source_real="$1"
  local root
  for root in "${SOURCE_ROOTS[@]}"; do
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

validate_target() {
  local target="$1"
  local owner="$2"
  local mode="$3"

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
}

render_entry() {
  local source="$1"
  local target="$2"
  local owner="$3"
  local mode="$4"
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
  if ! is_allowed_source "${source_real}"; then
    err "source file is outside infra/configs/ and infra/runtime/: ${source}"
    return 1
  fi

  if ! validate_target "${target}" "${owner}" "${mode}"; then
    return 1
  fi
  if is_executable_mode "${mode}" \
    && [[ "${source_real}" != "${REPO_ROOT}/infra/runtime/"* ]]; then
    err "executable source must be under infra/runtime/: ${source}"
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
  local component
  local source
  local target
  local owner
  local mode

  : > "${TMP_BLOCK}"
  for row in "${FILE_ROWS[@]}"; do
    IFS=$'\t' read -r component source target owner mode <<< "${row}"
    if [[ -z "${component}" || -z "${source}" || -z "${target}" ]]; then
      err "invalid manifest row: ${row}"
      return 1
    fi
    render_entry "${source}" "${target}" "${owner}" "${mode}" \
      >> "${TMP_BLOCK}"
  done
}

render_release_block() {
  local architecture
  local repository
  local asset
  local version
  local sha256

  architecture="$(yq -r '.architecture' "${LOCK}")"
  repository="$(yq -r '.components.traefik.repository' "${LOCK}")"
  asset="$(yq -r '.components.traefik.asset' "${LOCK}")"
  version="$(yq -r '.components.traefik.version' "${LOCK}")"
  sha256="$(yq -r '.components.traefik.sha256' "${LOCK}")"

  printf '    TRAEFIK_ARCH="%s"\n' "${architecture}"
  printf '    TRAEFIK_REPOSITORY="%s"\n' "${repository}"
  printf '    TRAEFIK_ASSET="%s"\n' "${asset}"
  printf '    TRAEFIK_VERSION="%s"\n' "${version}"
  printf '    TRAEFIK_SHA256="%s"\n' "${sha256}"
}

render_architecture_block() {
  printf '    TARGET_ARCH="%s"\n' "$(yq -r '.architecture' "${LOCK}")"
}

render_images_block() {
  local name
  local image
  local version
  local digest
  local variable

  while IFS=$'\t' read -r name image; do
    if [[ -z "${name}" || -z "${image}" ]]; then
      continue
    fi

    version="$(yq -r ".components[\"${name}\"].version // \"\"" "${LOCK}")"
    digest="$(yq -r ".components[\"${name}\"].sha256 // \"\"" "${LOCK}")"
    if [[ -z "${version}" || ! "${digest}" =~ ^[0-9a-f]{64}$ ]]; then
      err "lock has no valid OCI image for ${name}"
      return 1
    fi

    variable="$(printf '%s' "${name}" | tr '[:lower:]' '[:upper:]' \
      | tr '-' '_')_IMAGE"
    printf '    %s="%s:%s@sha256:%s"\n' \
      "${variable}" "${image}" "${version}" "${digest}"
  done < <(
    yq -r '
      .components | to_entries[]
      | select(.value.source.type == "oci-image")
      | [.key, .value.source.image] | @tsv
    ' "${MANIFEST}"
  )
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
  ' "${TEMPLATE}" | awk -v block="${TMP_RELEASE_BLOCK}" '
    /^    # BEGIN GENERATED TRAEFIK RELEASE$/ {
      print
      while ((getline line < block) > 0) {
        print line
      }
      close(block)
      in_block = 1
      next
    }
    /^    # END GENERATED TRAEFIK RELEASE$/ {
      in_block = 0
      print
      next
    }
    !in_block { print }
  ' | awk -v block="${TMP_ARCH_BLOCK}" '
    /^    # BEGIN GENERATED TARGET ARCHITECTURE$/ {
      print
      while ((getline line < block) > 0) {
        print line
      }
      close(block)
      in_block = 1
      next
    }
    /^    # END GENERATED TARGET ARCHITECTURE$/ {
      in_block = 0
      print
      next
    }
    !in_block { print }
  ' | awk -v block="${TMP_IMAGES_BLOCK}" '
    /^    # BEGIN GENERATED LOCKED IMAGES$/ {
      print
      while ((getline line < block) > 0) {
        print line
      }
      close(block)
      in_block = 1
      next
    }
    /^    # END GENERATED LOCKED IMAGES$/ {
      in_block = 0
      print
      next
    }
    !in_block { print }
  '
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
  load_file_entries

  mkdir -p -- "${TMP_DIR}"
  TMP_BLOCK="$(mktemp "${TMP_DIR}/render-config-block.XXXXXX")"
  TMP_RELEASE_BLOCK="$(mktemp "${TMP_DIR}/render-config-release.XXXXXX")"
  TMP_ARCH_BLOCK="$(mktemp "${TMP_DIR}/render-config-arch.XXXXXX")"
  TMP_IMAGES_BLOCK="$(mktemp "${TMP_DIR}/render-config-images.XXXXXX")"
  TMP_RENDER="$(mktemp "${TMP_DIR}/render-config-output.XXXXXX")"

  render_all
  render_release_block > "${TMP_RELEASE_BLOCK}"
  render_architecture_block > "${TMP_ARCH_BLOCK}"
  render_images_block > "${TMP_IMAGES_BLOCK}"
  render_template > "${TMP_RENDER}"
  validate_render

  if (( CHECK_ONLY == 1 )); then
    printf 'manifest ok: %s components, %s files\n' \
      "$(yq -r '.components | length' "${MANIFEST}")" "${#FILE_ROWS[@]}"
    return 0
  fi

  render_output "${OUTPUT_PATH}"
}

trap cleanup EXIT
trap 'on_error "${LINENO}" "$?"' ERR

main "$@"
