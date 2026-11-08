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
#   21 type changes (T) are scanned: a T-only commit with a token is refused, a
#      T .py with F821 is linted, a deletion-only commit is clean (0 files)
#   22g-22l the config's global path allowlist is dropped: a token in
#      node_modules, an .svg or a lockfile is refused; a config with no paths
#      key works; one that does not parse or has an [extend] is exit 2; an allowlist of only paths is dropped whole
#   22 gitleaks reads raw blobs: -diff, binary and UTF-16 working-tree-encoding
#      cannot hide a token (--staged and --all); a tracked root .gitleaksignore
#      holding its fingerprint does not suppress it
#   23 --deps does not execute a venv that git tracks; symlinked pyvenv.cfg
#   24 --deps: packages not audited are listed and keep exit 0; any skipped
#      venv makes the run exit 2 ("incomplete")
#   25 --deps runs pip-audit from an empty directory: a pip/ or pip.py at the
#      repo root cannot shadow "python -m pip"; a relative GATES_PIP_AUDIT works
#   26 bandit sees explicitly named files under .github/, .githooks/, .gitlab/
#   27 a file bandit cannot analyse (1200-term expression, syntax error): exit 2
#   28 a killed bandit (no exit status) is exit 2; no .py means no bandit run
#   29 a newline or CR in a selected path: exit 2 naming it
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
execpy)   "$PIPAPI_PYTHON_LOCATION" >/dev/null 2>&1; echo '{"dependencies":[{"name":"requests","version":"2.0","vulns":[]}],"fixes":[]}'; exit 0 ;;
pipmod)   "$PIPAPI_PYTHON_LOCATION" -m pip --version >/dev/null 2>&1; echo '{"dependencies":[{"name":"requests","version":"2.0","vulns":[]}],"fixes":[]}'; exit 0 ;;
skipdep)  echo '{"dependencies":[{"name":"requests","version":"2.0","vulns":[]},{"name":"weirdpkg","skip_reason":"Dependency not found on PyPI"}],"fixes":[]}'; exit 0 ;;
skipmany) python3 -c 'import json; print(json.dumps({"dependencies": [{"name": "p%d" % i, "skip_reason": "x"} for i in range(1, 13)], "fixes": []}))'; exit 0 ;;
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
expect "13e --deps one skipped, one clean: incomplete, exit 2" 2 'v1: skipped.*\n?.*v2: 1 packages|v2: 1 packages'
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

# 21 --------------------------------------------------------------------
# Type changes (T). A symlink replaced by a regular file is staged as T, which
# the old ACMR list dropped, so neither linters nor gitleaks saw it.
# mktype NAME CONTENT: commit NAME as a symlink, then stage a regular file.
mktype() {
  ln -s elsewhere "$R/$1"; git -C "$R" add -- "$1"; git -C "$R" commit -q --no-verify -m link
  rm -f "$R/$1"; put "$1" "$2"
  git -C "$R" diff --cached --name-status | grep -q "^T.$1\$" || echo "fixture: $1 is not a type change" >&2
}
mkrepo; mktype tok.txt "token = \"ghp_${SECRET_TAIL}\""$'\n'; commit
expect "21a type-change-only commit holding a token: refused through the hook, redacted" 1 'tok\.txt:1: github-pat' "$SECRET_TAIL"
mkrepo; mktype t.py "$BAD_PY"; put ok.py "$CLEAN_PY"; scan --staged
expect "21b T .py with F821 beside a clean A .py: exit 1" 1 't\.py:2:[0-9]+: F821'
mkrepo; put a.py "$CLEAN_PY"; commit; git -C "$R" rm -q a.py; scan --staged
expect "21c staged deletion only: clean (0 files)" 0 'scan: clean \(0 files\)'
mkrepo; put a.py "$BAD_PY"; commit --no-verify; rm "$R/a.py"; ln -s elsewhere "$R/a.py"; git -C "$R" add a.py; scan --staged
expect "21d file replaced by a symlink (T): skipped, not read through" 0 'scan: clean'

