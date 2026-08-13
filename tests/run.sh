#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$ROOT"

source "$ROOT/config/defaults.conf"
SERVER_DOCTOR_ROOT=$ROOT
export SERVER_DOCTOR_ROOT
source "$ROOT/lib/common.sh"
source "$ROOT/lib/preflight.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected=$1 actual=$2 message=$3
  [[ $expected == "$actual" ]] || fail "$message: expected '$expected', got '$actual'"
}

assert_eq "30" "$(since_to_minutes 30m)" "minutes conversion"
assert_eq "1440" "$(since_to_minutes 24h)" "hours conversion"
assert_eq "2880" "$(since_to_minutes 2d)" "days conversion"
assert_eq "10080" "$(since_to_minutes 1w)" "weeks conversion"
assert_eq "24 hours" "$(since_to_words 24h)" "PCP/journal duration conversion"
assert_eq "unsafe_name_here" "$(safe_name 'unsafe name/here')" "safe filename"

secret_input='postgres://alice:s3cret@db.internal/app
Authorization: Bearer abcdefghijklmnopqrstuvwxyz
Cookie: session=super-secret
password="hunter2"
api_key=abcdef123456
AKIA1234567890ABCDEF
ghp_1234567890abcdefghijklmnop
eyJabcdefghijk.abcdefghijklmnop.abcdefghijklmnop
source 10.20.30.40:5432
listening on 8080
email alice@example.org
path /home/alice/private/file'
redacted=$(printf '%s\n' "$secret_input" | redact_stream)
for secret in s3cret abcdefghijklmnopqrstuvwxyz super-secret hunter2 abcdef123456 AKIA1234567890ABCDEF ghp_1234567890abcdefghijklmnop eyJabcdefghijk 10.20.30.40 5432 8080 alice@example.org /home/alice; do
  [[ $redacted != *"$secret"* ]] || fail "redactor leaked $secret"
done
[[ $redacted == *"[REDACTED]"* ]] || fail "redactor produced no marker"
[[ $redacted == *"[REDACTED_JWT]"* ]] || fail "JWT redaction marker missing"
[[ $redacted == *"[REDACTED_IP]"* ]] || fail "IP redaction marker missing"
[[ $redacted == *"[REDACTED_PORT]"* ]] || fail "port redaction marker missing"
[[ $redacted == *"[REDACTED_HOME]"* ]] || fail "home path redaction marker missing"
if command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"path":"/home/alice/private","ip":"10.20.30.40","unit":"user@1000.service"}' |
    redact_stream | jq -e . >/dev/null || fail "redaction broke JSON syntax"
fi

MISSING_PACKAGES=()
add_package_once jq
add_package_once jq
assert_eq "1" "${#MISSING_PACKAGES[@]}" "package de-duplication"

PREFLIGHT_ERRORS=()
PREFLIGHT_WARNINGS=()
CAP_SYSSTAT=0
CAP_SYSSTAT_HISTORY=0
CAP_SYSSTAT_HISTORY_RECENT=0
check_sysstat_history
assert_eq "0" "${#PREFLIGHT_ERRORS[@]}" "missing sysstat must not block preflight"
assert_eq "1" "${#PREFLIGHT_WARNINGS[@]}" "missing sysstat warning"

"$ROOT/bin/server-doctor" help >/dev/null
if "$ROOT/bin/server-doctor" doctor --profile invalid >/dev/null 2>&1; then
  fail "invalid profile unexpectedly passed"
fi
if "$ROOT/bin/server-doctor" doctor --since yesterday >/dev/null 2>&1; then
  fail "invalid duration unexpectedly passed"
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/server-doctor-test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

INSTALL_TEST_HOME="$TMP_ROOT/home"
INSTALL_TEST_LAUNCHER="$INSTALL_TEST_HOME/server-doctor"
mkdir -p "$INSTALL_TEST_HOME"
HOME="$INSTALL_TEST_HOME" "$ROOT/bin/install-user" >/dev/null
[[ -L $INSTALL_TEST_LAUNCHER ]] || fail "user launcher symlink was not created"
assert_eq "0.2.1" "$("$INSTALL_TEST_LAUNCHER" version)" "installed launcher version"
first_release=$(readlink "$INSTALL_TEST_LAUNCHER")
HOME="$INSTALL_TEST_HOME" "$ROOT/bin/install-user" >/dev/null
second_release=$(readlink "$INSTALL_TEST_LAUNCHER")
[[ $first_release != "$second_release" ]] || fail "reinstall did not create a clean release"
[[ -x $first_release && -x $second_release ]] || fail "versioned install releases are missing"

