#!/usr/bin/env bash
set -uo pipefail

source "$SERVER_DOCTOR_ROOT/lib/common.sh"

run_capture "operating system" system/os-release.txt "$SERVER_DOCTOR_COMMAND_TIMEOUT" cat /etc/os-release
run_capture "kernel" system/kernel.txt "$SERVER_DOCTOR_COMMAND_TIMEOUT" uname -srvmo
run_capture "virtualization" system/virtualization.txt "$SERVER_DOCTOR_COMMAND_TIMEOUT" bash -c '
  printf "vm: "
  systemd-detect-virt --vm || echo none
  printf "container: "
  systemd-detect-virt --container || echo none
'
run_capture "uptime" system/uptime.txt "$SERVER_DOCTOR_COMMAND_TIMEOUT" uptime
run_capture "boot history" system/boot-history.txt "$SERVER_DOCTOR_COMMAND_TIMEOUT" last -x -n 30 reboot shutdown
run_capture "time status" system/time-status.txt "$SERVER_DOCTOR_COMMAND_TIMEOUT" timedatectl status
run_capture "CPU inventory" system/lscpu.json "$SERVER_DOCTOR_COMMAND_TIMEOUT" lscpu --json
run_capture "memory summary" system/memory.txt "$SERVER_DOCTOR_COMMAND_TIMEOUT" free -h -w
run_capture "proc meminfo" system/proc-meminfo.txt "$SERVER_DOCTOR_COMMAND_TIMEOUT" cat /proc/meminfo
run_capture "proc vmstat" system/proc-vmstat.txt "$SERVER_DOCTOR_COMMAND_TIMEOUT" cat /proc/vmstat
run_capture "pressure stall information" system/pressure.txt "$SERVER_DOCTOR_COMMAND_TIMEOUT" bash -c '
  for file in /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io; do
    [[ -r $file ]] || continue
    printf "\n## %s\n" "$file"
    cat "$file"
  done
'
run_capture "tool versions" system/tool-versions.txt "$SERVER_DOCTOR_COMMAND_TIMEOUT" bash -c '
  printf "server-doctor\t%s\n" "$1"
  for command in bash make systemctl docker sar iostat pidstat jq zip smartctl; do
    command -v "$command" >/dev/null 2>&1 || continue
    printf "\n[%s]\n" "$command"
    "$command" --version 2>&1 | head -n 3 || true
  done
' _ "${SERVER_DOCTOR_VERSION:-unknown}"
run_capture "diagnostic package versions" system/package-versions.tsv "$SERVER_DOCTOR_COMMAND_TIMEOUT" bash -c '
  printf "package\tversion\n"
  dpkg-query -W -f="\${Package}\t\${Version}\n" \
    bash coreutils util-linux wtmpdb procps findutils gawk grep sed zip unzip jq lsof \
    sysstat pcp smartmontools \
    docker.io docker-ce docker-ce-cli 2>/dev/null || true
'
