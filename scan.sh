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
# or under --deps every venv skipped).
#
# --staged and --all are offline. They scan the INDEX content, not the working
# tree: the selected paths are exported with git checkout-index into a temp
# dir, so a partly staged file is judged as it will be committed, and nothing
# is written into the repo. Paths in scan.exclude (beside this script)
# are dropped first.
#   Python: *.py, or no extension and a shebang naming python.
#   Shell:  *.sh, or no extension and a shebang ending in sh, bash or dash.
#   ruff        --isolated, only E9,F63,F7,F82 (syntax errors, undefined names)
#   bandit      medium and higher severity and confidence
#   Shell lint  shellcheck --norc, warning and higher
#   gitleaks    every selected file, not only py and sh; always the config
#               beside the binary and --redact (a .gitleaks.toml in the scanned tree
#               would otherwise replace the rules). Under --staged it reads
#               git itself, so scan.exclude does not apply to it, and it runs
#               even when every staged path is excluded. A .gitleaksignore in
#               the scanned tree is not honoured: gitleaks reads one from its
#               working directory (-i, default ".") and, under git, from the
#               source directory. -i points at a file that does not exist and
#               --staged names an empty directory as the source, with GIT_DIR
#               set to the repo, so the staged content is still what is read.
#               Under --all the source is the exported tree by absolute path,
#               and fingerprints carry that path, which no tracked file can
#               match.
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
# fails (no network, pip-audit error) is skipped, not a finding; if every venv
# is skipped the exit is 2.
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
  command -v python3 >/dev/null || die "setup: python3 not found on PATH"
  venvs=()
  SEARCH=$(git rev-parse --show-toplevel 2>/dev/null) || SEARCH=''
  if [ $# -gt 0 ]; then
    venvs=("$@")
  else
    [ -n "$SEARCH" ] || die "--deps: not inside a git repository; pass VENV_DIR arguments"
    while IFS= read -r -d '' cfg; do
      venvs+=("$(dirname "$cfg")")
    done < <(find "$SEARCH" \( -name node_modules -o -name .git \) -prune -o -name pyvenv.cfg -print0 2>/dev/null | sort -z)
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
real, tool, seen_r, seen_t = [], [], set(), set()
for d in deps:
    name = str(d.get("name", "?"))
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
if tool:
    line += " (+%d tooling: %s)" % (len(tool), "; ".join(tool))
print(line)
for item in real:
    print("    " + item)
sys.exit(10 if real else 0)
'
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
    if [ ! -x "$abs/bin/python" ]; then
      echo "$rel: skipped (no bin/python)"; nskip=$((nskip + 1)); continue
    fi
    errf=$(mktemp) || die "mktemp failed"
    json=$(PIPAPI_PYTHON_LOCATION="$abs/bin/python" timeout 180 "$PIP_AUDIT" --progress-spinner off -f json 2>"$errf")
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
  if [ $naud -eq 0 ]; then
    echo "scan --deps: every venv was skipped; nothing audited" >&2
    exit 2
  fi
  echo "scan --deps: clean ($naud audited, $nskip skipped)"
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
  while IFS= read -r -d '' p; do all+=("$p"); done < <(git diff --cached --name-only --diff-filter=ACMR -z)
else
  while IFS= read -r -d '' p; do all+=("$p"); done < <(git ls-files -z)
fi

files=()
for p in "${all[@]}"; do
  skip=0
  for g in "${excludes[@]}"; do
    # shellcheck disable=SC2053  # the glob is meant to be a pattern
    if [[ $p == $g ]]; then skip=1; break; fi
  done
  [ $skip -eq 1 ] || files+=("$p")
done

# Under --staged gitleaks reads git itself and ignores scan.exclude, so it runs
# whenever anything is staged, even if every staged path is excluded. Under
# --all it scans the exported tree, which honours the exclude list.
if [ ${#all[@]} -eq 0 ] || { [ "$mode" = all ] && [ ${#files[@]} -eq 0 ]; }; then
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
  ( cd "$W" && "$@" >"$TMP/$n.out" 2>"$TMP/$n.err"; echo $? >"$TMP/$n.rc" ) &
}
if [ ${#py[@]} -gt 0 ]; then
  run ruff "$RUFF" check --isolated --no-cache --select E9,F63,F7,F82 --output-format concise -- "${py[@]}"
  run bandit "$BANDIT" -q -ll -ii -f custom --msg-template '{relpath}:{line}: {test_id} [{severity}] {msg}' -- "${py[@]}"
fi
if [ ${#sh[@]} -gt 0 ]; then
  run shellcheck shellcheck --norc -S warning -f gcc -- "${sh[@]}"
fi
if [ "$mode" = staged ]; then
  GLSRC=$TMP/gl-src
  mkdir "$GLSRC" || die "mkdir failed"
  GLGIT=$(git rev-parse --absolute-git-dir) || die "cannot find the git dir"
  GLIDX=$(git rev-parse --path-format=absolute --git-path index) || die "cannot find the index"
  run gitleaks env GIT_DIR="$GLGIT" GIT_WORK_TREE="$GLSRC" GIT_INDEX_FILE="$GLIDX" "$GITLEAKS" git --pre-commit --staged --redact --no-banner --no-color --config "$GL_CONFIG" --gitleaks-ignore-path "$TMP/no-gitleaksignore" -f json -r - "$GLSRC"
else
  run gitleaks "$GITLEAKS" dir "$W" --redact --no-banner --no-color --config "$GL_CONFIG" --gitleaks-ignore-path "$TMP/no-gitleaksignore" -f json -r -
fi
wait

total=0; toolerr=0; known=0
declare -A cnt=([ruff]=0 [bandit]=0 [shellcheck]=0 [gitleaks]=0)
re_ruff='^(.+):[0-9]+:[0-9]+: ([^ :]+)'
re_bandit='^(.+):[0-9]+: (B[0-9]+) '
re_sc='^(.+):[0-9]+:[0-9]+: .*\[(SC[0-9]+)\]$'
re_gl='^(.+):[0-9]+: (.+)$'
for n in ruff bandit shellcheck gitleaks; do
  [ -f "$TMP/$n.rc" ] || continue
  rc=$(cat "$TMP/$n.rc")
  case $n in
  ruff | shellcheck) lines=$(grep -E '^.+:[0-9]+:[0-9]+: ' "$TMP/$n.out") ;;
  bandit) lines=$(grep -E '^.+:[0-9]+: B[0-9]+ ' "$TMP/$n.out") ;;
  gitleaks)
    lines=$(python3 -I -c '
import json, sys
for r in json.load(sys.stdin) or []:
    print("%s:%s: %s" % (r["File"], r["StartLine"], r["RuleID"]))' <"$TMP/$n.out" 2>/dev/null | sed "s#$W/##")
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
