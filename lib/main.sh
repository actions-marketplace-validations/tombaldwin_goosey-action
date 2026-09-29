#!/usr/bin/env bash
# The action itself: read the inputs, ask the API for a site plan if one was wanted, check each
# page, then hand every result to report.jq for the verdict. The rules live in judge.jq and
# report.jq, which never touch the network; this file is the plumbing between them and curl.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="${GOOSEY_API:-https://api.poly.io/og}"
PACE="${GOOSEY_PACE:-0.4}"              # the API's burst limit is shared by every caller
RETRY_WAIT="${GOOSEY_RETRY_WAIT:-5}"    # one retry after a 429 or 5xx, then stop

urls_in="${INPUT_URLS:-}"
site="${INPUT_SITE:-}"
cap="${INPUT_CAP:-40}"
fail_on="${INPUT_FAIL_ON:-error}"
levels_in="${INPUT_LEVELS:-}"
key="${INPUT_KEY:-}"
contact="${INPUT_CONTACT:-}"
fail_unchecked="${INPUT_FAIL_ON_UNREACHABLE:-true}"

die() { echo "::error title=goosey::$1"; exit 1; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

command -v jq >/dev/null || die "jq is not installed on this runner."
command -v curl >/dev/null || die "curl is not installed on this runner."

# ---- inputs ----------------------------------------------------------------
site="$(trim "$site")"
fail_on="$(trim "$fail_on")"
cap="$(trim "$cap")"
fail_unchecked="$(trim "$fail_unchecked")"
contact="$(trim "$contact")"
case "$fail_on" in error|warn) ;; *) die "fail-on must be error or warn, not '$fail_on'." ;; esac
case "$fail_unchecked" in true|false) ;; *) die "fail-on-unreachable must be true or false, not '$fail_unchecked'." ;; esac
if ! [[ "$cap" =~ ^[0-9]+$ ]] || [ "$cap" -lt 1 ] || [ "$cap" -gt 100 ]; then
  die "cap must be a whole number from 1 to 100, not '$cap'."
fi
[ -n "$key" ] && echo "::add-mask::$key"

