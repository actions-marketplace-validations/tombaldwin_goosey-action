#!/usr/bin/env bash
# The assertions are single-quoted strings run by eval: they expand when they run, not when they are
# written, and shellcheck cannot see them read $code, $ours or $theirs.
# shellcheck disable=SC2016,SC2034
# The gate's rules against recorded API answers. No network, no dependencies beyond bash and jq.
#   test/run.sh
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$root/test/fixtures"
export FIXTURES
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0

ok() { pass=$((pass + 1)); echo "ok    $1"; }
no() { fail=$((fail + 1)); echo "FAIL  $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if eval "$2"; then ok "$1"; else no "$1" "$2"; fi; }

# judge <fixture> [http] [levels] -> one page result
judge() {
  local lv="${3:-}"; [ -n "$lv" ] || lv='{}'
  jq -cRs --arg url "https://www.example.org/${1%.json}" --arg http "${2:-200}" --argjson levels "$lv" \
    -f "$root/lib/judge.jq" <"$FIXTURES/$1"
}
# verdict <results-file> [fail-on] [fail-unchecked] [levels] -> the report object
verdict() {
  local lv="${4:-}"; [ -n "$lv" ] || lv='{}'
  jq -s --arg failOn "${2:-error}" --arg failUnchecked "${3:-true}" --argjson plan null \
    --argjson levels "$lv" -f "$root/lib/report.jq" "$1"
}
# gate <fixture> <http> <fail-on> <fail-unchecked> <levels> -> "fail" or "pass"
gate() {
  judge "$1" "$2" "$5" >"$tmp/r.ndjson"
  verdict "$tmp/r.ndjson" "$3" "$4" "$5" >"$tmp/v.json"
  jq -r 'if .failed then "fail" else "pass" end' "$tmp/v.json"
}
v() { jq -r "$1" "$tmp/v.json"; }

echo "# the cases"

check "all pass: passes" '[ "$(gate pass.json 200 error true "{}")" = pass ] && [ "$(v .errors)" = 0 ] && [ "$(v .failedPages)" = 0 ]'
check "all pass: passes at fail-on warn too" '[ "$(gate pass.json 200 warn true "{}")" = pass ]'
check "all pass: no annotations" '[ "$(v ".annotations | length")" = 0 ]'

check "an error: fails" '[ "$(gate error.json 200 error true "{}")" = fail ] && [ "$(v .errors)" = 1 ] && [ "$(v .warnings)" = 2 ] && [ "$(v .failedPages)" = 1 ]'
check "an error: one ::error:: and two ::warning:: annotations" \
  '[ "$(v "[.annotations[] | select(startswith(\"::error \"))] | length")" = 1 ] && [ "$(v "[.annotations[] | select(startswith(\"::warning \"))] | length")" = 2 ]'
check "an error: the annotation names the id and escapes the colon in its title" \
  'v ".annotations[0]" | grep -q "^::error title=goosey%3A image.missing::https://www.example.org/error: No og:image"'
check "an error: the summary links the id to its reference page" \
  'v .summary | grep -qF "[\`image.missing\`](https://www.poly.io/social-card-preview/api/checks/image.missing/)"'
check "an error: the summary has one line per page with its worst level" \
  'v .summary | grep -qF "| <https://www.example.org/error> | Error | 1 error, 2 warnings, 1 tip |"'
check "an error: a tip is listed but not annotated" \
  'v .summary | grep -qF "site-name.missing" && ! v ".annotations[]" | grep -q site-name'

check "a warn: passes at fail-on error" '[ "$(gate warn.json 200 error true "{}")" = pass ] && [ "$(v .warnings)" = 1 ]'
check "a warn: fails at fail-on warn" '[ "$(gate warn.json 200 warn true "{}")" = fail ] && [ "$(v .failedPages)" = 1 ]'
check "a tip alone never fails, even at fail-on warn" \
  '[ "$(gate warn.json 200 warn true "{\"description.missing\":\"tip\"}")" = pass ]'

check "a level raises a warn to error: fails" \
  '[ "$(gate warn.json 200 error true "{\"description.missing\":\"error\"}")" = fail ] && [ "$(v .errors)" = 1 ]'
check "a raised level is shown as yours in the summary" \
  'v .summary | grep -qF "_(warning by default; your levels set error)_"'

check "a level lowers an error to ignore: passes" \
  '[ "$(gate error.json 200 error true "{\"image.missing\":\"ignore\"}")" = pass ] && [ "$(v .errors)" = 0 ]'
check "an ignored check is neither listed nor annotated, only counted" \
  '! v .summary | grep -qF "[\`image.missing\`]" && v .summary | grep -qF "Levels in force: \`{\"image.missing\":\"ignore\"}\`" && ! v ".annotations[]" | grep -q image.missing && v .summary | grep -qF "1 ignored"'
check "a level lowers an error to warn: passes at error, fails at warn" \
  '[ "$(gate error.json 200 error true "{\"image.missing\":\"warn\"}")" = pass ] && [ "$(gate error.json 200 warn true "{\"image.missing\":\"warn\"}")" = fail ]'

check "re-levelling a pass to error: it stays a pass" \
  '[ "$(gate pass.json 200 error true "{\"title.ok\":\"error\"}")" = pass ] && [ "$(v .errors)" = 0 ]'
check "re-levelling a pass to ignore: it stays a pass and is not counted as ignored" \
  '[ "$(judge pass.json 200 "{\"title.ok\":\"ignore\"}" | jq -r "[.passed, .ignored] | @tsv")" = "$(printf "4\t0")" ]'

check "ok:false fails by default" \
  '[ "$(gate unreachable.json 200 error true "{}")" = fail ] && [ "$(v .failedPages)" = 1 ] && v ".annotations[0]" | grep -q "^::error title=goosey%3A not checked::.*host_not_found"'
check "ok:false passes with fail-on-unreachable false, as a warning" \
  '[ "$(gate unreachable.json 200 error false "{}")" = pass ] && v ".annotations[0]" | grep -q "^::warning "'
check "ok:false is reported as not checked, not as a pass" \
  'v .summary | grep -qF "| Could not check | \`host_not_found\`"'

check "a 429 body is the API, not the page" \
  '[ "$(judge ratelimit.json 429 | jq -r "[.status, .code] | @tsv")" = "$(printf "api\thttp_429")" ]'
check "a 429 fails by default and passes with fail-on-unreachable false" \
  '[ "$(gate ratelimit.json 429 error true "{}")" = fail ] && [ "$(gate ratelimit.json 429 error false "{}")" = pass ]'
check "quota_exceeded is its own outcome" '[ "$(judge quota.json | jq -r .status)" = quota ]'
check "a bad key fails even with fail-on-unreachable false" \
  '[ "$(judge badkey.json | jq -r .status)" = auth ] && [ "$(gate badkey.json 200 error false "{}")" = fail ]'
check "a body that is not JSON is the API, not the page" \
  '[ "$(printf "<html>502</html>" | jq -cRs --arg url x --arg http 502 --argjson levels "{}" -f "$root/lib/judge.jq" | jq -r .status)" = api ]'

check "Markdown in a message is escaped in the summary" \
  '[ "$(jq -rn "\"a [link](x) *b* | c\" | $(sed -n "/^def md/p" "$root/lib/report.jq") md")" = "a \[link\](x) \*b\* \| c" ]'

# ---- the same answers as goosey's own gate ------------------------------------
# goosey's "Gate a build on this" (ciGate in goosey.js) emits a curl | jq line. Its filter is
# copied here verbatim, fed the same answers and the same levels, and must agree with this
# action at fail-on error on every one: that is what "the same semantics" means, checked.
echo "# agreement with goosey's ciGate"
cigate='.ok and ([.checks[]
       | select(.level == "error" or (.level != "ok" and (.id as $i | $up | index($i))))
       | select(.id as $i | $down | index($i) | not)
     ] | length == 0)'
