#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export PATH="$tmp:$PATH"
export SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export OTHER_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

cat > "$tmp/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == -q ]]
while (( $# )); do
  case "$1" in
    --dump-header) headers=$2; shift ;;
    --output) body=$2; shift ;;
    https://*) url=$1 ;;
  esac
  shift
done
: > "$headers"
base=https://api.github.com/repos/JeanKoerich/comando
case "$url" in
  "$base/git/ref/heads/main")
    if [[ $SCENARIO == timeout ]]; then exit 28; fi
    if [[ $SCENARIO == bad_json ]]; then
      printf '{' > "$body"
    else
      sha=$SHA
      if [[ $SCENARIO == head_changed && -e $body ]]; then sha=$OTHER_SHA; fi
      printf '{"ref":"refs/heads/main","object":{"type":"commit","sha":"%s"}}' "$sha" > "$body"
    fi
    printf 200
    ;;
  "$base/actions/workflows/ci.yml/runs?branch=main&event=push&head_sha=$SHA&per_page=100")
    run() {
      printf '{"id":%s,"run_number":%s,"run_attempt":%s,"head_sha":"%s","status":"%s","conclusion":%s,"repository":{"full_name":"JeanKoerich/comando"},"head_repository":{"full_name":"%s"},"head_branch":"%s","event":"%s","path":"%s"}' \
        "$1" "$1" "$2" "$3" "$4" "$5" "${repo:-JeanKoerich/comando}" \
        "${branch:-main}" "${event:-push}" "${workflow:-.github/workflows/ci.yml@main}"
    }
    case "$SCENARIO" in
      http_error) printf 500; exit ;;
      forbidden) printf 403; exit ;;
      rate_limit)
        printf 'X-RateLimit-Remaining: 0\r\nX-RateLimit-Reset: 1800000000\r\nRetry-After: 900\r\n' > "$headers"
        printf 429
        exit
        ;;
      no_run) printf '{"total_count":0,"workflow_runs":[]}' > "$body"; printf 200; exit ;;
      wrong_repo) repo=other/comando ;;
      wrong_branch) branch=develop ;;
      wrong_event) event=pull_request ;;
      wrong_workflow) workflow=.github/workflows/deploy.yml ;;
    esac
    {
      printf '{"total_count":2,"workflow_runs":['
      case "$SCENARIO" in
        rejected) run 2 2 "$SHA" completed '"failure"' ;;
        pending) run 2 2 "$SHA" in_progress null ;;
        wrong_sha) run 2 1 "$OTHER_SHA" completed '"success"' ;;
        *) run 2 1 "$SHA" completed '"success"' ;;
      esac
      printf ','
      run 1 1 "$SHA" completed '"success"'
      printf ']}'
    } > "$body"
    printf 200
    ;;
  *) exit 99 ;;
esac
MOCK
chmod +x "$tmp/curl"

check() {
  local scenario=$1 expected_code=$2 expected_log=$3 code=0
  SCENARIO=$scenario bash "$root/scripts/check-deploy-ci.sh" --repository-url https://github.com/JeanKoerich/comando.git --dry-run > "$tmp/stdout" 2> "$tmp/stderr" || code=$?
  if [[ $code != "$expected_code" ]] || ! grep -Fq "$expected_log" "$tmp/stderr" ||
      { [[ $code == 0 ]] && [[ $(cat "$tmp/stdout") != "$SHA" ]]; } ||
      { [[ $code != 0 ]] && [[ -s $tmp/stdout ]]; }; then
    printf 'FAIL %s (exit=%s)\n' "$scenario" "$code" >&2
    cat "$tmp/stderr" >&2
    exit 1
  fi
  printf 'PASS %s\n' "$scenario"
}

check approved 0 "result=eligible sha=$SHA run_id=2 run_attempt=1"
check rejected 10 "result=ci_rejected sha=$SHA run_id=2 run_attempt=2"
check pending 10 "result=ci_pending sha=$SHA run_id=2 run_attempt=2"
check wrong_sha 10 'result=sha_mismatch'
check no_run 10 'result=no_run'
check wrong_repo 10 'result=run_mismatch'
check wrong_branch 10 'result=run_mismatch'
check wrong_event 10 'result=run_mismatch'
check wrong_workflow 10 'result=run_mismatch'
check head_changed 10 'result=head_changed'
check http_error 20 'result=http_error stage=ci http=500'
check forbidden 20 'result=api_restricted stage=ci http=403'
check rate_limit 20 'http=429 remaining=0 reset_epoch=1800000000 retry_after_seconds=900'
check bad_json 20 'result=head_unavailable'
check timeout 20 'result=transport_error stage=head curl_exit=28'
