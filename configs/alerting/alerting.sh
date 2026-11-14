#!/usr/bin/env bash
set -euo pipefail

readonly ENV_FILE="/data/monitoring/alerting/env"
readonly SERVICES_FILE="/etc/pcp/alerting/services.list"
readonly STATE_DIR="/var/lib/stack-alerting/state"
readonly ACME_FILE="/data/traefik/letsencrypt/acme.json"
readonly CERT_WARN_DAYS=14
readonly COOLDOWN_SECONDS=1800

usage() {
  cat <<'USAGE'
Usage: stack-alerting <command> [arguments]

Commands:
  notify <source> <message>     Send an explicit alert.
  notify-code <code>            Send a pmie alert code with deduplication.
  check-services                Check systemd units and HTTP health endpoints.
  check-cert                    Check the earliest Traefik certificate expiry.
  heartbeat                     Send the external heartbeat.
  test                          Send a test alert.

The runtime secrets come from /data/monitoring/alerting/env.
USAGE
}

err() {
  printf 'ERROR: %s\n' "$*" >&2
}

load_env() {
  if [[ ! -r "${ENV_FILE}" ]]; then
    err "cannot read ${ENV_FILE}"
    exit 1
  fi

  # shellcheck disable=SC1090
  source "${ENV_FILE}"

  if [[ -z "${ALERT_WEBHOOK_URL:-}" ]]; then
    err "ALERT_WEBHOOK_URL is not set"
    exit 1
  fi
  if [[ "${ALERT_WEBHOOK_URL}" != https://* ]]; then
    err "ALERT_WEBHOOK_URL must use HTTPS"
    exit 1
  fi
}

send_webhook() {
  local source="$1"
  local message="$2"
  local payload

  load_env
  payload="$(
    jq -n \
      --arg source "${source}" \
      --arg message "${message}" \
      --arg host "$(hostname 2>/dev/null || printf 'unknown')" \
      --arg time "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
      '{source: $source, message: $message, host: $host, time: $time}'
  )"

  curl -fsS --max-time 10 \
    -H 'Content-Type: application/json' \
    --data "${payload}" \
    "${ALERT_WEBHOOK_URL}" >/dev/null
}

state_file() {
  local key="$1"
  local safe

  safe="$(printf '%s' "${key}" | tr -c 'A-Za-z0-9._-' '_')"
  printf '%s/%s' "${STATE_DIR}" "${safe}"
}

read_state() {
  local file="$1"

  if [[ -r "${file}" ]]; then
    cat "${file}"
  fi
}

write_state() {
  local file="$1"
  local value="$2"

  printf '%s\n' "${value}" > "${file}"
}

notify_transition() {
  local key="$1"
  local message="$2"
  local current="$3"
  local file
  local previous

  file="$(state_file "${key}")"
  previous="$(read_state "${file}")"

  if [[ "${previous}" == "${current}" ]]; then
    return 0
  fi

  if [[ "${current}" == "fail" ]]; then
    if send_webhook "check" "${message}"; then
      write_state "${file}" "fail"
    fi
    return 0
  fi

  if [[ "${previous}" == "fail" ]]; then
    if send_webhook "recovery" "${message}"; then
      write_state "${file}" "ok"
    fi
    return 0
  fi

  write_state "${file}" "ok"
}

acquire_lock() {
  if [[ ! -d "${STATE_DIR}" ]]; then
    err "state directory ${STATE_DIR} is missing"
    exit 1
  fi
  exec 9>"${STATE_DIR}/lock"
  if ! flock -n 9; then
    err "another alerting check is already running"
    exit 0
  fi
}

check_system_unit() {
  local unit="$1"
  local optional="$2"
  local state

  if [[ "${optional}" == "true" ]]; then
    if ! systemctl list-unit-files --no-legend "${unit}" 2>/dev/null | grep -q "^${unit}"; then
      return 0
    fi
  fi

  if systemctl is-active --quiet "${unit}"; then
    state="ok"
  else
    state="fail"
  fi

  notify_transition "service:${unit}" "Service ${unit} is inactive" "${state}"
}

check_http_endpoint() {
  local name="$1"
  local url="$2"
  local state

  if curl -fsS --max-time 5 "${url}" >/dev/null 2>&1; then
    state="ok"
  else
    state="fail"
  fi

  notify_transition "http:${name}" "Health endpoint ${name} is unavailable" "${state}"
}

check_services() {
  local line
  local kind
  local rest

  load_env

  if [[ ! -r "${SERVICES_FILE}" ]]; then
    err "cannot read ${SERVICES_FILE}"
    exit 1
  fi

  while IFS= read -r line; do
    if [[ -z "${line}" || "${line}" == \#* ]]; then
      continue
    fi

    kind="${line%%:*}"
    rest="${line#*:}"

    case "${kind}" in
      system)
        check_system_unit "${rest}" "false"
        ;;
      system-optional)
        check_system_unit "${rest}" "true"
        ;;
      http)
        check_http_endpoint "${rest%%:*}" "${rest#*:}"
        ;;
      *)
        err "unknown service check type: ${kind}"
        exit 1
        ;;
    esac
  done < "${SERVICES_FILE}"
}

