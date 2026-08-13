#!/usr/bin/env bash
set -uo pipefail

source "$SERVER_DOCTOR_ROOT/lib/common.sh"

run_capture "all processes" performance/processes.tsv "$SERVER_DOCTOR_COMMAND_TIMEOUT" \
  ps -eo pid,ppid,stat,ni,pri,nlwp,pcpu,pmem,rss,vsz,etimes,comm --sort=pid
run_capture "processes by CPU" performance/processes-by-cpu.tsv "$SERVER_DOCTOR_COMMAND_TIMEOUT" \
  ps -eo pid,ppid,stat,nlwp,pcpu,pmem,rss,vsz,etimes,comm --sort=-pcpu
run_capture "processes by RSS" performance/processes-by-rss.tsv "$SERVER_DOCTOR_COMMAND_TIMEOUT" \
  ps -eo pid,ppid,stat,nlwp,pcpu,pmem,rss,vsz,etimes,comm --sort=-rss
run_capture "process memory PSS and swap" performance/process-memory.tsv "$SERVER_DOCTOR_COMMAND_TIMEOUT" bash -c '
  printf "pid\tppid\trss_kib\tpss_kib\tprivate_kib\tswap_pss_kib\tcommand\n"
  for process in /proc/[0-9]*; do
    [[ -r $process/status && -r $process/comm ]] || continue
    pid=${process##*/}
    ppid=$(awk "/^PPid:/ {print \$2}" "$process/status" 2>/dev/null)
    rss=$(awk "/^VmRSS:/ {print \$2}" "$process/status" 2>/dev/null)
    if [[ -r $process/smaps_rollup ]]; then
      read -r pss private swap_pss < <(awk "
        /^Pss:/ {pss=\$2}
        /^Private_Clean:/ {private_clean=\$2}
        /^Private_Dirty:/ {private_dirty=\$2}
        /^SwapPss:/ {swap_pss=\$2}
        END {print pss+0, private_clean+private_dirty, swap_pss+0}
      " "$process/smaps_rollup" 2>/dev/null)
    else
      pss=0; private=0; swap_pss=0
    fi
    command=$(tr "\t\n" "  " <"$process/comm")
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$pid" "${ppid:-0}" "${rss:-0}" "${pss:-0}" "${private:-0}" "${swap_pss:-0}" "$command"
  done | sort -rn -k4,4
'

interval=5
count=$((SERVER_DOCTOR_OBSERVE_SECONDS / interval))
(( count < 2 )) && count=2
sample_timeout=$((SERVER_DOCTOR_OBSERVE_SECONDS + 30))

run_capture "vmstat active sample" performance/vmstat.txt "$sample_timeout" vmstat -w "$interval" "$count" &
run_capture "pidstat active sample" performance/pidstat.txt "$sample_timeout" bash -c '
  pidstat -u -r -d -h -p ALL "$1" "$2" | awk "
    /^Linux / {next}
    {
      uid=0
      for (i=1; i<=NF; i++) if (\$i == \"UID\") uid=i
      if (uid) {active_uid=uid; for (i=1; i<=NF; i++) if (i != uid) printf \"%s%s\", \$i, (i==NF ? ORS : OFS); next}
      if (active_uid && NF >= active_uid) {
        for (i=1; i<=NF; i++) if (i != active_uid) printf \"%s%s\", \$i, (i==NF ? ORS : OFS)
        next
      }
      print
    }
  "
' _ "$interval" "$count" &
run_capture "iostat active sample" performance/iostat.txt "$sample_timeout" bash -c '
  iostat -x -z -y "$1" "$2" | sed "/^Linux /d"
' _ "$interval" "$count" &
run_capture "resource active sample" performance/sar-resource.txt "$sample_timeout" bash -c '
  sar -u ALL -r ALL -S -W -B -q ALL -d "$1" "$2" | sed "/^Linux /d"
' _ "$interval" "$count" &
if (( CAP_SYSTEMD )); then
  run_capture "cgroup active sample" performance/systemd-cgtop.txt "$sample_timeout" bash -c '
    systemd-cgtop --batch --iterations="$1" --delay="${2}s" |
      sed -E "s/user-[0-9]+\\.slice/[REDACTED_USER_SLICE]/g"
  ' _ "$count" "$interval" &
fi
wait

history_minutes=$(since_to_minutes "$SERVER_DOCTOR_SINCE")
run_capture "sysstat historical data" performance/sar-history.txt "$SERVER_DOCTOR_PCP_TIMEOUT" bash -c '
  set -o pipefail
  window=$((10#$1 + 1440))
  mapfile -d "" files < <(find /var/log/sysstat /var/log/sa -type f -name "sa[0-9]*" -mmin "-$window" -print0 2>/dev/null | sort -z)
  ((${#files[@]})) || { echo "No sysstat archives found"; exit 1; }
  for file in "${files[@]}"; do
    printf "\n### %s\n" "$file"
    sar -u ALL -r ALL -S -W -B -q ALL -d -f "$file" | sed "/^Linux /d" || true
  done
' _ "$history_minutes"

run_capture "processes after sample" performance/processes-after.tsv "$SERVER_DOCTOR_COMMAND_TIMEOUT" \
  ps -eo pid,ppid,stat,nlwp,pcpu,pmem,rss,vsz,etimes,comm --sort=-pcpu
