#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joe Fernandez
#
# Test for public-scan.sh, found beside this file. Exit 0 if every case passed,
# 1 if any failed, 2 if the fixture could not be built.
#
#   ./test-public-scan.sh
#
# Offline. Fixtures live in a mktemp -d that is removed at the end, with HOME
# and the git config pointed there. Dummy values only: a password assignment,
# example.com and example.invalid addresses, addresses in the TEST-NET-1
# documentation range (RFC 5737), and fd-prefixed unique-local IPv6 and
# locally administered MAC values. They are assembled at run time, so this file
# holds no literal the scanner would flag when it is itself scanned.
#
# Cases:
#   controls       clean dir, plain hit, empty dir, each in a git and a plain dir
#   fail-open      a name with a newline (git and plain), a NUL-byte file
#                  (skipped and named, exit 0, counted), an invalid UTF-8 byte
#                  on the secret's line under a UTF-8 locale, an unreadable file,
#                  a tracked file deleted from the work tree, a directory where
#                  a file was listed, a fifo, an unreadable subdirectory (git
#                  and plain: the listing is incomplete), grep writing to
#                  stderr; the T files count is the text files given to grep
#   links          a symlink (git and plain; dangling, to a directory, to a
#                  file outside DIR) is named, counted and not followed, its
#                  target string is scanned and a hit printed as (symlink
#                  target); a gitlink and a real submodule are named, counted
#                  and not scanned
#   bash version   the 4.4 check is asserted by grep only: the script cannot be
#                  run under a faked BASH_VERSINFO (it is read-only), and no old
#                  bash is installed
#   allow list     a longer address, a longer IPv4 address, the exact string
#                  alone, a second address on the line, an angle-bracketed one,
#                  a colon extending an IPv6 or MAC address on either side
#   audit 11-08    escaped . and @ forms next to an allowed string (exit 1), an
#                  escaped allow string, core.fsmonitor in DIR not run
#   deny list      PUBLIC_SCAN_DENY missing or unreadable (exit 2), a CRLF term,
#                  a trailing-space term, comments and blanks, the term count
#
# The unreadable-file cases are skipped when run as root.
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/public-scan.sh"
[ -r "$SRC" ] || { echo "public-scan.sh not found beside this file" >&2; exit 2; }

TMP=$(mktemp -d) || { echo "mktemp failed" >&2; exit 2; }
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
mkdir "$TMP/home" "$TMP/w" "$TMP/bin"
# The script under test is run from a copy, so that a public-scan.deny beside
# the original (the box keeps a real one) does not change the term counts.
PS="$TMP/bin/public-scan.sh"
cp "$SRC" "$PS" || exit 2
export HOME="$TMP/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE PUBLIC_SCAN_ALLOW PUBLIC_SCAN_DENY PUBLIC_SCAN_TERMS
W="$TMP/w"

CRED="pass""word=hunter2abc"
AT="@"
ADDR="support${AT}example.com"
NET="192.0.2"
IP="$NET.4"
ULA="fd12"":3456"":789a""::1"
MAC="02:00:5e"":10:00:01"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

out=; rc=0
# run DIR [VAR=value ...]: public-scan.sh on DIR, stdout and stderr together.
run() {
  local d=$1; shift
  out=$(env "$@" bash "$PS" "$d" 2>&1); rc=$?
}
# expect NAME RC REGEX: the last run exited RC and its output matches REGEX.
expect() {
  if [ "$rc" = "$2" ] && printf '%s\n' "$out" | grep -Eq -- "$3"; then ok "$1"
  else bad "$1 (rc $rc, want $2; wanted /$3/)"; printf '%s\n' "$out" | head -n 8 | sed 's/^/     | /'; fi
}
# expect_not NAME REGEX: the last run's output does not match REGEX.
expect_not() {
  if printf '%s\n' "$out" | grep -Eq -- "$2"; then bad "$1 (matched /$2/)"; else ok "$1"; fi
}

mk()  { rm -rf "${W:?}/$1"; mkdir -p "$W/$1"; }
gmk() { mk "$1"; git -C "$W/$1" init -q || exit 2; }
gadd() { local d=$1; shift; git -C "$W/$d" add -- "$@" || exit 2; }

AS_ROOT=0; [ "$(id -u)" = 0 ] && AS_ROOT=1