# quota.json is left out on purpose: goosey's pasted gate fails a build on a spent allowance, and
# the action only warns (see the quota tests below), because it says nothing about the change.
for fx in pass.json error.json warn.json unreachable.json badkey.json; do
  for lv in '{}' '{"description.missing":"error"}' '{"image.missing":"ignore"}' '{"image.missing":"warn"}' \
            '{"title.ok":"error"}' '{"type.missing":"error","image.missing":"tip"}' '{"site-name.missing":"error"}'; do
    # ciGate's two lists, built as it builds them: the ids passed on the page are left out, then
    # error goes up and every other level goes down.
    passed="$(jq -c '[(.checks // [])[] | select((.level // "ok") == "ok") | .id]' "$FIXTURES/$fx")"
    up="$(jq -c --argjson p "$passed" '[to_entries | sort_by(.key)[] | select(.key as $k | $p | index($k) | not) | select(.value == "error") | .key]' <<<"$lv")"
    down="$(jq -c --argjson p "$passed" '[to_entries | sort_by(.key)[] | select(.key as $k | $p | index($k) | not) | select(.value != "error") | .key]' <<<"$lv")"
    if jq -e --argjson up "$up" --argjson down "$down" "$cigate" "$FIXTURES/$fx" >/dev/null 2>&1; then theirs=pass; else theirs=fail; fi
    ours="$(gate "$fx" 200 error true "$lv")"
    check "ciGate agrees: $fx $lv ($theirs)" '[ "$ours" = "$theirs" ]'
  done