# 22 --------------------------------------------------------------------
# gitleaks reads raw blobs: no attribute can hide a staged or tracked token.
TOKTXT="token = \"ghp_${SECRET_TAIL}\""$'\n'
mkrepo; put .gitattributes $'*.txt -diff\n'; commit; put s.txt "$TOKTXT"; scan --staged
expect "22a committed '*.txt -diff' and a token in s.txt: --staged refuses" 1 's\.txt:1: github-pat' "$SECRET_TAIL"
commit --no-verify; scan --all
expect "22a2 the same, --all: refuses" 1 's\.txt:1: github-pat' "$SECRET_TAIL"
mkrepo; put .gitattributes $'*.txt -diff\n'; put s.txt "$TOKTXT"; commit
expect "22b .gitattributes staged in the same commit: refused" 1 's\.txt:1: github-pat'
mkrepo; put .gitattributes $'*.txt binary\n'; commit; put s.txt "$TOKTXT"; commit
expect "22c 'binary' macro: refused" 1 's\.txt:1: github-pat'
mkrepo; put .gitattributes $'*.txt text working-tree-encoding=UTF-16\n'; commit
printf '%s' "$TOKTXT" | iconv -f UTF-8 -t UTF-16 >"$R/s.txt"; git -C "$R" add s.txt
commit
expect "22d UTF-16 working-tree-encoding file holding a token: refused" 1 's\.txt:1: github-pat'
commit --no-verify; scan --all
expect "22d2 the same, --all: refused" 1 's\.txt:1: github-pat'
# A tracked root .gitleaksignore with the finding's fingerprint, in the form
# gitleaks writes it (path:rule:line) with this path, the path relative to the
# root, and the absolute path of a scratch copy; none may suppress.
mkrepo; put s.txt "$TOKTXT"
mkdir "$TMP/glx$n"; cp "$R/s.txt" "$TMP/glx$n/s.txt"
"$GATES_GITLEAKS" dir "$TMP/glx$n" --no-banner --no-color --config "$GATES_GITLEAKS_CONFIG" -f json -r - 2>/dev/null |
  python3 -I -c 'import json, sys
for r in json.load(sys.stdin) or []:
    print(r["Fingerprint"])' >"$R/.gitleaksignore"
printf 's.txt:github-pat:1\n./s.txt:github-pat:1\n' >>"$R/.gitleaksignore"
[ "$(wc -l <"$R/.gitleaksignore")" -ge 3 ] || bad "22e0 fingerprints" "no fingerprint read from gitleaks"
git -C "$R" add .gitleaksignore
scan --staged
expect "22e tracked root .gitleaksignore with the fingerprint, token in s.txt: --staged refuses" 1 's\.txt:1: github-pat'
commit --no-verify; scan --all
expect "22e2 the same, --all: refuses" 1 's\.txt:1: github-pat'
# The .gitleaksignore file is itself scanned, under its real name.
mkrepo; put .gitleaksignore "token = \"ghp_${SECRET_TAIL}\""$'\n'; scan --staged
expect "22f a token inside .gitleaksignore is reported under that name" 1 '(^|[^.a-z])\.gitleaksignore:1: github-pat' 'gitleaksignore\.content'

# 22g-22m: the release config's global path allowlist (node_modules, images,
# lockfiles) must not hide a token: scan.sh drops it from a temp copy of the
# config. 2026-11-08 audit run 3, finding 1.
for p in plain.txt node_modules/pkg/x.js logo.svg package-lock.json; do
  mkrepo; put "$p" "$TOKTXT"; scan --staged
  expect "22g $p holding a token: --staged refuses" 1 "$(printf '%s' "$p" | sed 's/\./\\./g'):1: github-pat" "$SECRET_TAIL"
