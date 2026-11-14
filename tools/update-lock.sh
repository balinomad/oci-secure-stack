#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
readonly REPO_ROOT
readonly MANIFEST="${REPO_ROOT}/infra/manifest.yaml"
readonly SCHEMA="${REPO_ROOT}/infra/manifest.schema.json"
readonly LOCK="${REPO_ROOT}/infra/manifest.lock.yaml"
readonly TMP_ROOT="${REPO_ROOT}/tmp"

TMP_DIR=""
LOCK_TMP=""
ARCHITECTURE=""
LOCK_VERSION=""
LOCK_DIGEST=""
LOCK_ASSET=""

err() {
  printf 'ERROR: %s\n' "$*" >&2
}

on_error() {
  err "line ${1}: command failed with status ${2}"
}

cleanup() {
  if [[ -n "${TMP_DIR}" ]]; then
    rm -rf -- "${TMP_DIR}"
  fi
}

usage() {
  cat <<'EOF'
Usage: update-lock.sh

Resolve the component sources in infra/manifest.yaml and write
infra/manifest.lock.yaml for the manifest architecture.

The lock is generated. Do not edit it by hand.
EOF
}

require_commands() {
  local command
  for command in yq jq curl awk sort tr mktemp mkdir install sha256sum; do
    if ! command -v "${command}" >/dev/null 2>&1; then
      err "required command not found: ${command}"
      return 1
    fi
  done

  if ! yq --version 2>/dev/null | grep -q 'version v4'; then
    err "yq v4 or later is required"
    return 1
  fi
}

validate_manifest() {
  if ! "${SCRIPT_DIR}/validate-manifest.sh" \
    --manifest "${MANIFEST}" --schema "${SCHEMA}" >&2; then
    err "manifest schema validation failed"
    return 1
  fi
}

