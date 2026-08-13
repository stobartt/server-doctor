#!/usr/bin/env bash

declare -a PREFLIGHT_ERRORS=()
declare -a PREFLIGHT_WARNINGS=()
declare -a MISSING_PACKAGES=()
declare -a MISSING_COMMANDS=()

add_error() { PREFLIGHT_ERRORS+=("$*"); }
add_warning() { PREFLIGHT_WARNINGS+=("$*"); }

add_package_once() {
  local package=$1
  local item
  for item in "${MISSING_PACKAGES[@]:-}"; do
    [[ $item == "$package" ]] && return
  done
  MISSING_PACKAGES+=("$package")
}

require_command() {
  local command=$1
  local package=$2
  if ! command -v "$command" >/dev/null 2>&1; then
    MISSING_COMMANDS+=("$command")
    add_package_once "$package"
  fi
}

has_sysstat_archive() {
  local directory
  for directory in /var/log/sysstat /var/log/sa; do
    [[ -d $directory ]] || continue
    if find "$directory" -type f -name 'sa[0-9]*' -size +0c -print -quit 2>/dev/null | grep -q .; then
      return 0
    fi
  done
  return 1
}

has_recent_sysstat_archive() {
  local directory
  for directory in /var/log/sysstat /var/log/sa; do
    [[ -d $directory ]] || continue
    if find "$directory" -type f -name 'sa[0-9]*' -size +0c -mmin -30 -print -quit 2>/dev/null | grep -q .; then
      return 0
    fi
  done
  return 1
}

detect_capabilities() {
  CAP_SYSTEMD=0
  CAP_DOCKER=0
  CAP_PCP=0
  CAP_SYSSTAT=0
  CAP_SYSSTAT_HISTORY=0
  CAP_SYSSTAT_HISTORY_RECENT=0

  [[ -d /run/systemd/system ]] && CAP_SYSTEMD=1
  if command -v docker >/dev/null 2>&1 || [[ -S /run/docker.sock || -d /var/lib/docker ]]; then CAP_DOCKER=1; fi
  if command -v pcp >/dev/null 2>&1 || [[ -d /var/log/pcp/pmlogger ]]; then CAP_PCP=1; fi
  if command -v iostat >/dev/null 2>&1 && command -v pidstat >/dev/null 2>&1 && command -v sar >/dev/null 2>&1; then
    CAP_SYSSTAT=1
  fi
  if (( CAP_SYSSTAT )); then
    has_sysstat_archive && CAP_SYSSTAT_HISTORY=1
    has_recent_sysstat_archive && CAP_SYSSTAT_HISTORY_RECENT=1
  fi

  export CAP_SYSTEMD CAP_DOCKER CAP_PCP CAP_SYSSTAT CAP_SYSSTAT_HISTORY CAP_SYSSTAT_HISTORY_RECENT
}

