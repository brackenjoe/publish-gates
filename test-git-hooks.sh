#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joe Fernandez
#
# Test for git-hooks/pre-push and git-hooks/commit-msg (and xref.sh, which
# they source). Exit 0 if every case passed, 1 if any failed, 2 if the
# fixture could not be built. The hooks are found in git-hooks/ beside this
# file.
#
#   ./test-git-hooks.sh
#
# Offline. Everything happens in a mktemp -d that is removed at the end, with
# HOME and the git config pointed away from the operator's (GIT_CONFIG_GLOBAL
# is /dev/null, so no gates.privateRepo leaks in from outside); the private
# repo list is set in each temp repo's local config, with
# git config --add gates.privateRepo. pre-push is run directly with a stub in
# place of check-visibility.sh (GATES_CHECK_VISIBILITY), so no request is
# made, and ssh -G host resolution is stubbed the same way (GATES_SSH). The
# cases that go through git use local bare repositories; the
# github.com ones reach one through a fake ssh (GIT_SSH_COMMAND).
#
# Cases:
#   pre-push      local path allowed; github https private allowed; public
#                 refused, naming owner/repo; ask refused; public with
#                 GATES_PUBLIC_PUSH_OK=yes allowed; =1 refused; git@ and
#                 ssh:// forms parsed (the stub records OWNER and REPO);
#                 stub missing, crashing, or exiting nonzero after printing
#                 "private": refused; through git: a push to a local bare
#                 remote succeeds, a push to a github.com URL is stopped by
#                 the hook
#   pre-push scan git push over the fake ssh to a private github.com URL
#                 (the stub answers private): clean commits allowed; a
#                 `commit -n` xref refused naming its short sha and the fix;
#                 the xref via cherry-pick refused; new branch with an xref
#                 refused, clean new branch allowed; deletion allowed; an xref
#                 commit the target itself lists (ls-remote) not rescanned,
#                 one only on a mirror, or only on the old target of a
#                 re-pointed remote name, is; ls-remote failing still
#                 scans; xref in the body, a
#                 github.com pull URL: refused; OK=yes does not skip the
#                 scan; a repo the stub calls public is not scanned; ask, a
#                 crashing stub and an unlisted repo are scanned;
#                 gates.privateRepo unset: still scanned, the stub is
#                 consulted; xref.sh missing: pre-push and commit-msg refuse
#   host          alias for github.com (GATES_SSH stub) judged as GitHub, an
#                 alias for another host noted and allowed, a trailing dot,
#                 gist.github.com refused unless approved, a host starting
#                 with "-" never passed to ssh, a local path silent
#   commit-msg    origin example/private-one: owner/repo#12 refused,
#                 "example/upstream PR 1235" accepted; origin a public fork:
#                 the same message accepted; no origin: refused;
#                 gates.privateRepo unset with an origin: accepted; the list
#                 match is case-insensitive (in the config or in the URL)
set -uo pipefail

HOOKS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-hooks
if ! [ -x "$HOOKS/pre-push" ] || ! [ -x "$HOOKS/commit-msg" ]; then
  echo "hooks not found or not executable in $HOOKS" >&2; exit 2
fi

TMP=$(mktemp -d) || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/home"
export HOME="$TMP/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GATES_PUBLIC_PUSH_OK GATES_CHECK_VISIBILITY GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

STUB="$TMP/stub-visibility.sh"
LOG="$TMP/stub.log"
cat >"$STUB" <<'STUBEOF'
#!/bin/sh
printf '%s %s\n' "$1" "$2" >"$STUB_LOG"
printf '%s\n' "$STUB_WORD"
exit "$STUB_RC"
STUBEOF
chmod +x "$STUB"
export STUB_LOG="$LOG"

# privs REPO NAME...: add each NAME to gates.privateRepo in REPO's local config
privs() {
  local r=$1 n; shift
  for n in "$@"; do git -C "$r" config --add gates.privateRepo "$n"; done
}
PRIVATE_ONE=example/private-one
PRIVATE_TWO=example/private-two

pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok    $1"; }
bad() { failn=$((failn + 1)); echo "FAIL  $1: $2"; }

