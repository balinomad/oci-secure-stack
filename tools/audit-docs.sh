#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
DEFAULT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly DEFAULT_ROOT
readonly REQUIRED_FIELDS=(name description status version updated)
readonly ALLOWED_STATUSES=(draft active legacy final superseded)

declare -a errors=()
declare -a docs=()
declare BODY_START=0

add_error() {
  local path="$1"
  local line="$2"
  local message="$3"

  if [[ -n "${line}" ]]; then
    printf 'ERROR %s:%s: %s\n' "${path}" "${line}" "${message}" >&2
  else
    printf 'ERROR %s: %s\n' "${path}" "${message}" >&2
  fi
  errors+=("${path}:${line}: ${message}")
}

check_trailing_newline() {
  local path="$1"
  local size
  local last
  local previous

  size=$(wc -c < "${path}")
  if (( size == 0 )); then
    add_error "${path}" "" "must end with exactly one newline"
    return
  fi

  last=$(od -An -t u1 -j $((size - 1)) -N 1 "${path}" | tr -d ' ')
  if [[ "${last}" != "10" ]]; then
    add_error "${path}" "" "must end with exactly one newline"
    return
  fi

  if (( size >= 2 )); then
    previous=$(od -An -t u1 -j $((size - 2)) -N 1 "${path}" | tr -d ' ')
    if [[ "${previous}" == "10" ]]; then
      add_error "${path}" "" "must end with exactly one newline"
    fi
  fi
}