done
mkrepo; put node_modules/pkg/x.js "$TOKTXT"; commit --no-verify; scan --all
expect "22h node_modules/pkg/x.js, --all: refuses" 1 'node_modules/pkg/x\.js:1: github-pat'
mkrepo; put node_modules/pkg/x.js "$TOKTXT"; commit
expect "22h2 through the hook: refused" 1 'node_modules/pkg/x\.js:1: github-pat'
# Config variants, written here from the release config.
GLV=$TMP/glvariants; mkdir "$GLV"
python3 -I -c 'import sys
s = open(sys.argv[1], encoding="utf-8").read()
i = s.index("[allowlist]")
a = s.index("paths = [", i)
b = s.index("\n]\n", a)
open(sys.argv[2], "w", encoding="utf-8").write(s[:a] + s[b + 3:])
open(sys.argv[3], "w", encoding="utf-8").write(s[:i] + "[[allowlists]]" + s[i + 11:])' \
  "$GATES_GITLEAKS_CONFIG" "$GLV/nopaths.toml" "$GLV/plural.toml" || exit 2
if grep -q 'node_modules' "$GLV/nopaths.toml"; then bad "22i0 fixture" "paths key still in the no-paths config"; fi
mkrepo; put notes.txt "$TOKTXT"; GATES_GITLEAKS_CONFIG=$GLV/nopaths.toml scan --staged
expect "22i a config with no paths key still works: refuses" 1 'notes\.txt:1: github-pat'
mkrepo; put notes.txt $'nothing here\n'; GATES_GITLEAKS_CONFIG=$GLV/nopaths.toml scan --staged
expect "22i2 the same config, a clean file: succeeds" 0 'scan: clean'
mkrepo; put node_modules/pkg/x.js "$TOKTXT"; GATES_GITLEAKS_CONFIG=$GLV/plural.toml scan --staged
expect "22j a [[allowlists]] form with paths: node_modules token refused" 1 'node_modules/pkg/x\.js:1: github-pat'
mkrepo; put notes.txt "$TOKTXT"; printf 'this is [ not = toml\n' >"$GLV/bad.toml"
GATES_GITLEAKS_CONFIG=$GLV/bad.toml scan --staged
expect "22k a config that does not parse: exit 2" 2 'cannot make the gitleaks config' 'scan: clean'
mkrepo; put notes.txt "$TOKTXT"; printf '[allowlist]\nregexes = ["a"]\n[[rules]]\nid = "x"\nregex = "y"\npaths = [\n' >"$GLV/trunc.toml"
GATES_GITLEAKS_CONFIG=$GLV/trunc.toml scan --staged
expect "22l a truncated config: exit 2" 2 'cannot make the gitleaks config' 'scan: clean'

mkrepo; put notes.txt "$TOKTXT"; printf "[extend]\nuseDefault = true\n" >"$GLV/extend.toml"
GATES_GITLEAKS_CONFIG=$GLV/extend.toml scan --staged
expect "22m a config with [extend] useDefault: exit 2" 2 "cannot make the gitleaks config.*\[extend\]" "scan: clean"
# An [allowlist] holding only paths: gitleaks refuses the emptied table, so
# the edit drops it whole.
printf "[[rules]]\nid = \"tok\"\nregex = \x27\x27\x27ghp_[A-Za-z0-9]{36}\x27\x27\x27\n[allowlist]\ndescription = \"d\"\npaths = [\n    \x27\x27\x27node_modules\x27\x27\x27,\n]\n[[rules]]\nid = \"other\"\nregex = \x27\x27\x27zzzq\x27\x27\x27\n" >"$GLV/onlypaths.toml"
mkrepo; put node_modules/pkg/x.js "$TOKTXT"; GATES_GITLEAKS_CONFIG=$GLV/onlypaths.toml scan --staged
expect "22n an [allowlist] holding only paths: dropped, node_modules token refused" 1 "node_modules/pkg/x\.js:1: tok"