# pp NAME WANT_RC WANT_STDERR_PATTERN URL WORD STUBRC [WANT_LOG] [OKVAR]
# Runs pre-push directly with the stub answering WORD and exiting STUBRC.
pp() {
  local name=$1 want=$2 pat=$3 url=$4 word=$5 src=$6 wantlog=${7:-} okvar=${8-}
  local rc err
  : >"$LOG"
  if [ -n "$okvar" ]; then
    err=$(STUB_WORD=$word STUB_RC=$src GATES_CHECK_VISIBILITY=$STUB GATES_PUBLIC_PUSH_OK=$okvar \
      "$HOOKS/pre-push" origin "$url" </dev/null 2>&1 >/dev/null); rc=$?
  else
    err=$(STUB_WORD=$word STUB_RC=$src GATES_CHECK_VISIBILITY=$STUB \
      "$HOOKS/pre-push" origin "$url" </dev/null 2>&1 >/dev/null); rc=$?
  fi
  if [ "$rc" -ne "$want" ]; then bad "$name" "rc=$rc, want $want; stderr: $err"; return; fi
  if [ -n "$pat" ] && ! printf '%s' "$err" | grep -Eq -- "$pat"; then bad "$name" "stderr lacks /$pat/: $err"; return; fi
  if [ -n "$wantlog" ] && [ "$(cat "$LOG")" != "$wantlog" ]; then bad "$name" "stub called with '$(cat "$LOG")', want '$wantlog'"; return; fi
  ok "$name"
}

GH=https://github.com
pp "local path: allowed, stub not called"  0 ''                        /srv/x/repo.git public 0 ''
pp "other host: allowed"                   0 ''                        https://example.com/o/r.git public 0 ''
pp "github https, private: allowed"        0 ''                        $GH/o/r.git private 0 'o r'
pp "github https, public: refused"         1 'o/r is public, not private .*owner' $GH/o/r.git public 0 'o r'
pp "github https, ask: refused"            1 'o/r is ask, not private'              $GH/o/r.git ask 2 'o r'
pp "public + OK=yes: allowed"              0 'o/r \(public\).*approved by GATES_PUBLIC_PUSH_OK' $GH/o/r.git public 0 'o r' yes
pp "ask + OK=yes: allowed"                 0 'o/r \(ask\).*approved'  $GH/o/r.git ask 2 'o r' yes
pp "public + OK=1: refused"                1 'o/r is public'           $GH/o/r.git public 0 'o r' 1
pp "public + OK=YES: refused"              1 'o/r is public'           $GH/o/r.git public 0 'o r' YES
pp "git@ form parsed"                      0 ''                        git@github.com:acme/widget.git private 0 'acme widget'
pp "git@ form without .git"                0 ''                        git@github.com:acme/widget private 0 'acme widget'
pp "ssh:// form parsed"                    0 ''                        ssh://git@github.com/acme/widget.git private 0 'acme widget'
pp "ssh:// form with port"                 0 ''                        ssh://git@github.com:22/acme/widget.git private 0 'acme widget'
pp "https with token and trailing slash"   0 ''                        https://x-access-token:abc@github.com/acme/widget.git/ private 0 'acme widget'
pp "repo name with dots"                   0 ''                        $GH/acme/a.b-c.git private 0 'acme a.b-c'
pp "git@ form, public: refused"            1 'acme/widget is public'   git@github.com:acme/widget.git public 0 'acme widget'
pp "github URL with no repo: refused"      1 'unknown'                $GH/onlyowner public 0 ''
pp "stub prints private but exits 1"       1 'o/r is unknown'                    $GH/o/r.git private 1 'o r'
pp "stub prints junk: refused"             1 'o/r is unknown'          $GH/o/r.git 'maybe' 0 'o r'
pp "stub prints nothing, exits 139"        1 'o/r is unknown'                    $GH/o/r.git '' 139 'o r'

# stub missing: no such file
rc=0
err=$(GATES_CHECK_VISIBILITY="$TMP/nonexistent" "$HOOKS/pre-push" origin $GH/o/r.git </dev/null 2>&1 >/dev/null) || rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$err" | grep -q 'o/r'; then ok "stub missing: refused"; else bad "stub missing: refused" "rc=$rc: $err"; fi

# through git ------------------------------------------------------------
git init -q --bare "$TMP/remote.git" || { echo "fixture failed" >&2; exit 2; }
git init -q "$TMP/work" || { echo "fixture failed" >&2; exit 2; }
W="$TMP/work"
git -C "$W" config user.name t
git -C "$W" config user.email t@example.invalid
git -C "$W" config commit.gpgsign false
git -C "$W" config core.hooksPath "$HOOKS"
git -C "$W" remote add origin "$TMP/remote.git"
git -C "$W" checkout -q -b main
echo a >"$W/a"
git -C "$W" add a
git -C "$W" commit -q -m "first" || { echo "fixture commit failed" >&2; exit 2; }
if err=$(git -C "$W" push -q origin main 2>&1) && git -C "$TMP/remote.git" rev-parse -q --verify refs/heads/main >/dev/null; then
  ok "git push to a local bare remote succeeds with the hook enabled"