# ---- controls
mk clean;  printf 'nothing to see\n' > "$W/clean/a.txt"
run "$W/clean";  expect "plain clean dir: exit 0" 0 '^ok    no public-scan hits in .* \(1 files, 0 binary skipped\)$'
gmk gclean; printf 'nothing to see\n' > "$W/gclean/a.txt"; gadd gclean a.txt
run "$W/gclean"; expect "git clean dir: exit 0" 0 '^ok    no public-scan hits'
mk hit;  printf '%s\n' "$CRED" > "$W/hit/a.txt"
run "$W/hit";  expect "plain hit: exit 1, FAIL block" 1 '^FAIL  assigned password'
expect "plain hit: file and line printed" 1 'a\.txt:1:'
gmk ghit; printf '%s\n' "$CRED" > "$W/ghit/a.txt"; gadd ghit a.txt
run "$W/ghit"; expect "git hit: exit 1" 1 '^FAIL  assigned password'
gmk ghit2; printf '%s\n' "$CRED" > "$W/ghit2/a.txt"
run "$W/ghit2"; expect "git, untracked not ignored file is scanned: exit 1" 1 '^FAIL  assigned password'
mk empty;  run "$W/empty";  expect "empty plain dir: exit 2" 2 'nothing was scanned'
gmk gempty; run "$W/gempty"; expect "empty git dir: exit 2" 2 'nothing was scanned'
run "$W/nonexistent"; expect "missing DIR: usage, exit 2" 2 'usage'
mk addr; printf 'write to %s or see %s\n' "$ADDR" "$IP" > "$W/addr/a.txt"
run "$W/addr"; expect "email hit: exit 1" 1 '^FAIL  email address'
expect "IPv4 hit: exit 1" 1 '^FAIL  IPv4 address'

# ---- finding 3: names
gmk nlg; printf '%s\n' "$CRED" > "$W/nlg/$(printf 'x\ny.txt')"; gadd nlg .
run "$W/nlg"; expect "newline in a name, git branch: exit 2, named" 2 'not scanned: .*newline in name'
expect_not "newline in a name, git branch: not ok" '^ok '
mk nlp; printf '%s\n' "$CRED" > "$W/nlp/$(printf 'x\ny.txt')"
run "$W/nlp"; expect "newline in a name, find branch: exit 2, named" 2 'not scanned: .*newline in name'
expect_not "newline in a name, find branch: not ok" '^ok '

# ---- finding 3: binary
mk bin; printf '%s\n\0\n' "$CRED" > "$W/bin/f.bin"; printf 'text\n' > "$W/bin/t.txt"
run "$W/bin"; expect "NUL-byte file holding the dummy credential, exit 0" 0 '^ok    no public-scan hits'
expect "NUL-byte file is named as skipped" 0 'public-scan\.sh: skipped \(binary\): .*/bin/f\.bin'
expect "ok line counts 1 text file, 1 binary skipped" 0 '\(1 files, 1 binary skipped\)'
gmk gbin; printf '%s\n\0\n' "$CRED" > "$W/gbin/f.bin"; printf '%s\n' "$CRED" > "$W/gbin/t.txt"; gadd gbin f.bin t.txt
run "$W/gbin"; expect "git: text file still scanned beside a binary: exit 1" 1 'skipped \(binary\).*f\.bin'
expect "git: the hit is in the text file" 1 't\.txt:1:'
mk allbin; printf '\0\0\n' > "$W/allbin/f.bin"
run "$W/allbin"; expect "only binary files: exit 0, 0 files, 1 skipped" 0 '\(0 files, 1 binary skipped\)'
mk cnt; printf 'a\n' > "$W/cnt/1.txt"; printf 'b\n' > "$W/cnt/2.txt"; printf 'c\n' > "$W/cnt/3.txt"; printf '\0' > "$W/cnt/4.bin"; printf '\0' > "$W/cnt/5.bin"
run "$W/cnt"; expect "T counts text files only (3 text, 2 binary)" 0 '\(3 files, 2 binary skipped\)'

