#!/usr/bin/env bash
# Teste local de duas execucoes do auto-pull.sh REAL.
# O comando de implantacao e simulado, usando bloqueio consultivo PostgreSQL REAL.
# Nao provisiona nem altera recursos AWS.
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
auto="$root/scripts/auto-pull.sh"
[[ -f "$auto" ]] || { echo "ERRO: arquivo nao encontrado: $auto" >&2; exit 1; }
command -v docker >/dev/null || { echo 'ERRO: Docker nao encontrado.' >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo 'ERRO: Docker daemon indisponivel.' >&2; exit 1; }

work=$(mktemp -d)
container="comando-cd-multi-test-$$"
sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
pid_a=
cleanup() {
  if [[ -n "$pid_a" ]]; then kill "$pid_a" >/dev/null 2>&1 || true; wait "$pid_a" >/dev/null 2>&1 || true; fi
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf -- "$work"
}
trap cleanup EXIT

# Docker apenas local; sem publicar portas ou usar volumes persistentes.
docker run -d --name "$container" -e POSTGRES_PASSWORD=test_only -e POSTGRES_DB=comando_test postgres:17-alpine >/dev/null
ready=false
for ((i=0; i<90; i++)); do
  if docker exec "$container" pg_isready -U postgres -d comando_test >/dev/null 2>&1; then ready=true; break; fi
  sleep 1
done
[[ $ready == true ]] || { echo 'ERRO: PostgreSQL nao ficou pronto.' >&2; exit 1; }

# Substituto somente para a camada de deploy: retorna CI aprovado e em --apply
# segura o lock REAL por 8 segundos; registra estado local apos a liberacao.
cat > "$work/mock-pull.sh" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  --dry-run)
    printf '%s\n' "$COMANDO_TEST_SHA"
    ;;
  --apply)
    [[ ${2:-} == "$COMANDO_TEST_SHA" ]] || exit 2
    if ! docker exec -i "$COMANDO_TEST_PG_CONTAINER" \
      psql -q -U postgres -d comando_test -v ON_ERROR_STOP=1 <<'SQL'
DO $lock$
BEGIN
  IF NOT pg_try_advisory_lock(2026111701) THEN
    RAISE EXCEPTION 'lock_busy';
  END IF;
  PERFORM pg_sleep(8);
END
$lock$;
SQL
    then
      echo 'ERRO: falha na consulta PostgreSQL ou na disputa pelo bloqueio.' >&2
      echo 'result=postgres_lock_unavailable' >&2
      exit 1
    fi
    mkdir -p "$COMANDO_APP_DIR/pull-releases"
    printf 'healthy %s\n' "$COMANDO_TEST_SHA" > "$COMANDO_APP_DIR/pull-releases/state"
    echo "result=deployed sha=$COMANDO_TEST_SHA" >&2
    ;;
  *) echo 'mock: argumento invalido' >&2; exit 2 ;;
esac
MOCK
chmod +x "$work/mock-pull.sh"

mkdir -p "$work/a/app" "$work/b/app" "$work/a/state" "$work/b/state"
export COMANDO_AUTO_PULL_COMMAND="$work/mock-pull.sh"
export COMANDO_TEST_PG_CONTAINER="$container"
export COMANDO_TEST_SHA="$sha"

run_a() (
  export COMANDO_APP_DIR="$work/a/app" COMANDO_AUTO_STATE_DIR="$work/a/state"
  bash "$auto"
)
run_b() (
  export COMANDO_APP_DIR="$work/b/app" COMANDO_AUTO_STATE_DIR="$work/b/state"
  bash "$auto"
)

run_a >"$work/a.out" 2>"$work/a.err" &
pid_a=$!

# Esperar A deter o bloqueio realmente, evitando disputa de timing.
lock_seen=false
for ((i=0; i<60; i++)); do
  if [[ $(docker exec "$container" psql -At -U postgres -d comando_test \
        -c "SELECT EXISTS(SELECT 1 FROM pg_locks WHERE locktype='advisory' AND objid=2026111701 AND granted);" \
        2>/dev/null || true) == t ]]; then
    lock_seen=true
    break
  fi
  if ! kill -0 "$pid_a" 2>/dev/null; then break; fi
  sleep 0.15
done
[[ $lock_seen == true ]] || { cat "$work/a.err" >&2; echo 'FAIL ec2_a_lock' >&2; exit 1; }
echo 'PASS ec2_a_lock_acquired'

code_b=0
run_b >"$work/b-first.out" 2>"$work/b-first.err" || code_b=$?
[[ $code_b == 10 ]] && grep -q 'result=deferred' "$work/b-first.err" || {
  echo "FAIL ec2_b_deferred exit=$code_b" >&2
  cat "$work/b-first.err" >&2
  exit 1
}
[[ ! -e "$work/b/app/pull-releases/state" ]] || { echo 'FAIL ec2_b_changed_during_lock' >&2; exit 1; }
echo 'PASS ec2_b_deferred_while_a_active'

code_a=0
wait "$pid_a" || code_a=$?
pid_a=
[[ $code_a == 0 ]] && grep -q "result=deployed sha=$sha" "$work/a.err" && \
  [[ $(cat "$work/a/app/pull-releases/state") == "healthy $sha" ]] || {
  echo "FAIL ec2_a_completion exit=$code_a" >&2
  cat "$work/a.err" >&2
  exit 1
}
echo 'PASS ec2_a_completed'

run_b >"$work/b-second.out" 2>"$work/b-second.err" || {
  echo 'FAIL ec2_b_retry' >&2
  cat "$work/b-second.err" >&2
  exit 1
}
[[ $(cat "$work/b/app/pull-releases/state") == "healthy $sha" ]] || {
  echo 'FAIL ec2_b_state' >&2
  exit 1
}
echo 'PASS ec2_b_updated_after_retry'
[[ $(cat "$work/a/app/pull-releases/state") == "$(cat "$work/b/app/pull-releases/state")" ]] || {
  echo 'FAIL sha_convergence' >&2
  exit 1
}
echo "PASS two_auto_pull_processes_converged sha=$sha"
echo 'PASS local_multi_ec2_auto_pull_with_real_postgres_lock'