else
  bad "git push to a local bare remote" "$err"
fi

# The hook really is invoked by git, for a github.com remote: git@github.com
# URLs go through a fake ssh that serves a local bare repository, so nothing
# leaves this machine. Public and unapproved: refused and nothing arrives.
# Private: the push goes through.
git init -q --bare "$TMP/fake-gh.git" || { echo "fixture failed" >&2; exit 2; }
cat >"$TMP/fake-ssh" <<'SSHEOF'
#!/bin/sh
for a; do last=$a; done
case $last in
git-receive-pack*) exec git receive-pack "$FAKE_REMOTE" ;;
git-upload-pack*) exec git upload-pack "$FAKE_REMOTE" ;;
esac
exit 1
SSHEOF
chmod +x "$TMP/fake-ssh"
git -C "$W" remote add gh git@github.com:o/r.git
export FAKE_REMOTE="$TMP/fake-gh.git" GIT_SSH_COMMAND="$TMP/fake-ssh"
rc=0
err=$(STUB_WORD=public STUB_RC=0 GATES_CHECK_VISIBILITY=$STUB git -C "$W" push gh main 2>&1) || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$err" | grep -q 'pre-push: refused: o/r is public' \
   && ! git -C "$FAKE_REMOTE" rev-parse -q --verify refs/heads/main >/dev/null; then
  ok "git push to a public github.com remote is refused by the hook, nothing arrives"
else
  bad "git push to a public github.com remote" "rc=$rc: $err"
