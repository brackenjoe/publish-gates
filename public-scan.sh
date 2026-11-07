#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joe Fernandez
#
# public-scan.sh DIR
#
# Gate for anything bound for a public remote. Scans
# every file under DIR (tracked and untracked-not-ignored files if DIR is a
# git checkout, so files copied in before `git add` are covered; else all
# files, .git excluded) for host identity, contact details and credential
# shapes. Pass or fail only: exit 0 clean, 1 on any hit, 2 on bad usage or when
# the scan could not be done in full. It does not replace reading the diff; it
# catches what reading misses. Needs bash 4.4 or later (mapfile -d, declare -A,
# empty arrays under set -u); an older bash is exit 2 with a message saying so.
#
# What is scanned, and what stops the run. The file list is NUL-delimited end
# to end and every grep runs under LC_ALL=C, so only a NUL byte makes a file
# binary and no line is dropped for an encoding error (the deny list's -i and
# -w are then ASCII-only). Every listed path must be a readable regular file,
# checked before any grep; anything else is exit 2 naming each path as
# `public-scan.sh: not scanned: PATH (reason)`: a tracked file deleted from the
# work tree, a directory where a file was listed, a fifo, socket, device or
# other special file, an unreadable file, and a name containing a newline.
# The listing itself must be complete: `find` and `git ls-files` are run with
# their stderr and status captured, and any message (an unreadable directory,
# say) or nonzero status is exit 2 naming the message, since a directory they
# skip would otherwise shrink the list silently.
# A symlink (in a git checkout or not, dangling or not, pointing inside DIR or
# out) is never followed and its target is never read. Its target string
# (readlink) is scanned as one line of text under the same rules and deny terms,
# a hit is printed as `PATH (symlink target)`, and it is named on stderr as
# `public-scan.sh: not followed (symlink): PATH` and counted in the ok line as
# `L links not followed` (shown only when L > 0). It does not change the exit
# code by itself. A gitlink (a submodule directory listed by git ls-files) is
# not entered: `public-scan.sh: not scanned (submodule): PATH`, counted as
# `S submodules not scanned` (shown when S > 0), and not a failure. Scan a
# submodule by running this on its own checkout.
# A file containing a NUL byte is not scanned: it is named on stderr as
# `public-scan.sh: skipped (binary): PATH`, counted in the ok line, and does not
# change the exit code (the media gate covers those). grep's own stderr is not
# hidden: any output from it (a PCRE limit, say) is printed and is exit 2.
#
# The email and IPv4 patterns also take an address whose at sign or dots are
# written as a Markdown backslash escape or an HTML character reference, which
# a page renders as a plain address. The password pattern is case-insensitive and
# takes a quoted key and value, so a JSON field and an upper-case shell
# variable are caught as well as a plain assignment. Its one exemption is the
# sudoers keyword NOPASSWD (upper case, exactly): `NOPASSWD: ALIAS` passes,
# `nopassword=x`, `NOPASSWORD=x` and `NoPasswd: x` do not.
# Token shapes beyond the vendor-prefixed ones: OpenAI-style, Google API, npm and
# GitLab keys, an Authorization Bearer value, and an assigned API key (a value
# that starts with $, <, { or % is a placeholder and passes).
# A Cloudflare Artifacts git token (art_v<N>_ and 20 or more token characters;
# the bare prefix in prose passes) and a password in a URL of any scheme
# (scheme://user:<secret>@host, user may be empty; a password that starts with
# $, <, {, a backslash or *, or is the format directive %s, is a placeholder and
# passes. The password ends at white space, / ? # @ and a quote or angle bracket,
# so a port followed by a query string, or by markup and an @, is not read as
# one; a percent-encoded password (%40...) is a real one.)
#
# Deny list: each non-empty, non-# line of $PUBLIC_SCAN_DENY (default:
# public-scan.deny beside this script) is a term, matched case-insensitively
# as a fixed whole word. Each term has CR removed and surrounding white space
# trimmed. Only the default path is optional: a missing public-scan.deny is
# skipped, so a public copy of this script runs without one. A set
# $PUBLIC_SCAN_DENY that is not a readable regular file is exit 2, so a typo
# cannot turn the list off. The terms are never printed except as matched
# lines; the ok line gives their count when there are any.
# $PUBLIC_SCAN_TERMS adds terms, comma or newline separated, for environments
# where a deny file cannot be kept (e.g. a cloud environment variable).
#
# Allow list: $PUBLIC_SCAN_ALLOW names a file of exact strings a page publishes
# on purpose, one per line, `#` lines and blank lines skipped (the rest of a
# line is the string, spaces included, so a trailing space is part of it). When
# any rule, the deny list included, matches a line, every allow string is
# removed from that line (literal, case-sensitive, longest first, and only
# where it is not part of a longer token: the characters before and after it
# may not be letters, digits or any of . _ % + @ -) and the rule is tested
# against what is left; the hit counts only if the remainder still matches. So
# an allowed address passes, a second, different address on the same line
# still fails, and allowing an address does not mask a longer address that
# ends with it (the same name with a letter in front) or one that goes on
# past it (`.au`); a sentence full stop after it is not a longer token. A colon
# is treated like a dot for an allow string that holds a colon itself, so an
# allowed IPv6 or MAC address does not mask a longer one: after the string a
# colon extends it when a hex digit, a colon or a token character follows;
# before it a colon preceded by a hex digit or a colon does. (An allowed
# git@host followed by :path is not extended: that colon starts the next field.)
# The check applies on a side only where the string itself starts or ends with a
# letter or digit: one that begins with a dash, say, carries its own left boundary.
# Unset, nothing changes; set to a file that cannot be read, exit 2. Needs
# perl. Hits are printed as they stand in the file, not as the remainder.

