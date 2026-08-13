#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$ROOT"

while IFS= read -r file; do
  bash -n "$file"
done < <(find bin collectors lib tests -type f \( -name '*.sh' -o -name 'server-doctor' \) | sort)

make -n doctor >/dev/null
make -n audit >/dev/null
make -n install-user >/dev/null

if rg -n 'docker[[:space:]]+(system[[:space:]]+)?prune|docker[[:space:]]+(container|image|volume|network)[[:space:]]+prune|rm[[:space:]]+-rf|/proc/[^[:space:]]*/environ' \
  bin collectors lib; then
  echo "Forbidden destructive or secret-bearing collector pattern found" >&2
  exit 1
fi

if rg -n 'NetworkSettings|docker[[:space:]]+network|ip[[:space:]].*(address|route)|ss[[:space:]].*-l|nft([[:space:]]|$)|iptables|sshd[[:space:]]+-T|\.Config\.|hostname(ct|[[:space:]])' \
  bin collectors lib --glob '!redact.sh'; then
  echo "Forbidden identity, network, configuration, or hostname collector pattern found" >&2
  exit 1
fi

if command -v shellcheck >/dev/null 2>&1; then
  find bin collectors lib tests -type f \( -name '*.sh' -o -name 'server-doctor' \) -exec shellcheck -x {} +
else
  echo "SKIP: shellcheck is not installed on the development machine"
fi

echo "lint: ok"
