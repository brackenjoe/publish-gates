#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joe Fernandez
#
# Is a GitHub repo public? A push to a public remote needs the owner's
# approval every time, so this decides "public", "private" or "ask".
#
#   check-visibility.sh OWNER REPO
#   check-visibility.sh --selftest     offline, curl and gh replaced by stubs
#
# Prints exactly one word on stdout:
#   public    status 200 and the body has "visibility": "public"
#   private   status 200 and the body has "visibility": "private", or the
#             status is 404 with no visibility field. An unauthenticated
#             request to a private repo is a 404, but so is one to a repo
#             that does not exist: a misspelt name also prints "private".
#             Check against the remote's own URL, not a name typed by hand.
#   ask       anything else: 403, 5xx, 000 (no connection), an empty or
#             unparsable answer, a visibility field that is neither, or a
#             body holding both. Ask the owner. Do not push, and do not
#             read it as private.
# Exit status: 0 public or private, 2 ask, 1 bad usage.
#
# Second opinion (since 2026-11-07): the unauthenticated call sometimes
# answers 504 or another non-decision while the authenticated CLI knows the
# answer. ONLY when the curl answer is "ask", and only if gh is installed,
# run `GH_HOST=github.com timeout 20 gh repo view github.com/OWNER/REPO
# --json visibility -q .visibility`. The host is pinned twice, in the
# argument and in GH_HOST, so a stale GH_HOST or an enterprise host in gh's
# config can never answer for a github.com repo.
# Its output exactly PRIVATE gives "private", exactly PUBLIC gives "public";
# anything else (INTERNAL, empty, an error, a non-zero exit, gh missing or
# not logged in, a timeout) leaves "ask". A curl "public" or "private" is
# never consulted against gh, never overridden or downgraded. One attempt,
# no retry: the caller decides whether to try again. Stdout stays one word;
# CHECK_VISIBILITY_VERBOSE=1 prints the source (curl or gh) to stderr.
# GH_TIMEOUT (seconds) exists for the selftest; anything but a positive
# integer means 20 (0 would switch the timeout off). The second opinion needs
# GNU coreutils `timeout`; without it (stock macOS) it is skipped and the
# answer stays "ask", and the selftest SKIPs the cases that need it.
#
# Proxy caveat (seen 2026-10-17 behind a cloud session's git proxy): through
# such a proxy a private repo can answer 200, and a repo not attached to the
# session answers 403 even when public. A 200 is still judged by its
# body, so "public" and a 200 "private" hold; a "private" from a 404 proves
# less there. Either way, read the diff for credentials before the push.
#
# A visibility field is believed only with status 200; the same field with
# any other status is "ask".
set -uo pipefail

note() { [ "${CHECK_VISIBILITY_VERBOSE:-}" = 1 ] && echo "check-visibility: $*" >&2; return 0; }

# gh_visibility OWNER REPO -> prints public/private, or nothing for "ask"
gh_visibility() {
  command -v gh >/dev/null 2>&1 || return 0
  command -v timeout >/dev/null 2>&1 || return 0
  local v t=${GH_TIMEOUT:-20}
  case $t in ''|*[!0-9]*) t=20 ;; esac
  [ "$((10#$t))" -gt 0 ] || t=20
  v=$(GH_HOST=github.com GH_PROMPT_DISABLED=1 timeout "$t" gh repo view "github.com/$1/$2" --json visibility -q .visibility </dev/null 2>/dev/null) || return 0
  case $v in
    PRIVATE) echo private ;;
    PUBLIC)  echo public ;;
  esac
  return 0
}

# visibility OWNER REPO -> prints the word, returns 0 or 2
visibility() {
  local w
  w=$(curl_visibility "$1" "$2")
  if [ "$w" = ask ]; then
    w=$(gh_visibility "$1" "$2")
    if [ -n "$w" ]; then note "gh: $w"; echo "$w"; return 0; fi
    note "ask (curl undecided, gh undecided)"
    echo ask; return 2
  fi
  note "curl: $w"
  echo "$w"; return 0
}

# curl_visibility OWNER REPO -> prints the word from the unauthenticated call
curl_visibility() {
  local out status body
  out=$(curl -s --max-time 20 -w '\n%{http_code}\n' "https://api.github.com/repos/$1/$2" 2>/dev/null) || true
  # the last non-empty line is the status; everything before it is the body
  status=$(printf '%s\n' "$out" | awk 'NF {s = $0} END {print s}')
  body=$(printf '%s\n' "$out" | sed '$d')
  local pub=0 priv=0
  printf '%s' "$body" | grep -Eq '"visibility"[[:space:]]*:[[:space:]]*"public"' && pub=1
  printf '%s' "$body" | grep -Eq '"visibility"[[:space:]]*:[[:space:]]*"private"' && priv=1
  if [ "$status" = 200 ] && [ $pub -eq 1 ] && [ $priv -eq 0 ]; then
    echo public; return 0
  elif [ "$status" = 200 ] && [ $priv -eq 1 ] && [ $pub -eq 0 ]; then
    echo private; return 0
  elif [ "$status" = 404 ] && ! printf '%s' "$body" | grep -q '"visibility"'; then
    echo private; return 0
  fi
  echo ask; return 2
}