# ---- finding 3: encoding
mk enc; printf 'caf\xe9 %s\n' "$CRED" > "$W/enc/f.txt"
run "$W/enc" LANG=C.UTF-8 LC_ALL=C.UTF-8; expect "invalid byte 0xE9 on the secret's line, UTF-8 locale: exit 1" 1 '^FAIL  assigned password'
run "$W/enc" LANG=C LC_ALL=C;             expect "same under the C locale: exit 1" 1 '^FAIL  assigned password'
mk enc2; printf 'caf\xe9\n%s\n' "$CRED" > "$W/enc2/f.txt"
run "$W/enc2" LANG=C.UTF-8 LC_ALL=C.UTF-8; expect "invalid byte on another line: exit 1" 1 '^FAIL  assigned password'

# ---- finding 3: unreadable, deleted, symlink, gitlink
if [ "$AS_ROOT" = 1 ]; then
  echo "skip mode-000 cases (running as root)"
else
  mk unr; printf '%s\n' "$CRED" > "$W/unr/f.txt"; chmod 000 "$W/unr/f.txt"
  run "$W/unr"; expect "mode 000 file: exit 2, named" 2 'not scanned: .*f\.txt \(unreadable\)'
  expect_not "mode 000 file: not ok" '^ok '
  gmk gunr; printf '%s\n' "$CRED" > "$W/gunr/f.txt"; gadd gunr f.txt; chmod 000 "$W/gunr/f.txt"
  run "$W/gunr"; expect "git: mode 000 file: exit 2" 2 'not scanned: .*\(unreadable\)'
fi
gmk del; printf '%s\n' "$CRED" > "$W/del/f.txt"; printf 'x\n' > "$W/del/g.txt"; gadd del f.txt g.txt; rm "$W/del/f.txt"
run "$W/del"; expect "tracked file deleted from the work tree: exit 2, named" 2 'not scanned: .*f\.txt \(missing'
expect_not "deleted tracked file: not ok" '^ok '
gmk ggl; printf 'x\n' > "$W/ggl/a.txt"; gadd ggl a.txt; mkdir "$W/ggl/sub"
git -C "$W/ggl" update-index --add --cacheinfo 160000,0123456789abcdef0123456789abcdef01234567,sub || exit 2
run "$W/ggl"; expect "gitlink: exit 0, named" 0 'public-scan\.sh: not scanned \(submodule\): .*/sub'
expect "gitlink: counted in the ok line" 0 '\(1 files, 0 binary skipped, 1 submodules not scanned\)'
gmk gdir; printf 'x\n' > "$W/gdir/a.txt"; printf 'x\n' > "$W/gdir/b.txt"; gadd gdir a.txt b.txt
rm "$W/gdir/a.txt"; mkdir "$W/gdir/a.txt"
run "$W/gdir"; expect "git: directory where a tracked file was listed: exit 2" 2 'not scanned: .*a\.txt \(directory listed'
expect_not "git: directory in place of a file: not ok" '^ok '
mk fifo; printf 'x\n' > "$W/fifo/a.txt"; mkfifo "$W/fifo/p"
run "$W/fifo"; expect "fifo: exit 2, not read" 2 'not scanned: .*/p \(not a regular file\)'