parse_frontmatter() {
  local path="$1"
  local -a lines=()
  local total
  local end=-1
  local i
  local key
  local status=""
  local version=""
  local updated=""
  local previous_index=-1
  local index
  local allowed
  local candidate

  mapfile -t lines < "${path}"
  total=${#lines[@]}
  BODY_START=-1

  if (( total == 0 )) || [[ ! "${lines[0]}" =~ ^[[:space:]]*---[[:space:]]*$ ]]; then
    add_error "${path}" 1 "missing frontmatter"
    return
  fi

  for ((i = 1; i < total; i++)); do
    if [[ "${lines[i]}" == "---" ]]; then
      end=${i}
      break
    fi
  done

  if (( end == -1 )); then
    add_error "${path}" 1 "unclosed frontmatter"
    return
  fi

  declare -A seen=()
  local -a ordered=()

  for ((i = 1; i < end; i++)); do
    if [[ "${lines[i]}" =~ ^([A-Za-z_]+): ]]; then
      key="${BASH_REMATCH[1]}"
      if [[ -n "${seen[${key}]:-}" ]]; then
        add_error "${path}" "$((i + 1))" "duplicate frontmatter field: ${key}"
      else
        seen["${key}"]="$((i + 1))"
      fi
      case "${key}" in
        name|description|status|version|updated)
          ordered+=("${key}")
          ;;
      esac
    fi
  done

  for key in "${REQUIRED_FIELDS[@]}"; do
    if [[ -z "${seen[${key}]:-}" ]]; then
      add_error "${path}" 1 "missing frontmatter field: ${key}"
    fi
  done

  for key in "${ordered[@]}"; do
    case "${key}" in
      name) index=0 ;;
      description) index=1 ;;
      status) index=2 ;;
      version) index=3 ;;
      updated) index=4 ;;
      *) index=-1 ;;
    esac
    if (( index < previous_index )); then
      add_error "${path}" 2 \
        "frontmatter order must be: name, description, status, version, updated"
      break
    fi
    previous_index=${index}
  done

  for ((i = 1; i < end; i++)); do
    if [[ "${lines[i]}" =~ ^status:[[:space:]]*([^[:space:]]+) ]]; then
      status="${BASH_REMATCH[1]}"
    fi
    if [[ "${lines[i]}" =~ ^version:[[:space:]]*([^[:space:]]+) ]]; then
      version="${BASH_REMATCH[1]}"
    fi
    if [[ "${lines[i]}" =~ ^updated:[[:space:]]*([^[:space:]]+) ]]; then
      updated="${BASH_REMATCH[1]}"
    fi
  done

  if [[ -n "${status}" ]]; then
    allowed=0
    for candidate in "${ALLOWED_STATUSES[@]}"; do
      if [[ "${status}" == "${candidate}" ]]; then
        allowed=1
        break
      fi
    done
    if (( allowed == 0 )); then
      add_error "${path}" "${seen[status]:-1}" "invalid status: ${status}"
    fi
  fi

  if [[ -n "${version}" && ! "${version}" =~ ^[0-9]+\.[0-9]+$ ]]; then
    add_error "${path}" "${seen[version]:-1}" "invalid version: ${version}"
  fi

  if [[ -n "${updated}" && ! "${updated}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    add_error "${path}" "${seen[updated]:-1}" "invalid updated date: ${updated}"
  fi

  BODY_START=$((end + 1))
}

body_start_of() {
  local path="$1"
  local -a lines=()
  local i

  mapfile -t lines < "${path}"
  if (( ${#lines[@]} > 0 )) \
    && [[ "${lines[0]}" =~ ^[[:space:]]*---[[:space:]]*$ ]]; then
    for ((i = 1; i < ${#lines[@]}; i++)); do
      if [[ "${lines[i]}" == "---" ]]; then
        printf '%s\n' "$((i + 1))"
        return
      fi
    done
  fi
  printf '0\n'
}

extract_links() {
  local path="$1"
  local start="$2"

  awk -v start="${start}" '
    function trim(text) {
      sub(/^[ \t]+/, "", text)
      sub(/[ \t]+$/, "", text)
      return text
    }

    NR <= start {
      next
    }

    {
      line = trim($0)

      if (fence_char == "") {
        if (match(line, /^(`{3,}|~{3,})/)) {
          fence = substr(line, RSTART, RLENGTH)
          fence_char = substr(fence, 1, 1)
          fence_length = RLENGTH
          next
        }
      } else {
        if (match(line, /^(`{3,}|~{3,})/)) {
          candidate = substr(line, RSTART, RLENGTH)
          if (substr(candidate, 1, 1) == fence_char \
            && RLENGTH >= fence_length) {
            fence_char = ""
            fence_length = 0
          }
        }
        next
      }

      gsub(/`[^`]*`/, "", line)

      while (match(line, /!?\[[^]]*\]\([^)]+\)/)) {
        target = substr(line, RSTART, RLENGTH)
        sub(/^!?\[[^]]*\]\(/, "", target)
        sub(/\)$/, "", target)
        printf "%d\t%s\n", NR, target
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "${path}"
}

normalize_target() {
  local target="$1"

  if [[ "${target}" == "<"*">" ]]; then
    target="${target#<}"
    target="${target%>}"
  fi

  case "${target}" in
    http://*|https://*|mailto:*|tel:*|data:*|ftp://*|\#*)
      return 1
      ;;
  esac

  target="${target%%#*}"
  if [[ -z "${target}" ]]; then
    return 1
  fi
  target="${target%%[[:space:]]*}"
  printf '%s\n' "${target}"
}

resolve_target() {
  local source_path="$1"
  local target="$2"
  local root="$3"

  if [[ "${target}" == /* ]]; then
    printf '%s/%s\n' "${root}" "${target#/}"
  else
    printf '%s/%s\n' "$(dirname -- "${source_path}")" "${target}"
  fi
}

check_links() {
  local path="$1"
  local start="$2"
  local root="$3"
  local line
  local target
  local normalized
  local resolved

  while IFS=$'\t' read -r line target; do
    normalized=$(normalize_target "${target}" || true)
    if [[ -z "${normalized}" ]]; then
      continue
    fi
    resolved=$(realpath -m -- "$(resolve_target "${path}" "${normalized}" "${root}")")
    if [[ ! -e "${resolved}" ]]; then
      add_error "${path}" "${line}" "broken link: ${target}"
    fi
  done < <(extract_links "${path}" "${start}")
}

check_body() {
  local path="$1"
  local start="$2"
  local root="$3"
  local -a lines=()
  local i
  local line
  local lower
  local match
  local fence_char=""
  local fence_length=0
  local fence_re='^(`{3,}|~{3,})'
  local substantive=0

  mapfile -t lines < "${path}"

  for ((i = start; i < ${#lines[@]}; i++)); do
    line="${lines[i]}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    if [[ -z "${fence_char}" ]]; then
      if [[ "${line}" =~ ${fence_re} ]]; then
        fence_char="${BASH_REMATCH[1]:0:1}"
        fence_length=${#BASH_REMATCH[1]}
        continue
      fi
    else
      if [[ "${line}" =~ ${fence_re} ]]; then
        match="${BASH_REMATCH[1]}"
        if [[ "${match:0:1}" == "${fence_char}" ]] \
          && (( ${#match} >= fence_length )); then
          fence_char=""
          fence_length=0
        fi
      fi
      continue
    fi

    if [[ -n "${line}" ]] \
      && [[ ! "${line}" =~ ^#{1,6}[[:space:]]+ ]]; then
      substantive=1
    fi

    lower="${line,,}"
    if [[ "${lower}" =~ ^(status|version|date|owner|author|revision|updated|last[[:space:]]updated|document[[:space:]]status|document[[:space:]]version)[[:space:]]*: ]]; then
      add_error "${path}" "$((i + 1))" "body metadata: ${line}"
    fi
    if [[ "${lower}" =~ ^#{1,6}[[:space:]]+(status|version|metadata|revision)[[:space:]]*$ ]]; then
      add_error "${path}" "$((i + 1))" "body metadata heading: ${line}"
    fi
  done

  if (( substantive == 0 )); then
    add_error "${path}" "" "empty document: no substantive content"
  fi

  check_links "${path}" "${start}" "${root}"
}

check_line_references() {
  local path="$1"
  local start="$2"
  local root="$3"
  local -a lines=()
  local i
  local line
  local fence_char=""
  local fence_length=0
  local fence_re='^(`{3,}|~{3,})'
  # shellcheck disable=SC2016  # regex literal; no shell expansion intended
  local inline_re='`[^`]+`'
  local span
  local reference
  local file
  local spec
  local resolved
  local total
  local -a ranges=()
  local range
  local first
  local last

  mapfile -t lines < "${path}"

  for ((i = start; i < ${#lines[@]}; i++)); do
    line="${lines[i]}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    if [[ -z "${fence_char}" ]]; then
      if [[ "${line}" =~ ${fence_re} ]]; then
        fence_char="${BASH_REMATCH[1]:0:1}"
        fence_length=${#BASH_REMATCH[1]}
        continue
      fi
    else
      if [[ "${line}" =~ ${fence_re} ]]; then
        span="${BASH_REMATCH[1]}"
        if [[ "${span:0:1}" == "${fence_char}" ]] \
          && (( ${#span} >= fence_length )); then
          fence_char=""
          fence_length=0
        fi
      fi
      continue
    fi

    while [[ "${line}" =~ ${inline_re} ]]; do
      span="${BASH_REMATCH[0]}"
      reference="${span:1:${#span}-2}"
      line="${line#*"${span}"}"

      if [[ ! "${reference}" =~ ^([^:]+):([0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*)$ ]]; then
        continue
      fi
      file="${BASH_REMATCH[1]}"
      spec="${BASH_REMATCH[2]}"

      case "${file}" in
        docs/*|infra/*|tools/*|.env*|README.md|CONTRIBUTING.md|SECURITY.md|CHANGELOG.md)
          ;;
        *)
          continue
          ;;
      esac

      resolved=""
      if [[ -f "${root}/${file}" ]]; then
        resolved="${root}/${file}"
      elif [[ -f "$(dirname -- "${path}")/${file}" ]]; then
        resolved="$(dirname -- "${path}")/${file}"
      else
        add_error "${path}" "$((i + 1))" "line reference target not found: ${reference}"
        continue
      fi

      total=$(awk 'END { print NR }' "${resolved}")
      IFS=',' read -ra ranges <<< "${spec}"
      for range in "${ranges[@]}"; do
        if [[ "${range}" == *-* ]]; then
          first="${range%-*}"
          last="${range#*-}"
        else
          first="${range}"
          last="${range}"
        fi
        if (( 10#${first} < 1 || 10#${last} < 10#${first} || 10#${last} > total )); then
          add_error "${path}" "$((i + 1))" \
            "line reference out of range: ${reference} (file has ${total} lines)"
          break
        fi
      done
    done
  done
}

check_markdown_section_number() {
  local source="$1"
  local line="$2"
  local target="$3"
  local resolved="$4"
  local number="$5"
  local escaped="${number//./\\.}"

  if ! grep -Eq "^#{1,6}[[:space:]]+${escaped}([.[:space:]]|$)" "${resolved}"; then
    add_error "${source}" "${line}" "section not found: ${number} in ${target}"
  fi
}

check_markdown_section_name() {
  local source="$1"
  local line="$2"
  local target="$3"
  local resolved="$4"
  local name="$5"

  if ! awk -v name="${name}" '
    /^#{1,6}[[:space:]]+/ {
      heading = $0
      sub(/^#{1,6}[[:space:]]+/, "", heading)
      if (heading == name) {
        found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "${resolved}"; then
    add_error "${source}" "${line}" "section not found: \"${name}\" in ${target}"
  fi
}

check_code_section_name() {
  local source="$1"
  local line="$2"
  local target="$3"
  local resolved="$4"
  local name="$5"

  local first="${name%% *}"
  first="${first,,}"

  if ! grep -Fq "# ${name}" "${resolved}" \
    && ! grep -Fq "header \"${name}\"" "${resolved}" \
    && ! grep -Eq "^[[:space:]]*${first}:" "${resolved}"; then
    add_error "${source}" "${line}" "section not found: ${name} in ${target}"
  fi
}

check_yaml_key() {
  local source="$1"
  local line="$2"
  local target="$3"
  local resolved="$4"
  local key="$5"
  local part
  local -a parts=()

  IFS='.' read -ra parts <<< "${key}"
  for part in "${parts[@]}"; do
    if [[ -z "${part}" ]] || ! grep -Eq "^[[:space:]]*${part}:" "${resolved}"; then
      add_error "${source}" "${line}" "key not found: ${key} in ${target}"
      return
    fi
  done
}

check_function_name() {
  local source="$1"
  local line="$2"
  local target="$3"
  local resolved="$4"
  local name="$5"

  if ! grep -Eq "^[[:space:]]*(function[[:space:]]+)?${name}[[:space:]]*\(\)" "${resolved}"; then
    add_error "${source}" "${line}" "function not found: ${name} in ${target}"
  fi
}

check_anchor_references() {
  local source="$1"
  local start="$2"
  local root="$3"
  local -a lines=()
  local i
  local line
  local fence_char=""
  local fence_length=0
  local fence_re='^(`{3,}|~{3,})'
  # shellcheck disable=SC2016  # regex literals; no shell expansion intended
  local path_span_re='`((docs|infra|tools)/[^` :<>*?${}]+|\.env[^` :<>*?${}]*|README\.md|CONTRIBUTING\.md|SECURITY\.md|CHANGELOG\.md)`'
  # shellcheck disable=SC2016  # regex literal; no shell expansion intended
  local inline_re='`[^`]+`'
  local list_re='^[[:space:]]*[0-9]+(\.[0-9]+)?(([[:space:]]*(,|and|through|to)[[:space:]]*[0-9]+(\.[0-9]+)?)*)'
  local match
  local target
  local rest
  local next_match
  local anchor_text
  local keyword
  local list
  local resolved
  local item

  mapfile -t lines < "${source}"

  for ((i = start; i < ${#lines[@]}; i++)); do
    line="${lines[i]}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    if [[ -z "${fence_char}" ]]; then
      if [[ "${line}" =~ ${fence_re} ]]; then
        fence_char="${BASH_REMATCH[1]:0:1}"
        fence_length=${#BASH_REMATCH[1]}
        continue
      fi
    else
      if [[ "${line}" =~ ${fence_re} ]]; then
        match="${BASH_REMATCH[1]}"
        if [[ "${match:0:1}" == "${fence_char}" ]] \
          && (( ${#match} >= fence_length )); then
          fence_char=""
          fence_length=0
        fi
      fi
      continue
    fi

    while [[ "${line}" =~ ${path_span_re} ]]; do
      match="${BASH_REMATCH[0]}"
      target="${BASH_REMATCH[1]}"
      rest="${line#*"${match}"}"

      if [[ "${rest}" =~ ${path_span_re} ]]; then
        next_match="${BASH_REMATCH[0]}"
        anchor_text="${rest%%"${next_match}"*}"
      else
        anchor_text="${rest}"
      fi

      anchor_text="${anchor_text#"${anchor_text%%[![:space:]]*}"}"
      while [[ "${anchor_text}" == ";"* || "${anchor_text}" == ","* ]]; do
        anchor_text="${anchor_text:1}"
        anchor_text="${anchor_text#"${anchor_text%%[![:space:]]*}"}"
      done
      if [[ ! "${anchor_text}" =~ ^[[:space:]]*(section|sections|key|keys|component|components|function|functions)([[:space:]]|$) ]]; then
        line="${rest}"
        continue
      fi
      keyword="${BASH_REMATCH[1]}"
      list="${anchor_text#*"${keyword}"}"

      resolved=""
      if [[ -e "${root}/${target}" ]]; then
        resolved="${root}/${target}"
      elif [[ -e "$(dirname -- "${source}")/${target}" ]]; then
        resolved="$(dirname -- "${source}")/${target}"
      else
        add_error "${source}" "$((i + 1))" "anchored path not found: ${target}"
        line="${rest}"
        continue
      fi

      case "${keyword}" in
        section|sections)
          if [[ "${list}" == *'`'* ]]; then
            while [[ "${list}" =~ ${inline_re} ]]; do
              item="${BASH_REMATCH[0]}"
              item="${item:1:${#item}-2}"
              check_code_section_name "${source}" "$((i + 1))" "${target}" "${resolved}" "${item}"
              list="${list#*"${BASH_REMATCH[0]}"}"
            done
          elif [[ "${list}" == *'"'* ]]; then
            while [[ "${list}" =~ \"([^\"]+)\" ]]; do
              item="${BASH_REMATCH[1]}"
              check_markdown_section_name "${source}" "$((i + 1))" "${target}" "${resolved}" "${item}"
              list="${list#*"${BASH_REMATCH[0]}"}"
            done
          else
            if [[ "${list}" =~ ${list_re} ]]; then
              list="${BASH_REMATCH[0]}"
            fi
            while [[ "${list}" =~ ([0-9]+(\.[0-9]+)?) ]]; do
              item="${BASH_REMATCH[1]}"
              check_markdown_section_number "${source}" "$((i + 1))" "${target}" "${resolved}" "${item}"
              list="${list#*"${BASH_REMATCH[0]}"}"
            done
          fi
          ;;
        key|keys|component|components)
          while [[ "${list}" =~ ${inline_re} ]]; do
            item="${BASH_REMATCH[0]}"
            item="${item:1:${#item}-2}"
            check_yaml_key "${source}" "$((i + 1))" "${target}" "${resolved}" "${item}"
            list="${list#*"${BASH_REMATCH[0]}"}"
          done
          ;;
        function|functions)
          while [[ "${list}" =~ ${inline_re} ]]; do
            item="${BASH_REMATCH[0]}"
            item="${item:1:${#item}-2}"
            check_function_name "${source}" "$((i + 1))" "${target}" "${resolved}" "${item}"
            list="${list#*"${BASH_REMATCH[0]}"}"
          done
          ;;
      esac

      line="${rest}"
    done
  done
}

audit_file() {
  local path="$1"
  local root="$2"

  if grep -q $'\r' "${path}"; then
    add_error "${path}" "" "CRLF line endings"
  fi

  check_trailing_newline "${path}"
  parse_frontmatter "${path}"
  if (( BODY_START >= 0 )); then
    check_body "${path}" "${BODY_START}" "${root}"
    check_line_references "${path}" "${BODY_START}" "${root}"
    check_anchor_references "${path}" "${BODY_START}" "${root}"
  fi
}

check_reachability() {
  local root="$1"
  local readme="${root}/README.md"
  local -A reachable=()
  local -a queue=()
  local queue_index=0
  local source
  local line
  local target
  local normalized
  local resolved
  local markdown
  local markdown_absolute
  local doc
  local doc_absolute

  if [[ ! -f "${readme}" ]]; then
    add_error "${readme}" "" "missing README.md"
    return
  fi

  reachable["${readme}"]=1
  queue+=("${readme}")

  while (( queue_index < ${#queue[@]} )); do
    source="${queue[queue_index]}"
    ((queue_index += 1))

    while IFS=$'\t' read -r line target; do
      normalized=$(normalize_target "${target}" || true)
      if [[ -z "${normalized}" ]]; then
        continue
      fi

      resolved=$(realpath -m -- "$(resolve_target "${source}" "${normalized}" "${root}")")
      if [[ -d "${resolved}" ]]; then
        while IFS= read -r markdown; do
          markdown_absolute=$(realpath -m -- "${markdown}")
          if [[ -z "${reachable[${markdown_absolute}]:-}" ]]; then
            reachable["${markdown_absolute}"]=1
            queue+=("${markdown_absolute}")
          fi
        done < <(find "${resolved}" -type f -name '*.md' | sort)
      elif [[ "${resolved}" == *.md && -f "${resolved}" ]]; then
        if [[ -z "${reachable[${resolved}]:-}" ]]; then
          reachable["${resolved}"]=1
          queue+=("${resolved}")
        fi
      fi
    done < <(extract_links "${source}" "$(body_start_of "${source}")")
  done

  for doc in "${docs[@]}"; do
    doc_absolute=$(realpath -m -- "${doc}")
    if [[ -z "${reachable[${doc_absolute}]:-}" ]]; then
      add_error "${doc}" "" "orphan document: not reachable from README.md"
    fi
  done
}

main() {
  local root="${1:-${DEFAULT_ROOT}}"
  local docs_dir
  local doc
  local root_markdown

  root=$(realpath -m -- "${root}")
  docs_dir="${root}/docs"

  if [[ ! -d "${docs_dir}" ]]; then
    printf 'ERROR %s: docs directory not found\n' "${docs_dir}" >&2
    return 1
  fi

  mapfile -t docs < <(find "${docs_dir}" -type f -name '*.md' | sort)

  for doc in "${docs[@]}"; do
    audit_file "${doc}" "${root}"
  done

  while IFS= read -r root_markdown; do
    check_links "${root_markdown}" "$(body_start_of "${root_markdown}")" "${root}"
  done < <(find "${root}" -maxdepth 1 -type f -name '*.md' | sort)

  check_reachability "${root}"

  printf 'docs: %d, errors: %d\n' "${#docs[@]}" "${#errors[@]}"
  (( ${#errors[@]} == 0 ))
}

main "$@"
