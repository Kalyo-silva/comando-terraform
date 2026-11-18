#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir "$tmp/bin"
export PATH="$tmp/bin:$PATH"
export COMANDO_APP_DIR="$tmp/app" COMANDO_EFS_MOUNT="$tmp/efs"
export SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export BASE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export REPO=https://github.com/example/comando.git
export TRACE="$tmp/trace" CURRENT="$tmp/current" CI_COUNT="$tmp/ci-count"
export LOCK="$tmp/db-lock"
export BACKEND=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
export WEB=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd

cat > "$tmp/bin/mock" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "${0##*/}" in
  flock) [[ $SCENARIO != concurrent ]] ;;
  findmnt)
    [[ $SCENARIO != efs_missing ]] || exit 1
    printf 'nfs4\n'
    ;;
  git)
    [[ $1 == -C ]]
    directory=$2 command=$3
    case "$command" in
      config) printf '%s\n' "$REPO" ;;
      init) mkdir "$directory/docker" ;;
      fetch) [[ ${@: -2:1} == "$REPO" && ${@: -1} == "$SHA" ]] ;;
      checkout)
        cp "$COMANDO_APP_DIR/compose.yaml" "$directory/compose.yaml"
        printf '%s\n' "$SHA" > "$directory/mock-head"
        if [[ $SCENARIO == checkout_permissions ]]; then
          mkdir -p "$directory/backend/app" "$directory/.git/objects"
          touch "$directory/backend/app/index.php" "$directory/.git/objects/fixture"
          chmod 700 "$directory" "$directory/backend" "$directory/backend/app" \
            "$directory/.git" "$directory/.git/objects"
          chmod 600 "$directory/backend/app/index.php" "$directory/.git/objects/fixture"
          ln -s -- "$SENSITIVE_FIXTURE" "$directory/backend/app/sensitive-link"
        fi
        ;;
      diff) [[ $SCENARIO != dirty_baseline ]] ;;
      rev-parse)
        if [[ $directory == "$COMANDO_APP_DIR" && $SCENARIO == installed_head ]]; then printf '%s\n' "$SHA"
        elif [[ $directory == "$COMANDO_APP_DIR" ]]; then printf '%s\n' "$BASE"
        elif [[ $SCENARIO == wrong_checkout ]]; then printf '%s\n' "$BASE"
        else cat "$directory/mock-head"
        fi
        ;;
      *) exit 99 ;;
    esac
    ;;
  curl)
    while (( $# )); do
      case "$1" in
        --dump-header) headers=$2; shift ;;
        --output) body=$2; shift ;;
        http*) url=$1 ;;
      esac
      shift
    done
    api=https://api.github.com/repos/example/comando
    case "$url" in
      "$api/git/ref/heads/main")
        : > "$headers"
        if [[ $SCENARIO == api_error ]]; then printf 503; exit; fi
        printf '{"ref":"refs/heads/main","object":{"type":"commit","sha":"%s"}}' "$SHA" > "$body"
        printf 200
        ;;
      "$api/actions/workflows/ci.yml/runs?branch=main&event=push&head_sha=$SHA&per_page=100")
        : > "$headers"
        count=$(cat "$CI_COUNT")
        printf '%s\n' "$((count + 1))" > "$CI_COUNT"
        conclusion=success
        if [[ $SCENARIO == blocked || ( $SCENARIO == revalidation && $count == 1 ) ]]; then conclusion=failure; fi
        printf '{"total_count":1,"workflow_runs":[{"id":1,"run_number":1,"run_attempt":1,"head_sha":"%s","status":"completed","conclusion":"%s","repository":{"full_name":"example/comando"},"head_repository":{"full_name":"example/comando"},"head_branch":"main","event":"push","path":".github/workflows/ci.yml"}]}' "$SHA" "$conclusion" > "$body"
        printf 200
        ;;
      http://127.0.0.1:8080/health)
        if [[ $(cat "$CURRENT") == "$SHA" && ( $SCENARIO == unhealthy || $SCENARIO == rollback_failed ) ]]; then
          printf '{"status":"degradado","banco":"indisponivel"}'
        else
          printf '{"status":"ok","banco":"ok"}'
        fi
        ;;
      *) exit 99 ;;
    esac
    ;;
  docker)
    case "$1" in
      volume) printf 'local none bind %s\n' "$COMANDO_EFS_MOUNT" ;;
      tag) printf 'tag %s\n' "${@: -1}" >> "$TRACE" ;;
      image)
        if [[ $SCENARIO == images_missing && ${@: -1} == "comando-web:$SHA" ]]; then exit 1; fi
        case "${@: -1}" in comando-web:*) printf '%s\n' "$WEB" ;; *) printf '%s\n' "$BACKEND" ;; esac
        ;;
      inspect)
        if [[ ${@: -1} == 222222222222 ]]; then printf 'healthy %s comando-web:aws\n' "$WEB"
        elif [[ ${@: -1} == 333333333333 && $SCENARIO == baseline_unhealthy ]]; then
          printf 'unhealthy %s comando-backend:aws\n' "$BACKEND"
        elif [[ $SCENARIO == baseline_wrong_image ]]; then printf 'healthy %s comando-backend:aws\n' "$WEB"
        else printf 'healthy %s comando-backend:aws\n' "$BACKEND"
        fi
        ;;
      compose)
        shift
        [[ $1 == --project-name && $2 == comando ]]
        args="$*"
        while [[ $1 == --* || $1 == -f ]]; do
          if [[ $1 == --project-directory ]]; then project_directory=$2; fi
          shift 2
        done
        case "$1" in
          config)
            [[ $2 == --quiet && $args == *"--env-file $COMANDO_APP_DIR/.env"* &&
              $args == *"-f $COMANDO_APP_DIR/compose.aws.yaml"* ]] || exit 99
            printf 'config %s\n' "$COMANDO_TAG" >> "$TRACE"
            if [[ $SCENARIO == config_invalid && $COMANDO_TAG == "$SHA" ]]; then
              printf 'SENTINELA_SECRETA\n' >&2
              exit 15
            fi
            ;;
          ps)
            case "${@: -1}" in
              backend) printf '111111111111\n' ;;
              web) printf '222222222222\n' ;;
              worker) printf '333333333333\n' ;;
              scheduler) printf '444444444444\n' ;;
              *) exit 99 ;;
            esac
            ;;
          build)
            printf 'build %s\n' "$COMANDO_TAG" >> "$TRACE"
            if [[ $SCENARIO == checkout_permissions ]]; then
              check_mode() {
                local actual
                actual=$(stat -c %a -- "$1")
                if [[ $actual != "$2" ]]; then
                  printf 'build permission check failed: %s mode=%s expected=%s\n' "$1" "$actual" "$2" >> "$TRACE"
                  return 1
                fi
              }
              check_mode "$project_directory" 755
              check_mode "$project_directory/backend" 755
              check_mode "$project_directory/backend/app" 755
              check_mode "$project_directory/backend/app/index.php" 644
              check_mode "$project_directory/.git" 700
              check_mode "$project_directory/.git/objects" 700
              check_mode "$project_directory/.git/objects/fixture" 600
              link="$project_directory/backend/app/sensitive-link"
              [[ -L $link && $(readlink -- "$link") == "$SENSITIVE_FIXTURE" ]]
              check_mode "$link" 777
              check_mode "$SENSITIVE_FIXTURE" 600
              printf 'checked checkout permissions at build\n' >> "$TRACE"
            fi
            [[ $SCENARIO != build_failed ]]
            ;;
          run)
            if [[ ${@: -2:1} == -r ]]; then
              [[ ${@: -1} == *'pg_try_advisory_lock(2026111701)'* ]] || exit 99
              IFS= read -r request
              [[ $request == start ]] || exit 99
              if [[ $SCENARIO == db_busy ]]; then printf 'busy\n'; exit 1; fi
              printf 'locked\n'
              : > "$LOCK"
              trap 'rm -f -- "$LOCK"' EXIT
              while IFS= read -r request; do
                [[ $request == check ]] || exit 99
                if [[ $SCENARIO == db_lost && $(cat "$CURRENT") == "$SHA" ]]; then exit 1; fi
                printf 'locked\n'
              done
              exit 0
            fi
            [[ -f $LOCK ]] || exit 99
            grep -q 'getRan' || exit 99
            printf 'schema %s\n' "$COMANDO_TAG" >> "$TRACE"
            [[ $SCENARIO != schema_blocked ]]
            ;;
          up)
            [[ -f $LOCK ]] || exit 99
            printf 'up %s\n' "$COMANDO_TAG" >> "$TRACE"
            if [[ $SCENARIO == rollback_failed && $COMANDO_TAG == bootstrap-* ]]; then exit 1; fi
            printf '%s\n' "$COMANDO_TAG" > "$CURRENT"
            if [[ $SCENARIO == activation_timeout && $COMANDO_TAG == "$SHA" ]]; then exit 124; fi
            ;;
          *) exit 99 ;;
        esac
        ;;
      *) exit 99 ;;
    esac
    ;;
  *) exit 99 ;;
