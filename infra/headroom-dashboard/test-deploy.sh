#!/usr/bin/env bash
# Static checks, no Azure calls:
# 1. deploy.sh never puts a secret value on a command line, where process auditing
#    records it. Secret values reach az through its @file expansion.
# 2. No value from the git-ignored .env.local appears in any tracked or new file.
set -u
cd "$(dirname "$0")"
fail=0
code=$(grep -v '^[[:space:]]*#' deploy.sh)

if grep -n -- '--client-secret' <<<"$code"; then
  echo "FAIL deploy.sh passes --client-secret"; fail=1
fi
if grep -n 'credential reset' <<<"$code"; then
  echo "FAIL deploy.sh creates an app registration secret"; fail=1
fi
# Every --secrets value must be name=@file.
while IFS= read -r line; do
  for arg in $(grep -oE '"[^"]*"' <<<"${line#*--secrets }"); do
    [[ $arg == \"*=@* ]] || { echo "FAIL --secrets value not read from a file: $arg"; fail=1; }
  done
done < <(grep -- '--secrets' <<<"$code")

[ -f .env.local ] || { echo "FAIL .env.local missing: copy .env.example to .env.local and fill it in"; exit 1; }
git check-ignore -q .env.local || { echo "FAIL .env.local is not git-ignored"; fail=1; }
values=$(tr -d '\r' < .env.local | sed -n 's/^[A-Z_][A-Z0-9_]*=//p' | grep -v '^$')
# The DNS zone of the custom hostname is environment-specific too.
values+=$'\n'$(sed -n 's/^HOST=[^.]*\.//p' <<<"$(tr -d '\r' < .env.local)")
# A real file, not <(...): Git for Windows cannot open /dev/fd paths.
patterns=$(mktemp)
trap 'rm -f "$patterns"' EXIT
grep -v '^$' <<<"$values" > "$patterns"
git grep --untracked -n -F -f "$(cygpath -m "$patterns" 2>/dev/null || echo "$patterns")" -- .
case $? in
  0) echo "FAIL tracked files contain values from .env.local"; fail=1 ;;
  1) ;;
  *) echo "FAIL git grep could not run"; fail=1 ;;
esac

[ $fail = 0 ] && echo "PASS secrets stay off the command line; no .env.local value in tracked files"
exit $fail
