#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joe Fernandez
#
# Test for scan.sh and git-hooks/pre-commit, found beside this file. Exit 0 if
# every case passed, 1 if any failed, 2 if the fixture could not be built.
#
#   test-scan.sh
#
# Offline. Each case builds a throwaway git repo in a mktemp -d (removed at the
# end) holding a copy of scan.sh, scan.exclude and the pre-commit hook (under
# tools/ there, with gates.scan true), with HOME and the git config pointed away
# from the operator's. The real ruff, bandit, shellcheck and gitleaks are used,
# from the main checkout (override with GATES_SCAN_VENV, GATES_GITLEAKS,
# GATES_GITLEAKS_CONFIG); pip-audit is a stub (GATES_PIP_AUDIT), so --deps
# makes no request. The fake secret
# is assembled at run time so this file itself does not trip gitleaks.
#
# Cases (through git commit unless it says scan.sh):
#   1  clean .py and .sh: commit succeeds
#   2  undefined name: refused, file:line and F821
#   3  subprocess shell=True: refused (bandit B602)
#   4  unquoted-cd shell warning: refused (shellcheck SC2164)
#   5  extensionless #!/bin/sh and #!/usr/bin/env python3 files: refused
#   6  token-shaped secret in a .txt: refused, secret text not in the output
#   7  partial staging: clean staged / broken in tree passes; the reverse is
#      refused
#   8  repo-local pyproject.toml, ruff.toml, .shellcheckrc, .bandit,
#      .gitleaks.toml that suppress: still refused
#   9  broken .py under a scan.exclude path: succeeds
#   10 repo without gates.scan: hook exits 0 silently with a broken file
#      staged; the same repo after git config gates.scan true: refused
#   11 missing GATES_SCAN_VENV: scan.sh exit 2 naming the rebuild line, and
#      the commit is refused
#   12 scan.sh --all on a repo with a committed broken file: exit 1
#   13 scan.sh --deps with stub pip-audit: clean 0, real vuln 1, pip-only 0
#      with "tooling", all skipped 2, one skipped one clean 0, labels
#   14 staged requirements.txt: reminder printed, commit not blocked
#   15 git commit --no-verify with a broken file: succeeds
#   17 baseline entry masks a matching finding: exit 0, "1 known"; the same file
#      with a different code is still refused
#   18 --all lists a stale baseline entry and stays exit 0
#   19 malformed baseline line: exit 2 naming the line number
#   20 --all --verbose prints the known finding
#   16 a hook run in a worktree of the repo scans that worktree's staged files;
#      16c under an absolute hooksPath, with the main's scan.sh; 16d the public
#      layout (scan.sh and git-hooks/ outside the scanned repo)
#   8e a tracked .gitleaksignore does not suppress; 9b a secret in a
#      scan.exclude path is still refused by gitleaks; 10d a malformed
#      gates.scan refuses the commit; 13h/13i --deps with no arguments searches
#      the repo it is run in, exit 2 outside one
set -uo pipefail

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
for f in scan.sh scan.exclude git-hooks/pre-commit; do
  [ -f "$SELF/$f" ] || { echo "missing $SELF/$f" >&2; exit 2; }
