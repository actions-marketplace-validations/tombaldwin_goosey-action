# Every page result in (jq -s over the lines judge.jq wrote), one verdict out:
#   { failed, pages, errors, warnings, failedPages, annotations: [lines], summary: "markdown" }
# Arguments:
#   $failOn           "error" or "warn"
#   $failUnchecked    "true" or "false": whether a page the API could not check fails the step
#   $plan             the site plan's numbers, or null when no site was asked for
#   $levels           the overrides in force, shown in the summary so a reader knows why

def rank: {"ignore": -1, "ok": 0, "tip": 1, "warn": 2, "error": 3}[.] // 0;
def word: {"error": "Error", "warn": "Warning", "tip": "Tip", "ok": "Pass", "ignore": "Ignored"}[.] // .;
def plural($n; $one; $many): "\($n) " + (if $n == 1 then $one else $many end);
def ref: "https://www.poly.io/social-card-preview/api/checks/\(@uri)/";

# Annotation text: GitHub reads %, CR and LF as escapes in the message, and : and , as well in a
# property such as title=.
def esc: gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A");
def escp: esc | gsub(":"; "%3A") | gsub(","; "%2C");
# Page-supplied text must not become Markdown in somebody's job summary: the characters that start
# a link, code or HTML are backslashed, as goosey's own report does, and | so a table cell holds.
def md: gsub("(?<c>[\\\\`*_\\[\\]<>|])"; "\\\(.c)");
# An autolink, so an address with _ or * links to itself. Nothing inside <...> is read as
# Markdown; only what could close it, or break the line, is encoded.
def link: "<" + (gsub(" "; "%20") | gsub("<"; "%3C") | gsub(">"; "%3E") | gsub("\\|"; "%7C")) + ">";

($failUnchecked == "true") as $strict
| ($failOn | rank) as $bar
| map(. + { unchecked: (.status != "checked") }) as $all
| [ $all[] | select(.kind != "site") ] as $pages
| [ $all[] | select(.kind == "site") ] as $site
| def fails:
    if .status == "checked" then any(.findings[]; (.level | rank) >= $bar)
    elif .status == "auth" then true            # a bad key fails whatever: it is your configuration
    # A spent allowance says nothing about the change under review, so it warns rather than fails,
    # as the API's own docs advise; so do the pages a run stopped by it never reached.
    elif .status == "quota" or (.status == "skipped" and .code == "quota_exceeded") then false
    else $strict end;
  ([ $pages[] | select(.status == "checked") | .findings[] ]) as $found
| ([ $pages[] | select(fails) ] | length) as $failedPages
| (($failedPages > 0) or any($site[]; fails)) as $failed
| ([ $pages[] | select(.status == "skipped") ] | length) as $skipped
| {
    failed: $failed,
    pages: ($pages | length),
    errors: ([ $found[] | select(.level == "error") ] | length),
    warnings: ([ $found[] | select(.level == "warn") ] | length),
    failedPages: $failedPages,

    annotations: [
      ( $pages[] | select(.status == "checked") | .url as $u | .findings[]
        | select(.level == "error" or .level == "warn")
        | "::\(if .level == "error" then "error" else "warning" end) title=\("goosey: " + .id | escp)::\("\($u): \(.message) \(.id | ref)" | esc)" ),
      # Each refusal once. The pages a stopped run never reached share one line, below.
      ( $all[] | select(.unchecked and .status != "skipped")
        | "::\(if fails then "error" else "warning" end) title=\("goosey: " + (if .kind == "site" then "site not planned" else "not checked" end) | escp)::\("\(.url): \(.error) (\(.code))" | esc)" ),
      ( if $skipped > 0 then
          "::\(if any($pages[]; .status == "skipped" and fails) then "error" else "warning" end) title=goosey%3A run stopped::\("\(plural($skipped; "page was"; "pages were")) not checked because the run stopped early; see the first refusal above." | esc)"
        else empty end )
    ],

    summary: ([
      "## goosey: social cards",
      "",
      ( if $failed then "**Failed.** " else "**Passed.** " end
        + plural($pages | length; "page"; "pages")
        + ", " + plural([ $found[] | select(.level == "error") ] | length; "error"; "errors")
        + ", " + plural([ $found[] | select(.level == "warn") ] | length; "warning"; "warnings")
        + ( ([ $pages[] | select(.unchecked) ] | length) as $n | if $n > 0 then ", \($n) not checked" else "" end )
        + ". Fails at: " + (if $failOn == "warn" then "warning or worse" else "error" end)
        + (if $strict then "; a page that could not be checked fails too." else "; a page that could not be checked does not fail the step." end) ),
      "",
      ( $plan | select(. != null)
        | "Site plan for \(.site | md): \(plural(.checking; "page"; "pages")) chosen from \(plural(.urlsFound; "URL"; "URLs")) in the sitemap, \(plural(.shapesTotal; "template"; "templates")) found"
          + (if (.shapesSkipped // 0) > 0 then ", \(.shapesSkipped) not sampled" else "" end)
          + ". \(plural(.notChecked; "page was"; "pages were")) not checked.",
        "" ),
      ( $site[] | "Site plan for \(.url | link) failed: \(.error | md) (`\(.code)`)", "" ),
      ( if ($pages | length) > 0 then
          "| Page | Worst | Findings |", "|---|---|---|",
          ( $pages | sort_by(if .unchecked then -2.5 else -(.worst | rank) end)[]
            | "| \(.url | link) | "
              + ( if .status == "checked" then (.worst | word)
                  elif .status == "skipped" then "Not checked"
                  else "Could not check" end )
              + " | "
              + ( if .status == "checked" then
                    ( [ (.findings | map(select(.level == "error")) | length) as $n | select($n > 0) | plural($n; "error"; "errors") ]
                    + [ (.findings | map(select(.level == "warn")) | length) as $n | select($n > 0) | plural($n; "warning"; "warnings") ]
                    + [ (.findings | map(select(.level == "tip")) | length) as $n | select($n > 0) | plural($n; "tip"; "tips") ]
                    + [ .ignored | select(. > 0) | "\(.) ignored" ] )
                    | if length == 0 then "nothing to fix" else join(", ") end
                  else "`\(.code)`: \(.error | md)" end )
              + " |" ),
          ""
        else empty end ),
      ( [ $pages[] | select(.status == "checked" and (.findings | length) > 0) ] as $bad
        | if ($bad | length) > 0 then
            "### Findings", "",
            ( $bad | sort_by(-(.worst | rank))[]
              | "#### \(.url | link)", "",
                ( .findings[]
                  | "- \(.level | word) [`\(.id)`](\(.id | ref))"
                    + (if .message != "" then ": \(.message | md)" else "" end)
                    + (if .level != .apiLevel then " _(\(.apiLevel | word | ascii_downcase) by default; your levels set \(.level | word | ascii_downcase))_" else "" end) ),
                "" )
          else empty end ),
      ( if ($levels | length) > 0 then "Levels in force: `\($levels | tojson)`", "" else empty end )
    ] | join("\n"))
  }
