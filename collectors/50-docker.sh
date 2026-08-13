#!/usr/bin/env bash
set -uo pipefail

source "$SERVER_DOCTOR_ROOT/lib/common.sh"

if (( CAP_DOCKER == 0 )); then
  write_not_applicable docker "Docker was not detected on this server."
  exit 0
fi

run_capture "Docker resource summary" docker/info.json "$SERVER_DOCTOR_COMMAND_TIMEOUT" bash -c '
  docker info --format "{{json .}}" | jq "{
    server_version: .ServerVersion,
    storage_driver: .Driver,
    cgroup_driver: .CgroupDriver,
    cgroup_version: .CgroupVersion,
    cpus: .NCPU,
    memory_bytes: .MemTotal,
    containers: {total: .Containers, running: .ContainersRunning, paused: .ContainersPaused, stopped: .ContainersStopped},
    images: .Images
  }"
'
run_capture "Docker containers" docker/containers.tsv "$SERVER_DOCTOR_COMMAND_TIMEOUT" \
  docker ps -a --no-trunc --size --format 'table {{.ID}}\t{{.Names}}\t{{.State}}\t{{.Status}}\t{{.RunningFor}}\t{{.Size}}'
run_capture "Docker container stats" docker/container-stats.jsonl "$SERVER_DOCTOR_COMMAND_TIMEOUT" \
  docker stats -a --no-stream --no-trunc --format '{{ json . }}'
