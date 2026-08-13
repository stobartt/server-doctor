#!/usr/bin/env bash

# Fail closed before packaging if a collector bypassed the redactor. The scan
# reports file names only, never the matching content.
privacy_scan_report() {
  local result="$REPORT_DIR/privacy-scan.txt"
  local matches
  rm -f -- "$result"
  matches=$(mktemp "${TMPDIR:-/tmp}/server-doctor-privacy.XXXXXX") || return 1
  printf 'status\tpassed\npolicy\tno IP addresses, ports, user inventories, user-home paths, configurations, or raw application log messages\n' |
    redact_stream >"$result"
  chmod 0600 "$result"

  find "$REPORT_DIR" -type f -print0 |
    xargs -0 grep -IlE \
      '(^|[^0-9])([0-9]{1,3}\.){3}[0-9]{1,3}|([[:xdigit:]]{1,4}:){3,7}[[:xdigit:]]{0,4}|[[:xdigit:]]{0,4}::([[:xdigit:]]{0,4}:){0,6}[[:xdigit:]]{0,4}|/(home|[Uu]sers?)/[^/[:space:]]+|/root(/|[[:space:]]|$)|((port|listen(ing)?([[:space:]]+on)?|local[_ -]?port|remote[_ -]?port)[[:space:]:=]+)[0-9]{1,5}' \
      >"$matches" 2>/dev/null || true

  if [[ -n ${SERVER_DOCTOR_ACCOUNT_REGEX:-} ]]; then
    find "$REPORT_DIR" -type f -print0 |
      xargs -0 grep -IlE \
        "(^|[^[:alnum:]])(${SERVER_DOCTOR_ACCOUNT_REGEX})([^[:alnum:]]|$)" \
        >>"$matches" 2>/dev/null || true
    sort -u -o "$matches" "$matches"
  fi

  if [[ -n ${SERVER_DOCTOR_NODE_REGEX:-} ]]; then
    find "$REPORT_DIR" -type f -print0 |
      xargs -0 grep -IlE \
        "(^|[^[:alnum:]])(${SERVER_DOCTOR_NODE_REGEX})([^[:alnum:]]|$)" \
        >>"$matches" 2>/dev/null || true
    sort -u -o "$matches" "$matches"
  fi

  if [[ -s $matches ]]; then
    printf 'Privacy scan failed. Potential IP, port, or user-home data remains in:\n' >&2
    sed "s#^$REPORT_DIR/##" "$matches" >&2
    rm -f -- "$matches"
    rm -f -- "$result"
    return 1
  fi

  rm -f -- "$matches"
}
