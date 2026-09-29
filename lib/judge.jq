# One API answer in, one page result out. No network, so every rule here is testable offline.
#
# Input: the raw response body (run with jq -R -s, because a gateway 429 or a dropped connection
# is not always JSON). Arguments:
#   $url     the page that was asked about
#   $http    the HTTP status curl saw, as a string ("000" when the API could not be reached)
#   $levels  your overrides, {"image.webp":"ignore","author.missing":"error"}, already cleaned
#
# The levels rule is goosey's levelOf: a pass stays a pass whatever a level says, an id you have
# set takes your level, and anything else keeps the level the API gave it.

def rank: {"ignore": -1, "ok": 0, "tip": 1, "warn": 2, "error": 3}[.] // 0;

(try fromjson catch null) as $d
| {url: $url, http: ($http | tonumber? // 0)}
+ if ($d | type) == "object" and ($d | has("ok")) and $http == "200" then
    if $d.ok != true then
      # The API answered and could not check the page. `ok` is tested before `checks` is touched:
      # a refusal carries no checks at all.
      { status: (if $d.code == "quota_exceeded" then "quota"
                 elif ($d.code | IN("bad_key", "unknown_key", "revoked_key")) then "auth"
                 else "unreachable" end),
        code: ($d.code // "unknown"),
        error: ($d.error // "The page could not be checked."),
        resetSeconds: $d.resetSeconds }
    else
      [ ($d.checks // [])[] | . as $c | ($c.level // "ok") as $api | ($c.id // "") as $id
        | { id: $id, apiLevel: $api, message: ($c.message // ""),
            level: (if $api == "ok" then "ok"
                    elif ($levels | has($id)) then $levels[$id]
                    else $api end) } ] as $all
      | { status: "checked",
          finalUrl: ($d.finalUrl // $url),
          worst: ([ $all[] | .level | select(. != "ignore") ] | max_by(rank) // "ok"),
          findings: ([ $all[] | select(.level != "ok" and .level != "ignore") ] | sort_by(-(.level | rank))),
          ignored: ([ $all[] | select(.level == "ignore") ] | length),
          passed: ([ $all[] | select(.level == "ok") ] | length) }
    end
  else
    # Not an answer about the page: the gateway's burst limit (429), the compute layer under load
    # (5xx), or no connection at all. None of these carries an `ok` field.
    { status: "api",
      code: (if $http == "000" then "no_connection" else "http_" + $http end),
      error: (if $http == "429" then "The API's shared burst limit refused the call (HTTP 429)."
              elif $http == "000" then "The API could not be reached."
              else "The API answered HTTP \($http) without a result" + (($d | objects | .message | strings | ": " + .) // "") + "." end) }
  end