esac
MOCK
for name in flock findmnt git curl docker; do
  cp "$tmp/bin/mock" "$tmp/bin/$name"
  chmod +x "$tmp/bin/$name"
done

run() {
  local expected=$1 marker=$2 state_expected=$3 trace_expected=$4 code=0
  shift 4
  bash "$root/scripts/pull-deploy.sh" --repository-url "$REPO" "$@" > "$tmp/out" 2> "$tmp/err" || code=$?
  if [[ $code != "$expected" ]] || ! grep -Fq "$marker" "$tmp/err" ||
    [[ $(cat "$COMANDO_APP_DIR/pull-releases/state" 2>/dev/null || true) != "$state_expected" ]] ||
    [[ $(grep '^up ' "$TRACE" || true) != "$trace_expected" ]] ||
    [[ $(cat "$COMANDO_APP_DIR/.env") != APP_KEY=simulada || -e $LOCK ]] ||
    grep -Fq SENTINELA_SECRETA "$tmp/err"; then
    printf 'FAIL %s code=%s\n' "$SCENARIO" "$code" >&2
    cat "$tmp/err" "$TRACE" >&2
    exit 1
  fi
  printf 'PASS %s\n' "$SCENARIO"
}

reset() {
  export SCENARIO=$1
  rm -rf -- "$COMANDO_APP_DIR"
  mkdir -p "$COMANDO_APP_DIR/docker/certs"
  touch "$COMANDO_APP_DIR/compose.yaml" "$COMANDO_APP_DIR/compose.aws.yaml" "$COMANDO_APP_DIR/docker/certs/global-bundle.pem"
  printf 'APP_KEY=simulada\n' > "$COMANDO_APP_DIR/.env"
  printf '0\n' > "$CI_COUNT"
  printf 'bootstrap-%s\n' "$BASE" > "$CURRENT"
  : > "$TRACE"
}