# ---- symlinks and submodules: named, counted, not followed
mk sym; printf 'x\n' > "$W/sym/real.txt"; ln -s real.txt "$W/sym/link.txt"
run "$W/sym"; expect "symlink, find branch: exit 0, named" 0 'public-scan\.sh: not followed \(symlink\): .*link\.txt'
expect "symlink, find branch: counted, not a file" 0 '\(1 files, 0 binary skipped, 1 links not followed\)'
gmk gsym; printf 'x\n' > "$W/gsym/real.txt"; ln -s real.txt "$W/gsym/link.txt"; gadd gsym real.txt link.txt
run "$W/gsym"; expect "symlink, git branch: exit 0, named" 0 'not followed \(symlink\): .*link\.txt'
expect "symlink, git branch: counted" 0 '\(1 files, 0 binary skipped, 1 links not followed\)'
run "$W/clean"; expect_not "no links: no links count in the ok line" 'links not followed|submodules'
mk dsym; printf 'x\n' > "$W/dsym/real.txt"; ln -s /nonexistent "$W/dsym/dangling"
run "$W/dsym"; expect "dangling symlink: exit 0, named" 0 'not followed \(symlink\): .*dangling'
gmk gdsym; printf 'x\n' > "$W/gdsym/real.txt"; ln -s /nonexistent "$W/gdsym/dangling"; gadd gdsym real.txt dangling
run "$W/gdsym"; expect "git: dangling symlink: exit 0, named" 0 'not followed \(symlink\): .*dangling'
mk dirsym; mkdir "$W/dirsym/sub"; printf 'x\n' > "$W/dirsym/sub/a.txt"; ln -s sub "$W/dirsym/lnk"
run "$W/dirsym"; expect "symlink to a directory: exit 0, named, not entered" 0 'not followed \(symlink\): .*lnk'
mkdir -p "$W/outside"; printf '%s\n' "$CRED" > "$W/outside/secret.txt"
mk outl; printf 'x\n' > "$W/outl/a.txt"; ln -s "$W/outside/secret.txt" "$W/outl/out"
run "$W/outl"; expect "symlink to a file outside DIR with a hit in it: exit 0, named" 0 'not followed \(symlink\): .*/out$'
expect_not "outside file's content is not scanned" 'secret\.txt:1|FAIL'
gmk goutl; printf 'x\n' > "$W/goutl/a.txt"; ln -s "$W/outside/secret.txt" "$W/goutl/out"; gadd goutl a.txt out
run "$W/goutl"; expect "git: symlink to an outside file with a hit in it: exit 0" 0 'not followed \(symlink\)'
printf 'zebrafoo\n' > "$W/deny.z"
mk ldeny; printf 'x\n' > "$W/ldeny/a.txt"; ln -s "/opt/zebrafoo/x" "$W/ldeny/lnk"
run "$W/ldeny" "PUBLIC_SCAN_DENY=$W/deny.z"; expect "symlink target holding a deny term: exit 1, shown as (symlink target)" 1 '^FAIL  deny-list term'
expect "symlink target hit: path and line" 1 '/ldeny/lnk \(symlink target\):1:/opt/zebrafoo/x'
expect "symlink target hit: still named" 1 'not followed \(symlink\): .*lnk'
gmk gldeny; printf 'x\n' > "$W/gldeny/a.txt"; ln -s "/opt/zebrafoo/x" "$W/gldeny/lnk"; gadd gldeny a.txt lnk
run "$W/gldeny" "PUBLIC_SCAN_DENY=$W/deny.z"; expect "git: symlink target deny term: exit 1, (symlink target)" 1 'lnk \(symlink target\):1:'
printf '%s\n' "$ADDR" > "$W/allow1"
run "$W/ldeny" "PUBLIC_SCAN_DENY=$W/deny.z" "PUBLIC_SCAN_ALLOW=$W/allow1"; expect "symlink target hit with an allow file set: same output" 1 'lnk \(symlink target\):1:/opt/zebrafoo/x'
mk lsec; printf 'x\n' > "$W/lsec/a.txt"; ln -s "$CRED" "$W/lsec/lnk"
run "$W/lsec"; expect "symlink target holding a dummy credential, exit 1" 1 '^FAIL  assigned password'
mk lok; printf 'x\n' > "$W/lok/a.txt"; ln -s "$W/outside/secret.txt" "$W/lok/lnk"
run "$W/lok" "PUBLIC_SCAN_DENY=$W/deny.z"; expect "clean symlink target with a deny file set: exit 0" 0 '1 links not followed, 1 deny terms'
mkdir "$W/subsrc"; git -C "$W/subsrc" init -q || exit 2
printf '%s\n' "$CRED" > "$W/subsrc/s.txt"
git -C "$W/subsrc" add s.txt || exit 2
git -C "$W/subsrc" -c user.name=t -c "user.email=t${AT}example.invalid" commit -q -m x || exit 2
gmk gsm
git -C "$W/gsm" -c protocol.file.allow=always submodule add -q "$W/subsrc" sub >/dev/null 2>&1 || { echo "fixture: submodule add failed" >&2; exit 2; }
run "$W/gsm"; expect "git submodule: exit 0, named" 0 'public-scan\.sh: not scanned \(submodule\): .*/sub$'
expect "git submodule: counted (.gitmodules is the one file)" 0 '\(1 files, 0 binary skipped, 1 submodules not scanned\)'

# ---- an incomplete listing is exit 2
if [ "$AS_ROOT" = 1 ]; then
  echo "skip unreadable subdirectory cases (running as root)"
