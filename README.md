# publish-gates

Gates between a private working tree and anything public: a pre-commit code
scanner, a git hook that refuses commit messages GitHub would turn into
cross-references, a pre-push hook that stops a push to a public remote
unless the owner approved it, a scan of a directory for addresses, names and
credential shapes before it goes anywhere public, and a check of whether a
GitHub repo is public. Shell only; each gate is one file. They were written
for a machine where an AI coding agent commits and pushes on its own, and
they catch mistakes, not a hostile contributor: every one of them can be
bypassed by someone who means to.

| gate | runs | what it stops |
|---|---|---|
| `scan.sh` | by hand, or from `git-hooks/pre-commit` on every commit | syntax errors and undefined names (ruff), insecure Python patterns (bandit), shell mistakes (shellcheck) and secret shapes (gitleaks) in the files being committed |
| `git-hooks/pre-commit` | on `git commit`, in repos that opt in with `gates.scan true` | a commit that `scan.sh --staged` finds something in |
| `git-hooks/commit-msg` | on `git commit` in a private repo | a message holding `owner/repo#N`, `owner/repo@sha` or a github.com issue, pull, commit or discussions URL: GitHub posts the commit's title on that public item's timeline, which leaks a private repo's history one line at a time |
| `git-hooks/pre-push` | on every `git push` to github.com | the same cross-references in any commit being pushed, unless the target repo is known public (the gate behind `commit-msg`, which git skips for `-n`, cherry-pick, rebase and `am`); and any push to a GitHub repo that is not known private, unless `GATES_PUBLIC_PUSH_OK=yes` is on the command |
| `public-scan.sh DIR` | by hand, before a directory goes public | IPv4, IPv6 and MAC addresses, Tailscale names, email addresses, phone numbers, token and key shapes of a dozen vendors, private key blocks, passwords in assignments and URLs, and your own list of private terms |
| `check-visibility.sh OWNER REPO` | from `pre-push`, or by hand | prints `public`, `private` or `ask`; an answer it cannot settle is `ask`, not `private` (a 404, which is also what a misspelt name gets, is `private`: see below) |

## Setup

Clone the repo anywhere and keep the layout: the tools find each other by
relative path. The scanner's tools below go beside `scan.sh`, inside the
clone; add `.venv-scan/` and `gitleaks/` to the clone's `.git/info/exclude`
so they stay out of `git status` (the repo ships no `.gitignore`, so that
your own copy decides).

**Requirements:** bash 4 or later (`scan.sh` uses associative arrays; macOS
ships 3.2), GNU grep with PCRE (`grep -P`; `public-scan.sh` checks at start
and exits 2 without it), git 2.31 or later (`rev-parse --path-format`),
coreutils `timeout` for `scan.sh --deps`, curl for `check-visibility.sh`,
perl for `public-scan.sh`'s allow list, and gitleaks 8.30.1 or later
(`scan.sh` uses its `git` and `dir` subcommands and `--gitleaks-ignore-path`,
verified on 8.30.1 only).

**Scanner tools** for `scan.sh` (the hooks `commit-msg` and `pre-push`,
`public-scan.sh` and `check-visibility.sh` need none of these):

    python3 -m venv .venv-scan && .venv-scan/bin/pip install -r scan-requirements.txt
    # ruff, bandit and pip-audit, pinned

- gitleaks, a release binary at `gitleaks/gitleaks` beside `scan.sh`, with
  the release's default `config/gitleaks.toml` beside it as
  `gitleaks/gitleaks.toml`. The config is always passed explicitly: a
  `.gitleaks.toml` in a scanned tree must not be able to switch rules off.
- shellcheck on `PATH` (apt, brew or a release binary).

Other locations: `GATES_SCAN_VENV`, `GATES_GITLEAKS`, `GATES_GITLEAKS_CONFIG`
and `GATES_PIP_AUDIT` override the defaults, which are resolved beside the
script. From a git worktree the defaults resolve to the main checkout's
copies, so one install serves every worktree.

**Hooks.** Point git at the `git-hooks/` directory, for one repo or for every
repo on the machine:

    git config core.hooksPath /path/to/publish-gates/git-hooks            # this repo
    git config --global core.hooksPath /path/to/publish-gates/git-hooks   # every repo

**What is on from that moment:** `pre-push`'s visibility gate runs on every
push to github.com, so a push to your own public repo is refused until you
put `GATES_PUBLIC_PUSH_OK=yes` on the command; its cross-reference scan runs
on every push to a repo not known public; `commit-msg` runs in repos with no
origin. Everything else is opt-in by git config:

    git config --global --add gates.privateRepo OWNER/REPO    # once per private repo
    git config gates.scan true                                # in each repo to scan

