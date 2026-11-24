#!/usr/bin/env bash
# Local integration test of sequential deployment coordination using PostgreSQL.
# Simulates two independent application nodes; does not execute COMANDO deploy scripts.
set -Eeuo pipefail

container="comando-pg-multi-test-$$"
tmp="$(mktemp -d)"
sha="$(printf 'a%.0s' {1..40})"
lock_id=2026111701

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf -- "$tmp"
}
trap cleanup EXIT

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || fail 'Docker unavailable'
docker info >/dev/null 2>&1 || fail 'Docker daemon unavailable'

docker run --rm -d --name "$container" \
  -e POSTGRES_PASSWORD=local_test_only \
  -e POSTGRES_DB=comando_test postgres:17-alpine >/dev/null

ready=false
for _ in {1..40}; do
  if docker exec "$container" pg_isready -U postgres -d comando_test >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
[[ $ready == true ]] || fail 'PostgreSQL did not become ready'

query() {
  docker exec "$container" psql -X -qAt -v ON_ERROR_STOP=1 \
    -U postgres -d comando_test -c "$1"
}

# This is an actual database session holding the same advisory lock used by deploy-lock.php.
# The first query acquires the lock and the same connection remains open for 8 seconds.
docker exec "$container" psql -X -qAt -v ON_ERROR_STOP=1 \
  -U postgres -d comando_test \
  -c "SELECT pg_advisory_lock($lock_id); SELECT pg_sleep(8);" \
  >"$tmp/first.out" 2>"$tmp/first.err" &
pid_a=$!

# Wait until the lock is observably held, not just an arbitrary sleep.
locked=false
for _ in {1..40}; do
  if [[ "$(query "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND granted AND objid = $lock_id;" 2>/dev/null || true)" =~ ^[1-9][0-9]*$ ]]; then
    locked=true
    break
  fi
  sleep 0.2
done
[[ $locked == true ]] || fail 'EC2-A did not acquire the advisory lock'
printf 'PASS ec2_a_lock_acquired\n'

# Second simulated node: first attempt must be rejected while A is deploying.
first_b="$(query "SELECT pg_try_advisory_lock($lock_id);")"
[[ "$first_b" == f ]] || fail "EC2-B should be busy, got '$first_b'"
printf 'PASS ec2_b_deferred_while_a_active\n'

# A succeeds and publishes local simulated state (not actual COMANDO release activation).
wait "$pid_a" || { cat "$tmp/first.err" >&2; fail 'EC2-A lock holder failed'; }
printf '%s\n' "$sha" >"$tmp/ec2-a-version"
printf 'PASS ec2_a_completed\n'

# B retries after the connection holding the lock has exited.
second_b="$(query "SELECT pg_try_advisory_lock($lock_id);")"
[[ "$second_b" == t ]] || fail "EC2-B retry should succeed, got '$second_b'"
printf '%s\n' "$sha" >"$tmp/ec2-b-version"
printf 'PASS ec2_b_updated_after_retry\n'

[[ "$(cat "$tmp/ec2-a-version")" == "$sha" && "$(cat "$tmp/ec2-b-version")" == "$sha" ]] || fail 'Simulated nodes did not converge'
printf 'PASS simulated_sha_convergence sha=%s\n' "$sha"
printf 'PASS local_postgresql_multi_ec2_coordination\n'