# 22o-22s: gitleaks reads TOML keys case-insensitively, so the edit does too;
# an AND allowlist loses its whole table; an emptied array is no check.
glcase() { # name, config (printf format): token in node_modules/p/x.js
  mkrepo; put node_modules/p/x.js "$TOKTXT"; printf "$2" >"$GLV/$1.toml"
  GATES_GITLEAKS_CONFIG=$GLV/$1.toml scan --staged
}
RULE="[[rules]]\nid = \"tok\"\nregex = '''ghp_[A-Za-z0-9]{36}'''\n"
glcase case1 "${RULE}[Allowlist]\npaths = ['''node_modules''']\nregexes = ['''zzzq''']\n"
expect "22o [Allowlist] + paths: node_modules token refused" 1 'node_modules/p/x\.js:1: tok'
glcase case2 "${RULE}[allowlist]\nPaths = ['''node_modules''']\nregexes = ['''zzzq''']\n"
expect "22o2 [allowlist] + Paths: refused" 1 'node_modules/p/x\.js:1: tok'
glcase case3 "${RULE}[[AllowLists]]\npaths = ['''node_modules''']\nregexes = ['''zzzq''']\n"
expect "22o3 [[AllowLists]]: refused" 1 'node_modules/p/x\.js:1: tok'
glcase case4 "${RULE}[allowList]\nPATHS = ['''node_modules''']\nregexes = ['''zzzq''']\n"
expect "22o4 [allowList] + PATHS: refused" 1 'node_modules/p/x\.js:1: tok'
glcase case5 "${RULE}[Extend]\nuseDefault = true\n"
expect "22p [Extend]: exit 2" 2 'cannot make the gitleaks config.*\[extend\]' 'scan: clean'
# AND: "path AND regex" must not become "regex anywhere".
glsrc() { # name, config (printf format): token in src/a.txt
  mkrepo; put src/a.txt "$TOKTXT"; printf "$2" >"$GLV/$1.toml"
  GATES_GITLEAKS_CONFIG=$GLV/$1.toml scan --staged
}
glsrc and1 "${RULE}[[allowlists]]\ncondition = \"AND\"\npaths = ['''^test/''']\nregexes = ['''ghp_''']\n"
expect "22q AND [[allowlists]] with paths: token in src/a.txt refused" 1 'src/a\.txt:1: tok'
glsrc and2 "${RULE}[[allowlists]]\npaths = ['''^test/''']\nregexes = ['''ghp_''']\ncondition = \"and\"\n"
expect "22q2 condition after the keys, lower case: refused" 1 'src/a\.txt:1: tok'
glsrc and3 "${RULE}[allowlist]\nCondition = 'AND'\nPaths = ['''^test/''']\nstopwords = ['''ghp_''']\n"
expect "22q3 [allowlist] AND, mixed-case keys: refused" 1 'src/a\.txt:1: tok'
glsrc or1 "${RULE}[[allowlists]]\npaths = ['''^test/''']\nregexes = ['''ghp_''']\n"
expect "22q4 an OR table keeps its regexes: token suppressed" 0 'scan: clean'
# Empty arrays are no check: the table is dropped whole and gitleaks loads.
glsrc empty1 "${RULE}[[allowlists]]\npaths = ['''^test/''']\nregexes = []\n"
expect "22r paths + regexes = []: loads, token refused" 1 'src/a\.txt:1: tok' 'cannot make|rror'
# The release config comes out as the original minus allowlist.paths.
python3 -I -c 'import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^gl_cfg=\x27\n(.*?)^\x27$", s, re.S | re.M)
open(sys.argv[2], "w", encoding="utf-8").write(m.group(1))' "$SELF/scan.sh" "$GLV/gl_cfg.py" || exit 2
python3 -I "$GLV/gl_cfg.py" "$GATES_GITLEAKS_CONFIG" "$GLV/release.toml" || bad "22s gl_cfg on the release config" "failed"
python3 -I -c 'import sys, tomllib
a = tomllib.load(open(sys.argv[1], "rb"))
b = tomllib.load(open(sys.argv[2], "rb"))
a["allowlist"].pop("paths")
sys.exit(0 if a == b else 1)' "$GATES_GITLEAKS_CONFIG" "$GLV/release.toml" && ok "22s release config: the original minus allowlist.paths" || bad "22s release config" "not the original minus allowlist.paths"