done

# The Marketplace refuses a listing whose description is 125 characters or more. The first release was
# turned away for exactly that, which is some irony for a tool that checks description lengths.
desc="$(sed -n 's/^description: //p' "$root/action.yml")"
check "the action's description fits the Marketplace (under 125 characters)" '[ ${#desc} -gt 0 ] && [ ${#desc} -lt 125 ]'

# ---- the whole action, with curl faked -----------------------------------------
echo "# end to end"
mkdir -p "$tmp/bin"
cp "$root/test/fake-curl" "$tmp/bin/curl"
chmod +x "$tmp/bin/curl"
export FAKE_MAP="$tmp/map" FAKE_LOG="$tmp/log" GOOSEY_PACE=0 GOOSEY_RETRY_WAIT=0
tab="$(printf '\t')"
cat >"$FAKE_MAP" <<EOF
https://a.example/${tab}200${tab}pass.json
https://b.example/${tab}200${tab}error.json
https://c.example/${tab}200${tab}warn.json
https://gone.example/${tab}200${tab}unreachable.json
https://spent.example/${tab}200${tab}quota.json
https://busy.example/${tab}429${tab}ratelimit.json
https://www.example.org${tab}200${tab}plan.json
https://nomap.example${tab}200${tab}noplan.json
https://www.example.org/${tab}200${tab}pass.json
https://www.example.org/blog/post${tab}200${tab}warn.json
EOF
# action <exit-var> [NAME=value ...] -> runs lib/main.sh with those inputs
action() {
  : >"$FAKE_LOG"; : >"$tmp/summary"; : >"$tmp/output"
  env PATH="$tmp/bin:$PATH" GITHUB_STEP_SUMMARY="$tmp/summary" GITHUB_OUTPUT="$tmp/output" "$@" \
    "$root/lib/main.sh" >"$tmp/stdout" 2>&1
}
calls() { wc -l <"$FAKE_LOG" | tr -d ' '; }
out() { grep "^$1=" "$tmp/output" | cut -d= -f2; }

action INPUT_URLS="$(printf 'https://a.example/\n\n  https://c.example/  \n# a comment\nhttps://a.example/')"; code=$?
check "two clean pages pass, blank and comment lines skipped, the duplicate checked once" \
  '[ $code = 0 ] && [ "$(calls)" = 2 ] && [ "$(out pages)" = 2 ] && [ "$(out failed-pages)" = 0 ] && [ "$(out warnings)" = 1 ]'
check "the summary is written" 'grep -q "^## goosey: social cards" "$tmp/summary" && grep -q "^\*\*Passed.\*\*" "$tmp/summary"'

action INPUT_URLS="$(printf 'https://a.example/\nhttps://b.example/')"; code=$?
check "an error fails the step and sets the outputs" \
  '[ $code = 1 ] && [ "$(out errors)" = 1 ] && [ "$(out failed-pages)" = 1 ] && grep -q "^::error title=goosey%3A image.missing::" "$tmp/stdout"'

action INPUT_URLS="https://b.example/" INPUT_LEVELS='{"image.missing":"ignore","type.missing":"nonsense"}'; code=$?
check "levels apply end to end, and a value that is not a level is named and dropped" \
  '[ $code = 0 ] && grep -q "type.missing = \"nonsense\" is not a level" "$tmp/stdout"'