else
  mk udir; printf 'x\n' > "$W/udir/a.txt"; mkdir "$W/udir/sub"; printf '%s\n' "$CRED" > "$W/udir/sub/f.txt"; chmod 000 "$W/udir/sub"
  run "$W/udir"; expect "plain: unreadable subdirectory: exit 2, message named" 2 'could not list every file'
  expect "plain: the find message is shown" 2 'Permission denied'
  expect_not "plain: unreadable subdirectory: not ok" '^ok '
  gmk gudir2; printf 'x\n' > "$W/gudir2/a.txt"; gadd gudir2 a.txt
  mkdir "$W/gudir2/sub"; printf '%s\n' "$CRED" > "$W/gudir2/sub/f.txt"; chmod 000 "$W/gudir2/sub"
  run "$W/gudir2"; expect "git: unreadable untracked subdirectory: exit 2, message named" 2 'could not list every file'
  expect "git: the ls-files message is shown" 2 'Permission denied'
  expect_not "git: unreadable subdirectory: not ok" '^ok '
fi

# ---- bash version: asserted by grep (see the header)
if grep -q 'BASH_VERSINFO' "$SRC" && grep -q 'needs bash 4\.4 or later (this is bash' "$SRC"; then ok "bash 4.4 check present in the script"
else bad "bash 4.4 check present in the script"; fi

# ---- finding 5: grep errors are not hidden
mkdir "$W/fakebin"
REALGREP=$(command -v grep)
printf '#!/bin/bash\ncase "$*" in *AKIA*) echo "grep: simulated failure" >&2; exit 2 ;; esac\nexec %s "$@"\n' "$REALGREP" > "$W/fakebin/grep"
chmod 755 "$W/fakebin/grep"
run "$W/clean" "PATH=$W/fakebin:$PATH"; expect "grep stderr shown, exit 2" 2 'simulated failure'
expect_not "grep stderr: not ok" '^ok '

