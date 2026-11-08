#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joe Fernandez
#
# Code scanner: ruff, bandit, shellcheck and gitleaks over the files of a
# commit or of the whole index, and pip-audit over the Python venvs.
#
#   scan.sh [--staged]                  default; what git-hooks/pre-commit runs
#   scan.sh --all [-v|--verbose]        every tracked file (the whole index);
#                                       -v also prints the known findings
#   scan.sh --deps [VENV_DIR...]        pip-audit the venvs (needs network)
#
# Exit 0 clean, 1 findings, 2 usage or setup error (a tool or config missing,
# a scanner that started and left no exit status, or a bandit run that did
# not analyse every selected .py; under --deps any venv skipped; a selected
# path whose name holds a newline or carriage return).
#
# --staged and --all are offline. They scan the INDEX content, not the working
# tree, so a partly staged file is judged as it will be committed, and nothing
# is written into the repo. --staged covers added, copied, modified, renamed and
# type-changed paths (not deletions); a commit that only deletes files is clean
# (0 files). For the linters the selected paths are exported with git
# checkout-index into a temp dir. Paths in scan.exclude (beside this script)
# are dropped first.
#   Python: *.py, or no extension and a shebang naming python.
#   Shell:  *.sh, or no extension and a shebang ending in sh, bash or dash.
#   ruff        --isolated, only E9,F63,F7,F82 (syntax errors, undefined names)
#   bandit      medium and higher severity and confidence. Run with -f json and
#               an exclude that matches nothing (bandit's default exclude list
#               would otherwise drop explicitly named files under .github/,
#               .githooks/, .gitlab/ and the like). The JSON is turned into
#               PATH:LINE: CODE [SEVERITY] message lines. It is a tool error
#               (exit 2), not a clean run, if the JSON does not parse, bandit
#               reports any entry in "errors" (a file it could not parse or
#               analyse), or a selected .py is missing from its "metrics".
#   Shell lint  shellcheck --norc, warning and higher
#   gitleaks    every staged (--staged) or selected (--all) file, not only py
#               and sh; always the config beside the binary and --redact (a
#               .gitleaks.toml in the scanned tree would otherwise replace the
#               rules). It runs "gitleaks dir" over a separate tree, $TMP/gl,
#               holding the RAW blob of each path, read with git cat-file from
#               the index. No .gitattributes filter, working-tree-encoding or
#               -diff attribute applies, so none can hide content from it.
#               Symlinks and gitlinks are not copied. Whole files are scanned,
#               not only the added lines, so a secret already sitting in a
#               modified file is reported; that is intended. Under --staged
#               every staged path is read, so scan.exclude does not apply to
#               it and it runs even when every staged path is excluded; under
#               --all scan.exclude is honoured. Findings are reported under
#               the repo path. Checked against gitleaks 8.30.1: dir mode reads
#               a .gitleaksignore only from the source root (and from its
#               working directory, -i); a .gitleaksignore in a subdirectory
#               and a .gitleaks.toml anywhere in the source are not read. A
#               tracked root .gitleaksignore is therefore written into the
#               tree as .gitleaksignore.content (still scanned, reported under
#               its real name), so the source root never holds a file gitleaks
#               honours. -i points at a file that does not exist. Fingerprints
#               carry the temp path, which no tracked file can match.
# Every linter ignores config files in the scanned tree (pyproject.toml,
# ruff.toml, .shellcheckrc, .bandit). The only suppressions are the tools' own
# comments: # noqa: CODE, # nosec BNNN, # shellcheck disable=SCNNNN, and
# gitleaks:allow. Each needs a reason comment beside it.
#
# Known findings: scan.baseline (beside this script) lists findings that
# exist already, one per line: TOOL<TAB>PATH<TAB>CODE<TAB>REASON (see the file).
# A finding whose (tool, path, code) matches an entry is known: not printed, not
# counted, exit stays 0. There are no line numbers, so a NEW finding with the
# same code in the same file is masked too; accept that, and prefer an inline
# suppression with a reason for anything new. --all also lists entries that
# matched nothing as stale (informational, exit unchanged). A malformed baseline
# line is exit 2 naming the line number.
#
# --deps audits each venv's installed packages. Default list: every directory
# holding pyvenv.cfg under the top level of the repository the command is run
# in (git rev-parse --show-toplevel from the current directory; outside a
# repository it is exit 2 asking for VENV_DIR arguments). Labelled third-party when it sits
# in this script's directory (except its own .venv-scan; checked-out trees live
# beside the scanner), else ours. pip, setuptools and wheel findings are
# "venv tooling": printed, but do not make the exit 1. A venv whose audit
# fails (no network, pip-audit error, unparsable output), has no bin/python, or
# is tracked in git is skipped, not a finding. pip-audit runs from an empty
# temporary directory with PYTHONSAFEPATH=1, so a pip/ or pip.py in the current
# directory cannot shadow pip. A venv with tracked files is
# never executed (its bin/python would run), unless named as a VENV_DIR argument,
# which is trusted. A pyvenv.cfg that is not a regular file is not a venv.
# A package pip-audit could not resolve (skip_reason) is reported per venv as
# "K not audited (names)" and does not change the exit. Exit 1 on findings;
# else exit 2 if any venv was skipped ("incomplete (M audited, S skipped)");
# else 0 ("clean (M audited)"). So 0 means every venv was audited.
#
# Tools (resolved, never installed). DIR is this script's directory inside the
# main checkout (MAIN/REL, where REL is the script's path from its worktree top;
# empty when the script sits at the top):
#   GATES_SCAN_VENV           default DIR/.venv-scan (ruff, bandit, pip-audit);
#                             rebuild: python3 -m venv DIR/.venv-scan &&
#                             DIR/.venv-scan/bin/pip install -r
#                             DIR/scan-requirements.txt
#   GATES_GITLEAKS            default DIR/gitleaks/gitleaks
#   GATES_GITLEAKS_CONFIG     default DIR/gitleaks/gitleaks.toml
#   GATES_PIP_AUDIT           default the venv's bin/pip-audit
#   the shellcheck binary comes from PATH
# MAIN is the main checkout, found from this script's own directory so a
# worktree resolves to the same tools.
set -uo pipefail

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
MAIN=$SELF
REL=''
# Inside a git hook GIT_DIR and friends are set and would make git answer for
# the commit's repo (or for $SELF itself) instead of for this script's own.
selfgit() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR git -C "$SELF" "$@"; }
if TOPSELF=$(selfgit rev-parse --show-toplevel 2>/dev/null); then
  [ "$SELF" = "$TOPSELF" ] || REL=${SELF#"$TOPSELF"/}
  MAIN=$(dirname "$(selfgit rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")
  [ -d "$MAIN/$REL" ] || { MAIN=$SELF; REL=''; }
fi
DIR=$MAIN${REL:+/$REL}
SCAN_VENV=${GATES_SCAN_VENV:-$DIR/.venv-scan}
GITLEAKS=${GATES_GITLEAKS:-$DIR/gitleaks/gitleaks}
GL_CONFIG=${GATES_GITLEAKS_CONFIG:-$DIR/gitleaks/gitleaks.toml}
REBUILD="python3 -m venv $DIR/.venv-scan && $DIR/.venv-scan/bin/pip install -r $DIR/scan-requirements.txt"

die() { echo "scan: $*" >&2; exit 2; }

USAGE="usage: scan.sh [--staged | --all [-v|--verbose] | --deps [VENV_DIR...]]"
mode=staged
verbose=0
if [ "${1:-}" = --deps ]; then
  mode=deps; shift
else
  for arg in "$@"; do
    case $arg in
    --staged) mode=staged ;;
    --all) mode=all ;;
    -v | --verbose) verbose=1 ;;
    *) die "$USAGE" ;;
    esac
  done
