#!/usr/bin/env bash
set -uo pipefail

source "$SERVER_DOCTOR_ROOT/lib/common.sh"

# Only patch/reboot/CPU-mitigation state is retained. Account inventories,
# firewall, SSH policy, sysctl values, and other configuration are out of scope.
run_capture "available package updates" security/apt-upgradable.txt "$SERVER_DOCTOR_COMMAND_TIMEOUT" bash -c '
  apt list --upgradable 2>/dev/null || true
'
run_capture "reboot required" security/reboot-required.txt "$SERVER_DOCTOR_COMMAND_TIMEOUT" bash -c '
  if [[ -e /var/run/reboot-required ]]; then
    echo yes
    [[ -r /var/run/reboot-required.pkgs ]] && cat /var/run/reboot-required.pkgs
  else
    echo no
  fi
'
run_capture "CPU vulnerability mitigations" security/cpu-vulnerabilities.txt "$SERVER_DOCTOR_COMMAND_TIMEOUT" bash -c '
  lscpu | grep -Ei "^Vulnerability" || true
  for file in /sys/devices/system/cpu/vulnerabilities/*; do
    [[ -r $file ]] || continue
    printf "%s: " "${file##*/}"
    cat "$file"
  done
'