baseline="healthy bootstrap-$BASE"
switching="switching bootstrap-$BASE $SHA"
activated="up $SHA"
restored="up bootstrap-$BASE"

reset dry_run
run 0 result=dry_run '' '' --dry-run
[[ ! -e $COMANDO_APP_DIR/pull-releases && ! -s $TRACE && $(cat "$tmp/out") == "$SHA" ]]
reset blocked
run 1 result=ci_unavailable_or_blocked "$baseline" '' --apply "$SHA"
reset api_error
run 1 result=ci_unavailable_or_blocked "$baseline" '' --apply "$SHA"
reset efs_missing
run 1 result=efs_unavailable '' '' --apply "$SHA"
reset concurrent
run 1 result=locked '' '' --apply "$SHA"
reset installed_head
run 0 result=already_active "healthy bootstrap-$SHA" '' --apply "$SHA"
! grep -q '^build ' "$TRACE"
reset dirty_baseline
run 1 result=bootstrap_checkout_modified '' '' --apply "$SHA"
reset baseline_unhealthy
run 1 'result=unhealthy release=bootstrap-check service=worker' '' '' --apply "$SHA"
reset baseline_wrong_image
run 1 'stage=baseline result=image_mismatch service=backend' '' '' --apply "$SHA"
reset wrong_checkout
run 1 result=checkout_sha_mismatch "$baseline" '' --apply "$SHA"
reset build_failed
run 1 result=build_failed "$baseline" '' --apply "$SHA"
reset images_missing
run 1 result=images_missing "$baseline" '' --apply "$SHA"
reset schema_blocked
run 1 result=schema_blocked "$baseline" '' --apply "$SHA"
reset config_invalid
run 1 "stage=compose_config result=invalid release=$SHA exit_code=15" "$baseline" '' --apply "$SHA"
reset db_busy
run 1 'stage=postgres_lock result=busy' "$baseline" '' --apply "$SHA"
reset db_lost
run 1 'stage=postgres_lock result=lost' "$switching" "$activated" --apply "$SHA"
reset revalidation
run 1 result=revalidation_failed "$baseline" '' --apply "$SHA"
reset approved
run 0 result=deployed "healthy $SHA" "$activated" --apply "$SHA"
[[ $(cat "$CI_COUNT") == 2 ]]
reset unhealthy
run 1 result=rolled_back "$baseline" "$activated"$'\n'"$restored" --apply "$SHA"
grep -Fq "stage=http_health result=unhealthy release=$SHA" "$tmp/err"
reset activation_timeout
run 1 result=rolled_back "$baseline" "$activated"$'\n'"$restored" --apply "$SHA"
grep -Fq "stage=compose_up result=failed release=$SHA exit_code=124" "$tmp/err"
reset rollback_failed
run 1 result=rollback_failed "$switching" "$activated"$'\n'"$restored" --apply "$SHA"
reset recovery
mkdir "$COMANDO_APP_DIR/pull-releases"
printf '%s\n' "$switching" > "$COMANDO_APP_DIR/pull-releases/state"
printf '%s\n' "$SHA" > "$CURRENT"
run 0 result=rolled_back "$baseline" "$restored" --apply "$SHA"
[[ $(cat "$CI_COUNT") == 0 ]]

if [[ $(uname -s) == Linux ]]; then
  reset checkout_permissions
  export SENSITIVE_FIXTURE="$tmp/sensitive-fixture"
  printf 'fixture\n' > "$SENSITIVE_FIXTURE"
  chmod 600 "$SENSITIVE_FIXTURE"
  run 0 result=deployed "healthy $SHA" "$activated" --apply "$SHA"
  grep -Fxq 'checked checkout permissions at build' "$TRACE"
else
  printf 'SKIP checkout_permissions (requires Linux POSIX modes)\n'
fi