run_capture "Docker images by size" docker/images.tsv "$SERVER_DOCTOR_COMMAND_TIMEOUT" bash -c '
  printf "id\tcreated\tbytes\n"
  mapfile -t ids < <(docker image ls -aq --no-trunc | sort -u)
  ((${#ids[@]})) || exit 0
  docker image inspect "${ids[@]}" |
    jq -r ".[] | [.Id, .Created, (.Size // 0)] | @tsv" | sort -rn -k3,3
'
run_capture "Docker volumes" docker/volumes.tsv "$SERVER_DOCTOR_COMMAND_TIMEOUT" \
  docker volume ls --format 'table {{.Name}}\t{{.Driver}}\t{{.Scope}}'
run_capture "Docker aggregate disk usage" docker/disk-usage.jsonl "$SERVER_DOCTOR_DISK_SCAN_TIMEOUT" \
  docker system df --format '{{json .}}'

run_capture "Docker container resource state" docker/containers.jsonl "$SERVER_DOCTOR_COMMAND_TIMEOUT" bash -c '
  mapfile -t ids < <(docker ps -aq --no-trunc)
  ((${#ids[@]})) || exit 0
  docker inspect "${ids[@]}" | jq -c "
    .[] | {
      id: .Id,
      name: (.Name | ltrimstr(\"/\")),
      image_id: .Image,
      created: .Created,
      state: {
        status: .State.Status, running: .State.Running, paused: .State.Paused,
        restarting: .State.Restarting, oom_killed: .State.OOMKilled,
        dead: .State.Dead, pid: .State.Pid, exit_code: .State.ExitCode,
        error_present: ((.State.Error // \"\") != \"\"),
        started_at: .State.StartedAt, finished_at: .State.FinishedAt,
        health: (.State.Health.Status // null),
        recent_health_checks: ((.State.Health.Log // []) | .[-5:] | map({
          start: .Start, end: .End, exit_code: .ExitCode
        }))
      },
      restart_count: .RestartCount,
      limits: {
        memory: .HostConfig.Memory,
        memory_reservation: .HostConfig.MemoryReservation,
        memory_swap: .HostConfig.MemorySwap,
        nano_cpus: .HostConfig.NanoCpus,
        cpu_quota: .HostConfig.CpuQuota,
        cpu_period: .HostConfig.CpuPeriod,
        cpuset_cpus: .HostConfig.CpusetCpus,
        pids_limit: .HostConfig.PidsLimit
      },
      volumes: [.Mounts[]? | select(.Type == \"volume\") |
        {name: .Name, destination: .Destination, rw: .RW}]
    }
  "
'

run_capture "Docker image resource state" docker/images.jsonl "$SERVER_DOCTOR_COMMAND_TIMEOUT" bash -c '
  mapfile -t ids < <(docker image ls -aq --no-trunc | sort -u)
  ((${#ids[@]})) || exit 0
  docker image inspect "${ids[@]}" | jq -c "
    .[] | {id: .Id, parent: .Parent, created: .Created,
      architecture: .Architecture, os: .Os, size: .Size}
  "
'

run_capture "Docker volume resource state" docker/volumes.jsonl "$SERVER_DOCTOR_COMMAND_TIMEOUT" bash -c '
  mapfile -t names < <(docker volume ls -q)
  ((${#names[@]})) || exit 0
  docker volume inspect "${names[@]}" | jq -c "
    .[] | {name: .Name, driver: .Driver, created_at: .CreatedAt, scope: .Scope}
  "
'

run_capture "Docker log file sizes" docker/log-sizes.tsv "$SERVER_DOCTOR_COMMAND_TIMEOUT" bash -c '
  printf "bytes\tcontainer_id\tcontainer\n"
  mapfile -t ids < <(docker ps -aq --no-trunc)
  ((${#ids[@]})) || exit 0
  docker inspect "${ids[@]}" | jq -r "
    .[] | [.Id, (.Name | ltrimstr(\"/\")), .LogPath] | @tsv
  " | while IFS=$'"'"'\t'"'"' read -r id name path; do
    [[ -n $path && -e $path ]] || continue
    printf "%s\t%s\t%s\n" "$(stat -c %s "$path")" "$id" "$name"
  done | sort -rn -k1,1
'

run_capture "Docker lifecycle events" docker/events.jsonl "$SERVER_DOCTOR_COMMAND_TIMEOUT" bash -c '
  set -o pipefail
  docker events --since "$1" --until "$2" --filter type=container \
    --filter event=die --filter event=restart --filter event=oom \
    --filter event=health_status --format "{{json .}}" |
  jq -c "{time: .Time, time_nano: .TimeNano, type: .Type, action: .Action,
    actor: {id: .Actor.ID, name: .Actor.Attributes.name,
      exit_code: .Actor.Attributes.exitCode}}"
' _ "$SERVER_DOCTOR_SINCE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Read logs locally, but export only fixed categories and counts. No message
# text, address, port, user identity, or application payload enters the bundle.
run_capture "Docker error categories" docker/error-summary.tsv "$SERVER_DOCTOR_COMMAND_TIMEOUT" bash -c '
  printf "count\tcontainer_id\tcontainer\tcategory\n"
  while IFS=$'"'"'\t'"'"' read -r id name; do
    [[ -n $id ]] || continue
    docker logs --since "$1" "$id" 2>&1 | awk -v id="$id" -v name="$name" "
      BEGIN {IGNORECASE=1}
      /out of memory|oom/ {counts[\"out_of_memory\"]++; next}
      /segfault|segmentation fault/ {counts[\"segmentation_fault\"]++; next}
      /panic/ {counts[\"panic\"]++; next}
      /fatal/ {counts[\"fatal\"]++; next}
      /exception/ {counts[\"exception\"]++; next}
      /timeout|timed out/ {counts[\"timeout\"]++; next}
      /connection refused|connection reset/ {counts[\"connection_failure\"]++; next}
      /permission denied|access denied/ {counts[\"permission_failure\"]++; next}
      /error|failed|failure/ {counts[\"error_other\"]++; next}
      END {for (category in counts) print counts[category] \"\\t\" id \"\\t\" name \"\\t\" category}
    "
  done < <(docker ps -a --no-trunc --format "{{.ID}}\t{{.Names}}")
' _ "$SERVER_DOCTOR_SINCE"

run_capture "stopped Docker cleanup candidates" docker/stopped-containers.tsv "$SERVER_DOCTOR_COMMAND_TIMEOUT" bash -c '
  printf "id\tname\tstate\tstatus\tcreated\tsize\n"
  docker ps -a --no-trunc --size --filter status=created --filter status=exited \
    --filter status=dead --format "{{.ID}}\t{{.Names}}\t{{.State}}\t{{.Status}}\t{{.CreatedAt}}\t{{.Size}}"
'

run_capture "unreferenced Docker images" docker/unreferenced-images.tsv "$SERVER_DOCTOR_COMMAND_TIMEOUT" bash -c '
  printf "id\tcreated\tbytes\n"
  all=$(mktemp); used=$(mktemp)
  trap "rm -f -- $all $used" EXIT
  docker image ls -aq --no-trunc | sort -u >"$all"
  mapfile -t containers < <(docker ps -aq --no-trunc)
  if ((${#containers[@]})); then
    docker inspect "${containers[@]}" | jq -r ".[].Image" | sort -u >"$used"
  else
    : >"$used"
  fi
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    docker image inspect "$id" | jq -r ".[] | [.Id, .Created, (.Size // 0)] | @tsv"
  done < <(comm -23 "$all" "$used") | sort -rn -k3,3
'

if [[ $SERVER_DOCTOR_PROFILE == quick ]]; then
  write_not_applicable docker/volume-size-scan "The quick profile skips per-volume traversal. Use PROFILE=standard or deep."
else
  run_capture "Docker volume sizes and usage" docker/volume-sizes.tsv "$SERVER_DOCTOR_DISK_SCAN_TIMEOUT" bash -c '
    printf "bytes\tvolume\tin_use\n"
    declare -A dangling=()
    while IFS= read -r name; do [[ -n $name ]] && dangling["$name"]=1; done < <(docker volume ls -qf dangling=true)
    mapfile -t names < <(docker volume ls -q)
    ((${#names[@]})) || exit 0
    docker volume inspect "${names[@]}" | jq -r ".[] | [.Name, .Mountpoint] | @tsv" |
      while IFS=$'"'"'\t'"'"' read -r name path; do
        [[ -d $path ]] || continue
        bytes=$(ionice -c3 nice -n 19 du -x -s -B1 "$path" 2>/dev/null | awk "{print \$1}")
        if [[ ${dangling[$name]+yes} ]]; then in_use=no; else in_use=yes; fi
        printf "%s\t%s\t%s\n" "${bytes:-0}" "$name" "$in_use"
      done | sort -rn -k1,1
  '
fi