# ---- finding 8: allow list
printf '%s\n' "$ADDR" > "$W/allow1"
mk al1; printf 'mail xsupport%sexample.com now\n' "$AT" > "$W/al1/a.txt"
run "$W/al1"; expect "no allow: longer address is a hit" 1 '^FAIL  email address'
run "$W/al1" "PUBLIC_SCAN_ALLOW=$W/allow1"; expect "allow $ADDR vs x$ADDR: exit 1" 1 '^FAIL  email address'
printf '%s\n' "$IP" > "$W/allow2"
mk al2; printf 'host %s5 up\n' "$IP" > "$W/al2/a.txt"
run "$W/al2" "PUBLIC_SCAN_ALLOW=$W/allow2"; expect "allow $IP vs ${IP}5: exit 1" 1 '^FAIL  IPv4 address'
mk al2b; printf 'host-%s up\n' "$IP" > "$W/al2b/a.txt"
run "$W/al2b" "PUBLIC_SCAN_ALLOW=$W/allow2"; expect "allow $IP vs host-$IP: exit 1" 1 '^FAIL  IPv4 address'
mk al3; printf 'contact %s now\n' "$ADDR" > "$W/al3/a.txt"
run "$W/al3" "PUBLIC_SCAN_ALLOW=$W/allow1"; expect "the exact allowed string alone: exit 0" 0 '^ok    no public-scan hits'
mk al3b; printf 'contact <%s>, (%s)\n' "$ADDR" "$ADDR" > "$W/al3b/a.txt"
run "$W/al3b" "PUBLIC_SCAN_ALLOW=$W/allow1"; expect "allowed string in angle brackets and parentheses: exit 0" 0 '^ok    no public-scan hits'
mk al3c; printf '%s\n' "$ADDR" > "$W/al3c/a.txt"
run "$W/al3c" "PUBLIC_SCAN_ALLOW=$W/allow1"; expect "allowed string alone on its line: exit 0" 0 '^ok    no public-scan hits'
mk al4; printf 'contact %s or other%sexample.invalid\n' "$ADDR" "$AT" > "$W/al4/a.txt"
run "$W/al4" "PUBLIC_SCAN_ALLOW=$W/allow1"; expect "a second, different address on the line: exit 1" 1 '^FAIL  email address'
mk al5; printf 'contact %s.\n' "$ADDR" > "$W/al5/a.txt"
run "$W/al5" "PUBLIC_SCAN_ALLOW=$W/allow1"; expect "allowed string before a sentence full stop: exit 0" 0 '^ok    no public-scan hits'
mk al5b; printf 'contact %s.au now\n' "$ADDR" > "$W/al5b/a.txt"
run "$W/al5b" "PUBLIC_SCAN_ALLOW=$W/allow1"; expect "allowed string continued past a dot (.au): exit 1" 1 '^FAIL  email address'
mk al5c; printf 'contact %s: thanks\n' "$ADDR" > "$W/al5c/a.txt"
run "$W/al5c" "PUBLIC_SCAN_ALLOW=$W/allow1"; expect "allowed string before a colon and a space: exit 0" 0 '^ok    no public-scan hits'
mk al5d; printf 'remote %s:acme/widget.git\n' "$ADDR" > "$W/al5d/a.txt"
run "$W/al5d" "PUBLIC_SCAN_ALLOW=$W/allow1"; expect "allowed address followed by :path (scp style): exit 0" 0 '^ok    no public-scan hits'
printf '%s\n' "$ULA" > "$W/allow6"
mk v6a; printf 'addr %s:beef end\n' "$ULA" > "$W/v6a/a.txt"
run "$W/v6a"; expect "no allow: longer IPv6 address is a hit" 1 '^FAIL  IPv6 address'
run "$W/v6a" "PUBLIC_SCAN_ALLOW=$W/allow6"; expect "allow IPv6 vs the same continued by :beef: exit 1" 1 '^FAIL  IPv6 address'
mk v6b; printf 'addr fd00:%s end\n' "$ULA" > "$W/v6b/a.txt"
run "$W/v6b" "PUBLIC_SCAN_ALLOW=$W/allow6"; expect "allow IPv6 vs fd00: in front of it: exit 1" 1 '^FAIL  IPv6 address'
mk v6c; printf 'addr %s end\n' "$ULA" > "$W/v6c/a.txt"
run "$W/v6c"; expect "no allow: the IPv6 address alone is a hit" 1 '^FAIL  IPv6 address'
run "$W/v6c" "PUBLIC_SCAN_ALLOW=$W/allow6"; expect "allow IPv6, the exact string alone: exit 0" 0 '^ok    no public-scan hits'
mk v6d; printf 'addr %s. next\n' "$ULA" > "$W/v6d/a.txt"
run "$W/v6d" "PUBLIC_SCAN_ALLOW=$W/allow6"; expect "allow IPv6 before a sentence full stop: exit 0" 0 '^ok    no public-scan hits'
printf '%s\n' "$MAC" > "$W/allow7"
mk macc; printf 'dev %s end\n' "$MAC" > "$W/macc/a.txt"
run "$W/macc"; expect "no allow: the MAC address is a hit" 1 '^FAIL  MAC address'
run "$W/macc" "PUBLIC_SCAN_ALLOW=$W/allow7"; expect "allow MAC, the exact string alone: exit 0" 0 '^ok    no public-scan hits'
mk macd; printf 'dev %s:7f end\n' "$MAC" > "$W/macd/a.txt"
run "$W/macd" "PUBLIC_SCAN_ALLOW=$W/allow7"; expect "allow MAC vs a longer MAC-like token: exit 1" 1 '^FAIL  MAC address'
mk mace; printf 'dev 7f:%s end\n' "$MAC" > "$W/mace/a.txt"
run "$W/mace" "PUBLIC_SCAN_ALLOW=$W/allow7"; expect "allow MAC vs a MAC-like token with an octet in front: exit 1" 1 '^FAIL  MAC address'
printf -- '-x %s\n' "$IP" > "$W/allow4"
mk al6; printf 'M0.696-x %s z\n' "$IP" > "$W/al6/a.txt"
run "$W/al6"; expect "dash-led allow string, no allow: hit" 1 '^FAIL  IPv4 address'
run "$W/al6" "PUBLIC_SCAN_ALLOW=$W/allow4"; expect "allow string starting with a dash, after a digit: removed, exit 0" 0 '^ok    no public-scan hits'
run "$W/al3" "PUBLIC_SCAN_ALLOW=$W/nonexistent"; expect "PUBLIC_SCAN_ALLOW at a missing file: exit 2" 2 'PUBLIC_SCAN_ALLOW is not a readable file'