selftest() {
  local pass=0 failn=0 skipn=0 got rc STUB GH_MODE oldpath dir called realtimeout want
  # curl is shadowed by a function that answers with the case's stub text
  curl() { printf '%s' "$STUB"; }
  # gh is a stub executable on a private PATH (timeout linked in), so the
  # real command line runs; GH_MODE picks its behaviour, and it appends a
  # line to $dir/gh.called whenever it is run
  dir=$(mktemp -d) || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$dir'" RETURN
  mkdir "$dir/nogh"
  realtimeout=$(command -v timeout || true)
  for t in awk sed grep; do ln -s "$(command -v "$t")" "$dir/nogh/$t"; done
  if [ -n "$realtimeout" ]; then
    ln -s "$realtimeout" "$dir/nogh/timeout"
    # a wrapper that records timeout's first argument, then runs the real one
    printf '%s\n' '#!/bin/bash' "echo \"\$1\" > '$dir/timeout.arg'" \
      "exec '$realtimeout' \"\$@\"" > "$dir/timeout"
    chmod +x "$dir/timeout"
  fi
  # shellcheck disable=SC2016  # the stub's text is meant literal
  printf '%s\n' '#!/bin/bash' \
    'echo "${GH_HOST-unset}|$*" >> "$(dirname "$0")/gh.called"' \
    'case $GH_MODE in' \
    '  PRIVATE|PUBLIC|INTERNAL) echo "$GH_MODE" ;;' \
    '  PRIVATE_LC) echo private ;;' \
    '  PRIVATE_SP) echo "PRIVATE " ;;' \
    '  EMPTY) ;;' \
    '  FAIL) echo "not logged in" >&2; exit 4 ;;' \
    '  FAILOUT) echo PRIVATE; exit 1 ;;' \
    '  HANG) sleep 10; echo PRIVATE ;;' \
    'esac' > "$dir/gh"
  chmod +x "$dir/gh"
  oldpath=$PATH
  export GH_TIMEOUT=1
  # each case: name, wanted word, wanted exit, curl stub output, gh mode
  # (NONE removes gh from PATH), and optionally whether gh must have been
  # run (yes/no)
  check() {
    STUB=$4; GH_MODE=${5:-FAIL}; export GH_MODE
    if [ -z "$realtimeout" ] && [ "${6:-}" = yes ]; then
      skipn=$((skipn + 1)); echo "SKIP  $1: needs GNU coreutils timeout, not installed"
      return 0
    fi
    rm -f "$dir/gh.called"
    if [ "$GH_MODE" = NONE ]; then
      # shellcheck disable=SC2123  # a private PATH is the point
      PATH=$dir/nogh
    else
      PATH=$dir:$oldpath
    fi
    got=$(visibility o r); rc=$?
    PATH=$oldpath
    called=no; [ -e "$dir/gh.called" ] && called=yes
    if [ "$got" = "$2" ] && [ "$rc" -eq "$3" ] && { [ -z "${6:-}" ] || [ "$called" = "$6" ]; }; then
      pass=$((pass + 1)); echo "ok    $1"
    else
      failn=$((failn + 1)); echo "FAIL  $1: got '$got' rc=$rc gh=$called, want '$2' rc=$3 gh=${6:-any}"
    fi
  }
  local PUB=$'{\n  "id": 1,\n  "private": false,\n  "visibility": "public"\n}\n\n200\n'
  local PRV=$'{\n  "private": true,\n  "visibility": "private"\n}\n\n200\n'
  local ASK=$'oops\n\n504\n'
  # curl answers decide on their own; gh is not consulted
  check "public body"            public  0 "$PUB" FAIL no
  check "private body"           private 0 "$PRV" FAIL no
  check "bare 404"               private 0 $'{"message": "Not Found"}\n\n404\n' PUBLIC no
  check "404 with empty body"    private 0 $'\n404\n' PUBLIC no
  # curl ask, gh failing: still ask
  check "403"                    ask     2 $'{"message": "rate limit"}\n\n403\n'
  check "000 and empty body"     ask     2 $'\n000\n'
  check "wholly empty"           ask     2 ''
  check "500"                    ask     2 $'oops\n\n500\n'
  check "200 unparsable"         ask     2 $'<html>proxy</html>\n\n200\n'
  check "200 internal visibility" ask    2 $'{"visibility": "internal"}\n\n200\n'
  check "403 with visibility"    ask     2 $'{"visibility": "public"}\n\n403\n'
  check "404 with visibility"    ask     2 $'{"visibility": "public"}\n\n404\n'
  # the second opinion
  check "ask + gh PRIVATE"       private 0 "$ASK" PRIVATE yes
  check "ask + gh PUBLIC"        public  0 "$ASK" PUBLIC yes
  check "ask + gh INTERNAL"      ask     2 "$ASK" INTERNAL yes
  check "ask + gh empty"         ask     2 "$ASK" EMPTY yes
  check "ask + gh fails"         ask     2 "$ASK" FAIL yes
  check "ask + gh PRIVATE, exit 1" ask   2 "$ASK" FAILOUT yes
  check "ask + gh lower case"    ask     2 "$ASK" PRIVATE_LC yes
  check "ask + gh trailing space" ask    2 "$ASK" PRIVATE_SP yes
  check "ask + gh missing"       ask     2 "$ASK" NONE no
  check "ask + gh times out"     ask     2 "$ASK" HANG yes
  check "403 + gh PRIVATE"       private 0 $'{"message": "rate limit"}\n\n403\n' PRIVATE yes
  check "200 internal + gh PUBLIC" public 0 $'{"visibility": "internal"}\n\n200\n' PUBLIC yes
  # gh never overrides or downgrades a curl answer
  check "curl public + gh PRIVATE" public 0 "$PUB" PRIVATE no
  check "curl private + gh PUBLIC" private 0 "$PRV" PUBLIC no
  # gh is pinned to github.com whatever GH_HOST says, and the argv is exact
  want='github.com|repo view github.com/o/r --json visibility -q .visibility'
  if [ -z "$realtimeout" ]; then
    skipn=$((skipn + 1)); echo "SKIP  gh argv, GH_HOST pin and GH_TIMEOUT cases: need GNU coreutils timeout"
  else
    local hostval
    for hostval in unset other.invalid; do
      STUB=$ASK; GH_MODE=PRIVATE; export GH_MODE; PATH=$dir:$oldpath
      rm -f "$dir/gh.called"
      if [ "$hostval" = unset ]; then
        got=$(visibility o r); rc=$?
      else
        got=$(GH_HOST=$hostval visibility o r); rc=$?
      fi
      PATH=$oldpath
      called=$(cat "$dir/gh.called" 2>/dev/null)
      if [ "$got" = private ] && [ "$rc" -eq 0 ] && [ "$called" = "$want" ]; then
        pass=$((pass + 1)); echo "ok    gh argv and GH_HOST pinned (GH_HOST $hostval outside)"
      else
        failn=$((failn + 1)); echo "FAIL  gh argv and GH_HOST (GH_HOST $hostval outside): got '$got' rc=$rc gh saw '$called', want '$want'"
      fi
    done
    # GH_TIMEOUT: a positive integer is used, anything else becomes 20
    local tv
    for tv in 7:7 0:20 00:20 abc:20 -5:20 1.5:20 '':20 08:08; do
      STUB=$ASK; GH_MODE=PRIVATE; export GH_MODE; PATH=$dir:$oldpath
      rm -f "$dir/timeout.arg"
      got=$(GH_TIMEOUT=${tv%%:*} visibility o r); rc=$?
      PATH=$oldpath
      called=$(cat "$dir/timeout.arg" 2>/dev/null)
      if [ "$got" = private ] && [ "$called" = "${tv##*:}" ]; then
        pass=$((pass + 1)); echo "ok    GH_TIMEOUT '${tv%%:*}' runs timeout $called"
      else
        failn=$((failn + 1)); echo "FAIL  GH_TIMEOUT '${tv%%:*}': got '$got', timeout saw '$called', want '${tv##*:}'"
      fi
    done
  fi
  # stdout stays one word with the verbose switch on
  STUB=$PUB; GH_MODE=FAIL; export GH_MODE; PATH=$dir:$oldpath
  got=$(CHECK_VISIBILITY_VERBOSE=1 visibility o r 2>/dev/null); rc=$?
  PATH=$oldpath
  if [ "$got" = public ] && [ "$rc" -eq 0 ]; then
    pass=$((pass + 1)); echo "ok    verbose keeps stdout one word"
  else
    failn=$((failn + 1)); echo "FAIL  verbose keeps stdout one word: got '$got' rc=$rc"
  fi
  unset GH_TIMEOUT GH_MODE
  echo "$pass passed, $failn failed, $skipn skipped"
  [ "$failn" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ] && [ $# -eq 1 ]; then
  selftest; exit $?
fi
re='^[A-Za-z0-9_.][A-Za-z0-9._-]*$'   # no leading dash: an option, not a name
# "." and ".." pass the pattern but collapse out of the URL path.
if [ $# -ne 2 ] || ! [[ $1 =~ $re ]] || ! [[ $2 =~ $re ]] \
   || [[ $1 == . || $1 == .. || $2 == . || $2 == .. ]]; then
  echo "usage: $0 OWNER REPO | --selftest" >&2
  exit 1
fi
visibility "$1" "$2"