check_cert() {
  local now
  local earliest_epoch=""
  local earliest_name=""
  local certificate
  local end_date
  local epoch
  local days

  load_env

  if [[ ! -r "${ACME_FILE}" ]]; then
    err "cannot read ${ACME_FILE}"
    exit 1
  fi

  now="$(date +%s)"

  while IFS= read -r certificate; do
    if [[ -z "${certificate}" ]]; then
      continue
    fi

    end_date="$(
      printf '%s' "${certificate}" \
        | base64 -d 2>/dev/null \
        | openssl x509 -inform DER -noout -enddate 2>/dev/null \
        | cut -d= -f2
    )" || continue

    if [[ -z "${end_date}" ]]; then
      continue
    fi

    epoch="$(date -d "${end_date}" +%s 2>/dev/null)" || continue

    if [[ -z "${earliest_epoch}" || "${epoch}" -lt "${earliest_epoch}" ]]; then
      earliest_epoch="${epoch}"
      earliest_name="${end_date}"
    fi
  done < <(jq -r '.. | .certificate? // empty' "${ACME_FILE}" 2>/dev/null)

  if [[ -z "${earliest_epoch}" ]]; then
    err "no certificate found in ${ACME_FILE}"
    exit 1
  fi

  days=$(( (earliest_epoch - now) / 86400 ))

  if (( days < CERT_WARN_DAYS )); then
    notify_transition "certificate" \
      "TLS certificate expires in ${days} days (${earliest_name})" "fail"
  else
    notify_transition "certificate" "TLS certificate expiry is healthy" "ok"
  fi
}

notify_code() {
  local code="$1"
  local message
  local file
  local now
  local last

  case "${code}" in
    filesystem-usage)
      message="Filesystem usage is above 85 percent"
      ;;
    memory-low)
      message="Available memory is below 512 MB"
      ;;
    load-high)
      message="One-minute load average is above 4"
      ;;
    *)
      message="pmie alert: ${code}"
      ;;
  esac

  file="$(state_file "pmie:${code}")"
  now="$(date +%s)"
  last="$(read_state "${file}")"

  if [[ -n "${last}" ]] && (( now - last < COOLDOWN_SECONDS )); then
    return 0
  fi

  if send_webhook "pmie" "${message}"; then
    write_state "${file}" "${now}"
  fi
}

heartbeat() {
  load_env

  if [[ -z "${ALERT_HEARTBEAT_URL:-}" ]]; then
    err "ALERT_HEARTBEAT_URL is not set"
    exit 1
  fi
  if [[ "${ALERT_HEARTBEAT_URL}" != https://* ]]; then
    err "ALERT_HEARTBEAT_URL must use HTTPS"
    exit 1
  fi

  curl -fsS --max-time 10 "${ALERT_HEARTBEAT_URL}" >/dev/null
}

main() {
  local command="${1:-}"

  case "${command}" in
    notify)
      send_webhook "${2:-alert}" "${3:-Alert without a message}"
      ;;
    notify-code)
      notify_code "${2:-unknown}"
      ;;
    check-services)
      acquire_lock
      check_services
      ;;
    check-cert)
      acquire_lock
      check_cert
      ;;
    heartbeat)
      heartbeat
      ;;
    test)
      send_webhook "test" "Test alert from $(hostname 2>/dev/null || printf 'unknown')"
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