action INPUT_URLS="https://c.example/" INPUT_FAIL_ON=warn; code=$?
check "fail-on warn fails on a warning" '[ $code = 1 ]'

action INPUT_URLS="$(printf 'https://a.example/\nhttps://spent.example/\nhttps://b.example/\nhttps://c.example/')"; code=$?
check "quota: the run stops at the first refusal and asks nothing more" '[ "$(calls)" = 2 ]'
check "quota: a spent allowance warns and does not fail the step" '[ $code = 0 ] && grep -q "^::warning" "$tmp/stdout" && ! grep -q "^::error" "$tmp/stdout"'
check "quota: the pages after it are listed as not checked, with one message for all of them" \
  '[ "$(out pages)" = 4 ] && [ "$(grep -c "Not checked" "$tmp/summary")" = 2 ] && [ "$(grep -c "run stopped" "$tmp/stdout")" = 1 ]'

action INPUT_URLS="$(printf 'https://busy.example/\nhttps://a.example/\nhttps://b.example/')"; code=$?
check "429: one retry, then the run stops" '[ $code = 1 ] && [ "$(calls)" = 2 ] && [ "$(sort -u "$FAKE_LOG")" = "https://busy.example/" ]'
action INPUT_URLS="https://busy.example/" INPUT_FAIL_ON_UNREACHABLE=false; code=$?
check "429 with fail-on-unreachable false: a warning, not a failure" '[ $code = 0 ] && grep -q "^::warning " "$tmp/stdout"'

action INPUT_URLS="https://gone.example/" INPUT_FAIL_ON_UNREACHABLE=false; code=$?
check "ok:false with fail-on-unreachable false passes" '[ $code = 0 ] && [ "$(out failed-pages)" = 0 ]'

action INPUT_SITE="https://www.example.org" INPUT_URLS="https://www.example.org/"; code=$?
check "site: plans once, then checks the plan's pages, the one also in urls once" \
  '[ $code = 0 ] && [ "$(calls)" = 3 ] && [ "$(head -1 "$FAKE_LOG")" = "https://www.example.org" ] && [ "$(out pages)" = 2 ]'
check "site: the summary says how much of the site went unchecked" \
  'grep -qF "2 pages chosen from 312 URLs in the sitemap, 2 templates found. 310 pages were not checked." "$tmp/summary"'

action INPUT_SITE="https://nomap.example" INPUT_URLS="https://a.example/"; code=$?
check "site with no sitemap: fails, says why, still checks the urls" \
  '[ $code = 1 ] && [ "$(calls)" = 2 ] && grep -q "no_sitemap" "$tmp/summary" && [ "$(out pages)" = 1 ] && [ "$(out failed-pages)" = 0 ]'

action INPUT_URLS="https://a.example/" INPUT_KEY="sekrit-key"; code=$?
check "the key goes in the x-og-key header, and is masked" \
  '[ $code = 0 ] && grep -qF "[x-og-key: sekrit-key]" "$FAKE_LOG" && grep -qF "::add-mask::sekrit-key" "$tmp/stdout"'

action INPUT_URLS="https://a.example/" INPUT_CONTACT="  ops@example.com "; code=$?
check "a contact goes in the x-og-contact header, trimmed" \
  '[ $code = 0 ] && grep -qF "[x-og-contact: ops@example.com]" "$FAKE_LOG"'
action INPUT_URLS="https://a.example/"; code=$?
check "no contact, no header" '! grep -q "x-og-contact" "$FAKE_LOG"'

action; code=$?
check "no urls and no site is refused" '[ $code = 1 ] && grep -q "Give urls, site, or both" "$tmp/stdout" && [ "$(calls)" = 0 ]'
action INPUT_URLS="https://a.example/" INPUT_LEVELS='["image.webp"]'; code=$?
check "levels that are not an object are refused before any call" '[ $code = 1 ] && [ "$(calls)" = 0 ]'
action INPUT_URLS="https://a.example/" INPUT_FAIL_ON=tip; code=$?
check "fail-on other than error or warn is refused" '[ $code = 1 ] && [ "$(calls)" = 0 ]'
action INPUT_SITE="https://www.example.org" INPUT_CAP=500; code=$?
check "a cap outside 1 to 100 is refused" '[ $code = 1 ] && [ "$(calls)" = 0 ]'

echo
echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
