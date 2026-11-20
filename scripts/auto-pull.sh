#!/usr/bin/env bash
# CI-gated, single-instance automation. Fail closed; no arguments or unsafe overrides.
set -Eeuo pipefail
umask 077

if (( $# != 0 )); then
  printf 'Uso: auto-pull.sh (sem argumentos)\n' >&2
  exit 2
fi

app=${COMANDO_APP_DIR:-/opt/comando}
pull=${COMANDO_AUTO_PULL_COMMAND:-/usr/local/sbin/comando-pull}
state_dir=${COMANDO_AUTO_STATE_DIR:-/var/lib/comando-pull}
state="$app/pull-releases/state"
blocked="$state_dir/auto-blocked-sha"

audit() { printf '%s auto_deploy=true %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
fail() { audit "$*"; exit 20; }

[[ $app == /* && $state_dir == /* && $pull == /* && -x $pull ]] ||
  fail 'result=invalid_configuration'
install -d -m 0700 -- "$state_dir" || fail 'result=state_directory_unavailable'

phase= active= pending= extra=
if [[ -e $state ]]; then
  IFS=' ' read -r phase active pending extra < "$state" || fail 'result=state_unreadable'
  [[ $active =~ ^(bootstrap-)?[0-9a-f]{40}$ && -z $extra ]] ||
    fail 'result=state_invalid'
  case "$phase" in
    switching)
      [[ $pending =~ ^[0-9a-f]{40}$ ]] || fail 'result=state_invalid'
      audit "action=recover sha=$pending previous=$active"
      # pull-deploy.sh processes the persisted switching state BEFORE checking CI.
      "$pull" --apply "$pending" || fail "result=recovery_failed sha=$pending"
      IFS=' ' read -r new_phase new_active new_pending new_extra < "$state" ||
        fail 'result=recovery_state_unreadable'
      [[ $new_phase == healthy && $new_active == "$active" && -z $new_pending && -z $new_extra ]] ||
        fail 'result=recovery_state_invalid'
      audit "result=recovered sha=$active"
      exit 0
      ;;
    healthy)
      [[ -z $pending ]] || fail 'result=state_invalid'
      ;;
    *) fail 'result=state_invalid' ;;
  esac
fi

candidate=$("$pull" --dry-run) || {
  rc=$?
  if (( rc == 10 )); then
    audit 'result=not_eligible'
    exit 10
  fi
  fail "result=ci_check_failed exit_code=$rc"
}
[[ $candidate =~ ^[0-9a-f]{40}$ ]] || fail 'result=invalid_candidate'

if [[ $phase == healthy && ${active#bootstrap-} == "$candidate" ]]; then
  curl -q --silent --fail --connect-timeout 3 --max-time 8 http://127.0.0.1:8080/health |
    python3 -c 'import json, sys; d=json.load(sys.stdin); sys.exit(d.get("status") != "ok" or d.get("banco") != "ok")' ||
      fail "result=active_unhealthy sha=$candidate"
  audit "result=already_active sha=$candidate"
  exit 0
fi

if [[ -f $blocked && $(cat -- "$blocked") == "$candidate" ]]; then
  audit "result=quarantined sha=$candidate"
  exit 10
fi

audit "action=deploy sha=$candidate previous=${active:-uninitialized}"
log=$(mktemp "$state_dir/.apply.XXXXXXXX") || fail 'result=log_creation_failed'
trap 'rm -f -- "$log"' EXIT
if "$pull" --apply "$candidate" >"$log" 2>&1; then
  cat -- "$log"
  IFS=' ' read -r new_phase new_active new_pending new_extra < "$state" ||
    fail 'result=activation_state_unreadable'
  [[ $new_phase == healthy && ${new_active#bootstrap-} == "$candidate" && -z $new_pending && -z $new_extra ]] ||
    fail 'result=activation_state_invalid'
  rm -f -- "$blocked"
  audit "result=deployed sha=$candidate"
else
  rc=$?
  cat -- "$log" >&2
  # Temporary contention / CI changes must NOT quarantine a release.
  if grep -Eq 'result=(locked|ci_unavailable_or_blocked|revalidation_failed|postgres_lock_unavailable|efs_unavailable)' "$log"; then
    audit "result=deferred sha=$candidate exit_code=$rc"
    exit 10
  fi
  printf '%s\n' "$candidate" > "$blocked" || fail 'result=quarantine_write_failed'
  audit "result=quarantined_after_failure sha=$candidate exit_code=$rc"
  exit 20
fi