# 23 --------------------------------------------------------------------
# --deps must not run a venv that git tracks (its bin/python would run).
MARK=$TMP/mark23
mkrepo
mkdir -p "$R/tv/bin"; : >"$R/tv/pyvenv.cfg"
printf '#!/bin/sh\ntouch "%s"\n' "$MARK" >"$R/tv/bin/python"; chmod +x "$R/tv/bin/python"
deps execpy "$R/tv"
[ -e "$MARK" ] || bad "23a0 control: an explicit VENV_DIR is trusted and run" "the marker was not written"
rm -f "$MARK"
git -C "$R" add tv; git -C "$R" commit -q --no-verify -m venv
deps execpy
expect "23a tracked venv found by the default search: skipped, exit 2" 2 'tv: skipped \(tracked in git; not executed\)' 'audited\)$'
[ ! -e "$MARK" ] || bad "23b tracked venv not executed" "the marker was written"
printf '%s' "$OUT" | grep -q 'incomplete (0 audited, 1 skipped)' || bad "23c incomplete line" "$OUT"
mkrepo; mkdir -p "$R/real/bin"; printf 'home = /x\n' >"$R/real/pyvenv.cfg"; ln -s real/pyvenv.cfg "$R/lnk.cfg"
mkdir "$R/sl"; ln -s ../real/pyvenv.cfg "$R/sl/pyvenv.cfg"
deps clean
expect "23d a symlinked pyvenv.cfg is not a venv" 2 'no venvs found|real: skipped' 'sl:'

# 23e-23g: a venv inside a nested checkout or submodule that is gitignored in
# the scanned repo. The outer index cannot see what the inner repo tracks.
# mkinner DIR TRACK: DIR is its own repo with a venv "v"; TRACK=1 commits it.
mkinner() {
  mkdir -p "$1/v/bin"; : >"$1/v/pyvenv.cfg"
  printf '#!/bin/sh\ntouch "%s"\n' "$MARK" >"$1/v/bin/python"; chmod +x "$1/v/bin/python"
  git init -q "$1" || exit 2
  git -C "$1" config user.name t; git -C "$1" config user.email t@example.invalid
  git -C "$1" config commit.gpgsign false
  if [ "$2" = 1 ]; then git -C "$1" add v; git -C "$1" commit -q -m venv; fi
  : >"$1/keep"; git -C "$1" add keep; git -C "$1" commit -q -m keep
}
MARK=$TMP/mark23e; rm -f "$MARK"
mkrepo; mkinner "$R/third" 1; printf 'third/\n' >"$R/.gitignore"
deps execpy
expect "23e venv committed in a gitignored nested checkout: skipped, exit 2" 2 'third/v: skipped \(tracked in git; not executed\)' 'audited\)$'
[ ! -e "$MARK" ] || bad "23e2 nested tracked venv not executed" "the marker was written"
MARK=$TMP/mark23f; rm -f "$MARK"
SUBSRC=$TMP/subsrc23; mkinner "$SUBSRC" 1
mkrepo; git -C "$R" -c protocol.file.allow=always submodule add -q "$SUBSRC" sm >/dev/null 2>&1 || bad "23f0 fixture" "submodule add failed"
git -C "$R" commit -q --no-verify -m sm
deps execpy
expect "23f venv committed in a submodule: skipped, exit 2" 2 'sm/v: skipped \(tracked in git[^)]*not executed\)' 'audited\)$'
[ ! -e "$MARK" ] || bad "23f2 submodule venv not executed" "the marker was written"
MARK=$TMP/mark23g; rm -f "$MARK"
mkrepo; mkinner "$R/third" 0; printf 'third/\n' >"$R/.gitignore"
deps execpy
expect "23g untracked venv in a nested checkout: audited, exit 0" 0 'third/v: .*findings' 'skipped'
[ -e "$MARK" ] || bad "23g2 untracked nested venv is audited" "the marker was not written"