fi

# ---------------------------------------------------------------- --deps
if [ "$mode" = deps ]; then
  PIP_AUDIT=${GATES_PIP_AUDIT:-$SCAN_VENV/bin/pip-audit}
  [ -x "$PIP_AUDIT" ] || die "setup: pip-audit not found at $PIP_AUDIT; rebuild the scanner venv: $REBUILD"
  # Absolute: pip-audit runs from another directory below.
  case $PIP_AUDIT in /*) ;; *) PIP_AUDIT=$(cd "$(dirname "$PIP_AUDIT")" && pwd -P)/$(basename "$PIP_AUDIT") ;; esac
  command -v python3 >/dev/null || die "setup: python3 not found on PATH"
  venvs=()
  explicit=0
  SEARCH=$(git rev-parse --show-toplevel 2>/dev/null) || SEARCH=''
  if [ $# -gt 0 ]; then
    venvs=("$@"); explicit=1
  else
    [ -n "$SEARCH" ] || die "--deps: not inside a git repository; pass VENV_DIR arguments"
    while IFS= read -r -d '' cfg; do
      venvs+=("$(dirname "$cfg")")
    done < <(find "$SEARCH" \( -name node_modules -o -name .git \) -prune -o -type f -name pyvenv.cfg -print0 2>/dev/null | sort -z)
  fi
  [ ${#venvs[@]} -gt 0 ] || die "no venvs found under $SEARCH"

  parser='
import json, sys
label, path = sys.argv[1], sys.argv[2]
try:
    data = json.load(sys.stdin)
    deps = data["dependencies"]
except Exception:
    sys.exit(3)
TOOLING = {"pip", "setuptools", "wheel"}
real, tool, seen_r, seen_t, noaud = [], [], set(), set(), []
for d in deps:
    name = str(d.get("name", "?"))
    if d.get("skip_reason"):
        noaud.append(name)
    for v in d.get("vulns") or []:
        vid = str(v.get("id", "?"))
        fix = ", ".join(v.get("fix_versions") or []) or "none"
        item = "%s %s %s, fix %s" % (name, d.get("version", "?"), vid, fix)
        if name.lower().replace("_", "-") in TOOLING:
            if vid not in seen_t:
                seen_t.add(vid); tool.append(item)
        elif vid not in seen_r:
            seen_r.add(vid); real.append(item)
line = "[%s] %s: %d packages, %d findings" % (label, path, len(deps), len(real))
if noaud:
    line += ", %d not audited (%s%s)" % (len(noaud), ", ".join(noaud[:10]), ", ..." if len(noaud) > 10 else "")
if tool:
    line += " (+%d tooling: %s)" % (len(tool), "; ".join(tool))
print(line)
for item in real:
    print("    " + item)
sys.exit(10 if real else 0)
'
  # venv_tracked ABS: 0 untracked, 1 tracked, 2 git could not tell (the caller
  # treats it as tracked). Asks the outer repo, then the repository that holds
  # the venv itself (a nested checkout or submodule the outer index cannot
  # see). Any nonzero exit or stderr from git is "could not tell". The trees
  # are not ours, so every call turns core.fsmonitor off: a copied .git/config
  # could otherwise name a command for git to run.
  venv_tracked() {
    local abs=$1 gerr top out rc
    gerr=$(mktemp) || return 2
    gq() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR LC_ALL=C git -c core.fsmonitor=false "$@" 2>"$gerr"; }
    out=$(gq -C "$SEARCH" ls-files -- ":(literal)$abs"); rc=$?
    if [ $rc -ne 0 ] || [ -s "$gerr" ]; then rm -f "$gerr"; return 2; fi
    if [ -n "$out" ]; then rm -f "$gerr"; return 1; fi
    top=$(gq -C "$abs" rev-parse --show-toplevel); rc=$?
    if [ $rc -ne 0 ]; then
      if grep -q '^fatal: not a git repository' "$gerr"; then rm -f "$gerr"; return 0; fi
      rm -f "$gerr"; return 2
    fi
    if [ -s "$gerr" ] || [ -z "$top" ]; then rm -f "$gerr"; return 2; fi
    out=$(gq -C "$abs" ls-files -- .); rc=$?
    if [ $rc -ne 0 ] || [ -s "$gerr" ]; then rm -f "$gerr"; return 2; fi
    rm -f "$gerr"
    [ -n "$out" ] && return 1
    return 0
  }
  AUDCWD=$(mktemp -d) || die "mktemp failed"
  trap 'rm -rf "$AUDCWD"' EXIT
  nfind=0; nskip=0; naud=0
  for v in "${venvs[@]}"; do
    v=${v%/}
    abs=$(cd "$v" 2>/dev/null && pwd) || { echo "$v: skipped (no such directory)"; nskip=$((nskip + 1)); continue; }
    rel=$abs
    label=ours
    if [ -n "$SEARCH" ] && [ "${abs#"$SEARCH"/}" != "$abs" ]; then
      rel=${abs#"$SEARCH"/}
    elif [ "${abs#"$MAIN"/}" != "$abs" ]; then
      rel=${abs#"$MAIN"/}
    fi
    case $abs in
    "$DIR/.venv-scan") ;;
    "$DIR"/*) label=third-party ;;
    esac
    if [ "$explicit" -eq 0 ]; then
      venv_tracked "$abs"
      case $? in
      0) ;;
      1) echo "$rel: skipped (tracked in git; not executed)"; nskip=$((nskip + 1)); continue ;;
      *) echo "$rel: skipped (tracked in git, or git could not tell; not executed)"; nskip=$((nskip + 1)); continue ;;
      esac
    fi
    if [ ! -x "$abs/bin/python" ]; then
      echo "$rel: skipped (no bin/python)"; nskip=$((nskip + 1)); continue
    fi
    errf=$(mktemp) || die "mktemp failed"
    json=$(cd "$AUDCWD" && PYTHONSAFEPATH=1 PIPAPI_PYTHON_LOCATION="$abs/bin/python" timeout 180 "$PIP_AUDIT" --progress-spinner off -f json 2>"$errf")
    rc=$?
    out=$(printf '%s' "$json" | python3 -I -c "$parser" "$label" "$rel" 2>/dev/null)
    prc=$?
    if [ $prc -ne 0 ] && [ $prc -ne 10 ]; then
      reason=$(grep -v '^[[:space:]]*$' "$errf" | tail -n1 | cut -c1-160)
      echo "$rel: skipped (${reason:-pip-audit exit $rc, no usable output})"
      nskip=$((nskip + 1))
    else
      printf '%s\n' "$out"
      naud=$((naud + 1))
      [ $prc -eq 10 ] && nfind=$((nfind + 1))
    fi
    rm -f "$errf"
  done
  if [ $nfind -gt 0 ]; then
    echo "scan --deps: findings in $nfind of ${#venvs[@]} venvs ($nskip skipped)"
    exit 1
  fi
  if [ $nskip -gt 0 ]; then
    echo "scan --deps: incomplete ($naud audited, $nskip skipped)"
    exit 2
  fi
  echo "scan --deps: clean ($naud audited)"
  exit 0
fi

# ------------------------------------------------------ --staged and --all
missing=()
[ -x "$SCAN_VENV/bin/ruff" ] || missing+=("ruff ($SCAN_VENV/bin/ruff)")
[ -x "$SCAN_VENV/bin/bandit" ] || missing+=("bandit ($SCAN_VENV/bin/bandit)")
if [ ${#missing[@]} -gt 0 ]; then
  die "setup: missing ${missing[*]}; rebuild the scanner venv: $REBUILD"
fi
command -v shellcheck >/dev/null || die "setup: shellcheck not on PATH; see the publish-gates README, Setup"
command -v python3 >/dev/null || die "setup: python3 not on PATH"
[ -x "$GITLEAKS" ] || die "setup: gitleaks not found at $GITLEAKS; see the publish-gates README, Setup"
[ -f "$GL_CONFIG" ] || die "setup: gitleaks config not found at $GL_CONFIG; see the publish-gates README, Setup"
RUFF=$SCAN_VENV/bin/ruff
BANDIT=$SCAN_VENV/bin/bandit

TOP=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
cd "$TOP" || die "cannot enter $TOP"

excludes=()
if [ -f "$SELF/scan.exclude" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in '' | '#'*) continue ;; esac
    excludes+=("$line")
  done <"$SELF/scan.exclude"
fi

declare -A bl=() hits=()
baseorder=()
if [ -f "$SELF/scan.baseline" ]; then
  ln=0
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln + 1))
    case $line in '' | '#'*) continue ;; esac
    tabs=${line//[^$'\t']/}
    [ ${#tabs} -eq 3 ] || die "scan.baseline line $ln: want TOOL<TAB>PATH<TAB>CODE<TAB>REASON"
    t=${line%%$'\t'*}; rest=${line#*$'\t'}
    pth=${rest%%$'\t'*}; rest=${rest#*$'\t'}
    cde=${rest%%$'\t'*}; why=${rest#*$'\t'}
    case $t in ruff | bandit | shellcheck | gitleaks) ;; *) die "scan.baseline line $ln: unknown tool '$t'" ;; esac
    [ -n "$pth" ] && [ -n "$cde" ] && [ -n "${why// /}" ] || die "scan.baseline line $ln: empty PATH, CODE or REASON"
    key=$t$'\t'$pth$'\t'$cde
    bl[$key]=1; hits[$key]=0; baseorder+=("$key")
  done <"$SELF/scan.baseline"
fi

all=()
if [ "$mode" = staged ]; then
  while IFS= read -r -d '' p; do all+=("$p"); done < <(git diff --cached --name-only --diff-filter=ACMRT -z)
else
  while IFS= read -r -d '' p; do all+=("$p"); done < <(git ls-files -z)
fi

# The baseline key and the finding lines are newline-delimited; a path with a
# newline or CR could forge a key, so refuse it outright.
for p in "${all[@]}"; do
  case $p in
  *$'\n'* | *$'\r'*) die "path contains a newline or carriage return: $(printf '%q' "$p")" ;;
  esac
done

files=()
for p in "${all[@]}"; do
  skip=0
  for g in "${excludes[@]}"; do
    # shellcheck disable=SC2053  # the glob is meant to be a pattern
    if [[ $p == $g ]]; then skip=1; break; fi
  done
  [ $skip -eq 1 ] || files+=("$p")
done

# Under --staged gitleaks reads every staged path and ignores scan.exclude, so
# the early exit is only for a commit that holds nothing but deletions. Under
# --all gitleaks reads files[], which honours the exclude list.
if [ "$mode" = staged ]; then
  if git diff --cached --quiet --diff-filter=d; then
    echo "scan: clean (0 files)"
    exit 0
  fi
elif [ ${#files[@]} -eq 0 ]; then
  echo "scan: clean (0 files)"
  exit 0
fi

TMP=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT
W=$TMP/w
mkdir "$W" || die "mkdir failed"
if [ ${#files[@]} -gt 0 ]; then
  printf '%s\0' "${files[@]}" | git checkout-index --prefix="$W/" -z --stdin || die "could not export the index"
fi

# Fills the gitleaks tree: stdin is the NUL-separated path list, argv the
# target directory and a file that records the alias used for a root
# .gitleaksignore. Blobs come from the index (stage 0) through git cat-file,
# so no attribute, filter or encoding touches them; symlinks and gitlinks
# are left out.
gl_fill='
import os, subprocess, sys, tempfile
dst, aliasf = sys.argv[1], sys.argv[2]
paths = [p for p in sys.stdin.buffer.read().split(b"\0") if p]
want = set(paths)
alias = b".gitleaksignore.content"
while alias in want:
    alias += b"_"
open(aliasf, "wb").write(alias)
ls = subprocess.run(["git", "ls-files", "-s", "-z"], stdout=subprocess.PIPE, check=True).stdout
index = {}
for ent in ls.split(b"\0"):
    if not ent:
        continue
    meta, _, path = ent.partition(b"\t")
    mode, sha, stage = meta.split()
    if stage == b"0":
        index[path] = (mode, sha)
todo = []
for p in paths:
    ent = index.get(p)
    if ent and ent[0] in (b"100644", b"100755"):
        todo.append((p, ent[1]))
if not todo:
    sys.exit(0)
with tempfile.TemporaryFile() as req, tempfile.TemporaryFile() as resp:
    for _, sha in todo:
        req.write(sha + b"\n")
    req.seek(0)
    subprocess.run(["git", "cat-file", "--batch"], stdin=req, stdout=resp, check=True)
    resp.seek(0)
    for p, sha in todo:
        head = resp.readline().split()
        if len(head) != 3 or head[1] != b"blob":
            sys.exit(1)
        size = int(head[2])
        data = resp.read(size)
        resp.read(1)
        name = alias if p == b".gitleaksignore" else p
        out = os.path.join(os.fsencode(dst), name)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "wb") as fh:
            fh.write(data)
'
# Turns the gitleaks JSON into "path:line: rule" lines: strips the tree prefix
# as a plain string (no pattern) and maps the alias back to .gitleaksignore.
gl_parse='
import json, sys
root = sys.argv[1].rstrip("/") + "/"
alias = open(sys.argv[2], "rb").read().decode("utf-8", "surrogateescape")
for r in json.load(sys.stdin) or []:
    f = r["File"]
    if f.startswith(root):
        f = f[len(root):]
    if f == alias:
        f = ".gitleaksignore"
    print("%s:%s: %s" % (f, r["StartLine"], r["RuleID"]))
'

py=(); sh=()
re_py='^#!.*python'
re_sh='^#!.*[/ ](sh|bash|dash)([[:space:]].*)?$'
for p in "${files[@]}"; do
  f=$W/$p
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  base=${p##*/}
  case $base in
  *.py) py+=("$p"); continue ;;
  *.sh) sh+=("$p"); continue ;;
  *.*) continue ;;
  esac
  first=''
  IFS= read -r first <"$f" 2>/dev/null || true
  first=${first%$'\r'}
  if [[ $first =~ $re_py ]]; then py+=("$p")
  elif [[ $first =~ $re_sh ]]; then sh+=("$p")
  fi
