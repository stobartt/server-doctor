#!/usr/bin/env bash
set -uo pipefail

source "$SERVER_DOCTOR_ROOT/lib/common.sh"

since_words=$(since_to_words "$SERVER_DOCTOR_SINCE")
journal_since="-$since_words"

run_capture "systemd services" systemd/services.tsv "$SERVER_DOCTOR_COMMAND_TIMEOUT" \
  systemctl list-units --type=service --all --no-pager --plain
run_capture "failed systemd units" systemd/failed-units.tsv "$SERVER_DOCTOR_COMMAND_TIMEOUT" \
  systemctl list-units --state=failed --all --no-pager --plain
run_capture "systemd timers" systemd/timers.tsv "$SERVER_DOCTOR_COMMAND_TIMEOUT" \
  systemctl list-timers --all --no-pager
run_capture "systemd service resource properties" systemd/service-resources.txt "$SERVER_DOCTOR_COMMAND_TIMEOUT" bash -c '
  systemctl list-units --type=service --all --no-legend --plain | awk "{print \$1}" | while read -r unit; do
    [[ -n $unit ]] || continue
    display_unit=$(printf "%s" "$unit" | sed -E "s/user@[0-9]+/[REDACTED_USER_UNIT]/g")
    printf "\n## %s\n" "$display_unit"
    systemctl show "$unit" --no-pager \
      -p Id -p Description -p LoadState -p ActiveState -p SubState -p Result \
      -p MainPID -p ExecMainCode -p ExecMainStatus -p NRestarts -p TasksCurrent \
      -p MemoryCurrent -p MemoryPeak -p CPUUsageNSec -p IOReadBytes -p IOWriteBytes
  done
'

# Raw system/application messages can contain people, addresses, and ports.
# Export only service-level counts and a fixed diagnostic category.
run_capture "journal error categories" logs/journal-error-summary.tsv "$SERVER_DOCTOR_COMMAND_TIMEOUT" bash -c '
  printf "count\tpriority\tunit\tidentifier\tcategory\n"
  journalctl --since "$1" -p err --utc --no-pager --quiet -o json |
    jq -r "
      (.MESSAGE // \"\" | ascii_downcase) as \$message |
      [
        (.PRIORITY // \"unknown\"),
        ((._SYSTEMD_UNIT // \"-\") | gsub(\"user@[0-9]+\"; \"[REDACTED_USER_UNIT]\")),
        (.SYSLOG_IDENTIFIER // \"-\"),
        (if (\$message | test(\"out of memory|oom\")) then \"out_of_memory\"
         elif (\$message | test(\"segfault|segmentation fault\")) then \"segmentation_fault\"
         elif (\$message | test(\"panic\")) then \"panic\"
         elif (\$message | test(\"i/o error|filesystem error|read-only file system\")) then \"storage_error\"
         elif (\$message | test(\"timeout|timed out\")) then \"timeout\"
         elif (\$message | test(\"connection refused|connection reset\")) then \"connection_failure\"
         elif (\$message | test(\"permission denied|access denied\")) then \"permission_failure\"
         elif (\$message | test(\"failed|failure\")) then \"operation_failed\"
         else \"priority_error_other\" end)
      ] | @tsv
    " |
    sort | uniq -c | sort -rn |
    awk "{count=\$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, \"\"); print count \"\\t\" \$0}"
' _ "$journal_since"

run_capture "journal diagnostic signatures" logs/journal-signature-summary.tsv "$SERVER_DOCTOR_COMMAND_TIMEOUT" bash -c '
  printf "count\tpriority\tunit\tidentifier\tcategory\n"
  journalctl --since "$1" --utc --no-pager --quiet -o json \
    --case-sensitive=false --grep="error|fatal|panic|exception|oom|out of memory|segfault|timeout|timed out|failed|connection refused" |
    jq -r "
      (.MESSAGE // \"\" | ascii_downcase) as \$message |
      [
        (.PRIORITY // \"unknown\"),
        ((._SYSTEMD_UNIT // \"-\") | gsub(\"user@[0-9]+\"; \"[REDACTED_USER_UNIT]\")),
        (.SYSLOG_IDENTIFIER // \"-\"),
        (if (\$message | test(\"out of memory|oom\")) then \"out_of_memory\"
         elif (\$message | test(\"fatal\")) then \"fatal\"
         elif (\$message | test(\"panic\")) then \"panic\"
         elif (\$message | test(\"exception\")) then \"exception\"
         elif (\$message | test(\"segfault|segmentation fault\")) then \"segmentation_fault\"
         elif (\$message | test(\"timeout|timed out\")) then \"timeout\"
         elif (\$message | test(\"connection refused\")) then \"connection_failure\"
         elif (\$message | test(\"failed|failure\")) then \"operation_failed\"
         else \"error_other\" end)
      ] | @tsv
    " |
    sort | uniq -c | sort -rn |
    awk "{count=\$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, \"\"); print count \"\\t\" \$0}"
  status=${PIPESTATUS[0]}
  ((status == 0 || status == 1))
' _ "$journal_since"

# Kernel messages are retained because their exact OOM/storage context is
# diagnostic. They omit the journal node-name prefix and still pass redaction.
run_capture "kernel warnings and errors" logs/kernel-warnings.jsonl "$SERVER_DOCTOR_COMMAND_TIMEOUT" bash -c '
  journalctl -k --since "$1" -p warning --utc --no-pager --quiet -o json |
    jq -c "{timestamp_usec: .__REALTIME_TIMESTAMP, priority: .PRIORITY, message: .MESSAGE}"
' _ "$journal_since"
run_capture "kernel critical signatures" logs/kernel-signatures.jsonl "$SERVER_DOCTOR_COMMAND_TIMEOUT" bash -c '
  journalctl -k --since "$1" --utc --no-pager --quiet -o json \
    --case-sensitive=false --grep="oom|out of memory|segfault|panic|I/O error|filesystem error|reset|hung task|blocked for more than" |
    jq -c "{timestamp_usec: .__REALTIME_TIMESTAMP, priority: .PRIORITY, message: .MESSAGE}"
  status=${PIPESTATUS[0]}
  ((status == 0 || status == 1))
' _ "$journal_since"

run_capture "APT package history" logs/apt-history.txt "$SERVER_DOCTOR_COMMAND_TIMEOUT" bash -c '
  files=(/var/log/apt/history.log /var/log/apt/history.log.*)
  ((${#files[@]})) || exit 0
  zgrep -h -E "^(Start-Date|End-Date|Install|Upgrade|Remove|Purge|Error):" "${files[@]}" 2>/dev/null || true
'