set -u
export LC_ALL=C
# mapfile -d and empty arrays under set -u need bash 4.4; older bash would fail
# later with a misleading "no files selected".
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
  echo "public-scan.sh: needs bash 4.4 or later (this is bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]})" >&2
  exit 2
fi
dir="${1:-}"
if [ -z "$dir" ] || [ ! -d "$dir" ]; then echo "usage: $0 DIR" >&2; exit 2; fi

# Nine patterns use grep -P; without PCRE their stderr is hidden and they never
# match, so refuse to run rather than pass silently.
printf x | grep -qP 'x' 2>/dev/null || { echo "$0: needs GNU grep with PCRE support (grep -P); some rules would never match" >&2; exit 2; }

# label|regex, one per line; label|P|regex for a Perl regex (grep -P).
# Loopback 127.0.0.1 and the wildcard 0.0.0.0 identify nothing and pass.
patterns='
IPv4 address|P|\b(?!127[.]0[.]0[.]1\b|0[.]0[.]0[.]0\b)([0-9]{1,3}(?:\\?\.|&#0*46;|&#[xX]0*2[eE];|&period;)){3}[0-9]{1,3}\b
Tailscale MagicDNS name|[a-z0-9-]+\.ts\.net
email address|[A-Za-z0-9._%+-]+(\\?@|&#0*64;|&#[xX]0*40;|&commat;)([A-Za-z0-9-]|\\?\.|&#0*46;|&#[xX]0*2[eE];|&period;)+(\\?\.|&#0*46;|&#[xX]0*2[eE];|&period;)[A-Za-z]{2,}
US phone number|\b[0-9]{3}[-. ][0-9]{3}[-. ][0-9]{4}\b
GitHub token|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}
Anthropic key|sk-ant-[A-Za-z0-9_-]{10,}
OpenAI-style key|P|\bsk-(?!ant-)(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,}
Google API key|AIza[0-9A-Za-z_-]{35}
npm token|npm_[A-Za-z0-9]{36}
GitLab token|glpat-[A-Za-z0-9_-]{20,}
Bearer header|P|(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{16,}
assigned API key|P|(?i)(?<![A-Za-z0-9])api[_-]?key["\x27]?\s*[:=]\s*["\x27]?(?![$<{%])[^\s"\x27]{8,}
AWS access key|AKIA[0-9A-Z]{16}
Slack token|xox[abpr]-[A-Za-z0-9-]{10,}
Tailscale auth key|tskey-[a-z]+-[A-Za-z0-9-]{10,}
private key block|BEGIN [A-Z ]*PRIVATE KEY
WiFi PSK|psk[=]
assigned password|P|(?i)((?<!(?-i:NO))passwd|password|secret)["\x27]?\s*[:=]\s*["\x27]?[^\s"\x27]{4,}
Cloudflare tunnel credentials|Tunnel[S]ecret|Account[T]ag
Cloudflare Artifacts token|P|(?<![A-Za-z0-9])art_v[0-9]+_[A-Za-z0-9_-]{20,}
credentials in URL|P|[A-Za-z][A-Za-z0-9+.-]*://[^\s/?#@:]*:(?![$<{\\*]|%s)[^\s/?#@"\x27<>]{4,}@
IPv6 address|P|(?i)(?<![0-9a-f:])(?!2001:0*db8:)(?:[23][0-9a-f]{3}|fd[0-9a-f]{2})(?::{1,2}[0-9a-f]{1,4}){2,}(?![0-9a-f])
MAC address|P|(?i)(?<![0-9a-f])(?!00(?::00){5}(?![0-9a-f]))(?!ff(?::ff){5}(?![0-9a-f]))(?:[0-9a-f]{2}:){5}[0-9a-f]{2}(?![0-9a-f])
'

# Paths are named on stderr as they are, except that a name holding a newline
# is shown %q-quoted so it stays one line.
show() { case $1 in *$'\n'*) printf '%q' "$1" ;; *) printf '%s' "$1" ;; esac; }

work=$(mktemp -d) || exit 2
trap 'rm -rf "$work"' EXIT
gerr="$work/grep.err"; : > "$gerr"

# list_to FILE CMD...: run CMD with stdout to FILE and stderr captured. Any
# stderr output or nonzero status means the list may be short: exit 2.
list_to() {
  local out=$1 rc; shift
  "$@" >"$out" 2>"$out.err"; rc=$?
  if [ "$rc" -ne 0 ] || [ -s "$out.err" ]; then
    echo "public-scan.sh: could not list every file under $dir (${1##*/} exit $rc), scan incomplete:" >&2
    sed 's/^/  /' "$out.err" >&2
    exit 2
  fi
}

# rev-parse exits 0 and prints "false" inside a .git directory or a bare
# repository, where ls-files lists nothing: only "true" takes the git branch.
files=()
declare -A isgl=()
if [ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null)" = true ]; then
  list_to "$work/list" git -C "$dir" ls-files -z --cached --others --exclude-standard
  mapfile -d '' -t rel < "$work/list"
  for r in "${rel[@]}"; do files+=("$dir/$r"); done
  # gitlinks (mode 160000) are the submodule directories
  list_to "$work/stage" git -C "$dir" ls-files -z --stage
  mapfile -d '' -t stg < "$work/stage"
  for e in "${stg[@]}"; do
    case $e in 160000\ *) isgl["$dir/${e#*$'\t'}"]=1 ;; esac
  done
else
  # everything but directories, symlinks included, so both branches agree
  list_to "$work/list" find -H "$dir" -path '*/.git' -prune -o ! -type d -print0
  mapfile -d '' -t files < "$work/list"
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "$0: nothing was scanned: no files selected under $dir (a gitignored directory inside a checkout lists nothing, and so does an empty one)" >&2
  exit 2
fi

# Every listed path is a readable regular file, a symlink (never followed; its
# target string is scanned from $work/links/N, mapped back to the path through
# linkmap), or a gitlink (named, not entered); anything else stops the run.
# Checked before any grep.
mkdir "$work/links" || exit 2
: > "$work/linkmap"
bad=0; nsub=0
regular=(); linkfiles=()
for f in "${files[@]}"; do
  reason=
  case $f in *$'\n'*) reason="newline in name" ;; esac
  if [ -n "$reason" ]; then :
  elif [ -L "$f" ]; then
    k=$(( ${#linkfiles[@]} + 1 ))
    if readlink -- "$f" > "$work/links/$k" 2>/dev/null; then
      linkfiles+=("$work/links/$k")
      printf '%s\t%s\n' "$k" "$f" >> "$work/linkmap"
      echo "public-scan.sh: not followed (symlink): $(show "$f")" >&2
    else
      reason="symlink target unreadable"
    fi
  elif [ -d "$f" ] && [ -n "${isgl[$f]:-}" ]; then
    nsub=$((nsub + 1))
    echo "public-scan.sh: not scanned (submodule): $(show "$f")" >&2
  elif [ ! -e "$f" ]; then reason="missing: listed but not on disk"
  elif [ -d "$f" ]; then reason="directory listed where a file was expected"
  elif [ ! -f "$f" ]; then reason="not a regular file"
  elif [ ! -r "$f" ]; then reason="unreadable"
  else regular+=("$f")
  fi
  if [ -n "$reason" ]; then
    echo "public-scan.sh: not scanned: $(show "$f") ($reason)" >&2
    bad=1
  fi
done
[ "$bad" -eq 0 ] || exit 2
nlink=${#linkfiles[@]}
files=("${regular[@]}")

allow="${PUBLIC_SCAN_ALLOW:-}"
allowstrs="$work/allow"
if [ -n "$allow" ]; then
  if [ ! -f "$allow" ] || [ ! -r "$allow" ]; then echo "$0: PUBLIC_SCAN_ALLOW is not a readable file" >&2; exit 2; fi
  command -v perl >/dev/null 2>&1 || { echo "$0: PUBLIC_SCAN_ALLOW needs perl" >&2; exit 2; }
  grep -v -e '^#' -e '^[[:space:]]*$' "$allow" > "$allowstrs"
  [ -s "$allowstrs" ] || allow=""
fi

# Deny list: an explicit path must be a readable regular file; the default
# beside the script is optional, but if present it must be readable too.
terms="$work/terms"; : > "$terms"
deny="${PUBLIC_SCAN_DENY:-}"
if [ -n "$deny" ]; then
  if [ ! -f "$deny" ] || [ ! -r "$deny" ]; then echo "$0: PUBLIC_SCAN_DENY is not a readable file" >&2; exit 2; fi
else
  deny="$(dirname "$0")/public-scan.deny"
  if [ -e "$deny" ] && { [ ! -f "$deny" ] || [ ! -r "$deny" ]; }; then echo "$0: $deny exists but is not a readable file" >&2; exit 2; fi
fi
if [ -f "$deny" ]; then
  tr -d '\r' < "$deny" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^#/d' -e '/^$/d' >> "$terms"
fi
if [ -n "${PUBLIC_SCAN_TERMS:-}" ]; then
  printf '%s\n' "$PUBLIC_SCAN_TERMS" | tr ',' '\n' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' >> "$terms"
fi
nterms=$(grep -c . "$terms")

# Binary files (a NUL byte) are named and skipped; every rule runs over the rest.
declare -A isbin=()
nbin=0
binlist=()
if [ "${#files[@]}" -gt 0 ]; then
  mapfile -d '' -t binlist < <(printf '%s\0' "${files[@]}" | xargs -0 -r grep -laZP '\x00' -- 2>>"$gerr")
fi
for f in "${binlist[@]}"; do
  isbin["$f"]=1; nbin=$((nbin + 1))
  echo "public-scan.sh: skipped (binary): $f" >&2
done
text=()
for f in "${files[@]}"; do [ -n "${isbin[$f]:-}" ] || text+=("$f"); done
nfiles=${#text[@]}
# the symlink target files are text too, but are not counted as files
[ "$nlink" -eq 0 ] || text+=("${linkfiles[@]}")
ngrep=${#text[@]}

# grep prints nothing to stderr on a normal no-match (status 1); anything there
# is a failure to check, and the scan stops.
grep_failed() {
  [ -s "$gerr" ] || return 1
  echo "public-scan.sh: grep reported errors, scan incomplete:" >&2
  sed 's/^/  /' "$gerr" >&2
  return 0
}
grep_failed && exit 2

# run_grep GREP-ARGS...: the text files, NUL-delimited, through xargs to grep.
run_grep() {
  [ "$ngrep" -gt 0 ] || return 0
  printf '%s\0' "${text[@]}" | xargs -0 -r grep "$@" 2>>"$gerr"
}

# filter_allowed GREP-ARGS...: stdin is grep -HnIZ output (file NUL line:text);
# removes the allow strings from each text, runs the same grep (with -a, without
# -H and -I) over the remainders, and prints the original hits whose remainder
# still matches, in grep's usual file:line:text form.
filter_allowed() {
  : > "$work/orig"; : > "$work/rem"
  perl -e '
    open(my $a, "<", $ARGV[0]) or exit 2; my @s;
    while (<$a>) { chomp; s/\r\z//; push @s, $_ if length }
    @s = sort { length($b) <=> length($a) } @s;
    # a boundary is checked only on a side where the string itself starts (or
    # ends) with a letter or digit; one that starts with a dash, say, brings
    # its own (an allow string such as an SVG path fragment may start with a dash)
    my $tc = q{[A-Za-z0-9._%+\@-]};
    # on the right a full stop extends the token only when a token character
    # follows it, so a full stop ending a sentence after an allowed address is
    # fine; a colon extends it when a hex digit, a colon or a token character
    # follows (an IPv6 or MAC address going on past the allowed one)
    my $tr = q{(?:[A-Za-z0-9_%+\@-]|[.][A-Za-z0-9_%+\@-]|[:](?:[0-9A-Fa-f:]|[A-Za-z0-9._%+\@-]))};
    # on the left a colon preceded by a hex digit or a colon extends the token
    my $tl = q{(?<![0-9A-Fa-f:]:)};
    # the colon rules apply only to an allow string that holds a colon itself
    # (an IPv6 or MAC address): after an address like git@host a colon starts
    # the next field (scp-style host:path), not a longer token
    my $tr0 = q{(?:[A-Za-z0-9_%+\@-]|[.][A-Za-z0-9_%+\@-])};
    my @re = map { my $x = $_; my $col = $x =~ /:/;
      my $lb = $x =~ /^[A-Za-z0-9]/ ? qq{(?<!$tc)} . ($col ? $tl : q{}) : q{};
      my $rb = $x =~ /[A-Za-z0-9]\z/ ? ($col ? qq{(?!$tr)} : qq{(?!$tr0)}) : q{};
      qr/$lb\Q$x\E$rb/ } @s;
    open(my $o, ">", $ARGV[1]) or exit 2; open(my $r, ">", $ARGV[2]) or exit 2;
    while (<STDIN>) {
      chomp; my ($f, $rest) = split /\0/, $_, 2; next unless defined $rest;
      my ($n, $t) = split /:/, $rest, 2; next unless defined $t;
      print $o "$f:$n:$t\n";
      for my $re (@re) { $t =~ s/$re//g }
      print $r "$t\n";
    }' "$allowstrs" "$work/orig" "$work/rem" 2>>"$gerr" || { echo "perl allow filter failed" >> "$gerr"; return 2; }
  grep -a -n "$@" "$work/rem" 2>>"$gerr" | cut -d: -f1 > "$work/keep"
  awk 'NR==FNR { k[$1] = 1; next } FNR in k' "$work/keep" "$work/orig"
}

# remap: stdin is grep-style file:line:text; a hit in a symlink target file
# ($work/links/N) is shown as `PATH (symlink target):line:text`.
remap() {
  if [ -s "$work/linkmap" ]; then
    PRE="$work/links/" awk 'NR == FNR { i = index($0, "\t"); m[substr($0, 1, i - 1)] = substr($0, i + 1); next }
      { pre = ENVIRON["PRE"]
        if (index($0, pre) == 1) {
          rest = substr($0, length(pre) + 1); c = index(rest, ":")
          if (c > 0 && (substr(rest, 1, c - 1) in m)) $0 = m[substr(rest, 1, c - 1)] " (symlink target)" substr(rest, c)
        }
        print }' "$work/linkmap" -
  else
    cat
  fi
}

hits=0
while IFS='|' read -r label rx rest; do
  [ -z "$label" ] && continue
  mode=-E
  if [ "$rx" = "P" ]; then mode=-P; rx=$rest; elif [ -n "$rest" ]; then rx="$rx|$rest"; fi
  if [ -n "$allow" ]; then
    out=$(run_grep -HnIZ "$mode" -- "$rx" | filter_allowed "$mode" -- "$rx" | remap)
  else
    out=$(run_grep -HnI "$mode" -- "$rx" | remap)
  fi
  grep_failed && exit 2
  if [ -n "$out" ]; then
    hits=1
    echo "FAIL  $label"
    printf '%s\n' "$out" | sed 's/^/      /'
  fi
done <<< "$patterns"

if [ -s "$terms" ]; then
  if [ -n "$allow" ]; then
    out=$(run_grep -HnIiwFZ -f "$terms" -- | filter_allowed -iwF -f "$terms" -- | remap)
  else
    out=$(run_grep -HnIiwF -f "$terms" -- | remap)
  fi
  grep_failed && exit 2
  if [ -n "$out" ]; then
    hits=1
    echo "FAIL  deny-list term"
    printf '%s\n' "$out" | sed 's/^/      /'
  fi
fi

if [ "$hits" -eq 0 ]; then
  extra=
  [ "$nlink" -gt 0 ] && extra="$extra, $nlink links not followed"
  [ "$nsub" -gt 0 ] && extra="$extra, $nsub submodules not scanned"
  [ "$nterms" -gt 0 ] && extra="$extra, $nterms deny terms"
  echo "ok    no public-scan hits in $dir ($nfiles files, $nbin binary skipped$extra)"; exit 0
fi
exit 1