check_required_commands() {
  local last_package=util-linux
  local os_id os_version os_version_major os_version_minor
  os_id=$(awk -F= '$1 == "ID" {gsub(/"/, "", $2); print $2}' /etc/os-release 2>/dev/null || true)
  os_version=$(awk -F= '$1 == "VERSION_ID" {gsub(/"/, "", $2); print $2}' /etc/os-release 2>/dev/null || true)
  os_version_major=${os_version%%.*}
  os_version_minor=${os_version#*.}
  [[ $os_version_minor == "$os_version" ]] && os_version_minor=0
  if [[ $os_id == debian && $os_version_major =~ ^[0-9]+$ ]] && (( os_version_major >= 13 )); then
    last_package=wtmpdb
  elif [[ $os_id == ubuntu && $os_version_major =~ ^[0-9]+$ && $os_version_minor =~ ^[0-9]+$ ]] && \
    { (( os_version_major > 24 )) || (( os_version_major == 24 && os_version_minor >= 10 )); }; then
    last_package=wtmpdb
  fi
  local base_pairs=(
    "bash:bash" "make:make" "awk:gawk" "sed:sed" "grep:grep" "find:findutils"
    "uname:coreutils" "lscpu:util-linux" "uptime:procps"
    "sort:coreutils" "head:coreutils" "cut:coreutils" "tr:coreutils" "date:coreutils" "comm:coreutils" "uniq:coreutils"
    "cat:coreutils" "wc:coreutils" "tee:coreutils" "mkdir:coreutils" "mv:coreutils" "chmod:coreutils" "nice:coreutils"
    "rm:coreutils" "chown:coreutils" "sha256sum:coreutils" "stat:coreutils" "mktemp:coreutils"
    "du:coreutils" "df:coreutils" "timeout:coreutils" "xargs:findutils"
    "ps:procps" "free:procps" "vmstat:procps"
    "flock:util-linux" "ionice:util-linux" "lsblk:util-linux" "findmnt:util-linux"
    "zip:zip" "unzip:unzip" "jq:jq" "lsof:lsof"
    "zgrep:gzip" "dpkg-query:dpkg" "apt:apt"
  )
  local pair
  for pair in "${base_pairs[@]}"; do require_command "${pair%%:*}" "${pair#*:}"; done
  require_command last "$last_package"

  if (( CAP_SYSTEMD )); then
    require_command systemctl systemd
    require_command journalctl systemd
    require_command systemd-cgtop systemd
    require_command systemd-detect-virt systemd
    require_command timedatectl systemd
  fi

  if [[ $SERVER_DOCTOR_PROFILE != quick ]]; then
    require_command pmlogsummary pcp
    require_command pminfo pcp
  fi

  if (( CAP_DOCKER )); then require_command docker docker.io; fi
  if [[ $SERVER_DOCTOR_PROFILE == deep ]]; then require_command smartctl smartmontools; fi
  if [[ -n $SERVER_DOCTOR_ENCRYPT_TO ]]; then require_command age age; fi
}

check_sysstat_history() {
  if (( CAP_SYSSTAT == 0 )); then
    if [[ $SERVER_DOCTOR_PROFILE == quick ]]; then
      add_warning "sysstat is not installed; quick will use current process, vmstat, and cgroup observations without retrospective performance history"
    else
      add_warning "sysstat is not installed; PCP provides retrospective data and built-in samplers remain available"
    fi
  elif (( CAP_SYSSTAT_HISTORY == 0 )); then
    if [[ $SERVER_DOCTOR_PROFILE == quick ]]; then
      add_warning "sysstat has no readable archive; quick will use sysstat only for the active sample"
    else
      add_warning "sysstat has no readable archive; PCP will provide retrospective data and sysstat will be used only for the active sample"
    fi
  elif (( CAP_SYSSTAT_HISTORY_RECENT == 0 )); then
    if [[ $SERVER_DOCTOR_PROFILE == quick ]]; then
      add_warning "sysstat archive is stale; quick has no guaranteed current retrospective performance history"
    else
      add_warning "sysstat archive is stale; PCP will provide current retrospective data"
    fi
  fi
}

check_services_and_history() {
  if (( CAP_SYSTEMD == 0 )); then
    add_error "systemd is not PID 1; version 1 supports Debian/Ubuntu servers with systemd only"
    return
  fi

  if [[ $SERVER_DOCTOR_PROFILE != quick ]]; then
    if (( CAP_PCP == 0 )); then
      add_error "PCP is required by the ${SERVER_DOCTOR_PROFILE} profile for retrospective performance data"
    else
      systemctl is-active --quiet pmcd 2>/dev/null || add_error "PCP service pmcd is not active"
      systemctl is-active --quiet pmlogger 2>/dev/null || add_error "PCP service pmlogger is not active"
      if ! find /var/log/pcp/pmlogger -type f -name '*.meta' -print -quit 2>/dev/null | grep -q .; then
        add_error "PCP has no readable pmlogger archive yet; enable it, wait for samples, then rerun"
      elif ! find /var/log/pcp/pmlogger -type f -mmin -30 -print -quit 2>/dev/null | grep -q .; then
        add_error "PCP archive is stale (no file updated in 30 minutes); repair collection, then rerun"
      fi
    fi
  fi

  check_sysstat_history
}

check_runtime_access() {
  local mode=$1
  if [[ $mode == audit && $EUID -ne 0 ]]; then
    add_error "a complete audit requires root; run sudo ~/server-doctor audit ..."
  elif [[ $mode == doctor && $EUID -ne 0 ]]; then
    add_warning "run the final audit via sudo so journals, cgroups, Docker and storage metadata are complete"
  fi

  if (( CAP_DOCKER )) && command -v docker >/dev/null 2>&1; then
    if ! docker info >/dev/null 2>&1; then
      if [[ $mode == audit ]]; then
        add_error "Docker was detected but the daemon is unavailable to this user"
      else
        add_warning "Docker was detected but is not accessible now; sudo audit will check it again"
      fi
    fi
  fi
}

print_preflight() {
  local mode=$1
  printf 'server-doctor preflight\n'
  printf '  profile: %s\n  since: %s\n' "$SERVER_DOCTOR_PROFILE" "$SERVER_DOCTOR_SINCE"
  printf '  capabilities: systemd=%s docker=%s pcp=%s sysstat=%s sysstat_history=%s\n' \
    "$CAP_SYSTEMD" "$CAP_DOCKER" "$CAP_PCP" "$CAP_SYSSTAT" "$CAP_SYSSTAT_HISTORY"

  local item
  for item in "${PREFLIGHT_WARNINGS[@]:-}"; do [[ -n $item ]] && printf 'WARNING: %s\n' "$item"; done
  for item in "${PREFLIGHT_ERRORS[@]:-}"; do [[ -n $item ]] && printf 'ERROR: %s\n' "$item"; done

  if ((${#MISSING_COMMANDS[@]})); then
    printf 'ERROR: missing commands: %s\n' "${MISSING_COMMANDS[*]}"
  fi
  if ((${#MISSING_PACKAGES[@]})); then
    printf '\nInstall the missing Debian/Ubuntu packages, then rerun:\n'
    printf '  sudo apt-get update\n  sudo apt-get install --yes'
    printf ' %q' "${MISSING_PACKAGES[@]}"
    printf '\n'
  fi

  if [[ $SERVER_DOCTOR_PROFILE != quick ]] && { (( CAP_PCP == 0 )) || ! systemctl is-active --quiet pmlogger 2>/dev/null || ! find /var/log/pcp/pmlogger -type f -mmin -30 -print -quit 2>/dev/null | grep -q .; }; then
    printf '\nEnable historical PCP collection after installing packages:\n'
    printf '  sudo systemctl enable --now pmcd pmlogger\n'
  fi
  if ((${#PREFLIGHT_ERRORS[@]} || ${#MISSING_COMMANDS[@]})); then
    printf '\nPreflight failed. No audit data was collected.\n'
    return 1
  fi
  printf '\nPreflight passed%s.\n' "$([[ $mode == doctor ]] && printf '; audit may be started' || true)"
}

run_preflight() {
  local mode=$1
  PREFLIGHT_ERRORS=()
  PREFLIGHT_WARNINGS=()
  MISSING_PACKAGES=()
  MISSING_COMMANDS=()

  if [[ $(uname -s 2>/dev/null || true) != Linux ]]; then
    add_error "version 1 supports Linux only"
  elif [[ ! -r /etc/debian_version ]]; then
    add_error "version 1 supports Debian and Ubuntu package layouts only"
  fi
  if (( BASH_VERSINFO[0] < 4 )); then
    add_error "Bash 4 or newer is required (found ${BASH_VERSION})"
  fi

  detect_capabilities
  check_required_commands
  check_services_and_history
  check_runtime_access "$mode"
  print_preflight "$mode"
}
