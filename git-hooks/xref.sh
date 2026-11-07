# shellcheck shell=sh disable=SC2034
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joe Fernandez
#
# Sourced by commit-msg and pre-push (not a hook itself: git ignores names in
# the hooks directory that are not hook names). The single copy of the private
# repo list and the GitHub cross-reference rule, so the two hooks cannot drift.
# POSIX sh.
#
# The private repo list is git config, multi-valued key gates.privateRepo,
# one OWNER/REPO per value. Local, global and system config all count (the
# hooks run inside the repo). To protect a repo's history:
#   git config --global --add gates.privateRepo OWNER/REPO
# With the key unset the list is empty: commit-msg then enforces only where
# there is no origin at all. The list is used by commit-msg only; pre-push
# scans the pushed commits whatever the list holds.

# The private repos, as owner/repo, one per line, lowercased (GitHub names
# are case-insensitive). The rule protects their history.
private_repos=$(git config --get-all gates.privateRepo 2>/dev/null | tr '[:upper:]' '[:lower:]') || private_repos=''

# owner/repo#N, owner/repo@sha, or a github.com issue, pull, commit or
# discussions URL: what GitHub turns into a cross-reference.
xref_regex='[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(#[0-9]+|@[0-9a-f]{7,40})|github\.com/[^/[:space:]]+/[^/[:space:]]+/(issues|pull|commit|discussions)/'

# xref_is_private OWNER/REPO: 0 when it is in the list (case-insensitive,
# as GitHub names are).
xref_is_private() {
    _x=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    for _r in $private_repos; do
        [ "$_r" = "$_x" ] && return 0
    done
    return 1
}

# xref_grep: reads a message on stdin, prints the offending lines as N:line;
# status 0 when there is at least one.
xref_grep() {
    grep -nE -- "$xref_regex"
}