`gates.privateRepo` is read with `git config --get-all`, so a local entry
counts as well as a global one; names compare case-insensitively, as
GitHub's do. It is what `commit-msg` goes by (it has no network to ask);
`pre-push` scans by the repo's actual visibility, listed or not. Check the
list with `git config --get-all gates.privateRepo`: a second `git config
--global gates.privateRepo` without `--add` replaces the first entry.
`gates.scan` is read from the repo being committed in; a worktree shares
its main checkout's local config. A value that is not a boolean refuses the
commit rather than passing it.

## scan.sh

    scan.sh [--staged]            default: what the pre-commit hook runs
    scan.sh --all [-v|--verbose]  every tracked file; -v also prints known findings
    scan.sh --deps [VENV_DIR...]  pip-audit the venvs (needs network)

Exit 0 clean, 1 findings, 2 usage or setup error (a tool or config missing,
or under `--deps` every venv skipped).

`--staged` and `--all` are offline and scan the **index**, not the working
tree: the selected paths are exported with `git checkout-index` into a temp
directory, so a partly staged file is judged as it will be committed, and
nothing is written into the repo. Python files are `*.py` or an
extensionless file whose shebang names python; shell files are `*.sh` or an
extensionless file whose shebang ends in sh, bash or dash.

| linter | what it checks |
|---|---|
| ruff | `--isolated`, only E9, F63, F7, F82: syntax errors and undefined names |
| bandit | medium and higher severity and confidence |
| shellcheck | `--norc`, warning and higher |
| gitleaks | every selected file, not only Python and shell; `--redact`, so a found secret is never printed. Under `--staged` it reads git itself, so `scan.exclude` does not apply to it and a commit made only of excluded files still gets the secret scan |

Every linter ignores config files in the scanned tree (`pyproject.toml`,
`ruff.toml`, `.shellcheckrc`, `.bandit`, `.gitleaks.toml`, `.gitleaksignore`).
What suppresses a finding is the tools' own inline comments: `# noqa: CODE`,
`# nosec BNNN`, `# shellcheck disable=SCNNNN` and `gitleaks:allow` (the
blanket forms the tools accept, a bare `# noqa` or `# nosec`, work too; the
scanner does not police them, and nothing checks that a reason is written
beside the comment, which is a convention for you to keep).

`scan.exclude`, beside the script, lists paths not to lint, one glob per
line (`*` crosses `/`). It and `scan.baseline` live in this clone, so every
repo that opts in shares the one exclude list and the one baseline; their
paths are relative to whichever repo is being scanned. `scan.baseline` lists findings that exist already,
one per line, `TOOL<TAB>PATH<TAB>CODE<TAB>REASON`: a matching finding is
counted as known and does not fail the run. There are no line numbers, so a
new finding with the same code in the same file is masked too; prefer an
inline suppression with a reason for anything new. `--all` lists baseline
entries that no longer match anything. Both files ship empty but for their
format comment.

`--deps` runs pip-audit over each venv's installed packages: by default
every directory holding `pyvenv.cfg` under the top of the repository you
run it in (outside any repository, name the venvs), else the ones named. pip, setuptools and wheel findings are reported as "venv tooling" and
do not fail the run. A venv whose audit fails (no network, a pip-audit
error) is skipped, not a finding; if every venv is skipped the exit is 2.

## git-hooks/pre-commit

Runs the `scan.sh` beside its own directory (this clone's, not one in the
repo being committed in) with `--staged`, against the index of the repo
being committed in, when that repo has `gates.scan true`. Unset or false,
it exits 0 silently; any other value refuses the commit. Refuses the commit
on a finding (exit 1) or when the scanner is not set up (exit 2, with the
rebuild line). A staged `*requirements*.txt` prints a reminder to run
`scan.sh --deps`; it does not block. If no `scan.sh` sits beside the hook's
directory the commit passes with a one-line note. Bypass for one commit:
`git commit --no-verify`.

## git-hooks/commit-msg and git-hooks/pre-push

The rule: a commit message that holds `owner/repo#N`, `owner/repo@sha`, or
a github.com issue, pull, commit or discussions URL is refused in a private
repo. Write `owner/repo PR N` instead. A bare `#N` is not refused.

`commit-msg` is the early catch, on `git commit` and `git merge` (the two
commands githooks(5) lists for it), where the repo's `origin` is in
`gates.privateRepo` or there is no origin at all (a fresh repo is private
until proven otherwise). It exits 0 elsewhere, so a checkout of a public
fork can reference upstream on purpose. Git does not run it for `-n`,
cherry-pick, rebase picks, `commit-tree` or `am`, so the gate is
`pre-push`.

`pre-push` does two things on a push to github.com (https, the scp-like
`git@` form and `ssh://`):

1. It runs `check-visibility.sh OWNER REPO` once. Unless the answer is
   `public`, it scans the full message of every commit being pushed that is
   not already on the target remote (reachable from that remote's tracking
   refs or its current tip), and refuses the push on a cross-reference,
   naming the commit and line. A deleted ref is skipped; a git failure
   refuses. A push to a mirror or a second remote first does not exempt the
   commits.