# 24 --------------------------------------------------------------------
mkrepo
mkdir -p "$TMP/w1/bin" "$TMP/w2/bin"
for v in "$TMP/w1" "$TMP/w2"; do : >"$v/pyvenv.cfg"; printf '#!/bin/sh\n' >"$v/bin/python"; chmod +x "$v/bin/python"; done
deps skipdep "$TMP/w1"
expect "24a package pip-audit could not resolve: listed, exit 0" 0 'w1: 2 packages, 0 findings, 1 not audited \(weirdpkg\)' 'incomplete'
printf '%s' "$OUT" | grep -q 'scan --deps: clean (1 audited)$' || bad "24a2 clean line" "$OUT"
deps skipmany "$TMP/w1"
expect "24b more than ten not audited: first ten, then ..." 0 '12 not audited \(p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, \.\.\.\)' 'p11'
deps failone "$TMP/v1" "$TMP/w2"
expect "24c one venv fails, one audited: incomplete (1 audited, 1 skipped), exit 2" 2 'scan --deps: incomplete \(1 audited, 1 skipped\)' 'clean'
deps vuln "$TMP/w1"
expect "24d findings still exit 1" 1 'findings in 1 of 1 venvs'

# 25 --------------------------------------------------------------------
# pip-audit runs from an empty directory: a pip/ package or pip.py in the
# directory --deps is run from must not shadow "python -m pip". The stub does
# what pip-audit does with PIPAPI_PYTHON_LOCATION; the venv is real.
MARK25=$TMP/mark25
mkshadow() { # pkg|mod: R gets an untracked venv and a shadowing pip at its root
  mkrepo
  printf '.venv/\n' >"$R/.gitignore"
  python3 -m venv --without-pip "$R/.venv" || exit 2
  if [ "$1" = pkg ]; then
    mkdir "$R/pip"; : >"$R/pip/__init__.py"; body='pip/__main__.py'
  else body='pip.py'; fi
  printf 'import os\nopen(os.environ["MARK25"], "a").write("shadow ran\\n")\n' >"$R/$body"
}
for shape in pkg mod; do
  mkshadow "$shape"; rm -f "$MARK25"
  OUT=$(cd "$R" && MARK25=$MARK25 STUB_MODE=pipmod GATES_PIP_AUDIT="$STUB" ./tools/scan.sh --deps 2>&1); RC=$?
  expect "25a $shape: shadowing pip at the repo root, --deps from the root: exit 0" 0 '\.venv: .*findings'
  [ ! -e "$MARK25" ] || bad "25a2 $shape: shadow pip not executed" "the marker was written"
done
# A relative GATES_PIP_AUDIT still works after the directory change.
mkshadow mod; rm -f "$MARK25"
REL25=$(realpath --relative-to="$R" "$STUB")
OUT=$(cd "$R" && MARK25=$MARK25 STUB_MODE=pipmod GATES_PIP_AUDIT="$REL25" ./tools/scan.sh --deps 2>&1); RC=$?
expect "25b relative GATES_PIP_AUDIT: exit 0" 0 '\.venv: .*findings'
[ ! -e "$MARK25" ] || bad "25b2 shadow pip not executed (relative stub)" "the marker was written"

# 25c -------------------------------------------------------------------
# A .git/config in the scanned tree that sets core.fsmonitor to a command must
# not get that command run by the git calls --deps makes about a venv.
MARK25C=$TMP/mark25c
mkrepo
printf '.venv/\n' >"$R/.gitignore"
python3 -m venv --without-pip "$R/.venv" || exit 2
printf '#!/bin/sh\necho ran >>"%s"\nprintf "\\0"\n' "$MARK25C" >"$TMP/fsm25c"; chmod +x "$TMP/fsm25c"
git -C "$R" config core.fsmonitor "$TMP/fsm25c"
rm -f "$MARK25C"
OUT=$(cd "$R" && STUB_MODE=clean GATES_PIP_AUDIT="$STUB" ./tools/scan.sh --deps 2>&1); RC=$?
expect "25c core.fsmonitor in the tree's .git/config: --deps exit 0" 0 '\.venv: .*findings'
[ ! -e "$MARK25C" ] || bad "25c2 core.fsmonitor command not run by --deps" "the marker was written"