parse_constraint() {
  local constraint="$1"
  local raw

  if [[ "${constraint}" =~ ^\^v?([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    CONSTRAINT_MODE="caret"
  elif [[ "${constraint}" =~ ^~v?([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    CONSTRAINT_MODE="tilde"
  elif [[ "${constraint}" =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    CONSTRAINT_MODE="exact"
  else
    err "unsupported version constraint: ${constraint}"
    return 1
  fi

  raw="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
  IFS=. read -r CONSTRAINT_MAJOR CONSTRAINT_MINOR CONSTRAINT_PATCH <<< "${raw}"
}

select_version() {
  local tags_file="$1"
  local constraint="$2"
  local candidate

  parse_constraint "${constraint}"

  candidate="$(
    awk \
      -v mode="${CONSTRAINT_MODE}" \
      -v major="${CONSTRAINT_MAJOR}" \
      -v minor="${CONSTRAINT_MINOR}" \
      -v patch="${CONSTRAINT_PATCH}" '
        /^v?[0-9]+\.[0-9]+\.[0-9]+$/ {
          line = $0
          sub(/^v/, "", line)
          split(line, parts, ".")
          vmajor = parts[1] + 0
          vminor = parts[2] + 0
          vpatch = parts[3] + 0

          if (mode == "caret") {
            if (vmajor != major) next
            if (vminor < minor) next
            if (vminor == minor && vpatch < patch) next
          } else if (mode == "tilde") {
            if (vmajor != major || vminor != minor) next
            if (vpatch < patch) next
          } else {
            if (vmajor != major || vminor != minor || vpatch != patch) {
              next
            }
          }

          print $0
        }
      ' "${tags_file}" \
      | sort -V -r \
      | awk 'NR == 1 { print }'
  )"

  if [[ -z "${candidate}" ]]; then
    err "no stable version matches ${constraint}"
    return 1
  fi

  SELECTED_VERSION="${candidate}"
}

render_template() {
  local template="$1"
  local version="$2"
  local arch="$3"
  local output

  output="${template//\$\{version\}/${version}}"
  output="${output//\$\{arch\}/${arch}}"
  if [[ "${output}" == *"\${"* ]]; then
    err "unresolved placeholder in template: ${template}"
    return 1
  fi
  printf '%s\n' "${output}"
}

resolve_github_release() {
  local name="$1"
  local constraint="$2"
  local repository="$3"
  local asset_template="$4"
  local checksums_template="$5"
  local releases_file
  local tags_file
  local asset
  local digest
  local checksums_url
  local checksums_file

  releases_file="${TMP_DIR}/${name}-releases.json"
  tags_file="${TMP_DIR}/${name}-tags.txt"

  curl -fsSL --connect-timeout 10 --max-time 60 \
    -H 'Accept: application/vnd.github+json' \
    -H 'User-Agent: oci-secure-stack-lock-updater' \
    "https://api.github.com/repos/${repository}/releases?per_page=100" \
    -o "${releases_file}"

  jq -r \
    '.[] | select(.prerelease == false and .draft == false) | .tag_name' \
    "${releases_file}" > "${tags_file}"

  select_version "${tags_file}" "${constraint}"
  asset="$(render_template "${asset_template}" "${SELECTED_VERSION}" \
    "${ARCHITECTURE}")"

  digest="$(
    jq -r --arg tag "${SELECTED_VERSION}" --arg name "${asset}" '
      .[] | select(.tag_name == $tag)
      | .assets[] | select(.name == $name) | .digest // ""
    ' "${releases_file}"
  )"
  digest="${digest#sha256:}"

  if [[ ! "${digest}" =~ ^[0-9a-f]{64}$ && -n "${checksums_template}" ]]; then
    checksums_url="$(render_template "${checksums_template}" \
      "${SELECTED_VERSION}" "${ARCHITECTURE}")"
    checksums_file="${TMP_DIR}/${name}-checksums.txt"
    curl -fsSL --connect-timeout 10 --max-time 60 \
      "${checksums_url}" -o "${checksums_file}"
    digest="$(
      awk -v name="${asset}" '$2 == name { print $1; exit }' \
        "${checksums_file}"
    )"
  fi

  if [[ ! "${digest}" =~ ^[0-9a-f]{64}$ ]]; then
    err "no SHA256 digest for ${name} asset ${asset}"
    return 1
  fi

  LOCK_VERSION="${SELECTED_VERSION}"
  LOCK_DIGEST="${digest}"
  LOCK_ASSET="${asset}"
}

oci_registry_for_image() {
  local image="$1"
  local first

  if [[ "${image}" == */* ]]; then
    first="${image%%/*}"
    if [[ "${first}" == *.* || "${first}" == *:* \
      || "${first}" == "localhost" ]]; then
      OCI_REGISTRY="${first}"
      OCI_REPOSITORY="${image#*/}"
    else
      OCI_REGISTRY="docker.io"
      OCI_REPOSITORY="${image}"
    fi
  else
    OCI_REGISTRY="docker.io"
    OCI_REPOSITORY="library/${image}"
  fi

  case "${OCI_REGISTRY}" in
    docker.io)
      OCI_API="registry-1.docker.io"
      OCI_TOKEN_URL="https://auth.docker.io/token?service=registry.docker.io&scope=repository:${OCI_REPOSITORY}:pull"
      ;;
    ghcr.io)
      OCI_API="ghcr.io"
      OCI_TOKEN_URL="https://ghcr.io/token?scope=repository:${OCI_REPOSITORY}:pull"
      ;;
    *)
      err "unsupported OCI registry: ${OCI_REGISTRY}"
      return 1
      ;;
  esac
}

resolve_oci_image() {
  local name="$1"
  local constraint="$2"
  local image="$3"
  local token
  local tags_file
  local headers_file
  local manifest_file
  local digest

  oci_registry_for_image "${image}"

  token="$(
    curl -fsSL --connect-timeout 10 --max-time 60 "${OCI_TOKEN_URL}" \
      | jq -r '.token // .access_token // ""'
  )"
  if [[ -z "${token}" ]]; then
    err "no registry token for ${image}"
    return 1
  fi

  tags_file="${TMP_DIR}/${name}-tags.txt"
  curl -fsSL --connect-timeout 10 --max-time 60 \
    -H "Authorization: Bearer ${token}" \
    "https://${OCI_API}/v2/${OCI_REPOSITORY}/tags/list" \
    | jq -r '.tags[]?' > "${tags_file}"

  select_version "${tags_file}" "${constraint}"

  headers_file="${TMP_DIR}/${name}-headers.txt"
  manifest_file="${TMP_DIR}/${name}-manifest.json"
  curl -fsSL --connect-timeout 10 --max-time 60 \
    -D "${headers_file}" -o "${manifest_file}" \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "https://${OCI_API}/v2/${OCI_REPOSITORY}/manifests/${SELECTED_VERSION}"

  digest="$(
    awk -F': ' 'tolower($1) == "docker-content-digest" {
      gsub("\r", "", $2); print $2
    }' "${headers_file}"
  )"
  digest="${digest#sha256:}"
  if [[ ! "${digest}" =~ ^[0-9a-f]{64}$ ]]; then
    digest="$(sha256sum "${manifest_file}" | awk '{print $1}')"
  fi
  if [[ ! "${digest}" =~ ^[0-9a-f]{64}$ ]]; then
    err "no digest for ${image}:${SELECTED_VERSION}"
    return 1
  fi

  LOCK_VERSION="${SELECTED_VERSION}"
  LOCK_DIGEST="${digest}"
}

prepare_lock() {
  mkdir -p -- "${TMP_ROOT}"
  TMP_DIR="$(mktemp -d "${TMP_ROOT}/update-lock.XXXXXX")"
  LOCK_TMP="${TMP_DIR}/manifest.lock.yaml"

  {
    printf '# Generated lock for infra/manifest.yaml.\n'
    printf '# Resolved from the source blocks in infra/manifest.yaml.\n'
    printf '# Do not edit this file by hand.\n'
    printf 'version: 1\n'
    printf 'architecture: %s\n' "${ARCHITECTURE}"
    printf 'components: {}\n'
  } > "${LOCK_TMP}"
}

update_components() {
  local name
  local constraint
  local source_type
  local repository
  local asset
  local checksums
  local image
  local source_fields
  local updated=0

  while IFS= read -r name; do
    if [[ -z "${name}" ]]; then
      continue
    fi

    source_type="$(yq -r ".components[\"${name}\"].source.type // \"\"" \
      "${MANIFEST}")"
    if [[ -z "${source_type}" ]]; then
      continue
    fi

    constraint="$(yq -r ".components[\"${name}\"].version" "${MANIFEST}")"
    case "${source_type}" in
      github-release)
        repository="$(yq -r ".components[\"${name}\"].source.repository" \
          "${MANIFEST}")"
        asset="$(yq -r ".components[\"${name}\"].source.asset" "${MANIFEST}")"
        checksums="$(yq -r \
          ".components[\"${name}\"].source.checksums // \"\"" "${MANIFEST}")"
        resolve_github_release "${name}" "${constraint}" "${repository}" \
          "${asset}" "${checksums}"
        ;;
      oci-image)
        image="$(yq -r ".components[\"${name}\"].source.image" "${MANIFEST}")"
        resolve_oci_image "${name}" "${constraint}" "${image}"
        ;;
      *)
        err "unsupported source type for ${name}: ${source_type}"
        return 1
        ;;
    esac

    case "${source_type}" in
      github-release)
        source_fields=".components[\"${name}\"].source_type = \"github-release\" | \
          .components[\"${name}\"].repository = \"${repository}\" | \
          .components[\"${name}\"].asset = \"${LOCK_ASSET}\""
        ;;
      oci-image)
        source_fields=".components[\"${name}\"].source_type = \"oci-image\" | \
          .components[\"${name}\"].image = \"${image}\""
        ;;
    esac

    yq -i \
      ".components[\"${name}\"].version = \"${LOCK_VERSION}\" | \
      .components[\"${name}\"].sha256 = \"${LOCK_DIGEST}\" | \
      ${source_fields}" \
      "${LOCK_TMP}"
    updated=$((updated + 1))
  done < <(yq -r '.components | keys[]' "${MANIFEST}")

  if (( updated == 0 )); then
    err "no components with a source block"
    return 1
  fi
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

  require_commands
  validate_manifest
  ARCHITECTURE="$(yq -r '.architecture' "${MANIFEST}")"
  prepare_lock
  update_components
  install -m 0644 "${LOCK_TMP}" "${LOCK}"
  printf 'Updated lock: %s\n' "${LOCK}"
}

trap cleanup EXIT
trap 'on_error "${LINENO}" "$?"' ERR
main "$@"