INSTALL_CONFLICT_HOME="$TMP_ROOT/conflict-home"
INSTALL_CONFLICT="$INSTALL_CONFLICT_HOME/server-doctor"
mkdir -p "$INSTALL_CONFLICT_HOME"
printf 'preserve me\n' >"$INSTALL_CONFLICT"
if HOME="$INSTALL_CONFLICT_HOME" "$ROOT/bin/install-user" >/dev/null 2>&1; then
  fail "installer overwrote a non-symlink launcher"
fi
grep -q 'preserve me' "$INSTALL_CONFLICT" || fail "installer changed conflicting launcher"

REPORT_DIR="$TMP_ROOT/report"
mkdir -p "$REPORT_DIR/storage" "$REPORT_DIR/systemd" "$REPORT_DIR/logs" "$REPORT_DIR/security"
CHECKS_TSV="$REPORT_DIR/checks.tsv"
STARTED_UTC=2026-08-13T00:00:00Z
SERVER_DOCTOR_PROFILE=standard
SERVER_DOCTOR_SINCE=24h
SERVER_DOCTOR_OBSERVE_SECONDS=60
SERVER_DOCTOR_WARN_PERCENT=80
export REPORT_DIR CHECKS_TSV STARTED_UTC SERVER_DOCTOR_PROFILE SERVER_DOCTOR_SINCE
export SERVER_DOCTOR_OBSERVE_SECONDS SERVER_DOCTOR_WARN_PERCENT

printf 'started_utc\tduration_seconds\texit_code\tstatus\tbytes\tcheck\tfile\n' >"$CHECKS_TSV"
printf '2026-08-13T00:00:00Z\t1\t0\tok\t10\ttest\ttest.txt\n' >>"$CHECKS_TSV"
printf 'Filesystem Type 1B-blocks Used Available Capacity Mounted on\n/dev/sda ext4 100 85 15 85%% /\n' >"$REPORT_DIR/storage/filesystems.tsv"
printf 'Filesystem Inodes IUsed IFree IUse%% Mounted on\n/dev/sda 100 10 90 10%% /\n' >"$REPORT_DIR/storage/inodes.tsv"
printf 'UNIT LOAD ACTIVE SUB DESCRIPTION\n' >"$REPORT_DIR/systemd/failed-units.tsv"
printf 'no\n' >"$REPORT_DIR/security/reboot-required.txt"
printf 'count\tpriority\tunit\tidentifier\tcategory\n' >"$REPORT_DIR/logs/journal-error-summary.tsv"
: >"$REPORT_DIR/logs/kernel-signatures.jsonl"
: >"$REPORT_DIR/storage/open-deleted-files.txt"

source "$ROOT/lib/summary.sh"
generate_summary
[[ -s $REPORT_DIR/summary.md ]] || fail "summary was not generated"
grep -q '85%' "$REPORT_DIR/summary.md" || fail "disk threshold missing from summary"
grep -q 'All scheduled checks completed' "$REPORT_DIR/summary.md" || fail "completion statement missing"
[[ -s $REPORT_DIR/README.md ]] || fail "bundle README was not generated"

source "$ROOT/lib/privacy.sh"
privacy_scan_report
[[ -s $REPORT_DIR/privacy-scan.txt ]] || fail "privacy scan result was not generated"
printf 'unexpected 192.168.10.20\n' >"$REPORT_DIR/leak.txt"
if privacy_scan_report >/dev/null 2>&1; then
  fail "privacy scan accepted an IP address"
fi
[[ ! -e $REPORT_DIR/privacy-scan.txt ]] || fail "stale privacy pass remained after failure"
rm -f -- "$REPORT_DIR/leak.txt"
printf 'root\n' >"$REPORT_DIR/leak-user.txt"
if privacy_scan_report >/dev/null 2>&1; then
  fail "privacy scan accepted a local account name"
fi
rm -f -- "$REPORT_DIR/leak-user.txt"
privacy_scan_report

if command -v zip >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1 && command -v shasum >/dev/null 2>&1; then
  VERIFY_BUNDLE="$TMP_ROOT/server-doctor_test_20260813T000000Z"
  mkdir -p "$VERIFY_BUNDLE"
  printf 'verification fixture\n' >"$VERIFY_BUNDLE/data.txt"
  (cd "$VERIFY_BUNDLE" && shasum -a 256 data.txt >SHA256SUMS)
  (cd "$TMP_ROOT" && zip -q -r "$(basename "$VERIFY_BUNDLE").zip" "$(basename "$VERIFY_BUNDLE")")
  (cd "$TMP_ROOT" && shasum -a 256 "$(basename "$VERIFY_BUNDLE").zip" >"$(basename "$VERIFY_BUNDLE").zip.sha256")
  "$ROOT/bin/server-doctor" verify --archive "${VERIFY_BUNDLE}.zip" >/dev/null
fi

echo "tests: ok"
