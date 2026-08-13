#!/usr/bin/env bash

markdown_escape() {
  sed 's/|/\\|/g'
}

generate_summary() {
  local summary="$REPORT_DIR/summary.md"
  local bundle_readme="$REPORT_DIR/README.md"
  local failed_checks=0 timed_out=0 truncated=0 failed_units=0
  local journal_errors=0 oom_lines=0 disk_error_lines=0 deleted_open=0
  local stopped_containers=0 unreferenced_images=0 unused_volumes=0
  local mem_total_kib=0 mem_available_kib=0 swap_total_kib=0 swap_free_kib=0 mem_available_pct=0
  local cache_kib=0 anon_kib=0 slab_kib=0 shmem_kib=0 kernel_stack_kib=0 page_tables_kib=0 process_pss_kib=0
  local disk_findings inode_findings psi_findings reboot_required=no

  failed_checks=$(awk -F '\t' 'NR > 1 && $4 == "failed" {n++} END {print n+0}' "$CHECKS_TSV")
  timed_out=$(awk -F '\t' 'NR > 1 && $4 == "timeout" {n++} END {print n+0}' "$CHECKS_TSV")
  truncated=$(awk -F '\t' 'NR > 1 && $4 == "truncated" {n++} END {print n+0}' "$CHECKS_TSV")

  if [[ -f $REPORT_DIR/system/proc-meminfo.txt ]]; then
    mem_total_kib=$(awk '/^MemTotal:/ {print $2+0}' "$REPORT_DIR/system/proc-meminfo.txt")
    mem_available_kib=$(awk '/^MemAvailable:/ {print $2+0}' "$REPORT_DIR/system/proc-meminfo.txt")
    swap_total_kib=$(awk '/^SwapTotal:/ {print $2+0}' "$REPORT_DIR/system/proc-meminfo.txt")
    swap_free_kib=$(awk '/^SwapFree:/ {print $2+0}' "$REPORT_DIR/system/proc-meminfo.txt")
    cache_kib=$(awk '
      /^Buffers:/ {buffers=$2} /^Cached:/ {cached=$2} /^SReclaimable:/ {reclaim=$2} /^Shmem:/ {shmem=$2}
      END {value=buffers+cached+reclaim-shmem; print (value > 0 ? value : 0)}
    ' "$REPORT_DIR/system/proc-meminfo.txt")
    anon_kib=$(awk '/^AnonPages:/ {print $2+0}' "$REPORT_DIR/system/proc-meminfo.txt")
    slab_kib=$(awk '/^Slab:/ {print $2+0}' "$REPORT_DIR/system/proc-meminfo.txt")
    shmem_kib=$(awk '/^Shmem:/ {print $2+0}' "$REPORT_DIR/system/proc-meminfo.txt")
    kernel_stack_kib=$(awk '/^KernelStack:/ {print $2+0}' "$REPORT_DIR/system/proc-meminfo.txt")
    page_tables_kib=$(awk '/^PageTables:/ {print $2+0}' "$REPORT_DIR/system/proc-meminfo.txt")
    if (( mem_total_kib > 0 )); then
      mem_available_pct=$(awk -v available="$mem_available_kib" -v total="$mem_total_kib" \
        'BEGIN {printf "%.1f", available * 100 / total}')
    fi
  fi
  [[ -f $REPORT_DIR/performance/process-memory.tsv ]] && \
    process_pss_kib=$(awk -F '\t' 'NR > 1 {total += $4} END {print total+0}' "$REPORT_DIR/performance/process-memory.tsv")

  disk_findings=$(awk -v warn="$SERVER_DOCTOR_WARN_PERCENT" '
    NR > 1 {value=$(NF-1); gsub(/%/, "", value); if (value+0 >= warn) print value "%\t" $NF}
  ' "$REPORT_DIR/storage/filesystems.tsv" 2>/dev/null || true)
  inode_findings=$(awk -v warn="$SERVER_DOCTOR_WARN_PERCENT" '
    NR > 1 {value=$(NF-1); gsub(/%/, "", value); if (value+0 >= warn) print value "%\t" $NF}
  ' "$REPORT_DIR/storage/inodes.tsv" 2>/dev/null || true)
  [[ -f $REPORT_DIR/systemd/failed-units.tsv ]] && \
    failed_units=$(grep -Ec '^[^[:space:]].*[[:space:]]failed[[:space:]]' "$REPORT_DIR/systemd/failed-units.tsv" 2>/dev/null || true)
  [[ -f $REPORT_DIR/logs/journal-error-summary.tsv ]] && \
    journal_errors=$(awk -F '\t' 'NR > 1 {n += $1} END {print n+0}' "$REPORT_DIR/logs/journal-error-summary.tsv")
  [[ -f $REPORT_DIR/logs/kernel-signatures.jsonl ]] && \
    oom_lines=$(grep -Eic 'oom|out of memory' "$REPORT_DIR/logs/kernel-signatures.jsonl" 2>/dev/null || true)
  [[ -f $REPORT_DIR/logs/kernel-signatures.jsonl ]] && \
    disk_error_lines=$(grep -Eic 'I/O error|filesystem error|reset|hung task|blocked for more than' "$REPORT_DIR/logs/kernel-signatures.jsonl" 2>/dev/null || true)
  [[ -f $REPORT_DIR/storage/open-deleted-files.txt ]] && \
    deleted_open=$(awk 'NR > 1 {n++} END {print n+0}' "$REPORT_DIR/storage/open-deleted-files.txt")
  [[ -f $REPORT_DIR/security/reboot-required.txt ]] && reboot_required=$(head -n 1 "$REPORT_DIR/security/reboot-required.txt")
  [[ -f $REPORT_DIR/docker/stopped-containers.tsv ]] && \
    stopped_containers=$(awk 'NR > 1 {n++} END {print n+0}' "$REPORT_DIR/docker/stopped-containers.tsv")
  [[ -f $REPORT_DIR/docker/unreferenced-images.tsv ]] && \
    unreferenced_images=$(awk 'NR > 1 {n++} END {print n+0}' "$REPORT_DIR/docker/unreferenced-images.tsv")
  [[ -f $REPORT_DIR/docker/volume-sizes.tsv ]] && \
    unused_volumes=$(awk -F '\t' 'NR > 1 && $3 == "no" {n++} END {print n+0}' "$REPORT_DIR/docker/volume-sizes.tsv")

  if [[ -f $REPORT_DIR/system/pressure.txt ]]; then
    psi_findings=$(awk '
      /^## / {section=$2; sub("/proc/pressure/", "", section)}
      /avg10=/ {
        for (i=1; i<=NF; i++) if ($i ~ /^avg10=/) {
          split($i, value, "="); if (value[2]+0 >= 10) print section "\t" $0
        }
      }
    ' "$REPORT_DIR/system/pressure.txt")
  fi

  {
    printf '# server-doctor resource summary\n\n'
    printf -- '- Collected: `%s` to `%s`\n' "$STARTED_UTC" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf -- '- Profile / history window / active sample: `%s` / `%s` / `%ss`\n' \
      "$SERVER_DOCTOR_PROFILE" "$SERVER_DOCTOR_SINCE" "$SERVER_DOCTOR_OBSERVE_SECONDS"
    printf -- '- Collector results: `%s` failed, `%s` timed out, `%s` truncated\n\n' \
      "$failed_checks" "$timed_out" "$truncated"

    printf '## Memory diagnosis\n\n'
    printf '| Metric | KiB |\n|---|---:|\n'
    printf '| Total RAM | %s |\n' "$mem_total_kib"
    printf '| Available RAM | %s |\n' "$mem_available_kib"
    printf '| Available RAM | %s%% |\n' "$mem_available_pct"
    printf '| Approx. reclaimable file cache | %s |\n' "$cache_kib"
    printf '| Anonymous pages | %s |\n' "$anon_kib"
    printf '| Sum of process PSS snapshot | %s |\n' "$process_pss_kib"
    printf '| Shared memory / tmpfs | %s |\n' "$shmem_kib"
    printf '| Kernel slab | %s |\n' "$slab_kib"
    printf '| Kernel stacks | %s |\n' "$kernel_stack_kib"
    printf '| Page tables | %s |\n' "$page_tables_kib"
    printf '| Swap used | %s |\n\n' "$((swap_total_kib - swap_free_kib))"
    printf 'Linux may use otherwise free RAM for reclaimable cache. `MemAvailable`, PSI, swap activity, '
    printf 'OOM records, and per-process PSS are therefore more useful than the `free` column alone.\n\n'
    printf '### Largest processes by proportional set size\n\n'
    if [[ -s $REPORT_DIR/performance/process-memory.tsv ]]; then
      printf '```text\n'
      awk -F '\t' 'NR == 1 || NR <= 11' "$REPORT_DIR/performance/process-memory.tsv"
      printf '```\n\n'
    else
      printf 'Process PSS data was unavailable.\n\n'
    fi

    printf '## Signals requiring attention\n\n'
    printf '| Signal | Observed |\n|---|---:|\n'
    printf '| Failed systemd units | %s |\n' "$failed_units"
    printf '| Journal error events | %s |\n' "$journal_errors"
    printf '| Kernel OOM records | %s |\n' "$oom_lines"
    printf '| Kernel storage or hung-task records | %s |\n' "$disk_error_lines"
    printf '| Open deleted file handles | %s |\n' "$deleted_open"
    printf '| Reboot required | %s |\n\n' "$(printf '%s' "$reboot_required" | markdown_escape)"

    printf '### Error categories\n\n'
    if [[ -s $REPORT_DIR/logs/journal-signature-summary.tsv ]]; then
      printf '```text\n'
      head -n 21 "$REPORT_DIR/logs/journal-signature-summary.tsv"
      printf '```\n\n'
    else
      printf 'No categorized journal signatures were collected.\n\n'
    fi

    printf '### Filesystems at or above %s%%\n\n' "$SERVER_DOCTOR_WARN_PERCENT"
    if [[ -n $disk_findings ]]; then
      printf '```text\nusage\tmountpoint\n%s\n```\n\n' "$disk_findings"
    else
      printf 'None detected.\n\n'
    fi
    printf '### Inodes at or above %s%%\n\n' "$SERVER_DOCTOR_WARN_PERCENT"
    if [[ -n $inode_findings ]]; then
      printf '```text\nusage\tmountpoint\n%s\n```\n\n' "$inode_findings"
    else
      printf 'None detected.\n\n'
    fi
    printf '### PSI lines with avg10 at or above 10%%\n\n'
    if [[ -n $psi_findings ]]; then
      printf '```text\nresource\tpressure\n%s\n```\n\n' "$psi_findings"
    else
      printf 'None detected in the current snapshot.\n\n'
    fi

    if [[ -s $REPORT_DIR/docker/containers.jsonl ]] && jq -e -s . "$REPORT_DIR/docker/containers.jsonl" >/dev/null 2>&1; then
      printf '## Docker resource and cleanup analysis\n\n'
      printf '| Signal | Count |\n|---|---:|\n'
      jq -s -r '
        "| Unhealthy containers | \([.[] | select(.state.health == \"unhealthy\")] | length) |",
        "| Containers previously OOM-killed | \([.[] | select(.state.oom_killed == true)] | length) |",
        "| Containers with restarts | \([.[] | select((.restart_count // 0) > 0)] | length) |",
        "| Running containers without memory limit | \([.[] | select(.state.running == true and ((.limits.memory // 0) == 0))] | length) |"
      ' "$REPORT_DIR/docker/containers.jsonl"
      printf '| Stopped container cleanup candidates | %s |\n' "$stopped_containers"
      printf '| Images unreferenced by any container | %s |\n' "$unreferenced_images"
      printf '| Volumes unreferenced by any container | %s |\n\n' "$unused_volumes"

      if [[ -s $REPORT_DIR/docker/disk-usage.jsonl ]]; then
        printf '### Docker aggregate disk accounting\n\n```json\n'
        cat "$REPORT_DIR/docker/disk-usage.jsonl"
        printf '```\n\n'
      fi

      if [[ -s $REPORT_DIR/docker/container-stats.jsonl ]] && jq -e -s . "$REPORT_DIR/docker/container-stats.jsonl" >/dev/null 2>&1; then
        printf '### Containers with highest current memory percentage\n\n```text\n'
        jq -s -r '
          sort_by((.MemPerc // "0%" | rtrimstr("%") | tonumber? // 0)) | reverse | .[:10][] |
          [.Container, .Name, .MemUsage, .MemPerc, .CPUPerc, .BlockIO, .PIDs] | @tsv
        ' "$REPORT_DIR/docker/container-stats.jsonl"
        printf '```\n\n'
      fi

      if [[ -s $REPORT_DIR/docker/volume-sizes.tsv ]]; then
        printf '### Heaviest Docker volumes\n\n```text\n'
        head -n 11 "$REPORT_DIR/docker/volume-sizes.tsv"
        printf '```\n\n'
      fi
      if [[ -s $REPORT_DIR/docker/unreferenced-images.tsv ]]; then
        printf '### Largest unreferenced Docker images\n\n```text\n'
        head -n 11 "$REPORT_DIR/docker/unreferenced-images.tsv"
        printf '```\n\n'
      fi
      if [[ -s $REPORT_DIR/docker/error-summary.tsv ]]; then
        printf '### Docker error categories\n\n```text\n'
        head -n 21 "$REPORT_DIR/docker/error-summary.tsv"
        printf '```\n\n'
      fi
    fi

    printf '## Largest files by allocated space\n\n'
    if [[ -s $REPORT_DIR/storage/largest-files.tsv ]]; then
      printf '```text\n'; cat "$REPORT_DIR/storage/largest-files.tsv"; printf '```\n\n'
    else
      printf 'Not collected by this profile.\n\n'
    fi

    printf '## Incomplete checks\n\n'
    if (( failed_checks + timed_out + truncated > 0 )); then
      printf '```text\n'
      awk -F '\t' 'NR == 1 || $4 ~ /^(failed|timeout|truncated)$/' "$CHECKS_TSV"
      printf '```\n\n'
    else
      printf 'All scheduled checks completed without a recorded failure, timeout, or truncation.\n\n'
    fi

    printf '> This is triage, not automatic remediation. Cleanup reports identify candidates; review dependencies before deleting anything.\n'
  } >"$summary"

  cat >"$bundle_readme" <<EOF
# server-doctor bundle

This privacy-minimized, read-only resource snapshot was collected at
\`$STARTED_UTC\` with profile \`$SERVER_DOCTOR_PROFILE\`.

Start with \`summary.md\`, then inspect \`checks.tsv\` for incomplete
observations. \`privacy-scan.txt\` records the mandatory pre-archive privacy
gate. The bundle intentionally excludes user inventories, user-home paths,
network addresses, listening endpoints, configuration, command arguments,
raw application messages, and raw PCP archives.

Container, volume, service, process executable, device, and non-user file-path
identifiers remain because they are needed to attribute resource usage. Treat
those operational identifiers according to your organization's data policy.
EOF

  chmod 0600 "$summary" "$bundle_readme"
}