# 26 --------------------------------------------------------------------
# bandit's default exclude list must not drop explicitly named files.
B602_PY=$'import subprocess\n\n\ndef f(c):\n    subprocess.call(c, shell=True)\n'
for d in .github/scripts .githooks .gitlab scripts; do
  mkrepo; put "$d/s.py" "$B602_PY"; commit
  expect "26a B602 under $d/: refused" 1 's\.py:5: B602'
done
mkrepo; put .github/scripts/s.py "$B602_PY"; commit --no-verify; scan --all
expect "26b the same, --all: refused" 1 's\.py:5: B602'
mkrepo; put .github/scripts/ok.py "$CLEAN_PY"; commit
expect "26c a clean file under .github/: succeeds" 0

# 27 --------------------------------------------------------------------
# A file bandit cannot analyse is a tool error, not a clean file. A 1200-term
# expression makes bandit raise; a file that does not parse lands in "errors".
DEEP_PY=$(python3 -c "print('import subprocess, sys'); print('x = ' + '+'.join(['1'] * 1200)); print('subprocess.call(sys.argv[1], shell=True)')")$'\n'
mkrepo; put d.py "$DEEP_PY"; scan --staged
expect "27a 1200-term expression plus B602: not clean (tool error)" 2 'd\.py: exception while scanning'  
mkrepo; put p.py $'def (:\n'; scan --staged
expect "27b a file bandit cannot parse: tool error, exit 2" 2 'tool error'

# 28 --------------------------------------------------------------------
# A scanner killed before it writes its exit status is a tool error.
FV=$TMP/fv28; mkdir -p "$FV/bin"
printf '#!/bin/sh\nexec "%s/bin/ruff" "$@"\n' "$GATES_SCAN_VENV" >"$FV/bin/ruff"
# shellcheck disable=SC2016  # $PPID is for the stub, not this shell
printf '#!/bin/sh\nkill -9 $PPID\n' >"$FV/bin/bandit"; chmod +x "$FV/bin/ruff" "$FV/bin/bandit"
mkrepo; put s.py "$B602_PY"
OUT=$(cd "$R" && GATES_SCAN_VENV="$FV" ./tools/scan.sh --staged 2>&1); RC=$?
expect "28a bandit killed: exit 2, not clean" 2 'bandit: tool error' 'scan: clean'
# The kill stub must not matter when bandit never starts (no .py selected).
mkrepo; put notes.txt $'hello\n'
OUT=$(cd "$R" && GATES_SCAN_VENV="$FV" ./tools/scan.sh --staged 2>&1); RC=$?
expect "28b a commit with only a .txt: bandit not started, exit 0" 0 'scan: clean'
mkrepo; put x.sh "$CLEAN_SH"
OUT=$(cd "$R" && GATES_SCAN_VENV="$FV" ./tools/scan.sh --staged 2>&1); RC=$?
expect "28c a commit with only a .sh: exit 0" 0 'scan: clean'

# 29 --------------------------------------------------------------------
# A path with a newline could forge a baseline key or a finding line.
mkrepo; put $'src/a.py\nb.py' "$CLEAN_PY"; scan --staged
expect "29a newline in a staged path: exit 2 naming it" 2 'newline or carriage return.*src/a\.py' 'scan: clean'
mkrepo; put $'x\ry.txt' $'hello\n'; scan --staged
expect "29b carriage return in a staged path: exit 2" 2 'newline or carriage return'
mkrepo; put $'src/a.py\nb.py' "$CLEAN_PY"; commit
expect "29c through the hook: refused" 1 'newline or carriage return'
mkrepo; put $'src/a.py\nb.py' "$CLEAN_PY"; commit --no-verify; scan --all
expect "29d --all: exit 2" 2 'newline or carriage return'

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
