#!/usr/bin/env bash
set -uo pipefail

source "$SERVER_DOCTOR_ROOT/lib/common.sh"

run_capture "filesystem capacity" storage/filesystems.tsv "$SERVER_DOCTOR_COMMAND_TIMEOUT" \
  df -l -B1 --output=fstype,size,used,avail,pcent,target
run_capture "filesystem inodes" storage/inodes.tsv "$SERVER_DOCTOR_COMMAND_TIMEOUT" \
  df -li --output=itotal,iused,iavail,ipcent,target
run_capture "block devices" storage/lsblk.json "$SERVER_DOCTOR_COMMAND_TIMEOUT" \
  lsblk --json --bytes -o NAME,KNAME,PATH,TYPE,SIZE,FSTYPE,FSVER,MOUNTPOINTS,FSAVAIL,FSUSE%,RO,RM,ROTA,MODEL,TRAN
run_capture "mount topology" storage/findmnt.json "$SERVER_DOCTOR_COMMAND_TIMEOUT" \
  findmnt --json --bytes -t ext2,ext3,ext4,xfs,btrfs,zfs,f2fs,reiserfs,jfs \
    -o TARGET,FSTYPE,SIZE,USED,AVAIL,USE%
run_capture "open deleted files" storage/open-deleted-files.txt "$SERVER_DOCTOR_COMMAND_TIMEOUT" bash -c '
  printf "command\tpid\tfd\ttype\tsize_or_offset\tlinks\tpath\n"
  lsof -nP +L1 2>/dev/null | awk "
    NR == 1 {next}
    {
      path=\"\"; for (i=10; i<=NF; i++) path=path (path ? OFS : \"\") \$i
      printf \"%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n\", \$1, \$2, \$4, \$5, \$7, \$8, path
    }
  "
  status=${PIPESTATUS[0]}
  ((status == 0 || status == 1))
'
run_capture "journal disk usage" storage/journal-disk-usage.txt "$SERVER_DOCTOR_COMMAND_TIMEOUT" journalctl --disk-usage

if [[ $SERVER_DOCTOR_PROFILE == quick ]]; then
  write_not_applicable storage/full-scan "The quick profile intentionally skips whole-filesystem scans. Use PROFILE=standard or deep."
else
  run_capture "largest files by allocated blocks" storage/largest-files.tsv "$SERVER_DOCTOR_DISK_SCAN_TIMEOUT" bash -c '
    printf "allocated_bytes\tlogical_bytes\tpath\n"
    findmnt -rn -o TARGET,FSTYPE | awk '\''
      $2 ~ /^(ext2|ext3|ext4|xfs|btrfs|zfs|f2fs|reiserfs|jfs)$/ {print $1}
    '\'' | sort -u | while IFS= read -r mountpoint; do
      ionice -c3 nice -n 19 find "$mountpoint" -xdev -type f -printf "%b\t%s\t%p\n" 2>/dev/null || true
    done | awk -F "\t" '\''{allocated=$1*512; $1=allocated; print}'\'' OFS="\t" | sort -rn -k1,1 | head -n 10
  '
  run_capture "largest local directories" storage/largest-directories.tsv "$SERVER_DOCTOR_DISK_SCAN_TIMEOUT" bash -c '
    printf "bytes\tpath\n"
    findmnt -rn -o TARGET,FSTYPE | awk '\''
      $2 ~ /^(ext2|ext3|ext4|xfs|btrfs|zfs|f2fs|reiserfs|jfs)$/ {print $1}
    '\'' | sort -u | while IFS= read -r mountpoint; do
      ionice -c3 nice -n 19 du -x -B1 --max-depth=2 "$mountpoint" 2>/dev/null || true
    done | sort -rn -k1,1 | head -n 100
  '
fi

if [[ $SERVER_DOCTOR_PROFILE == deep ]]; then
  run_capture "SMART health and attributes" storage/smart.txt "$SERVER_DOCTOR_DISK_SCAN_TIMEOUT" bash -c '
    smartctl --scan-open | while read -r device rest; do
      [[ -n $device ]] || continue
      printf "\n## %s\n" "$device"
      smartctl -H -A "$device" 2>&1 |
        sed -E "/Serial Number|LU WWN|Logical Unit id|Device Model|Model Number/d" || true
    done
  '
else
  write_not_applicable storage/smart "SMART is collected only by PROFILE=deep."
fi
