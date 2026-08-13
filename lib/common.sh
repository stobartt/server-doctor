#!/usr/bin/env bash

if [[ -z ${SERVER_DOCTOR_ROOT:-} ]]; then
  SERVER_DOCTOR_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
fi

# shellcheck source=lib/redact.sh
source "$SERVER_DOCTOR_ROOT/lib/redact.sh"

log_message() {
  local level=$1
  shift
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*" | tee -a "${COLLECTION_LOG:-/dev/null}" >&2
}

safe_report_path() {
  local path=$1
  case "$path" in
    "$REPORT_DIR"/*) return 0 ;;
    *)
      printf 'Refusing path outside report directory: %s\n' "$path" >&2
      return 1
      ;;
  esac
}

record_check() {
  local label=$1
  local relative=$2
  local started=$3
  local duration=$4
  local exit_code=$5
  local status=$6
  local bytes=$7
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$started" "$duration" "$exit_code" "$status" "$bytes" "$label" "$relative" \
    >>"$CHECKS_TSV"
}

# Run one read-only check with a wall-clock timeout and per-file size limit.
# The function intentionally returns success: a failed individual observation is
# recorded and the remaining collectors continue. Strict dependency validation
# happens before any report directory is created.
run_capture() {
  local label=$1
  local relative=$2
  local limit_seconds=$3
  shift 3

  local output="$REPORT_DIR/$relative"
  safe_report_path "$output" || return 1
  mkdir -p "$(dirname "$output")"

  local raw="${output}.raw.$$"
  local started start_epoch end_epoch duration exit_code bytes raw_bytes status max_kib
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  start_epoch=$(date +%s)
  max_kib=$((SERVER_DOCTOR_MAX_FILE_MIB * 1024))

  (
    ulimit -f "$max_kib"
    exec timeout --signal=TERM --kill-after=5s "${limit_seconds}s" "$@"
  ) >"$raw" 2>&1
  exit_code=$?

  raw_bytes=$(wc -c <"$raw" | tr -d ' ')
  redact_file "$raw" "$output"
  bytes=$(wc -c <"$output" | tr -d ' ')
  end_epoch=$(date +%s)
  duration=$((end_epoch - start_epoch))

  if (( exit_code == 153 || raw_bytes >= SERVER_DOCTOR_MAX_FILE_MIB * 1024 * 1024 - 4096 )); then
    status=truncated
    printf '\n[server-doctor: output truncated at %s MiB]\n' "$SERVER_DOCTOR_MAX_FILE_MIB" >>"$output"
  elif (( exit_code == 0 )); then
    status=ok
  elif (( exit_code == 124 || exit_code == 137 )); then
    status=timeout
  else
    status=failed
  fi

  rm -f -- "$raw"
  record_check "$label" "$relative" "$started" "$duration" "$exit_code" "$status" "$bytes"
  log_message INFO "$label: $status (exit=$exit_code, duration=${duration}s, bytes=$bytes)"
  return 0
}

write_not_applicable() {
  local section=$1
  local reason=$2
  local file="$REPORT_DIR/$section/NOT_APPLICABLE.md"
  safe_report_path "$file" || return 1
  mkdir -p "$(dirname "$file")"
  printf '# Not applicable\n\n%s\n' "$reason" >"$file"
  record_check "$section" "$section/NOT_APPLICABLE.md" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" 0 0 not_applicable "$(wc -c <"$file" | tr -d ' ')"
}

since_to_words() {
  local value=$1
  local number=${value%?}
  local suffix=${value: -1}
  case "$suffix" in
    m) printf '%s minutes' "$number" ;;
    h) printf '%s hours' "$number" ;;
    d) printf '%s days' "$number" ;;
    w) printf '%s weeks' "$number" ;;
  esac
}

since_to_minutes() {
  local value=$1
  local number=${value%?}
  local suffix=${value: -1}
  case "$suffix" in
    m) printf '%s' "$number" ;;
    h) printf '%s' $((number * 60)) ;;
    d) printf '%s' $((number * 1440)) ;;
    w) printf '%s' $((number * 10080)) ;;
  esac
}

safe_name() {
  printf '%s' "$1" | sed -E 's/[^A-Za-z0-9_.-]+/_/g; s/^_+//; s/_+$//'
}
