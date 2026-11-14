#!/usr/bin/env bash
set -euo pipefail

# The project forbids Python, Perl, Node, and other large runtime
# dependencies. This validator uses Bash and yq only.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
readonly REPO_ROOT
readonly DEFAULT_SCHEMA="${REPO_ROOT}/infra/manifest.schema.json"
readonly DEFAULT_MANIFEST="${REPO_ROOT}/infra/manifest.yaml"

SCHEMA="${DEFAULT_SCHEMA}"
MANIFEST="${DEFAULT_MANIFEST}"
FIELD_VALUE=""

err() {
  printf '[%s] ERROR: %s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "$*" >&2
}

on_error() {
  err "line ${1}: command failed with status ${2}"
}

fail() {
  err "$*"
  exit 1
}

usage() {
  cat <<'EOF'
Usage: validate-manifest.sh [--manifest PATH] [--schema PATH]

Validate a deployment manifest against the manifest schema.
The default manifest is infra/manifest.yaml.
The default schema is infra/manifest.schema.json.

Options:
  --manifest PATH  Manifest to validate.
  --schema PATH    Schema to validate against.
  -h, --help       Show this help.
EOF
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --manifest)
        if (( $# < 2 )); then
          err "--manifest requires a path"
          return 2
        fi
        MANIFEST="$2"
        shift 2
        ;;
      --schema)
        if (( $# < 2 )); then
          err "--schema requires a path"
          return 2
        fi
        SCHEMA="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        err "unknown argument: $1"
        usage >&2
        return 2
        ;;
    esac
  done
}

check_dependencies() {
  local tool
  for tool in yq awk cut sort uniq; do
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

manifest_query() {
  yq -r "$1" "${MANIFEST}"
}

schema_query() {
  yq -r "$1" "${SCHEMA}"
}

component_query() {
  local name="$1"
  local expression="$2"
  yq -r ".components[\"${name}\"] | ${expression}" "${MANIFEST}"
}

source_query() {
  local name="$1"
  local expression="$2"
  yq -r ".components[\"${name}\"].source | ${expression}" "${MANIFEST}"
}

entry_query() {
  local name="$1"
  local section="$2"
  local index="$3"
  local expression="$4"
  yq -r \
    ".components[\"${name}\"].${section}[${index}] | ${expression}" \
    "${MANIFEST}"
}

require_string() {
  local name="$1"
  local section="$2"
  local index="$3"
  local field="$4"
  local value_type
  local value

  value_type="$(entry_query "${name}" "${section}" "${index}" \
    ".${field} | type")"
  if [[ "${value_type}" != "!!str" ]]; then
    fail "component ${name}: ${section}[${index}].${field} must be a string"
  fi

  value="$(entry_query "${name}" "${section}" "${index}" \
    ".${field} // \"\"")"
  if [[ -z "${value}" ]]; then
    fail "component ${name}: ${section}[${index}].${field} must not be empty"
  fi

  FIELD_VALUE="${value}"
}

validate_files() {
  local name="$1"
  local count
  local i
  local extra
  local item_type
  local source
  local target
  local owner
  local mode

  if [[ "$(component_query "${name}" '.files | type')" \
    != "!!seq" ]]; then
    fail "component ${name}: files must be a list"
  fi

  count="$(component_query "${name}" '.files | length')"
  if (( count == 0 )); then
    fail "component ${name}: files must not be empty"
  fi

  for (( i = 0; i < count; i++ )); do
    item_type="$(entry_query "${name}" "files" "${i}" 'type')"
    if [[ "${item_type}" != "!!map" ]]; then
      fail "component ${name}: files[${i}] must be a mapping"
    fi

    extra="$(entry_query "${name}" "files" "${i}" \
      'keys - ["source", "target", "owner", "mode"] | .[]')"
    if [[ -n "${extra}" ]]; then
      fail "component ${name}: files[${i}] has unexpected keys: ${extra}"
    fi

    require_string "${name}" "files" "${i}" "source"
    source="${FIELD_VALUE}"
    require_string "${name}" "files" "${i}" "target"
    target="${FIELD_VALUE}"
    require_string "${name}" "files" "${i}" "owner"
    owner="${FIELD_VALUE}"
    require_string "${name}" "files" "${i}" "mode"
    mode="${FIELD_VALUE}"

    if [[ "${source}" == /* ]]; then
      fail "component ${name}: files[${i}].source must be relative"
    fi
    if [[ "${source}" =~ (^|/)\.\.(/|$) ]]; then
      fail "component ${name}: files[${i}].source must not contain .."
    fi
    if [[ "${target}" != /* ]]; then
      fail "component ${name}: files[${i}].target must be absolute"
    fi
    if [[ "${target}" =~ (^|/)\.\.(/|$) ]]; then
      fail "component ${name}: files[${i}].target must not contain .."
    fi
    if [[ ! "${owner}" =~ ^[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+$ ]]; then
      fail "component ${name}: files[${i}].owner must be user:group"
    fi
    if [[ ! "${mode}" =~ ^[0-7]{4}$ ]]; then
      fail "component ${name}: files[${i}].mode must be four octal digits"
    fi
  done
}

validate_secrets() {
  local name="$1"
  local count
  local i
  local extra
  local item_type
  local target
  local owner
  local mode
  local keys_type
  local keys_count
  local bad
  local duplicate

  if [[ "$(component_query "${name}" '.secrets | type')" \
    != "!!seq" ]]; then
    fail "component ${name}: secrets must be a list"
  fi

  count="$(component_query "${name}" '.secrets | length')"
  if (( count == 0 )); then
    fail "component ${name}: secrets must not be empty"
  fi

  for (( i = 0; i < count; i++ )); do
    item_type="$(entry_query "${name}" "secrets" "${i}" 'type')"
    if [[ "${item_type}" != "!!map" ]]; then
      fail "component ${name}: secrets[${i}] must be a mapping"
    fi

    extra="$(entry_query "${name}" "secrets" "${i}" \
      'keys - ["target", "owner", "mode", "keys"] | .[]')"
    if [[ -n "${extra}" ]]; then
      fail "component ${name}: secrets[${i}] has unexpected keys: ${extra}"
    fi

    require_string "${name}" "secrets" "${i}" "target"
    target="${FIELD_VALUE}"
    require_string "${name}" "secrets" "${i}" "owner"
    owner="${FIELD_VALUE}"
    require_string "${name}" "secrets" "${i}" "mode"
    mode="${FIELD_VALUE}"

    if [[ "${target}" != /* ]]; then
      fail "component ${name}: secrets[${i}].target must be absolute"
    fi
    if [[ "${target}" =~ (^|/)\.\.(/|$) ]]; then
      fail "component ${name}: secrets[${i}].target must not contain .."
    fi
    if [[ ! "${owner}" =~ ^[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+$ ]]; then
      fail "component ${name}: secrets[${i}].owner must be user:group"
    fi
    if [[ ! "${mode}" =~ ^[0-7]{4}$ ]]; then
      fail "component ${name}: secrets[${i}].mode must be four octal digits"
    fi

    keys_type="$(entry_query "${name}" "secrets" "${i}" '.keys | type')"
    if [[ "${keys_type}" != "!!seq" ]]; then
      fail "component ${name}: secrets[${i}].keys must be a list"
    fi

    keys_count="$(entry_query "${name}" "secrets" "${i}" '.keys | length')"
    if (( keys_count == 0 )); then
      fail "component ${name}: secrets[${i}].keys must not be empty"
    fi

    bad="$(entry_query "${name}" "secrets" "${i}" \
      '.keys[] | select(type != "!!str")')"
    if [[ -n "${bad}" ]]; then
      fail "component ${name}: secrets[${i}].keys entries must be strings"
    fi

    bad="$(entry_query "${name}" "secrets" "${i}" \
      '.keys[] | select(test("^[A-Z_][A-Z0-9_]*$") | not)')"
    if [[ -n "${bad}" ]]; then
      fail "component ${name}: secrets[${i}].keys has invalid names: ${bad}"
    fi

    duplicate="$(entry_query "${name}" "secrets" "${i}" \
      '.keys | group_by(.)[] | select(length > 1) | .[0]')"
    if [[ -n "${duplicate}" ]]; then
      fail "component ${name}: secrets[${i}].keys has duplicates: ${duplicate}"
    fi
  done
}

validate_source() {
  local name="$1"
  local version="$2"
  local has_source
  local source_type
  local extra
  local repository
  local asset
  local checksums
  local image

  has_source="$(component_query "${name}" 'has("source")')"
  if [[ "${version}" == "unpinned" ]]; then
    if [[ "${has_source}" == "true" ]]; then
      fail "component ${name}: unpinned components must not declare source"
    fi
    return 0
  fi

  if [[ "${has_source}" != "true" ]]; then
    fail "component ${name}: source is required for a pinned component"
  fi
  if [[ "$(component_query "${name}" '.source | type')" != "!!map" ]]; then
    fail "component ${name}: source must be a mapping"
  fi
  if [[ "$(source_query "${name}" 'has("type")')" != "true" ]]; then
    fail "component ${name}: source has no type"
  fi
  if [[ "$(source_query "${name}" '.type | type')" != "!!str" ]]; then
    fail "component ${name}: source.type must be a string"
  fi

  source_type="$(source_query "${name}" '.type')"
  case "${source_type}" in
    github-release)
      extra="$(source_query "${name}" \
        'keys - ["type", "repository", "asset", "checksums"] | .[]')"
      if [[ -n "${extra}" ]]; then
        fail "component ${name}: source has unexpected keys: ${extra}"
      fi

      if [[ "$(source_query "${name}" 'has("repository")')" != "true" ]]; then
        fail "component ${name}: source has no repository"
      fi
      if [[ "$(source_query "${name}" '.repository | type')" \
        != "!!str" ]]; then
        fail "component ${name}: source.repository must be a string"
      fi
      repository="$(source_query "${name}" '.repository')"
      if [[ ! "${repository}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        fail "component ${name}: source.repository must be owner/name"
      fi

      if [[ "$(source_query "${name}" 'has("asset")')" != "true" ]]; then
        fail "component ${name}: source has no asset"
      fi
      if [[ "$(source_query "${name}" '.asset | type')" != "!!str" ]]; then
        fail "component ${name}: source.asset must be a string"
      fi
      asset="$(source_query "${name}" '.asset')"
      if [[ -z "${asset}" || "${asset}" =~ [[:space:]] ]]; then
        fail "component ${name}: source.asset must be non-empty without whitespace"
      fi
      if [[ "${asset}" != *"\${version}"* ]]; then
        fail "component ${name}: source.asset must contain \${version}"
      fi
      if [[ "${asset}" != *"\${arch}"* ]]; then
        fail "component ${name}: source.asset must contain \${arch}"
      fi

      if [[ "$(source_query "${name}" 'has("checksums")')" == "true" ]]; then
        if [[ "$(source_query "${name}" '.checksums | type')" \
          != "!!str" ]]; then
          fail "component ${name}: source.checksums must be a string"
        fi
        checksums="$(source_query "${name}" '.checksums')"
        if [[ -z "${checksums}" || "${checksums}" =~ [[:space:]] ]]; then
          fail "component ${name}: source.checksums must be non-empty without whitespace"
        fi
        if [[ "${checksums}" != *"\${version}"* ]]; then
          fail "component ${name}: source.checksums must contain \${version}"
        fi
      fi
      ;;
    oci-image)
      extra="$(source_query "${name}" 'keys - ["type", "image"] | .[]')"
      if [[ -n "${extra}" ]]; then
        fail "component ${name}: source has unexpected keys: ${extra}"
      fi

      if [[ "$(source_query "${name}" 'has("image")')" != "true" ]]; then
        fail "component ${name}: source has no image"
      fi
      if [[ "$(source_query "${name}" '.image | type')" != "!!str" ]]; then
        fail "component ${name}: source.image must be a string"
      fi
      image="$(source_query "${name}" '.image')"
      if [[ -z "${image}" || "${image}" =~ [[:space:]] ]]; then
        fail "component ${name}: source.image must be non-empty without whitespace"
      fi
      if [[ "${image}" == *"@"* || "${image}" == *:* ]]; then
        fail "component ${name}: source.image must not contain a tag or digest"
      fi
      if [[ ! "${image}" \
        =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*(/[A-Za-z0-9][A-Za-z0-9_.-]*)+$ ]]; then
        fail "component ${name}: source.image must be a repository path"
      fi
      ;;
    *)
      fail "component ${name}: unsupported source.type: ${source_type}"
      ;;
  esac
}

validate_component() {
  local name="$1"
  local extra
  local version

  if [[ "$(component_query "${name}" 'type')" \
    != "!!map" ]]; then
    fail "component ${name} must be a mapping"
  fi

  extra="$(component_query "${name}" \
    'keys - ["version", "source", "files", "secrets"] | .[]')"
  if [[ -n "${extra}" ]]; then
    fail "component ${name} has unexpected keys: ${extra}"
  fi

  if [[ "$(component_query "${name}" 'has("version")')" \
    != "true" ]]; then
    fail "component ${name} has no version"
  fi

  if [[ "$(component_query "${name}" '.version | type')" \
    != "!!str" ]]; then
    fail "component ${name}: version must be a string"
  fi

  version="$(component_query "${name}" '.version')"
  if [[ -z "${version}" || "${version}" =~ [[:space:]] ]]; then
    fail "component ${name}: version must be non-empty without whitespace"
  fi

  validate_source "${name}" "${version}"

  if [[ "$(component_query "${name}" 'has("files")')" \
    == "true" ]]; then
    validate_files "${name}"
  fi

  if [[ "$(component_query "${name}" 'has("secrets")')" \
    == "true" ]]; then
    validate_secrets "${name}"
  fi
}

validate_components() {
  local name
  while IFS= read -r name; do
    if [[ -n "${name}" ]]; then
      validate_component "${name}"
    fi
  done < <(manifest_query '.components | keys[]')
}

validate_targets() {
  local duplicates
  duplicates="$(
    {
      manifest_query \
        ".components | to_entries[] | .key as \$c
        | (.value.files // [])[] | [\$c, \"files\", .target] | @tsv"
      manifest_query \
        ".components | to_entries[] | .key as \$c
        | (.value.secrets // [])[] | [\$c, \"secrets\", .target] | @tsv"
    } | cut -f3 | sort | uniq -d
  )"
  if [[ -n "${duplicates}" ]]; then
    fail "duplicate targets: ${duplicates}"
  fi
}

validate_top_level() {
  local extra
  local expected_version
  local actual_version
  local architecture
  local architectures
  local bad

  if [[ "$(manifest_query 'type')" != "!!map" ]]; then
    fail "manifest root must be a mapping"
  fi

  extra="$(manifest_query \
    'keys - ["version", "architecture", "components"] | .[]')"
  if [[ -n "${extra}" ]]; then
    fail "unexpected top-level keys: ${extra}"
  fi

  if [[ "$(manifest_query 'has("version")')" != "true" ]]; then
    fail "manifest has no version"
  fi
  if [[ "$(manifest_query '.version | type')" != "!!int" ]]; then
    fail "manifest version must be an integer"
  fi

  expected_version="$(schema_query '.properties.version.const')"
  actual_version="$(manifest_query '.version')"
  if [[ "${actual_version}" != "${expected_version}" ]]; then
    fail "manifest version ${actual_version} does not match schema version ${expected_version}"
  fi

  if [[ "$(manifest_query 'has("architecture")')" != "true" ]]; then
    fail "manifest has no architecture"
  fi
  if [[ "$(manifest_query '.architecture | type')" != "!!str" ]]; then
    fail "manifest architecture must be a string"
  fi
  architecture="$(manifest_query '.architecture')"
  if [[ -z "${architecture}" || "${architecture}" =~ [[:space:]] ]]; then
    fail "manifest architecture must be non-empty without whitespace"
  fi
  architectures="$(schema_query '.properties.architecture.enum[]' \
    | tr '\n' ' ')"
  if [[ " ${architectures} " != *" ${architecture} "* ]]; then
    fail "manifest architecture ${architecture} is not in the schema enum"
  fi

  if [[ "$(manifest_query 'has("components")')" != "true" ]]; then
    fail "manifest has no components"
  fi
  if [[ "$(manifest_query '.components | type')" != "!!map" ]]; then
    fail "components must be a mapping"
  fi
  if [[ "$(manifest_query '.components | length')" -eq 0 ]]; then
    fail "components must not be empty"
  fi

  bad="$(manifest_query \
    '.components | keys[] | select(type != "!!str")')"
  if [[ -n "${bad}" ]]; then
    fail "component names must be strings"
  fi

  bad="$(manifest_query \
    '.components | keys[] | select(test("^[a-z0-9][a-z0-9-]*$") | not)')"
  if [[ -n "${bad}" ]]; then
    fail "invalid component names: ${bad}"
  fi
}

validate_schema_file() {
  if [[ ! -f "${SCHEMA}" ]]; then
    fail "schema not found: ${SCHEMA}"
  fi
  if ! yq e '.' "${SCHEMA}" >/dev/null 2>&1; then
    fail "schema is not valid JSON: ${SCHEMA}"
  fi
}

validate_manifest_file() {
  if [[ ! -f "${MANIFEST}" ]]; then
    fail "manifest not found: ${MANIFEST}"
  fi
  if ! yq e '.' "${MANIFEST}" >/dev/null 2>&1; then
    fail "manifest is not valid YAML: ${MANIFEST}"
  fi
}

main() {
  local component_count
  local file_count
  local secret_count
  local architecture

  parse_args "$@" || return $?
  check_dependencies
  validate_schema_file
  validate_manifest_file
  validate_top_level
  validate_components
  validate_targets

  component_count="$(manifest_query '.components | length')"
  file_count="$(manifest_query '.components[].files // [] | length' \
    | awk '{ total += $1 } END { print total + 0 }')"
  secret_count="$(manifest_query '.components[].secrets // [] | length' \
    | awk '{ total += $1 } END { print total + 0 }')"
  architecture="$(manifest_query '.architecture')"

  printf 'manifest schema ok: %s components, %s files, %s secrets, %s\n' \
    "${component_count}" "${file_count}" "${secret_count}" "${architecture}"
}

trap 'on_error "${LINENO}" "$?"' ERR
main "$@"