# Levels: the shape goosey stores. Only ignore, tip, warn and error are levels, as in goosey,
# which drops anything else when it loads; here the dropped ones are named, because in CI a typo
# nobody hears about is a gate that quietly means something else.
if [ -z "$(trim "$levels_in")" ]; then levels_in='{}'; fi
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$levels_in" \
  || die "levels must be a JSON object of check id to level, such as {\"image.webp\":\"ignore\"}."
levels="$(jq -c 'with_entries(select(.value | IN("ignore", "tip", "warn", "error")))' <<<"$levels_in")"
while IFS= read -r bad; do
  [ -n "$bad" ] && echo "::warning title=goosey::levels: $bad is not a level (use ignore, tip, warn or error), so the API's level stands."
done < <(jq -r 'to_entries[] | select(.value | IN("ignore", "tip", "warn", "error") | not) | "\(.key) = \(.value | tojson)"' <<<"$levels_in")

urls=()
while IFS= read -r line; do
  line="$(trim "$line")"
  [ -z "$line" ] || [ "${line:0:1}" = "#" ] || urls+=("$line")
done <<<"$urls_in"
[ ${#urls[@]} -gt 0 ] || [ -n "$site" ] || die "Give urls, site, or both."

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/goosey.XXXXXX")"
trap 'rm -rf "$work"' EXIT
results="$work/results.ndjson"
: >"$results"
plan='null'
stopped=''    # set to the code that ended the run early

# ---- the API ---------------------------------------------------------------
# One call. The key goes in a header, never the query string, and is never echoed.
call() {   # call <param> <value> [extra --data-urlencode pairs...]
  local args=(-sS -G --max-time 60 -o "$work/body" -w '%{http_code}' --data-urlencode "$1=$2")
  shift 2
  local p; for p in "$@"; do args+=(--data-urlencode "$p"); done
  [ -n "$key" ] && args+=(-H "x-og-key: $key")
  [ -n "$contact" ] && args+=(-H "x-og-contact: $contact")
  : >"$work/body"
  http="$(curl "${args[@]}" "$API" 2>"$work/curl.err")" || http=000
}
judge() {  # judge <url> -> one result line from the body just fetched
  jq -cRs --arg url "$1" --arg http "$http" --argjson levels "$levels" -f "$here/judge.jq" <"$work/body"
}
# Fetch and judge, retrying ONCE when the API itself was the problem (a 429 from the shared burst
# limit, a 5xx, no connection). A second failure stops the run: more attempts would only add to
# the load that caused the first.
fetch() {  # fetch <param> <value> [extra...] -> sets $result
  local tried=0
  while :; do
    call "$@"
    result="$(judge "$2")"
    [ "$(jq -r .status <<<"$result")" = api ] && [ $tried -eq 0 ] || return 0
    tried=1
    echo "goosey: $(jq -r .error <<<"$result") Trying once more in ${RETRY_WAIT}s."
    sleep "$RETRY_WAIT"
  done
}
# The three outcomes that mean every later call would be refused the same way.
stops() { case "$(jq -r .status <<<"$1")" in quota|auth|api) return 0 ;; *) return 1 ;; esac; }

# ---- the site plan ---------------------------------------------------------
if [ -n "$site" ]; then
  fetch site "$site" "cap=$cap"
  if [ "$http" = 200 ] && jq -e '.ok == true and (.plan | type == "array" and length > 0)' "$work/body" >/dev/null 2>&1; then
    plan="$(jq -c '{site, checking: (.checking // (.plan | length)), urlsFound: (.urlsFound // (.plan | length)),
      shapesTotal: (.shapesTotal // 0), shapesSkipped: (.shapesSkipped // 0), notChecked: (.notChecked // 0)}' "$work/body")"
    while IFS= read -r u; do urls+=("$u"); done < <(jq -r '.plan[] | strings' "$work/body")
    echo "goosey: site plan for $(jq -r .site <<<"$plan"): $(jq -r .checking <<<"$plan") pages from $(jq -r .urlsFound <<<"$plan") in the sitemap."
  else
    [ "$(jq -r .status <<<"$result")" = checked ] \
      && result="$(jq -c '. + {status: "unreachable", code: "empty_plan", error: "The API returned a plan with no pages in it."}' <<<"$result")"
    jq -c '. + {kind: "site"}' <<<"$result" >>"$results"
    echo "goosey: could not plan $site: $(jq -r .error <<<"$result")"
    stops "$result" && stopped="$(jq -r .code <<<"$result")"
  fi
  [ ${#urls[@]} -gt 0 ] && sleep "$PACE"
fi

# Each page once, in the order given: a URL in both lists would otherwise spend two checks.
if [ ${#urls[@]} -gt 0 ]; then
  deduped=()
  while IFS= read -r u; do deduped+=("$u"); done < <(printf '%s\n' "${urls[@]}" | awk '!seen[$0]++')
  urls=("${deduped[@]}")
fi

# ---- the pages -------------------------------------------------------------
n=0
for u in ${urls[@]+"${urls[@]}"}; do
  if [ -n "$stopped" ]; then
    jq -cn --arg url "$u" --arg code "$stopped" '{url: $url, status: "skipped", code: $code, error: "Not checked: the run stopped early."}' >>"$results"
    continue
  fi
  [ $n -gt 0 ] && sleep "$PACE"
  n=$((n + 1))
  fetch url "$u"
  echo "$result" >>"$results"
  case "$(jq -r .status <<<"$result")" in
    checked) echo "goosey: $(jq -r '.worst | ascii_upcase' <<<"$result")  $u" ;;
    *) echo "goosey: NOT CHECKED  $u: $(jq -r .error <<<"$result")" ;;
  esac
  if stops "$result"; then stopped="$(jq -r .code <<<"$result")"; fi
done

# ---- the verdict -----------------------------------------------------------
verdict="$(jq -s --arg failOn "$fail_on" --arg failUnchecked "$fail_unchecked" --argjson plan "$plan" \
  --argjson levels "$levels" -f "$here/report.jq" "$results")"

jq -r '.annotations[]' <<<"$verdict"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  jq -r .summary <<<"$verdict" >>"$GITHUB_STEP_SUMMARY"
else
  echo; jq -r .summary <<<"$verdict"
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  jq -r '"errors=\(.errors)", "warnings=\(.warnings)", "pages=\(.pages)", "failed-pages=\(.failedPages)"' <<<"$verdict" >>"$GITHUB_OUTPUT"
fi
[ "$(jq -r .failed <<<"$verdict")" = false ]
