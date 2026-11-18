#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} != --repository-url || ! ${2:-} =~ ^https://github\.com/([A-Za-z0-9-]+/[A-Za-z0-9_.-]+)$ ]]; then
  printf 'Informe --repository-url com a URL HTTPS do GitHub definida no Terraform.\n' >&2
  exit 2
fi
repository=${BASH_REMATCH[1]%.git}
shift 2
api="https://api.github.com/repos/$repository"
dry_run=false
case "${1:-}" in
  --dry-run) dry_run=true; shift ;;
esac
if (( $# )); then
  printf 'Uso: bash %s --repository-url URL [--dry-run]\n' "$0" >&2
  exit 2
fi

audit() {
  printf '%s repository=%s branch=main dry_run=%s %s\n' \
    "$(date -u +%FT%TZ)" "$repository" "$dry_run" "$*" >&2
}

python=python3
if ! "$python" --version >/dev/null 2>&1; then
  python=python
fi
if ! "$python" -c 'import sys; sys.exit(sys.version_info.major != 3)' >/dev/null 2>&1; then
  audit 'result=missing_dependency dependency=python3'
  exit 20
fi

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

numeric_header() {
  awk -v key="$1" '
    tolower($1) == key && $2 ~ /^[0-9]+\r?$/ {
      sub(/\r$/, "", $2)
      value = $2
    }
    END { print (value == "" ? "unknown" : value) }
  ' "$tmp/headers"
}

request() {
  local stage=$1 url=$2 status rc
  if status=$(curl -q --silent --connect-timeout 5 --max-time 20 \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --dump-header "$tmp/headers" --output "$tmp/body" --write-out '%{http_code}' "$url"); then
    case "$status" in
      200) return ;;
      403|429)
        audit "result=api_restricted stage=$stage http=$status remaining=$(numeric_header x-ratelimit-remaining:) reset_epoch=$(numeric_header x-ratelimit-reset:) retry_after_seconds=$(numeric_header retry-after:)"
        ;;
      [1-5][0-9][0-9]) audit "result=http_error stage=$stage http=$status" ;;
      *) audit "result=invalid_http_status stage=$stage" ;;
    esac
  else
    rc=$?
    audit "result=transport_error stage=$stage curl_exit=$rc"
  fi
  exit 20
}

read_response() {
  "$python" - "$tmp/body" "$@" 2>/dev/null <<'PY'
import json
import re
import sys

filename, stage, repository, *args = sys.argv[1:]
with open(filename, encoding="utf-8") as response:
    data = json.load(response)

if stage == "head":
    sha = data["object"]["sha"]
    if (data["ref"] != "refs/heads/main" or data["object"]["type"] != "commit"
            or not re.fullmatch(r"[0-9a-f]{40}", sha)):
        sys.exit(1)
    print(sha)
    sys.exit(0)

runs = data["workflow_runs"]
# Reject incomplete listings so a run outside the response cannot be missed.
if (not isinstance(runs, list) or type(data["total_count"]) is not int
        or data["total_count"] != len(runs)):
    sys.exit(1)
if not runs:
    print("no_run")
    sys.exit(0)

if any(type(item["run_number"]) is not int or item["run_number"] < 1 for item in runs):
    sys.exit(1)
if len({item["run_number"] for item in runs}) != len(runs):
    sys.exit(1)
run = max(runs, key=lambda item: item["run_number"])
sha, = args
if (run["repository"]["full_name"] != repository
        or run["head_repository"]["full_name"] != repository
        or run["head_branch"] != "main" or run["event"] != "push"
        or run["path"] not in (".github/workflows/ci.yml", ".github/workflows/ci.yml@main",
                               ".github/workflows/ci.yml@refs/heads/main")):
    print("run_mismatch")
    sys.exit(0)
if run["head_sha"] != sha:
    print("sha_mismatch")
    sys.exit(0)
if any(type(run[field]) is not int or run[field] < 1
       for field in ("id", "run_attempt")):
    sys.exit(1)
status, conclusion = run["status"], run["conclusion"]
if status == "completed" and isinstance(conclusion, str) and conclusion:
    result = "approved" if conclusion == "success" else "ci_rejected"
elif status in ("queued", "in_progress", "requested", "waiting", "pending") and conclusion is None:
    result = "ci_pending"
else:
    sys.exit(1)
print(result, run["id"], run["run_attempt"])
PY
}

read_head() {
  request head "$api/git/ref/heads/main"
  read_response head "$repository"
}

if ! sha=$(read_head); then
  audit 'result=head_unavailable'
  exit 20
fi

request ci "$api/actions/workflows/ci.yml/runs?branch=main&event=push&head_sha=$sha&per_page=100"
if ! decision=$(read_response ci "$repository" "$sha"); then
  audit "result=invalid_response stage=ci sha=$sha"
  exit 20
fi
read -r result run_id run_attempt <<< "$decision"
audit "result=$result sha=$sha run_id=${run_id:-none} run_attempt=${run_attempt:-none}"
[[ $result == approved ]] || exit 10

if ! current_sha=$(read_head); then
  audit 'result=head_unavailable stage=recheck'
  exit 20
fi
if [[ $current_sha != "$sha" ]]; then
  audit "result=head_changed sha=$sha current_sha=$current_sha"
  exit 10
fi
audit "result=eligible sha=$sha run_id=$run_id run_attempt=$run_attempt"
printf '%s\n' "$sha"
