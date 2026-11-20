#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/app/pull-releases" "$tmp/state"
export COMANDO_APP_DIR="$tmp/app" COMANDO_AUTO_STATE_DIR="$tmp/state" \
  COMANDO_AUTO_PULL_COMMAND="$tmp/bin/comando-pull"
export CANDIDATE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export OLD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export TRACE="$tmp/trace" SCENARIO=success

cat > "$tmp/bin/comando-pull" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$TRACE"
if [[ $1 == --dry-run ]]; then
  case "$SCENARIO" in
    not_eligible) exit 10 ;;
    api_failure) exit 20 ;;
    invalid) printf 'not-a-sha\n'; exit 0 ;;
    *) printf '%s\n' "$CANDIDATE" ;;
  esac
  exit 0
fi
[[ $1 == --apply && $2 =~ ^[0-9a-f]{40}$ ]]
case "$SCENARIO" in
  error) echo 'result=rolled_back' >&2; exit 1 ;;
  locked) echo 'result=locked' >&2; exit 1 ;;
  recovery) printf 'healthy %s\n' "$OLD" > "$COMANDO_APP_DIR/pull-releases/state" ;;
  *) printf 'healthy %s\n' "$2" > "$COMANDO_APP_DIR/pull-releases/state" ;;
esac
MOCK
cat > "$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
if [[ $SCENARIO == unhealthy ]]; then
  echo '{"status":"erro","banco":"ok"}'
else
  echo '{"status":"ok","banco":"ok"}'
fi
MOCK
chmod +x "$tmp/bin/curl" "$tmp/bin/comando-pull"
export PATH="$tmp/bin:$PATH"

reset() {
  rm -f "$COMANDO_APP_DIR/pull-releases/state" "$COMANDO_AUTO_STATE_DIR/auto-blocked-sha" "$TRACE"
  SCENARIO="$1"; export SCENARIO
}
run() {
  local expected=$1 marker=$2 rc=0
  bash "$root/scripts/auto-pull.sh" > "$tmp/out" 2> "$tmp/err" || rc=$?
  if [[ $rc != "$expected" ]] || ! grep -Fq "$marker" "$tmp/err"; then
    echo "FAIL scenario=$SCENARIO expected=$expected got=$rc marker=$marker" >&2
    cat "$tmp/err" >&2
    exit 1
  fi
  echo "PASS $SCENARIO $marker"
}
reset success
run 0 'result=deployed sha='
grep -Fxq "healthy $CANDIDATE" "$COMANDO_APP_DIR/pull-releases/state"
reset success
printf 'healthy %s\n' "$OLD" > "$COMANDO_APP_DIR/pull-releases/state"
run 0 'result=deployed sha='
reset success
printf 'healthy bootstrap-%s\n' "$CANDIDATE" > "$COMANDO_APP_DIR/pull-releases/state"
run 0 'result=already_active sha='
! grep -q -- '--apply' "$TRACE"
reset unhealthy
printf 'healthy %s\n' "$CANDIDATE" > "$COMANDO_APP_DIR/pull-releases/state"
run 20 'result=active_unhealthy'
reset not_eligible
run 10 'result=not_eligible'
reset api_failure
run 20 'result=ci_check_failed'
reset invalid
run 20 'result=invalid_candidate'
reset error
printf 'healthy %s\n' "$OLD" > "$COMANDO_APP_DIR/pull-releases/state"
run 20 'result=quarantined_after_failure'
grep -Fxq "$CANDIDATE" "$COMANDO_AUTO_STATE_DIR/auto-blocked-sha"
run 10 'result=quarantined sha='
[[ $(grep -c -- '--apply' "$TRACE") == 1 ]]
reset locked
printf 'healthy %s\n' "$OLD" > "$COMANDO_APP_DIR/pull-releases/state"
run 10 'result=deferred sha='
[[ ! -f "$COMANDO_AUTO_STATE_DIR/auto-blocked-sha" ]]
reset recovery
printf 'switching %s %s\n' "$OLD" "$CANDIDATE" > "$COMANDO_APP_DIR/pull-releases/state"
run 0 'result=recovered sha='
! grep -q -- '--dry-run' "$TRACE"
reset success
printf 'unexpected %s\n' "$OLD" > "$COMANDO_APP_DIR/pull-releases/state"
run 20 'result=state_invalid'