done
# MAINDIR: this directory inside the main checkout, where the scanner's tools
# live (same rule as scan.sh: through the common git dir, so a worktree works).
MAINDIR=$SELF
if TOPSELF=$(git -C "$SELF" rev-parse --show-toplevel 2>/dev/null); then
  REL=''
  [ "$SELF" = "$TOPSELF" ] || REL=${SELF#"$TOPSELF"/}
  MAINROOT=$(dirname "$(git -C "$SELF" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")
  [ -d "$MAINROOT/$REL" ] && MAINDIR=$MAINROOT${REL:+/$REL}
fi
export GATES_SCAN_VENV=${GATES_SCAN_VENV:-$MAINDIR/.venv-scan}
export GATES_GITLEAKS=${GATES_GITLEAKS:-$MAINDIR/gitleaks/gitleaks}
export GATES_GITLEAKS_CONFIG=${GATES_GITLEAKS_CONFIG:-$MAINDIR/gitleaks/gitleaks.toml}
for f in "$GATES_SCAN_VENV/bin/ruff" "$GATES_SCAN_VENV/bin/bandit" "$GATES_GITLEAKS" "$GATES_GITLEAKS_CONFIG"; do
  [ -e "$f" ] || { echo "scanner tool not found: $f" >&2; exit 2; }
done
command -v shellcheck >/dev/null || { echo "shellcheck not on PATH" >&2; exit 2; }

TMP=$(mktemp -d) || { echo "mktemp failed" >&2; exit 2; }
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/home"
export HOME="$TMP/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GATES_PIP_AUDIT

pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok    $1"; }
bad() { failn=$((failn + 1)); echo "FAIL  $1: $2"; }

n=0
# mkrepo: a fresh repo in R with the scanner installed and committed.
mkrepo() {
  n=$((n + 1))
  R=$TMP/r$n
  mkdir -p "$R/tools/git-hooks" || exit 2
  cp "$SELF/scan.sh" "$SELF/scan.exclude" "$R/tools/" || exit 2
  cp "$SELF/git-hooks/pre-commit" "$R/tools/git-hooks/" || exit 2
  git init -q "$R" || { echo "git init failed" >&2; exit 2; }
  git -C "$R" config user.name t
  git -C "$R" config user.email t@example.invalid
  git -C "$R" config commit.gpgsign false
  git -C "$R" config core.hooksPath "$R/tools/git-hooks"
  git -C "$R" config gates.scan true
  git -C "$R" add tools || exit 2
  git -C "$R" commit -q --no-verify -m init || { echo "fixture commit failed" >&2; exit 2; }
}
# put FILE CONTENT: write R/FILE (parent dirs made), git add it.
put() { mkdir -p "$R/$(dirname "$1")"; printf '%s' "$2" >"$R/$1"; git -C "$R" add -- "$1"; }
# commit [git commit args]: sets OUT and RC.
commit() { OUT=$(cd "$R" && git commit -q -m x "$@" 2>&1); RC=$?; }
# scan args: runs R's scan.sh in R.
scan() { OUT=$(cd "$R" && "$R/tools/scan.sh" "$@" 2>&1); RC=$?; }

# expect NAME WANT_RC [PATTERN [NOT_PATTERN]] against OUT and RC.
expect() {
  local name=$1 want=$2 pat=${3:-} nopat=${4:-}
  if [ "$RC" -ne "$want" ]; then bad "$name" "rc=$RC, want $want; output: $OUT"; return; fi
  if [ -n "$pat" ] && ! printf '%s' "$OUT" | grep -Eq -- "$pat"; then bad "$name" "output lacks /$pat/: $OUT"; return; fi
  if [ -n "$nopat" ] && printf '%s' "$OUT" | grep -Eq -- "$nopat"; then bad "$name" "output has /$nopat/: $OUT"; return; fi
  ok "$name"
}

CLEAN_PY=$'import os\nprint(os.getcwd())\n'
CLEAN_SH=$'#!/bin/sh\necho "$1"\n'
BAD_PY=$'import os\nprint(undefined_name)\n'
BAD_SH=$'#!/bin/sh\ncd $1\necho hi\n'

# 1 ---------------------------------------------------------------------
mkrepo; put a.py "$CLEAN_PY"; put b.sh "$CLEAN_SH"; commit
expect "1  clean .py and .sh: commit succeeds" 0
git -C "$R" rev-parse -q --verify HEAD~1 >/dev/null || bad "1  clean commit" "no commit made"

# 2 ---------------------------------------------------------------------
mkrepo; put pkg/m.py "$BAD_PY"; commit
expect "2  undefined name: refused with file:line and F821" 1 'pkg/m\.py:2:[0-9]+: F821'

# 3 ---------------------------------------------------------------------
mkrepo; put run.py $'import subprocess\n\n\ndef f(cmd):\n    subprocess.call(cmd, shell=True)\n'; commit
expect "3  shell=True on a variable: refused (bandit)" 1 'run\.py:5: B602'

# 4 ---------------------------------------------------------------------
mkrepo; put x.sh "$BAD_SH"; commit
expect "4  shell warning: refused (shellcheck)" 1 'x\.sh:2:[0-9]+: warning.*SC2164'

# 5 ---------------------------------------------------------------------
mkrepo; put bin/tool "$BAD_SH"; commit
expect "5a extensionless #!/bin/sh with a warning: refused" 1 'bin/tool:2:[0-9]+: warning.*SC2164'
mkrepo; put bin/tool $'#!/usr/bin/env bash\ncd $1\n'; commit
expect "5b extensionless #!/usr/bin/env bash: refused" 1 'bin/tool:2:[0-9]+: warning'
mkrepo; put bin/tool $'#!/usr/bin/env python3\nprint(undefined_name)\n'; commit
expect "5c extensionless python shebang: refused (ruff)" 1 'bin/tool:2:[0-9]+: F821'
mkrepo; put bin/tool $'#!/bin/sh\necho "$1"\n'; put notes $'cd $1\nprint(undefined_name)\n'; commit
expect "5d extensionless clean script and a plain file with no shebang: succeeds" 0

# 6 ---------------------------------------------------------------------
# The token's 36-character tail is random per run, so this file holds no
# secret-shaped literal (a fixed tail tripped gitleaks' generic-api-key rule).
SECRET_TAIL=$(head -c 64 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9' | head -c 36)
[ ${#SECRET_TAIL} -eq 36 ] || { echo "could not make a test token" >&2; exit 2; }
mkrepo; put notes.txt "token = \"ghp_${SECRET_TAIL}\""$'\n'; commit
expect "6  secret in a .txt: refused, redacted" 1 'notes\.txt:1: github-pat' "$SECRET_TAIL"

# 7 ---------------------------------------------------------------------
mkrepo; put a.py "$CLEAN_PY"; printf '%s' "$BAD_PY" >"$R/a.py"; commit
expect "7a clean staged, broken only in the working tree: succeeds" 0
mkrepo; put a.py "$BAD_PY"; printf '%s' "$CLEAN_PY" >"$R/a.py"; commit
expect "7b broken staged, clean in the working tree: refused" 1 'a\.py:2:[0-9]+: F821'

# 8 ---------------------------------------------------------------------
mkrepo
printf '[tool.ruff.lint]\nignore = ["F821"]\n' >"$R/pyproject.toml"
printf '[lint]\nignore = ["F821"]\nselect = []\n' >"$R/ruff.toml"
printf '[bandit]\nskips = ["B602"]\n' >"$R/.bandit"
printf 'disable=SC2164\n' >"$R/.shellcheckrc"
printf '[extend]\nuseDefault = true\n[allowlist]\nregexes = [".*"]\n' >"$R/.gitleaks.toml"
git -C "$R" add pyproject.toml ruff.toml .bandit .shellcheckrc .gitleaks.toml
git -C "$R" commit -q --no-verify -m cfg || exit 2
put a.py "$BAD_PY"; commit
expect "8a pyproject.toml/ruff.toml ignoring F821: still refused" 1 'a\.py:2:[0-9]+: F821'
git -C "$R" reset -q --hard
put b.sh "$BAD_SH"; commit
expect "8b .shellcheckrc disabling the code: still refused" 1 'b\.sh:2:[0-9]+: warning.*SC2164'
git -C "$R" reset -q --hard
put c.py $'import subprocess\n\n\ndef f(c):\n    subprocess.call(c, shell=True)\n'; commit
expect "8c .bandit skipping B602: still refused" 1 'c\.py:5: B602'
git -C "$R" reset -q --hard
put notes.txt "token = \"ghp_${SECRET_TAIL}\""$'\n'; commit
expect "8d .gitleaks.toml with a catch-all allowlist: still refused" 1 'notes\.txt:1: github-pat'

# 8e: a tracked .gitleaksignore holding the finding's own fingerprint, read
# from a first run of gitleaks, must not suppress it.
git -C "$R" reset -q --hard
put notes.txt "token = \"ghp_${SECRET_TAIL}\""$'\n'
FP=$(cd "$R" && "$GATES_GITLEAKS" git --pre-commit --staged --no-banner --no-color --config "$GATES_GITLEAKS_CONFIG" -f json -r - "$R" 2>/dev/null |
  python3 -I -c 'import json, sys
for r in json.load(sys.stdin) or []:
    print(r["Fingerprint"])')
[ -n "$FP" ] || bad "8e0 fingerprint read from gitleaks" "no finding to take a fingerprint from"
printf '%s\n' "$FP" >"$R/.gitleaksignore"
git -C "$R" add .gitleaksignore
OUT=$(cd "$R" && "$GATES_GITLEAKS" git --pre-commit --staged --no-banner --no-color --config "$GATES_GITLEAKS_CONFIG" -f json -r - "$R" 2>&1); RC=$?
[ "$RC" -eq 0 ] || bad "8e0 the fixture ignore file works for gitleaks itself" "rc=$RC, so a refusal below would prove nothing: $OUT"
commit
expect "8e tracked .gitleaksignore with the finding's fingerprint: still refused" 1 'notes\.txt:1: github-pat'
commit --no-verify
scan --all
expect "8e2 --all: the same tracked .gitleaksignore does not suppress either" 1 'notes\.txt:1: github-pat'

# 9 ---------------------------------------------------------------------
# The glob is written into the temp repo's own scan.exclude, so the case does
# not depend on what the shipped file lists (the public copy ships it empty).
mkrepo; printf '*/docs/security-audit-*/agents/*/artifacts/*\n' >>"$R/tools/scan.exclude"
put work/p/docs/security-audit-x/agents/a/artifacts/h.py "$BAD_PY"; commit
expect "9  broken .py under a scan.exclude path: succeeds" 0
EXCL=$'*/docs/security-audit-*/agents/*/artifacts/*\n'
mkrepo; printf '%s' "$EXCL" >>"$R/tools/scan.exclude"
put work/p/docs/security-audit-x/agents/a/artifacts/notes.txt "token = \"ghp_${SECRET_TAIL}\""$'\n'; commit
expect "9b only a scan.exclude path staged, holding a token, gitleaks still refuses" 1 'artifacts/notes\.txt:1: github-pat' "$SECRET_TAIL"
mkrepo; printf '%s' "$EXCL" >>"$R/tools/scan.exclude"
put work/p/docs/security-audit-x/agents/a/artifacts/notes.txt $'nothing here\n'; commit
expect "9c only a scan.exclude path staged, clean: succeeds" 0 '' 'tool error'

# 10 --------------------------------------------------------------------
mkrepo; git -C "$R" config --unset gates.scan; put a.py "$BAD_PY"; commit
expect "10a repo without gates.scan: hook exits 0, silent" 0 '' 'scan|refused'
git -C "$R" config gates.scan true; put b.py "$BAD_PY"; commit
expect "10b same repo after git config gates.scan true: refused" 1 'b\.py:2:[0-9]+: F821'
git -C "$R" config gates.scan false; put c.py "$BAD_PY"; commit
expect "10c gates.scan false: hook exits 0, silent" 0 '' 'scan|refused'
mkrepo; put a.py "$BAD_PY"
git -C "$R" config gates.scan yess
commit
expect "10d malformed gates.scan: the commit is refused, message names gates.scan and the value" 1 'refused: gates\.scan.*yess'
OUT=$(cd "$R" && sh "$R/tools/git-hooks/pre-commit" 2>&1); RC=$?
expect "10d2 the hook itself exits 2 on a malformed gates.scan" 2 'gates\.scan.*yess'

# 11 --------------------------------------------------------------------
mkrepo; put a.py "$CLEAN_PY"
OUT=$(cd "$R" && GATES_SCAN_VENV="$TMP/no-such-venv" ./tools/scan.sh --staged 2>&1); RC=$?
expect "11a missing venv: scan.sh exit 2 naming the rebuild line with its directory" 2 "python3 -m venv $R/tools/\\.venv-scan && $R/tools/\\.venv-scan/bin/pip install -r $R/tools/scan-requirements\\.txt"
OUT=$(cd "$R" && GATES_SCAN_VENV="$TMP/no-such-venv" git commit -q -m x 2>&1); RC=$?
expect "11b missing venv: the commit is refused with the message" 1 'python3 -m venv .*/tools/\.venv-scan'
OUT=$(cd "$R" && GATES_GITLEAKS="$TMP/no-gitleaks" ./tools/scan.sh --staged 2>&1); RC=$?
expect "11c missing gitleaks: exit 2, points at the publish-gates README, Setup" 2 'see the publish-gates README, Setup'

# 12 --------------------------------------------------------------------
mkrepo; put a.py "$BAD_PY"; commit --no-verify
scan --all
expect "12a --all with a committed broken file: exit 1" 1 'a\.py:2:[0-9]+: F821.*|scan: 1 findings'
git -C "$R" rm -q -f a.py; git -C "$R" commit -q --no-verify -m rm
put a.py "$CLEAN_PY"; commit
scan --all
expect "12b --all on a clean repo: exit 0" 0 'scan: clean'
scan --bogus
expect "12c unknown option: exit 2" 2 'usage'

# 13 --------------------------------------------------------------------
STUB=$TMP/pip-audit-stub
cat >"$STUB" <<'STUBEOF'
#!/bin/sh
case $STUB_MODE in
clean)    echo '{"dependencies":[{"name":"requests","version":"2.0","vulns":[]},{"name":"pip","version":"24.0","vulns":[]}],"fixes":[]}'; exit 0 ;;
vuln)     echo '{"dependencies":[{"name":"requests","version":"2.0","vulns":[{"id":"PYSEC-1","fix_versions":["2.1"]},{"id":"PYSEC-1","fix_versions":["2.1"]}]}],"fixes":[]}'; exit 1 ;;
pip)      echo '{"dependencies":[{"name":"requests","version":"2.0","vulns":[]},{"name":"pip","version":"24.0","vulns":[{"id":"PYSEC-9","fix_versions":["26.1"]}]}],"fixes":[]}'; exit 1 ;;
fail)     echo "ConnectionError: no network" >&2; exit 3 ;;
failone)  case $PIPAPI_PYTHON_LOCATION in *v1/*) echo "boom" >&2; exit 3 ;; *) echo '{"dependencies":[{"name":"requests","version":"2.0","vulns":[]}],"fixes":[]}'; exit 0 ;; esac ;;
esac
STUBEOF
chmod +x "$STUB"
mkrepo
for v in "$TMP/v1" "$TMP/v2" "$R/tools/.venv-fake" "$R/work/.venv-ours"; do
  mkdir -p "$v/bin"; : >"$v/pyvenv.cfg"; printf '#!/bin/sh\n' >"$v/bin/python"; chmod +x "$v/bin/python"
done
deps() { local mode=$1; shift; OUT=$(cd "$R" && STUB_MODE=$mode GATES_PIP_AUDIT="$STUB" ./tools/scan.sh --deps "$@" 2>&1); RC=$?; }
deps clean "$TMP/v1"
expect "13a --deps clean JSON: exit 0" 0 '\[ours\] .*v1: 2 packages, 0 findings'
deps vuln "$TMP/v1"
expect "13b --deps real-package vuln: exit 1, id once" 1 'requests 2\.0 PYSEC-1, fix 2\.1'
[ "$(printf '%s\n' "$OUT" | grep -c 'PYSEC-1')" -eq 1 ] || bad "13b2 de-duplicated ids" "$OUT"
deps pip "$TMP/v1"
expect "13c --deps pip-only vuln: exit 0, tooling printed" 0 '0 findings \(\+1 tooling: pip 24\.0 PYSEC-9, fix 26\.1\)'
deps fail "$TMP/v1" "$TMP/v2"
expect "13d --deps every venv fails: exit 2, skipped" 2 'v1: skipped .*no network' 
deps failone "$TMP/v1" "$TMP/v2"
expect "13e --deps one skipped, one clean: exit 0" 0 'v1: skipped.*\n?.*v2: 1 packages|v2: 1 packages'
deps clean "$R/tools/.venv-fake" "$R/work/.venv-ours"
expect "13f --deps labels: tools/ is third-party, elsewhere ours" 0 '\[third-party\] tools/\.venv-fake:' 
printf '%s' "$OUT" | grep -q '\[ours\] work/\.venv-ours:' || bad "13f2 ours label" "$OUT"
deps clean "$TMP/no-such-dir"
expect "13g --deps on a missing dir: skipped, exit 2" 2 'skipped \(no such directory\)'
deps clean
expect "13h --deps with no args, run from the repo top: finds that repo's venvs" 0 'tools/\.venv-fake'
# Another repo with its own venv, using this repo's scanner: only its venv is found.
P=$TMP/proj13
mkdir -p "$P/venv/bin" && git init -q "$P" || exit 2
: >"$P/venv/pyvenv.cfg"; printf '#!/bin/sh\n' >"$P/venv/bin/python"; chmod +x "$P/venv/bin/python"
OUT=$(cd "$P" && STUB_MODE=clean GATES_PIP_AUDIT="$STUB" "$R/tools/scan.sh" --deps 2>&1); RC=$?
expect "13h2 --deps from another repo: its venv, not the scanner's" 0 '\[ours\] venv: ' 'venv-fake|venv-ours'
OUT=$(cd "$TMP/home" && STUB_MODE=clean GATES_PIP_AUDIT="$STUB" "$R/tools/scan.sh" --deps 2>&1); RC=$?
expect "13i --deps with no args outside any repo: exit 2 asking for VENV_DIR" 2 'VENV_DIR'

# 14 --------------------------------------------------------------------
mkrepo; put requirements.txt $'requests==2.0\n'; commit
expect "14a staged requirements.txt: reminder printed, commit succeeds" 0 'requirements changed: run scan\.sh --deps after installing'
mkrepo; put sub/dev-requirements-extra.txt $'requests==2.0\n'; commit
expect "14b *requirements*.txt in a subdir: reminder" 0 'requirements changed'
mkrepo; put a.py "$CLEAN_PY"; commit
expect "14c no requirements: no reminder" 0 '' 'requirements changed'

# 15 --------------------------------------------------------------------
mkrepo; put a.py "$BAD_PY"; commit --no-verify
expect "15 git commit --no-verify with a broken file: succeeds" 0

# 16 --------------------------------------------------------------------
mkrepo; put a.py "$CLEAN_PY"; commit
# A relative hooksPath resolves in each worktree to its own hook and scan.sh.
git -C "$R" config core.hooksPath tools/git-hooks
git -C "$R" worktree add -q -b wt "$TMP/wt$n" || exit 2
W2=$TMP/wt$n
printf '%s' "$BAD_PY" >"$W2/w.py"; git -C "$W2" add w.py
OUT=$(cd "$W2" && git commit -q -m x 2>&1); RC=$?
expect "16a worktree of the repo: its staged file is scanned and refused" 1 'w\.py:2:[0-9]+: F821'
rm -rf "$W2/tools/scan.sh"; git -C "$W2" rm -q --cached tools/scan.sh 2>/dev/null; git -C "$W2" reset -q w.py
printf '%s' "$CLEAN_PY" >"$W2/w.py"; git -C "$W2" add w.py
OUT=$(cd "$W2" && git commit -q -m x 2>&1); RC=$?
expect "16b worktree with no scan.sh beside its hook: passes with a note" 0 'no scan\.sh beside the hook'

# 16c: the box layout. An ABSOLUTE core.hooksPath at the main repo's hooks, so
# a worktree commit runs the main checkout's scan.sh beside that hook. The
# worktree's own scan.sh is removed to show the scan that ran is the main's.
mkrepo; put a.py "$CLEAN_PY"; commit
git -C "$R" config core.hooksPath "$R/tools/git-hooks"
git -C "$R" worktree add -q -b wt "$TMP/wt$n" || exit 2
W2=$TMP/wt$n
git -C "$W2" rm -q -f tools/scan.sh || exit 2
printf '%s' "$BAD_PY" >"$W2/w.py"; git -C "$W2" add w.py
OUT=$(cd "$W2" && git commit -q -m x 2>&1); RC=$?
expect "16c worktree under an absolute hooksPath: the main's scan.sh refuses its broken file" 1 'w\.py:2:[0-9]+: F821'
git -C "$W2" reset -q w.py
printf '%s' "$CLEAN_PY" >"$W2/w.py"; git -C "$W2" add w.py
OUT=$(cd "$W2" && git commit -q -m x 2>&1); RC=$?
expect "16c2 the same worktree with a clean file: succeeds" 0 '' 'no scan\.sh'

# 16d: the public layout. scan.sh and git-hooks/ sit flat in a directory outside
# the scanned repo; the repo's local config enables gates.scan and points
# core.hooksPath at that git-hooks/ by absolute path.
G=$TMP/gates16
mkdir -p "$G/git-hooks" || exit 2
cp "$SELF/scan.sh" "$SELF/scan.exclude" "$G/" || exit 2
cp "$SELF/git-hooks/pre-commit" "$G/git-hooks/" || exit 2
P=$TMP/proj16
git init -q "$P" || exit 2
git -C "$P" config user.name t
git -C "$P" config user.email t@example.invalid
git -C "$P" config commit.gpgsign false
git -C "$P" config gates.scan true
git -C "$P" config core.hooksPath "$G/git-hooks"
printf '%s' "$BAD_PY" >"$P/a.py"; git -C "$P" add a.py
OUT=$(cd "$P" && git commit -q -m x 2>&1); RC=$?
expect "16d public layout (scan.sh and hooks outside the repo): broken file refused" 1 'a\.py:2:[0-9]+: F821'
printf '%s' "$CLEAN_PY" >"$P/a.py"; git -C "$P" add a.py
OUT=$(cd "$P" && git commit -q -m x 2>&1); RC=$?
expect "16d2 public layout: clean file commits" 0 '' 'refused'

# 17 --------------------------------------------------------------------
TAB=$'\t'
mkrepo
printf '# header\n\nruff%sa.py%sF821%sbacklog test\n' "$TAB" "$TAB" "$TAB" >"$R/tools/scan.baseline"
git -C "$R" add tools/scan.baseline
put a.py "$BAD_PY"; commit
expect "17a baseline entry masks a matching finding: commit succeeds" 0
scan --all
expect "17b --all: exit 0, 1 known, not printed individually" 0 'scan: clean .*; 1 known \(tools/scan\.baseline\)' 'F821'
put a.py $'import subprocess\n\n\ndef f(c):\n    subprocess.call(c, shell=True)\nprint(undefined_name)\n'; commit
expect "17c same file, different code (B602): still refused, F821 still known" 1 'a\.py:5: B602.*|scan: 1 findings .*1 known' 'F821 Undefined'

# 18 --------------------------------------------------------------------
mkrepo
printf 'ruff%sgone.py%sF821%sfixed since\n' "$TAB" "$TAB" "$TAB" >"$R/tools/scan.baseline"
git -C "$R" add tools/scan.baseline
put a.py "$CLEAN_PY"; commit
scan --all
expect "18 --all lists a stale baseline entry, exit 0" 0 'stale baseline entry \(remove\): ruff gone\.py F821'

# 19 --------------------------------------------------------------------
mkrepo
printf '# ok\nruff%sa.py%sF821\n' "$TAB" "$TAB" >"$R/tools/scan.baseline"
put a.py "$CLEAN_PY"
scan --staged
expect "19a baseline line with 3 fields: exit 2 naming line 2" 2 'scan\.baseline line 2'
printf 'lint%sa.py%sF821%swhy\n' "$TAB" "$TAB" "$TAB" >"$R/tools/scan.baseline"
scan --staged
expect "19b unknown tool in the baseline: exit 2 naming line 1" 2 'scan\.baseline line 1'
printf 'ruff%sa.py%sF821%s\n' "$TAB" "$TAB" "$TAB" >"$R/tools/scan.baseline"
scan --staged
expect "19c empty reason: exit 2" 2 'scan\.baseline line 1'

# 20 --------------------------------------------------------------------
mkrepo
printf 'ruff%sa.py%sF821%sbacklog test\n' "$TAB" "$TAB" "$TAB" >"$R/tools/scan.baseline"
git -C "$R" add tools/scan.baseline
put a.py "$BAD_PY"; commit
scan --all --verbose
expect "20 --all --verbose prints the known finding" 0 'a\.py:2:[0-9]+: F821.*' 
scan --all -v
expect "20b -v is the same" 0 'a\.py:2:[0-9]+: F821'

# timing (information only) ----------------------------------------------
mkrepo
for i in 1 2 3; do put "m$i.py" "$CLEAN_PY"; done
put s1.sh "$CLEAN_SH"; put s2.sh "$CLEAN_SH"
s=$(date +%s.%N)
scan --staged
e=$(date +%s.%N)
echo "info  5-file --staged scan: $(awk -v a="$s" -v b="$e" 'BEGIN{printf "%.2f", b-a}') s (rc=$RC)"

echo "$pass passed, $failn failed"
[ "$failn" -eq 0 ]
