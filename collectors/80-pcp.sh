#!/usr/bin/env bash
set -uo pipefail

source "$SERVER_DOCTOR_ROOT/lib/common.sh"

if [[ $SERVER_DOCTOR_PROFILE == quick ]]; then
  write_not_applicable pcp "The quick profile omits PCP history. Use PROFILE=standard or deep."
  exit 0
fi

archive_dir=$(find /var/log/pcp/pmlogger -type f -name '*.meta' -printf '%T@\t%h\n' 2>/dev/null |
  sort -rn | head -n 1 | cut -f2-)
if [[ -z $archive_dir ]]; then
  printf 'PCP archive disappeared after preflight.\n' >&2
  exit 1
fi

since_words=$(since_to_words "$SERVER_DOCTOR_SINCE")
pcp_start="-$since_words"

# Only aggregate resource metrics are exported. The raw PCP archive remains on
# the server because its labels can contain local instance identifiers.
run_capture "PCP historical resource summary" pcp/summary.tsv "$SERVER_DOCTOR_PCP_TIMEOUT" \
  pmlogsummary -f -H -i -I -m -M -y -S "$pcp_start" -T now "$archive_dir" \
    kernel.all.cpu kernel.all.load mem.util swap disk.all

run_capture "PCP historical per-process summary" pcp/process-summary.tsv "$SERVER_DOCTOR_PCP_TIMEOUT" bash -c '
  metrics=()
  for metric in proc.memory.rss proc.memory.vsize proc.io.total_bytes; do
    pminfo -a "$1" "$metric" >/dev/null 2>&1 && metrics+=("$metric")
  done
  if ((${#metrics[@]} == 0)); then
    echo "No per-process metrics were logged in the selected PCP archives."
    exit 0
  fi
  pmlogsummary -f -H -i -I -m -M -y -S "$2" -T now "$1" "${metrics[@]}"
' _ "$archive_dir" "$pcp_start"