done

# Each linter runs in $W (cwd), writes to $TMP/NAME.out and NAME.err, and its
# exit status to NAME.rc. They run in parallel.
run() { # name, command...
  local n=$1; shift
  : >"$TMP/$n.started"
  ( cd "$W" && "$@" >"$TMP/$n.out" 2>"$TMP/$n.err"; echo $? >"$TMP/$n.rc" ) &
}
if [ ${#py[@]} -gt 0 ]; then
  run ruff "$RUFF" check --isolated --no-cache --select E9,F63,F7,F82 --output-format concise -- "${py[@]}"
  # -x with a path that matches nothing: the default exclude list otherwise
  # drops explicitly named files (.github/, .githooks/, ...), silently.
  run bandit "$BANDIT" -q -ll -ii -f json -x /nonexistent/scan-sh-no-exclude -- "${py[@]}"
  printf '%s\0' "${py[@]}" >"$TMP/py.list"
fi
if [ ${#sh[@]} -gt 0 ]; then
  run shellcheck shellcheck --norc -S warning -f gcc -- "${sh[@]}"
fi
# gitleaks reads a separate tree of raw blobs (see the header).
GLDIR=$TMP/gl
mkdir "$GLDIR" || die "mkdir failed"
printf "%s" .gitleaksignore.content >"$TMP/gl.alias"
if [ "$mode" = staged ]; then glpaths=("${all[@]}"); else glpaths=("${files[@]}"); fi
if [ ${#glpaths[@]} -gt 0 ]; then
  printf '%s\0' "${glpaths[@]}" | python3 -I -c "$gl_fill" "$GLDIR" "$TMP/gl.alias" || die "could not read the index blobs for gitleaks"
fi
run gitleaks "$GITLEAKS" dir "$GLDIR" --redact --no-banner --no-color --config "$GL_CONFIG" --gitleaks-ignore-path "$TMP/no-gitleaksignore" -f json -r -
wait

# Bandit JSON to finding lines on stdout. argv[1] is the NUL-separated list of
# the .py paths that were selected. Exit 3 (nothing trusted) if the JSON does
# not parse, "errors" is non-empty, or a selected path is missing from
# "metrics" (an analysed file always has an entry, even a clean one).
bandit_parse='
import json, os, sys
try:
    d = json.load(sys.stdin)
    errs = d["errors"]
    metrics = d["metrics"]
    results = d["results"]
    want = [p for p in open(sys.argv[1], "rb").read().decode("utf-8", "surrogateescape").split("\0") if p]
    seen = {os.path.normpath(k) for k in metrics if k != "_totals"}
    problems = ["%s: %s" % (e.get("filename"), e.get("reason")) for e in errs]
    problems += ["%s: not analysed" % p for p in want if os.path.normpath(p) not in seen]
    if problems:
        for x in problems:
            sys.stderr.write(x + "\n")
        sys.exit(3)
    for r in results:
        msg = " ".join(str(r["issue_text"]).split())
        print("%s:%s: %s [%s] %s" % (os.path.normpath(r["filename"]), r["line_number"], r["test_id"], r["issue_severity"], msg))
except SystemExit:
    raise
except Exception as e:
    sys.stderr.write("unusable bandit output: %r\n" % (e,))
    sys.exit(3)
'

total=0; toolerr=0; known=0
declare -A cnt=([ruff]=0 [bandit]=0 [shellcheck]=0 [gitleaks]=0)
re_ruff='^(.+):[0-9]+:[0-9]+: ([^ :]+)'
re_bandit='^(.+):[0-9]+: (B[0-9]+) '
re_sc='^(.+):[0-9]+:[0-9]+: .*\[(SC[0-9]+)\]$'
re_gl='^(.+):[0-9]+: (.+)$'
for n in ruff bandit shellcheck gitleaks; do
  if [ ! -f "$TMP/$n.rc" ]; then
    if [ -f "$TMP/$n.started" ]; then
      echo "== $n: tool error (started, no exit status: killed?) ==" >&2
      cat "$TMP/$n.out" "$TMP/$n.err" 2>/dev/null >&2
      toolerr=1
    fi
    continue
  fi
  rc=$(cat "$TMP/$n.rc")
  case $n in
  ruff | shellcheck) lines=$(grep -E '^.+:[0-9]+:[0-9]+: ' "$TMP/$n.out") ;;
  bandit)
    if ! lines=$(python3 -I -c "$bandit_parse" "$TMP/py.list" <"$TMP/$n.out" 2>"$TMP/bandit.perr"); then
      echo "== bandit: tool error (exit $rc; output not trusted) ==" >&2
      cat "$TMP/bandit.perr" "$TMP/$n.err" >&2
      toolerr=1
      continue
    fi
    ;;
  gitleaks)
    lines=$(python3 -I -c "$gl_parse" "$GLDIR" "$TMP/gl.alias" <"$TMP/$n.out" 2>/dev/null)
    ;;
  esac
  k=0
  [ -n "$lines" ] && k=$(printf '%s\n' "$lines" | wc -l)
  if [ "$rc" -ne 0 ] && [ "$k" -eq 0 ]; then
    echo "== $n: tool error (exit $rc) ==" >&2
    cat "$TMP/$n.out" "$TMP/$n.err" >&2
    toolerr=1
    continue
  fi
  new_lines=(); known_lines=()
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    case $n in ruff) re=$re_ruff ;; bandit) re=$re_bandit ;; shellcheck) re=$re_sc ;; gitleaks) re=$re_gl ;; esac
    key=''
    if [[ $l =~ $re ]]; then
      code=${BASH_REMATCH[2]}
      key=$n$'\t'${BASH_REMATCH[1]}$'\t'$code
    fi
    if [ -n "$key" ] && [ -n "${bl[$key]:-}" ]; then
      hits[$key]=$((hits[$key] + 1)); known_lines+=("$l")
    else
      new_lines+=("$l")
    fi
  done <<<"$lines"
  known=$((known + ${#known_lines[@]}))
  if [ ${#new_lines[@]} -gt 0 ]; then
    echo "== $n =="
    printf '%s\n' "${new_lines[@]}"
  fi
  if [ "$verbose" -eq 1 ] && [ ${#known_lines[@]} -gt 0 ]; then
    echo "== $n (known) =="
    printf '%s\n' "${known_lines[@]}"
  fi
  cnt[$n]=${#new_lines[@]}
  total=$((total + ${#new_lines[@]}))
done

[ $toolerr -eq 0 ] || exit 2
if [ "$mode" = all ]; then
  for key in "${baseorder[@]}"; do
    [ "${hits[$key]}" -eq 0 ] || continue
    IFS=$'\t' read -r t pth cde <<<"$key"
    echo "stale baseline entry (remove): $t $pth $cde"
  done
fi
suffix=''
[ $known -eq 0 ] || suffix="; $known known (${REL:+$REL/}scan.baseline)"
if [ $total -gt 0 ]; then
  echo "scan: $total findings (ruff ${cnt[ruff]}, bandit ${cnt[bandit]}, shellcheck ${cnt[shellcheck]}, gitleaks ${cnt[gitleaks]})$suffix"
  exit 1
fi
echo "scan: clean (${#files[@]} files)$suffix"
exit 0
