#!/usr/bin/env bash
# Judge one API answer read on stdin, as the action would, without a network:
#   curl -s 'https://api.poly.io/og?url=https%3A%2F%2Fexample.com' | lib/judge.sh https://example.com
# The second argument is the HTTP status (default 200); GOOSEY_LEVELS holds your levels as JSON.
set -euo pipefail
levels="${GOOSEY_LEVELS:-}"; [ -n "$levels" ] || levels='{}'
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec jq -cRs --arg url "${1:?usage: judge.sh <url> [http-status]}" --arg http "${2:-200}" \
  --argjson levels "$levels" -f "$here/judge.jq"