fi
rc=0
err=$(STUB_WORD=private STUB_RC=0 GATES_CHECK_VISIBILITY=$STUB git -C "$W" push gh main 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && git -C "$FAKE_REMOTE" rev-parse -q --verify refs/heads/main >/dev/null && [ "$(cat "$LOG")" = "o r" ]; then
  ok "git push to a private github.com remote goes through, hook called with o r"
else
  bad "git push to a private github.com remote" "rc=$rc: $err"
fi

# commit-msg -------------------------------------------------------------
# cm NAME WANT_RC ORIGIN MESSAGE   (ORIGIN empty: no origin at all)
CM_REPOS="$PRIVATE_ONE $PRIVATE_TWO"
cm() {
  local name=$1 want=$2 origin=$3 msg=$4 d rc err
  d=$(mktemp -d "$TMP/cm.XXXXXX")
  git init -q "$d" || { bad "$name" "git init failed"; return; }
  git -C "$d" config user.name t
  git -C "$d" config user.email t@example.invalid
  git -C "$d" config commit.gpgsign false
  git -C "$d" config core.hooksPath "$HOOKS"
  # shellcheck disable=SC2086
  [ -z "$CM_REPOS" ] || privs "$d" $CM_REPOS
  [ -n "$origin" ] && git -C "$d" remote add origin "$origin"
  echo x >"$d/f"
  git -C "$d" add f
  rc=0
  err=$(git -C "$d" commit -q -m "$msg" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ] && [ "$want" -ne 0 ]; then bad "$name" "commit accepted, want refusal"; return; fi
  if [ "$rc" -ne 0 ] && [ "$want" -eq 0 ]; then bad "$name" "commit refused: $err"; return; fi
  if [ "$want" -ne 0 ] && ! printf '%s' "$err" | grep -q 'commit-msg: GitHub cross-reference'; then bad "$name" "refused, but not by the hook: $err"; return; fi
  ok "$name"
}
XREF="fix per example/upstream#12"
cm "private origin, owner/repo#12: refused"          1 https://github.com/example/private-one.git "$XREF"
cm "private origin, owner/repo PR 1235: accepted"    0 https://github.com/example/private-one.git "see example/upstream PR 1235"
cm "private origin without .git: refused"            1 https://github.com/example/private-one "$XREF"
cm "private origin via git@: refused"                1 git@github.com:example/private-one.git "$XREF"
cm "second listed repo origin: refused"              1 https://github.com/example/private-two.git "$XREF"
cm "github URL in message, private origin: refused"  1 https://github.com/example/private-one.git "see https://github.com/o/r/pull/3"
cm "public fork origin: owner/repo#12 accepted"      0 https://github.com/example/public-fork.git "$XREF"
cm "similar name, not ours: accepted"                0 https://github.com/example/private-one-fork.git "$XREF"
cm "other owner, same repo name: accepted"           0 https://github.com/someone/private-one.git "$XREF"
cm "no origin: owner/repo#12 refused"                1 '' "$XREF"
cm "no origin: plain message accepted"               0 '' "plain message"
# no gates.privateRepo set: an origin means accepted, no origin is still enforced
CM_REPOS=''
cm "no list, origin set: owner/repo#12 accepted"     0 https://github.com/example/private-one.git "$XREF"
cm "no list, no origin: owner/repo#12 refused"       1 '' "$XREF"
# the list match ignores case, in the URL or in the config
CM_REPOS="$PRIVATE_ONE $PRIVATE_TWO"
cm "mixed-case origin URL: refused"                  1 https://github.com/EXAMPLE/Private-One.git "$XREF"
CM_REPOS='EXAMPLE/Private-One'
cm "mixed-case config, lowercase URL: refused"       1 https://github.com/example/private-one.git "$XREF"
CM_REPOS="$PRIVATE_ONE $PRIVATE_TWO"

# pre-push scan of the commits being pushed (every repo but a public one) ----------
# Real `git push` over the fake ssh to a github.com URL. The work repo has no
# origin, so commit-msg would refuse an xref message; those commits are made
# with -n, as the scan exists to catch exactly that.
PRIV=git@github.com:example/private-one.git
sc_new() { # sc_new URL: fresh work repo S and fresh fake remote, one clean commit pushed
  SC=$(mktemp -d "$TMP/sc.XXXXXX")
  git init -q "$SC" || { echo "fixture failed" >&2; exit 2; }
  git -C "$SC" config user.name t
  git -C "$SC" config user.email t@example.invalid
  git -C "$SC" config commit.gpgsign false
  git -C "$SC" config core.hooksPath "$HOOKS"
  privs "$SC" "$PRIVATE_ONE" "$PRIVATE_TWO"
  git -C "$SC" remote add gh "$1"
  git -C "$SC" checkout -q -b main
  FAKE_REMOTE=$(mktemp -d "$TMP/scr.XXXXXX"); export FAKE_REMOTE
  git init -q --bare "$FAKE_REMOTE" || { echo "fixture failed" >&2; exit 2; }
  echo base >"$SC/base"; git -C "$SC" add base
  git -C "$SC" commit -q -m "base" || { echo "fixture commit failed" >&2; exit 2; }
}
sc_commit() { # sc_commit FILE MESSAGE...: commit with -n
  local f=$1; shift
  echo "$f" >"$SC/$f"; git -C "$SC" add "$f"
  git -C "$SC" commit -q -n -m "$*" || { echo "fixture commit failed" >&2; exit 2; }
}
sc_push() { # sc_push WORD [OKVAR] ARGS...: sets rc and err
  local word=$1 okvar=$2; shift 2
  rc=0
  if [ -n "$okvar" ]; then
    err=$(STUB_WORD=$word STUB_RC=0 GATES_CHECK_VISIBILITY=$STUB GATES_PUBLIC_PUSH_OK=$okvar git -C "$SC" push gh "$@" 2>&1) || rc=$?
  else
    err=$(STUB_WORD=$word STUB_RC=0 GATES_CHECK_VISIBILITY=$STUB git -C "$SC" push gh "$@" 2>&1) || rc=$?
  fi
}
sc_arrived() { git -C "$FAKE_REMOTE" rev-parse -q --verify "refs/heads/$1" >/dev/null; }
# sc_expect NAME refused|allowed [SHA_REV]: judges rc/err from sc_push
sc_expect() {
  local name=$1 want=$2 rev=${3:-}
  if [ "$want" = allowed ]; then
    if [ "$rc" -eq 0 ]; then ok "$name"; else bad "$name" "rc=$rc: $err"; fi
    return
  fi
  if [ "$rc" -eq 0 ]; then bad "$name" "push accepted, want refusal"; return; fi
  if ! printf '%s' "$err" | grep -q 'pre-push: refused: GitHub cross-reference'; then bad "$name" "refused, but not by the scan: $err"; return; fi
  if [ -n "$rev" ] && ! printf '%s' "$err" | grep -q "$(git -C "$SC" rev-parse --short "$rev")"; then bad "$name" "stderr lacks short sha of $rev: $err"; return; fi
  ok "$name"
}

sc_new $PRIV
sc_commit c1 "clean one"; sc_commit c2 "clean two"
sc_push private '' main
sc_expect "scan: clean commits to a private repo: allowed" allowed
sc_arrived main || bad "scan: clean push arrived" "main missing on the remote"

sc_commit x1 "fix per foo/bar#12"
sc_push private '' main
sc_expect "scan: commit -n with foo/bar#12: refused, names short sha" refused HEAD
if printf '%s' "$err" | grep -q "owner/repo PR N"; then ok "scan: refusal gives the fix"; else bad "scan: refusal gives the fix" "$err"; fi
if sc_arrived main && [ "$(git -C "$FAKE_REMOTE" rev-parse main)" = "$(git -C "$SC" rev-parse HEAD)" ]; then bad "scan: refused push delivered nothing" "xref commit arrived"; else ok "scan: refused push delivered nothing"; fi

sc_new $PRIV
sc_push private '' main
git -C "$SC" checkout -q -b other
sc_commit y1 "see foo/bar#12"
bad_sha=$(git -C "$SC" rev-parse HEAD)
git -C "$SC" checkout -q main
git -C "$SC" cherry-pick "$bad_sha" >/dev/null 2>&1 || { echo "fixture cherry-pick failed" >&2; exit 2; }
sc_push private '' main
sc_expect "scan: xref arriving by cherry-pick: refused" refused HEAD

sc_new $PRIV
sc_push private '' main
git -C "$SC" checkout -q -b newbr
sc_commit z1 "ref foo/bar@abcdef1234"
sc_push private '' newbr
sc_expect "scan: new branch carrying an xref commit: refused" refused HEAD
git -C "$SC" checkout -q main
git -C "$SC" checkout -q -b cleanbr
sc_commit z2 "nothing special"
sc_push private '' cleanbr
sc_expect "scan: clean new branch: allowed" allowed
sc_arrived cleanbr || bad "scan: clean new branch arrived" "missing"

sc_push private '' :cleanbr
sc_expect "scan: branch deletion: allowed" allowed
if sc_arrived cleanbr; then bad "scan: branch deletion took effect" "still there"; else ok "scan: branch deletion took effect"; fi

# an xref commit already on the target (pushed with --no-verify) is old
# history: a clean commit on top is allowed
sc_new $PRIV
sc_commit o1 "old foo/bar#12"
sc_push private '' --no-verify main
sc_commit o2 "clean on top"
sc_push private '' main
sc_expect "scan: xref already on the target, clean on top: allowed" allowed

sc_new $PRIV
sc_push private '' main
sc_commit b1 "subject is fine

body line one
body mentions foo/bar#99 here"
sc_push private '' main
sc_expect "scan: xref in the body, not the subject: refused" refused HEAD
if printf '%s' "$err" | grep -q 'subject is fine'; then ok "scan: refusal prints the subject"; else bad "scan: refusal prints the subject" "$err"; fi

sc_new $PRIV
sc_push private '' main
sc_commit u1 "see https://github.com/x/y/pull/3"
sc_push private '' main
sc_expect "scan: github.com pull URL in the message: refused" refused HEAD

sc_new $PRIV
sc_push private '' main
sc_commit p1 "fix per foo/bar#12"
sc_push private yes main
sc_expect "scan: GATES_PUBLIC_PUSH_OK=yes does not skip the scan: refused" refused HEAD

sc_new git@github.com:example/upstream.git
sc_commit n1 "fix per foo/bar#12"
sc_push public yes main
sc_expect "scan: same commit to a non-private github repo (OK=yes): allowed, no scan" allowed

# the scan does not depend on gates.privateRepo: with the key unset an xref
# commit to a private repo is still refused by the scan, and the visibility
# stub is still consulted
sc_new $PRIV
sc_push private '' main
git -C "$SC" config --unset-all gates.privateRepo
sc_commit nl1 "fix per foo/bar#12"
: >"$LOG"
sc_push private '' main
sc_expect "scan: no gates.privateRepo: xref commit still scanned, refused" refused HEAD
if [ "$(cat "$LOG")" = "example private-one" ]; then ok "scan: no gates.privateRepo: visibility stub consulted"; else bad "scan: no gates.privateRepo: visibility stub consulted" "stub log '$(cat "$LOG")'"; fi
sc_new $PRIV
git -C "$SC" config --unset-all gates.privateRepo
sc_commit nl2 "nothing special"
sc_push private '' main
sc_expect "scan: no gates.privateRepo: clean commits to a private repo: allowed" allowed
sc_new $PRIV
git -C "$SC" config --unset-all gates.privateRepo
sc_push public '' main
if [ "$rc" -ne 0 ] && printf '%s' "$err" | grep -q 'pre-push: refused: example/private-one is public' && ! sc_arrived main; then ok "scan: no gates.privateRepo: public repo still refused"; else bad "scan: no gates.privateRepo: public repo still refused" "rc=$rc: $err"; fi

# a repo the checker calls public is not scanned (its history is public);
# a repo not in the list and not public is
UNL=git@github.com:someone/unlisted.git
sc_new $UNL
sc_commit l1 "fix per foo/bar#12"
sc_push private '' main
sc_expect "scan: unlisted private github repo with an xref commit: refused" refused HEAD
sc_new $UNL
sc_commit l3 "fix per foo/bar#12"
sc_push public yes main
sc_expect "scan: stub says public, OK=yes, xref commit: allowed, not scanned" allowed
sc_arrived main || bad "scan: public + OK=yes push arrived" "main missing on the remote"
sc_new $UNL
sc_commit l4 "fix per foo/bar#12"
sc_push ask '' main
sc_expect "scan: stub says ask, xref commit: refused by the scan" refused HEAD
if ! printf '%s' "$err" | grep -q 'is ask, not private'; then ok "scan: hit is reported before the visibility verdict"; else bad "scan: hit reported before the verdict" "$err"; fi
sc_new $UNL
sc_commit l5 "fix per foo/bar#12"
rc=0
err=$(STUB_WORD='' STUB_RC=139 GATES_CHECK_VISIBILITY=$STUB git -C "$SC" push gh main 2>&1) || rc=$?
sc_expect "scan: stub crashing, xref commit: refused by the scan" refused HEAD

# exclusion is what the target itself lists (ls-remote): a commit pushed to a
# mirror first is still scanned on the push to the private remote
sc_new $PRIV
sc_push private '' main
MIRROR=$(mktemp -d "$TMP/mirror.XXXXXX")
git init -q --bare "$MIRROR" || { echo "fixture failed" >&2; exit 2; }
git -C "$SC" remote add mirror "$MIRROR"
sc_commit m1 "mirrored foo/bar#12"
if git -C "$SC" push -q mirror main 2>/dev/null; then ok "scan: xref commit pushed to a non-github mirror: allowed"; else bad "scan: xref commit pushed to a mirror" "refused"; fi
sc_push private '' main
sc_expect "scan: xref commit already on a mirror, now to the private remote: refused" refused HEAD

# host resolution (ssh -G stubbed by GATES_SSH) ------------------------------
# A Host alias for github.com is judged as GitHub; an alias for anything else
# passes with a note; a host beginning with "-" never reaches ssh.
SSHSTUB="$TMP/stub-ssh-g"
SSH_ARGV="$TMP/stub-ssh-g.argv"
cat >"$SSHSTUB" <<'SSHSTUBEOF'
#!/bin/sh
printf '%s\n' "$*" >>"$SSH_ARGV"
printf 'user git\nhostname %s\nport 22\n' "$STUB_HOSTNAME"
SSHSTUBEOF
chmod +x "$SSHSTUB"
export SSH_ARGV
# ppssh NAME WANT_RC STDERR_PATTERN URL WORD HOSTNAME WANT_LOG: pattern '-' means stderr must be empty
ppssh() {
  local name=$1 want=$2 pat=$3 url=$4 word=$5 hn=$6 wantlog=$7 rc err
  : >"$LOG"; : >"$SSH_ARGV"
  err=$(STUB_WORD=$word STUB_RC=0 STUB_HOSTNAME=$hn GATES_SSH=$SSHSTUB GATES_CHECK_VISIBILITY=$STUB \
    "$HOOKS/pre-push" origin "$url" </dev/null 2>&1 >/dev/null); rc=$?
  if [ "$rc" -ne "$want" ]; then bad "$name" "rc=$rc, want $want; stderr: $err"; return; fi
  if [ "$pat" = - ]; then
    [ -z "$err" ] || { bad "$name" "stderr not empty: $err"; return; }
  elif [ -n "$pat" ] && ! printf '%s' "$err" | grep -Eq -- "$pat"; then bad "$name" "stderr lacks /$pat/: $err"; return; fi
  if [ "$(cat "$LOG")" != "$wantlog" ]; then bad "$name" "stub called with '$(cat "$LOG")', want '$wantlog'"; return; fi
  ok "$name"
}
ppssh "alias for github.com, public: refused, checker called" 1 'o/r is public' git@gh-work:o/r.git public github.com 'o r'
ppssh "alias for github.com, private: allowed, checker called" 0 '' git@gh-work:o/r.git private GitHub.com. 'o r'
ppssh "ssh:// alias for github.com, public: refused"          1 'o/r is public' ssh://git@gh-work/o/r.git public github.com 'o r'
ppssh "alias for another host: allowed with a note"           0 'not checked: host gh-work is not GitHub' git@gh-work:o/r.git public example.net ''
ppssh "ssh -G prints no hostname: allowed with a note"        0 'not checked: host gh-work is not GitHub' git@gh-work:o/r.git public '' ''
ppssh "https URL on another host: note, ssh not run"          0 'not checked: host example.com is not GitHub' https://example.com/o/r.git public github.com ''
if [ ! -s "$SSH_ARGV" ]; then ok "https host is never resolved through ssh"; else bad "https host is never resolved" "ssh argv: $(cat "$SSH_ARGV")"; fi
ppssh "github.com via ssh: no resolution needed"              0 '' git@github.com:o/r.git private example.net 'o r'
if [ ! -s "$SSH_ARGV" ]; then ok "a GitHub name is not passed to ssh -G"; else bad "a GitHub name is not passed to ssh" "$(cat "$SSH_ARGV")"; fi
ppssh "https://github.com./ trailing dot: reaches the checker" 1 'o/r is public' https://github.com./o/r.git public example.net 'o r'
ppssh "git@github.com.:o/r trailing dot: reaches the checker" 0 '' git@github.com.:o/r.git private example.net 'o r'
ppssh "gist https, no approval: refused, says gist"           1 'gist' https://gist.github.com/abc.git private github.com ''
ppssh "git@gist.github.com, no approval: refused"             1 'gist' git@gist.github.com:abc.git private github.com ''
rc=0
err=$(STUB_WORD=private STUB_RC=0 GATES_CHECK_VISIBILITY=$STUB GATES_PUBLIC_PUSH_OK=yes "$HOOKS/pre-push" origin https://gist.github.com/abc.git </dev/null 2>&1 >/dev/null) || rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$err" | grep -q 'gist.*approved by GATES_PUBLIC_PUSH_OK'; then ok "gist with GATES_PUBLIC_PUSH_OK=yes: allowed"; else bad "gist with OK=yes" "rc=$rc: $err"; fi
ppssh "host starting with - (scp-like): not resolved, note"    0 'not checked' 'git@-oProxyCommand=x:o/r.git' public github.com ''
if [ ! -s "$SSH_ARGV" ]; then ok "host starting with - is never passed to ssh (scp-like)"; else bad "dash host passed to ssh (scp-like)" "$(cat "$SSH_ARGV")"; fi
ppssh "host starting with - (ssh://): not resolved, note"      0 'not checked' 'ssh://-oProxyCommand=x/o/r.git' public github.com ''
if [ ! -s "$SSH_ARGV" ]; then ok "host starting with - is never passed to ssh (ssh://)"; else bad "dash host passed to ssh (ssh://)" "$(cat "$SSH_ARGV")"; fi
ppssh "a resolved host is passed after --"                    0 '' git@gh-work:o/r.git private github.com 'o r'
if [ "$(cat "$SSH_ARGV")" = "-G -- gh-work" ]; then ok "ssh is run as: ssh -G -- HOST"; else bad "ssh argv" "$(cat "$SSH_ARGV")"; fi
ppssh "local path: no note"                                    0 - /srv/x/repo.git public github.com ''
ppssh "relative local path: no note"                           0 - ./repo.git public github.com ''
rm -f "$SSH_ARGV"

# through git: an alias for github.com whose checker answers public is refused
# and nothing arrives; the alias for another host goes through with a note
sc_new git@gh-work:o/r.git
sc_commit al1 "alias commit"
: >"$LOG"
rc=0
err=$(STUB_WORD=public STUB_RC=0 STUB_HOSTNAME=github.com GATES_SSH=$SSHSTUB GATES_CHECK_VISIBILITY=$STUB git -C "$SC" push gh main 2>&1) || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$err" | grep -q 'pre-push: refused: o/r is public' && ! sc_arrived main && [ "$(cat "$LOG")" = "o r" ]; then
  ok "git push through an alias for github.com, public: refused, nothing arrives, checker called"
else bad "git push through an alias for github.com" "rc=$rc: $err"; fi
rc=0
err=$(STUB_WORD=public STUB_RC=0 STUB_HOSTNAME=example.net GATES_SSH=$SSHSTUB GATES_CHECK_VISIBILITY=$STUB git -C "$SC" push gh main 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$err" | grep -q 'not checked: host gh-work' && sc_arrived main; then
  ok "git push through an alias for another host: arrives, with the note"
else bad "git push through an alias for another host" "rc=$rc: $err"; fi

# the remote name is re-pointed after an xref commit went to the old target
# with --no-verify: the old tracking refs must not exempt it
OLDBARE=$(mktemp -d "$TMP/old.XXXXXX")
git init -q --bare "$OLDBARE" || { echo "fixture failed" >&2; exit 2; }
sc_new "$OLDBARE"
sc_commit rp1 "old foo/bar#12"
git -C "$SC" push -q --no-verify gh main 2>/dev/null || { echo "fixture push failed" >&2; exit 2; }
git -C "$SC" remote set-url gh "$PRIV"
sc_push private '' main
sc_expect "scan: remote re-pointed, xref commit only on the old target: refused" refused HEAD
if sc_arrived main; then bad "scan: re-pointed push delivered nothing" "main arrived"; else ok "scan: re-pointed push delivered nothing"; fi

# a commit already on the target is not rescanned when a new branch is pushed
sc_new $PRIV
sc_commit pre1 "old foo/bar#12"
sc_push private '' --no-verify main
git -C "$SC" checkout -q -b newer
sc_commit pre2 "clean new branch work"
sc_push private '' newer
sc_expect "scan: new branch on top of an xref commit already on the target: allowed" allowed
sc_commit pre3 "new foo/bar#13"
sc_push private '' newer
sc_expect "scan: a new xref commit on that branch is still refused" refused HEAD
if printf '%s' "$err" | grep -q "old foo"; then bad "scan: only the new commit is named" "$err"; else ok "scan: only the new commit is named"; fi

# ls-remote failing (upload-pack not served): xref still refused, clean allowed
cat >"$TMP/fake-ssh-noup" <<'SSHEOF'
#!/bin/sh
for a; do last=$a; done
case $last in
git-receive-pack*) exec git receive-pack "$FAKE_REMOTE" ;;
esac
exit 1
SSHEOF
chmod +x "$TMP/fake-ssh-noup"
SAVED_SSH=$GIT_SSH_COMMAND
export GIT_SSH_COMMAND="$TMP/fake-ssh-noup"
sc_new $PRIV
sc_push private '' main
sc_commit nu1 "fix per foo/bar#12"
sc_push private '' main
sc_expect "scan: ls-remote fails, xref commit: refused" refused HEAD
sc_new $PRIV
sc_push private '' main
sc_commit nu2 "nothing special"
sc_push private '' main
sc_expect "scan: ls-remote fails, clean commit: allowed" allowed
if sc_arrived main && [ "$(git -C "$FAKE_REMOTE" rev-parse main)" = "$(git -C "$SC" rev-parse HEAD)" ]; then ok "scan: ls-remote fails, clean push arrived"; else bad "scan: ls-remote fails, clean push arrived" "tip missing"; fi
export GIT_SSH_COMMAND=$SAVED_SSH

# xref.sh missing: both hooks refuse
NOLIB="$TMP/hooks-nolib"
mkdir "$NOLIB"; cp "$HOOKS/pre-push" "$HOOKS/commit-msg" "$NOLIB/"
rc=0
err=$(STUB_WORD=private STUB_RC=0 GATES_CHECK_VISIBILITY=$STUB "$NOLIB/pre-push" origin $GH/o/r.git </dev/null 2>&1 >/dev/null) || rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$err" | grep -q 'pre-push: refused: .*xref.sh'; then ok "xref.sh missing: pre-push refuses"; else bad "xref.sh missing: pre-push refuses" "rc=$rc: $err"; fi
sc_new $PRIV
git -C "$SC" config core.hooksPath "$NOLIB"
echo q >"$SC/q"; git -C "$SC" add q
rc=0
err=$(git -C "$SC" commit -q -m "plain message" 2>&1) || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$err" | grep -q 'commit-msg: refused: .*xref.sh'; then ok "xref.sh missing: commit-msg refuses"; else bad "xref.sh missing: commit-msg refuses" "rc=$rc: $err"; fi

echo "$pass passed, $failn failed"
[ "$failn" -eq 0 ]
