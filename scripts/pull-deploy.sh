#!/usr/bin/env bash
set -euo pipefail
umask 077

scripts=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
app=${COMANDO_APP_DIR:-/opt/comando}
efs=${COMANDO_EFS_MOUNT:-/mnt/comando-anexos}
releases="$app/pull-releases"
state="$releases/state"
services=(backend web worker scheduler)

audit() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
fail() { audit "$*"; exit 1; }
usage() { fail 'Uso: bash pull-deploy.sh --repository-url URL [--dry-run | --apply SHA]'; }

[[ ${1:-} == --repository-url && ${2:-} =~ ^https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$ ]] || usage
url=$2
shift 2
mode=${1:---dry-run}
case "$mode" in
  --dry-run) (( $# <= 1 )) || usage ;;
  --apply) [[ $# == 2 && $2 =~ ^[0-9a-f]{40}$ ]] || usage; reviewed=$2 ;;
  *) usage ;;
esac

check_ci() { bash "$scripts/check-deploy-ci.sh" --repository-url "$url" --dry-run; }
if [[ $mode == --dry-run ]]; then
  candidate=$(check_ci) || exit "$?"
  audit "result=dry_run sha=$candidate"
  printf '%s\n' "$candidate"
  exit 0
fi

mkdir -p -- "$releases"
exec 9>"$releases/lock"
flock -n 9 || fail 'result=locked'

python=python3
if ! "$python" --version >/dev/null 2>&1; then python=python; fi

write_state() {
  "$python" - "$state" "$*" 2>/dev/null <<'PY'
import os
import sys
import tempfile

target, record = sys.argv[1:]
parent = os.path.dirname(target)
with tempfile.NamedTemporaryFile(dir=parent, delete=False) as output:
    output.write((record + "\n").encode("ascii"))
    output.flush()
    os.fsync(output.fileno())
os.replace(output.name, target)
if os.name == "posix":
    fd = os.open(parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
PY
}

compose() {
  local release=$1 directory
  shift
  directory="$releases/$release"
  if [[ $release == bootstrap-* ]]; then directory=$app; fi
  COMANDO_TAG="$release" timeout -k 10s "${compose_timeout:-240s}" docker compose --project-name comando \
    --project-directory "$directory" --env-file "$app/.env" \
    -f "$directory/compose.yaml" -f "$app/compose.aws.yaml" "$@"
}

config_ready() {
  local release=$1 directory="$releases/$1" rc
  if [[ $release == bootstrap-* ]]; then directory=$app; fi
  if [[ ! -r $directory/.env || ! -r $directory/docker/certs/global-bundle.pem ]] ||
    ! cmp -s "$app/.env" "$directory/.env" ||
    ! cmp -s "$app/docker/certs/global-bundle.pem" "$directory/docker/certs/global-bundle.pem"; then
    audit "stage=compose_config result=runtime_files_invalid release=$release"
    return 1
  fi
  compose "$release" config --quiet >/dev/null 2>&1 || {
    rc=$?
    audit "stage=compose_config result=invalid release=$release exit_code=$rc"
    return 1
  }
}

cleanup() {
  if [[ -n ${lock_write:-} ]]; then exec {lock_write}>&-; fi
  if [[ -n ${lock_read:-} ]]; then exec {lock_read}<&-; fi
  if [[ -n ${lock_pid:-} ]]; then wait "$lock_pid" 2>/dev/null || true; fi
  if [[ -n ${staging:-} && -d $staging ]]; then rm -rf -- "$staging"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

acquire_db_lock() {
  local reply input output lock_code
  lock_code=$(tail -n +2 "$scripts/deploy-lock.php") || return 1
  coproc DEPLOY_LOCK {
    compose_timeout=900s compose "$1" run -T --rm --no-deps --pull never backend php -r "$lock_code" 2>/dev/null
  }
  lock_pid=${DEPLOY_LOCK_PID:-}
  input=${DEPLOY_LOCK[1]:-}
  output=${DEPLOY_LOCK[0]:-}
  if [[ -z $input || -z $output ]]; then
    audit 'stage=postgres_lock result=unavailable'
    return 1
  fi
  exec {lock_write}>&"$input" {lock_read}<&"$output"
  exec {input}>&- {output}<&-
  if ! ( trap '' PIPE; printf 'start\n' >&"$lock_write" ) 2>/dev/null ||
    ! IFS= read -r -t 20 reply <&"$lock_read" || [[ $reply != locked ]]; then
    if [[ ${reply:-} == busy ]]; then
      audit 'stage=postgres_lock result=busy'
    else
      audit 'stage=postgres_lock result=unavailable'
    fi
    return 1
  fi
  audit 'stage=postgres_lock result=acquired'
}

db_lock_held() {
  local reply
  # A closed coprocess pipe must be handled as a failed lock check.
  if ( trap '' PIPE; printf 'check\n' >&"$lock_write" ) 2>/dev/null &&
    IFS= read -r -t 10 reply <&"$lock_read" && [[ $reply == locked ]]; then
    return 0
  fi
  audit 'stage=postgres_lock result=lost'
  return 1
}

efs_ready() {
  local filesystem binding
  filesystem=$(timeout 10s findmnt -n -o FSTYPE --mountpoint "$efs") || return 1
  [[ $filesystem == nfs4 ]] || return 1
  binding=$(timeout 10s docker volume inspect --format \
    '{{.Driver}} {{index .Options "type"}} {{index .Options "o"}} {{index .Options "device"}}' comando_anexos) || return 1
  [[ $binding == "local none bind $efs" ]]
}

healthy() {
  local release=$1 service id info status image reference expected
  for service in "${services[@]}"; do
    if ! id=$(compose "$release" ps -q "$service" 2>/dev/null) ||
      [[ ! $id =~ ^[0-9a-f]{12,64}$ ]] ||
      ! info=$(timeout 10s docker inspect --format '{{.State.Health.Status}} {{.Image}} {{.Config.Image}}' "$id" 2>/dev/null); then
      audit "stage=service_health result=inspect_failed release=$release service=$service"
      return 1
    fi
    read -r status image reference <<< "$info"
    if [[ $status != healthy || ! $image =~ ^sha256:[0-9a-f]{64}$ ]]; then
      audit "stage=service_health result=unhealthy release=$release service=$service"
      return 1
    fi
    expected=backend
    if [[ $service == web ]]; then expected=web; fi
    if [[ $release == bootstrap-check ]]; then
      if [[ ! $reference =~ ^comando-$expected:[A-Za-z0-9_.-]+$ ||
        $image != "$(timeout 10s docker image inspect --format '{{.Id}}' "$reference" 2>/dev/null)" ]]; then
        audit "stage=baseline result=image_mismatch service=$service"
        return 1
      fi
      if [[ $service == web ]]; then
        web_image=$image
      elif [[ $service == backend ]]; then
        backend_image=$image
      else
        [[ $image == "$backend_image" ]] || {
          audit "stage=service_health result=image_mismatch release=$release service=$service"
          return 1
        }
      fi
    else
      [[ $image == "$(timeout 10s docker image inspect --format '{{.Id}}' "comando-$expected:$release" 2>/dev/null)" ]] || {
        audit "stage=service_health result=image_mismatch release=$release service=$service"
        return 1
      }
    fi
  done
  curl -q --silent --fail --connect-timeout 3 --max-time 8 http://127.0.0.1:8080/health |
    "$python" -c 'import json, sys; d = json.load(sys.stdin); sys.exit(d.get("status") != "ok" or d.get("banco") != "ok")' 2>/dev/null || {
    audit "stage=http_health result=unhealthy release=$release"
    return 1
  }
}

images_ready() {
  timeout 10s docker image inspect "comando-backend:$1" "comando-web:$1" >/dev/null 2>&1
}

switch_to() {
  local release=$1 rc
  efs_ready 2>/dev/null || { audit "stage=activation result=efs_unavailable release=$release"; return 1; }
  images_ready "$release" || { audit "stage=activation result=images_missing release=$release"; return 1; }
  config_ready "$release" && db_lock_held || return 1
  compose "$release" up -d --no-build --pull never --force-recreate --wait --wait-timeout 180 >/dev/null 2>&1 || {
    rc=$?
    audit "stage=compose_up result=failed release=$release exit_code=$rc"
    return 1
  }
  healthy "$release" && db_lock_held
}

rollback() {
  audit "action=rollback target=$active candidate=$pending"
  if ! switch_to "$active" || ! write_state healthy "$active"; then
    fail "result=rollback_failed target=$active candidate=$pending"
  fi
  audit "result=rolled_back target=$active candidate=$pending"
}

[[ -f $app/.env && -f $app/compose.aws.yaml && -f $app/docker/certs/global-bundle.pem ]] ||
  fail 'result=bootstrap_files_missing'
origin=$(timeout 10s git -C "$app" config --get remote.origin.url 2>/dev/null) || fail 'result=bootstrap_origin_missing'
[[ ${origin%.git} == "${url%.git}" ]] || fail 'result=bootstrap_repository_mismatch'
efs_ready >/dev/null 2>&1 || fail 'result=efs_unavailable'

active=
if [[ -e $state ]]; then
  read -r phase active pending extra < "$state" || fail 'result=invalid_state'
  [[ $active =~ ^(bootstrap-)?[0-9a-f]{40}$ && -z $extra ]] || fail 'result=invalid_state'
  case "$phase" in
    switching)
      [[ $pending =~ ^[0-9a-f]{40}$ ]] || fail 'result=invalid_state'
      images_ready "$active" && config_ready "$active" && acquire_db_lock "$active" ||
        fail "result=recovery_blocked target=$active"
      rollback
      exit 0
      ;;
    healthy) [[ -z $pending ]] || fail 'result=invalid_state' ;;
    *) fail 'result=invalid_state' ;;
  esac
fi

if [[ -z $active ]]; then
  baseline=$(timeout 10s git -C "$app" rev-parse HEAD 2>/dev/null) || fail 'result=bootstrap_sha_unavailable'
  [[ $baseline =~ ^[0-9a-f]{40}$ ]] || fail 'result=invalid_bootstrap_sha'
  timeout 10s git -C "$app" diff --quiet HEAD -- >/dev/null 2>&1 || fail 'result=bootstrap_checkout_modified'
  config_ready bootstrap-check && healthy bootstrap-check || fail 'result=bootstrap_unhealthy'
  active="bootstrap-$baseline"
  timeout 10s docker tag "$backend_image" "comando-backend:$active" >/dev/null 2>&1 &&
    timeout 10s docker tag "$web_image" "comando-web:$active" >/dev/null 2>&1 ||
    fail 'result=bootstrap_snapshot_failed'
  write_state healthy "$active" || fail 'result=state_write_failed'
  audit "result=baseline_recorded sha=$baseline"
fi

candidate=$(check_ci) || fail 'result=ci_unavailable_or_blocked'
[[ $candidate == "$reviewed" ]] || fail 'result=reviewed_sha_mismatch'
if [[ $candidate == "${active#bootstrap-}" ]]; then
  config_ready "$active" && healthy "$active" || fail "result=active_unhealthy sha=$candidate"
  audit "result=already_active sha=$candidate"
  exit 0
fi

release="$releases/$candidate"
if [[ ! -d $release ]]; then
  staging=$(mktemp -d "$releases/.build.XXXXXXXX")
  (
    git -C "$staging" init &&
      timeout -k 10s 120s env GIT_TERMINAL_PROMPT=0 git -C "$staging" fetch --depth 1 "$url" "$candidate" &&
      git -C "$staging" checkout --detach FETCH_HEAD
  ) >/dev/null 2>&1 || fail "result=checkout_failed sha=$candidate"
  [[ $(git -C "$staging" rev-parse HEAD) == "$candidate" ]] || fail 'result=checkout_sha_mismatch'
  cmp -s "$app/compose.yaml" "$staging/compose.yaml" || fail 'result=compose_changed'
  [[ -d $staging/docker && ! -L $staging/docker && ! -e $staging/.env && ! -L $staging/.env ]] ||
    fail 'result=reserved_path'
    # Permitir leitura do codigo versionado pelo usuario www-data.
  # Nao seguir links simbolicos nem alterar o diretorio .git.
  find "$staging" -xdev -path "$staging/.git" -prune -o \
    \( -type d -o -type f \) -exec chmod a+rX -- {} + ||
    fail "result=checkout_permissions_failed sha=$candidate"
  touch "$staging/.env"
  COMANDO_TAG="$candidate" timeout -k 10s 1200s docker compose --project-name comando \
    --project-directory "$staging" --env-file "$staging/.env" -f "$staging/compose.yaml" \
    build backend web >/dev/null 2>&1 || fail "result=build_failed sha=$candidate"
  images_ready "$candidate" || fail "result=images_missing sha=$candidate"
  rm -f -- "$staging/.env"
  rm -rf -- "$staging/docker/certs"
  ln -s -- "$app/.env" "$staging/.env"
  ln -s -- "$app/docker/certs" "$staging/docker/certs"
  mv -- "$staging" "$release"
fi

[[ $(git -C "$release" rev-parse HEAD) == "$candidate" ]] || fail 'result=checkout_sha_mismatch'
cmp -s "$app/compose.yaml" "$release/compose.yaml" || fail 'result=compose_changed'
images_ready "$active" && images_ready "$candidate" || fail 'result=images_missing'
efs_ready >/dev/null 2>&1 || fail 'result=efs_unavailable'
config_ready "$active" && config_ready "$candidate" || fail 'result=compose_config_invalid'
acquire_db_lock "$active" || fail 'result=postgres_lock_unavailable'
compose "$candidate" run -T --rm --no-deps --pull never backend php \
  < "$scripts/check-schema.php" >/dev/null 2>&1 || fail "result=schema_blocked sha=$candidate"

[[ $(check_ci) == "$candidate" ]] || fail "result=revalidation_failed sha=$candidate"
db_lock_held || fail 'result=postgres_lock_lost'
pending=$candidate
write_state switching "$active" "$pending" || fail 'result=state_write_failed'
audit "action=activate sha=$candidate previous=$active"
if ! switch_to "$candidate"; then
  audit "result=activation_failed sha=$candidate"
  rollback
  exit 1
fi
write_state healthy "$candidate" || fail 'result=state_write_failed'
audit "result=deployed sha=$candidate previous=$active"