# ---- audit 2026-11-08: escaped forms must not let an allow string be removed
# from inside a longer token; the allow file may hold the escaped spelling
printf '%s\n' "joe${AT}example.com" > "$W/allowj"
printf '%s\n' "example.com" > "$W/allowd"
esc() { # NAME ALLOWFILE LINE NOTE: a one-line file with the allow set must FAIL
  mk "$1"; printf 'contact %s\n' "$3" > "$W/$1/a.txt"
  run "$W/$1" "PUBLIC_SCAN_ALLOW=$2"; expect "$4" 1 '^FAIL  email address'
}
esc ae1 "$W/allowj" "joe${AT}example.com&#46;au" "allow joe@: &#46;au continuation: exit 1"
esc ae2 "$W/allowj" "joe${AT}example.com\\.au" "allow joe@: backslash-dot continuation: exit 1"
esc ae3 "$W/allowj" "joe${AT}example.com&period;au" "allow joe@: &period; continuation: exit 1"
esc ae4 "$W/allowj" "joe${AT}example.com&#x2E;au" "allow joe@: &#x2E; continuation: exit 1"
esc ae5 "$W/allowj" "x&#46;joe${AT}example.com" "allow joe@: &#46; in front: exit 1"
esc ae6 "$W/allowd" "priv&#64;ex""ample.com" "allow example.com vs escaped-at prefix: exit 1"
mk ae7; printf 'contact joe%sexample.com\n' "$AT" > "$W/ae7/a.txt"
run "$W/ae7" "PUBLIC_SCAN_ALLOW=$W/allowj"; expect "plain allowed address still passes: exit 0" 0 '^ok    no public-scan hits'
mk ae8; printf 'contact joe%sexample.com.au\n' "$AT" > "$W/ae8/a.txt"
run "$W/ae8" "PUBLIC_SCAN_ALLOW=$W/allowj"; expect "plain .au continuation still fails: exit 1" 1 '^FAIL  email address'
printf '%s\n' "joe&#64;exam""ple&#46;com" > "$W/allowesc"
run "$W/ae7" "PUBLIC_SCAN_ALLOW=$W/allowesc"; expect "allow string written escaped allows its plain form: exit 0" 0 '^ok    no public-scan hits'
run "$W/ae1" "PUBLIC_SCAN_ALLOW=$W/allowesc"; expect "escaped allow string vs &#46;au: exit 1" 1 '^FAIL  email address'
run "$W/ae1" "PUBLIC_SCAN_ALLOW=$W/allowj"; expect "FAIL line shows the original text" 1 'joe@exam''ple\.com&#46;au'

# ---- regression of the decode fix: decoding must not hide a hit from a rule
# with a minimum length; an unrelated allow file must not change the verdict
printf '%s\n' "nobody${AT}example.org" > "$W/allowo"
mk dc1; printf '%s%s%s\n' 'pass' 'word = a&#46;' 'b' > "$W/dc1/a.txt"
run "$W/dc1"; expect "short escaped assigned secret, no allow file: exit 1" 1 '^FAIL'
run "$W/dc1" "PUBLIC_SCAN_ALLOW=$W/allowo"; expect "short escaped assigned secret, unrelated allow file: still exit 1" 1 '^FAIL'
mk dc2; printf '%s%s%s\n' 'api_' 'key=abcd\.' 'ef' > "$W/dc2/a.txt"
run "$W/dc2"; expect "escaped-dot key value, no allow file: exit 1" 1 '^FAIL'
run "$W/dc2" "PUBLIC_SCAN_ALLOW=$W/allowo"; expect "escaped-dot key value, unrelated allow file: still exit 1" 1 '^FAIL'

# ---- audit 2026-11-08: a fsmonitor command in DIR/.git/config must not run
mk fsm; git -C "$W/fsm" init -q
printf 'plain text\n' > "$W/fsm/a.txt"
printf '#!/bin/sh\ntouch "%s/fsm-marker"\nprintf "token\\0"\n' "$W" > "$W/fsm-hook.sh"; chmod 755 "$W/fsm-hook.sh"
git -C "$W/fsm" config core.fsmonitor "$W/fsm-hook.sh"
run "$W/fsm"
if [ ! -e "$W/fsm-marker" ]; then ok "core.fsmonitor in DIR config: command not run"; else bad "core.fsmonitor in DIR config: command ran"; fi
expect "core.fsmonitor in DIR config: scan still lists the file (1 files)" 0 '\(1 files'

