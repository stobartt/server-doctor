#!/usr/bin/env bash

# Conservative last-line redaction for the small amount of unstructured text
# that remains in a bundle. Privacy-sensitive inventories and raw application
# messages are excluded at the source; this filter is a second boundary.
account_name_regex() {
  local name uid escaped regex=""
  [[ -r /etc/passwd ]] || return 0
  while IFS=: read -r name _ uid _; do
    [[ $uid =~ ^[0-9]+$ ]] || continue
    (( uid == 0 || (uid >= 1000 && uid < 65534) )) || continue
    escaped=$(printf '%s' "$name" | sed -E 's#[][\\.^$*+?(){}|]#\\&#g')
    [[ -n $escaped ]] || continue
    if [[ -n $regex ]]; then regex+="|"; fi
    regex+=$escaped
  done </etc/passwd
  printf '%s' "$regex"
}

SERVER_DOCTOR_ACCOUNT_REGEX=$(account_name_regex)
SERVER_DOCTOR_NODE_REGEX=""
if [[ -r /proc/sys/kernel/hostname ]]; then
  read -r SERVER_DOCTOR_NODE_REGEX </proc/sys/kernel/hostname || SERVER_DOCTOR_NODE_REGEX=""
  SERVER_DOCTOR_NODE_REGEX=$(printf '%s' "$SERVER_DOCTOR_NODE_REGEX" | sed -E 's#[][\\.^$*+?(){}|]#\\&#g')
fi

redact_stream() {
  local -a expressions=(
    -e 's#([A-Za-z][A-Za-z0-9+.-]*://)[^/@[:space:]]+:[^/@[:space:]]+@#\1[REDACTED]@#g' \
    -e 's#([Aa]uthorization[^:=]{0,3}[:=][[:space:]]*"?)([Bb]earer|[Bb]asic)[[:space:]]+[^"[:space:],;]+#\1\2 [REDACTED]#g' \
    -e 's#((Cookie|cookie|Set-Cookie|set-cookie)[^:=]{0,3}[:=][[:space:]]*"?)[^"[:space:];,]+#\1[REDACTED]#g' \
    -e 's#((password|passwd|pwd|token|access[_-]?token|refresh[_-]?token|api[_-]?key|apikey|secret|client[_-]?secret|private[_-]?key)[^:=]{0,3}[:=][[:space:]]*"?)[^"[:space:],;}{]+#\1[REDACTED]#Ig' \
    -e 's#[Bb]earer[[:space:]]+[A-Za-z0-9._~+/-]{16,}#Bearer [REDACTED]#g' \
    -e 's#AKIA[0-9A-Z]{16}#[REDACTED_AWS_KEY]#g' \
    -e 's#gh[pousr]_[A-Za-z0-9_]{20,}#[REDACTED_GITHUB_TOKEN]#g' \
    -e 's#eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}#[REDACTED_JWT]#g' \
    -e 's#([[:alnum:]._%+-]+)@([[:alnum:].-]+\.[[:alpha:]]{2,})#[REDACTED_EMAIL]#g' \
    -e 's#(^|[^0-9])([0-9]{1,3}\.){3}[0-9]{1,3}#\1[REDACTED_IP]#g' \
    -e 's#([[:xdigit:]]{1,4}:){3,7}[[:xdigit:]]{0,4}#[REDACTED_IP]#g' \
    -e 's#[[:xdigit:]]{0,4}::([[:xdigit:]]{0,4}:){0,6}[[:xdigit:]]{0,4}#[REDACTED_IP]#g' \
    -e 's#(\[REDACTED_IP\]):[0-9]{1,5}#\1:[REDACTED_PORT]#g' \
    -e 's#((port|listen(ing)?([[:space:]]+on)?|local[_ -]?port|remote[_ -]?port)[[:space:]:=]+)[0-9]{1,5}#\1[REDACTED_PORT]#Ig' \
    -e 's#/(home|[Uu]sers?)/[^/[:space:]"]+#/[REDACTED_HOME]#g' \
    -e 's#/root(/|[[:space:]"]|$)#[REDACTED_HOME]\1#g'
    -e 's#user@[0-9]+#[REDACTED_USER_UNIT]#g'
    -e 's#user-[0-9]+\.slice#[REDACTED_USER_SLICE]#g'
  )
  if [[ -n $SERVER_DOCTOR_ACCOUNT_REGEX ]]; then
    expressions+=(
      -e ':account_redaction'
      -e "s#(^|[^[:alnum:]])(${SERVER_DOCTOR_ACCOUNT_REGEX})([^[:alnum:]]|$)#\\1[REDACTED_USER]\\3#g"
      -e 't account_redaction'
    )
  fi
  if [[ -n $SERVER_DOCTOR_NODE_REGEX ]]; then
    expressions+=(
      -e ':node_redaction'
      -e "s#(^|[^[:alnum:]])(${SERVER_DOCTOR_NODE_REGEX})([^[:alnum:]]|$)#\\1[REDACTED_NODE]\\3#g"
      -e 't node_redaction'
    )
  fi
  sed -E "${expressions[@]}"
}

redact_file() {
  local input=$1
  local output=$2
  redact_stream <"$input" >"$output"
}