2. `private` passes. `public`, `ask`, a checker failure or a URL it cannot
   read an owner and repo from is refused, because an unknown is not
   private, unless the owner's approval is in the environment of the push
   as `GATES_PUBLIC_PUSH_OK=yes` (exactly `yes`; put it on the command, not
   exported, or every push in that shell is approved, each saying so on
   stderr). The approval does not skip step 1.

A remote that is not github.com (a local path, another host) passes both.
The visibility check is one unauthenticated API call, up to 20 s; with no
network it answers `ask` and the push is refused. Both hooks source
`git-hooks/xref.sh`, which holds the pattern and the config lookup; a
missing `xref.sh` refuses. `pre-push` finds `check-visibility.sh` at
`../check-visibility.sh`; `GATES_CHECK_VISIBILITY=PATH` replaces it (the test
stubs it). `git push --no-verify` bypasses the whole hook, and a
`core.hooksPath` override bypasses every hook: if an agent runs under an
outer permission layer, those two forms are what it should prompt on.

## public-scan.sh

    public-scan.sh DIR

Scans every file under DIR: in a git checkout the tracked and
untracked-not-ignored files, so a file copied in before `git add` is
covered; elsewhere every file, `.git` excluded. Pass or fail only: exit 0
clean (the ok line says how many files it read), 1 on any hit (each printed
with file and line), 2 on bad usage, on a grep without PCRE, or when the
selection is empty (an empty or gitignored directory), so a scan of nothing
never passes. It does not replace reading the diff; it catches what reading
misses.

Patterns: IPv4 addresses (`127.0.0.1` and `0.0.0.0` exactly pass), global and ULA IPv6
(`2001:db8:` passes), MAC addresses, `*.ts.net` names, email addresses,
US phone numbers, GitHub, Anthropic, OpenAI-style, Google API, npm, GitLab,
AWS, Slack and Tailscale token shapes, `Bearer` header values, assigned API
keys, private key blocks, WiFi pre-shared keys, assigned passwords, Cloudflare tunnel
credentials and Artifacts tokens, and a password in a URL of any scheme. An
email or IPv4 address written with Markdown backslash escapes or HTML
character references, which a page renders as a plain address, is caught
too. Placeholders: an API-key value that starts with `$`, `<`, `{` or `%`
passes, and a URL password that starts with `$`, `<`, `{`, `\` or `*` or is
`%s`; an assigned password has no placeholder form, except that sudoers'
`NOPASSWD` (upper case, exactly) is not read as one. Hostnames and
home-directory paths pass on purpose.

Your own terms: `public-scan.deny` beside the script, one term per line,
`#` comments, matched case-insensitively as a whole word; a missing file is
skipped, and so is a `PUBLIC_SCAN_DENY=FILE` that does not exist, so check
the path if a term you expect to hit does not. `PUBLIC_SCAN_DENY=FILE` names another file; `PUBLIC_SCAN_TERMS`
adds terms, comma or newline separated, for an environment where no file
can be kept. The terms are never printed except as matched lines.

`PUBLIC_SCAN_ALLOW=FILE` lists exact strings you publish on purpose, one per
line. On a hit, every allow string is removed from the line and the rule is
tested on what is left, so an allowed address passes and a second, different
address on the same line still fails. Needs perl.

## check-visibility.sh

    check-visibility.sh OWNER REPO
    check-visibility.sh --selftest      offline, curl replaced by a stub

Prints exactly one word: `public` (status 200 and `"visibility": "public"`),
`private` (200 and `"visibility": "private"`, or a 404 with no visibility
field: an unauthenticated request to a private repo is a 404, and so is one
to a repo that does not exist, so check against the remote's own URL, not a
name typed by hand) or `ask` (anything else: 403, 5xx, no connection, an
unparsable answer). Exit 0 for public or private, 2 for ask, 1 for bad usage.
Through some proxies a private repo can answer 200 and a public one 403; a
200 is still judged by its body, so `public` holds and a `private` from a
404 proves less there.

## Tests

    ./test-scan.sh             # scan.sh and pre-commit, in temp repos with the real linters
    ./test-git-hooks.sh        # commit-msg and pre-push, with a stub in place of the network
    ./check-visibility.sh --selftest

All offline, bash. `test-scan.sh` needs the scanner tools above; the others
need only git.

The tests' fixtures hold email-shaped strings on purpose (`t@example.invalid`
as the temp repos' author, the `git@` URL form), so `public-scan.sh .` run on
this clone flags them. That is the scanner working; a repo that ships such
fixtures lists them in a `PUBLIC_SCAN_ALLOW` file, as this one's publisher
does.

## Licence

GPL-3.0-or-later, Copyright (C) 2026 Joe Fernandez. See [LICENSE](LICENSE).