# ---- finding 9: deny list
mk dn; printf 'the term zebrafoo is here\n' > "$W/dn/a.txt"
printf 'zebrafoo\n' > "$W/deny.ok"
run "$W/dn" "PUBLIC_SCAN_DENY=$W/deny.ok"; expect "deny term matches: exit 1" 1 '^FAIL  deny-list term'
run "$W/dn" "PUBLIC_SCAN_DENY=$W/deny.missing"; expect "PUBLIC_SCAN_DENY at a missing path: exit 2" 2 'PUBLIC_SCAN_DENY is not a readable file'
run "$W/dn" "PUBLIC_SCAN_DENY=$W"; expect "PUBLIC_SCAN_DENY at a directory: exit 2" 2 'PUBLIC_SCAN_DENY is not a readable file'
if [ "$AS_ROOT" = 1 ]; then
  echo "skip unreadable deny file (running as root)"
else
  cp "$W/deny.ok" "$W/deny.unr"; chmod 000 "$W/deny.unr"
  run "$W/dn" "PUBLIC_SCAN_DENY=$W/deny.unr"; expect "PUBLIC_SCAN_DENY unreadable: exit 2" 2 'PUBLIC_SCAN_DENY is not a readable file'
fi
printf 'zebrafoo\r\n' > "$W/deny.crlf"
run "$W/dn" "PUBLIC_SCAN_DENY=$W/deny.crlf"; expect "CRLF term still matches: exit 1" 1 '^FAIL  deny-list term'
printf 'zebrafoo \n' > "$W/deny.sp"
run "$W/dn" "PUBLIC_SCAN_DENY=$W/deny.sp"; expect "trailing-space term matches: exit 1" 1 '^FAIL  deny-list term'
printf '  zebrafoo\t \n' > "$W/deny.ws"
run "$W/dn" "PUBLIC_SCAN_DENY=$W/deny.ws"; expect "leading and trailing white space trimmed: exit 1" 1 '^FAIL  deny-list term'
mk dc; printf 'no private words\n' > "$W/dc/a.txt"
run "$W/dc" "PUBLIC_SCAN_DENY=$W/deny.ok"; expect "ok line shows 1 deny terms" 0 '\(1 files, 0 binary skipped, 1 deny terms\)'
printf '# comment\n\n  # indented comment\nalpha\r\nbeta \n' > "$W/deny.multi"
run "$W/dc" "PUBLIC_SCAN_DENY=$W/deny.multi" "PUBLIC_SCAN_TERMS=gamma, delta"
expect "comments and blanks not counted; TERMS added: 4 terms" 0 ', 4 deny terms\)'
run "$W/dc"; expect_not "no terms: the ok line has no deny count" 'deny terms'
cp "$SRC" "$TMP/bin/public-scan.sh"; printf 'zebrafoo\n' > "$TMP/bin/public-scan.deny"
run "$W/dn"; expect "default public-scan.deny beside the script is read: exit 1" 1 '^FAIL  deny-list term'
run "$W/dc"; expect "default deny file: counted in the ok line" 0 ', 1 deny terms\)'
rm "$TMP/bin/public-scan.deny"
printf '# only a comment\n' > "$W/deny.none"
run "$W/dc" "PUBLIC_SCAN_DENY=$W/deny.none"; expect_not "a deny file with no terms: no deny count" 'deny terms'
run "$W/dn" "PUBLIC_SCAN_DENY=$W/deny.none" "PUBLIC_SCAN_TERMS=zebrafoo"; expect "PUBLIC_SCAN_TERMS alone matches: exit 1" 1 '^FAIL  deny-list term'
printf 'zebrafoo\n' > "$W/allow3"
run "$W/dn" "PUBLIC_SCAN_DENY=$W/deny.ok" "PUBLIC_SCAN_ALLOW=$W/allow3"; expect "allowed deny term passes: exit 0" 0 '1 deny terms'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
