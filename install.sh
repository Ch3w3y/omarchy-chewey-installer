#!/usr/bin/env bash
# shellcheck shell=bash
# Public-safe download entry point for the opt-in omarchy-chewey layer.
# Download first, review, then run — never pipe the fetch into Bash:
#   curl -fsSL <public-url> -o /tmp/chewey-install && bash /tmp/chewey-install
# This file must stay standalone: it runs before any checkout exists.
# It performs no hardware, provisioning or package work itself; after the
# checkout is ready it execs the clone's bootstrap.sh as the logged-in user.
set -euo pipefail

# Configurable published repo slug (owner/name). The published default points to the private repo; override only for a fork.
REPO_SLUG=${OMARCHY_CHEWEY_REPO_SLUG:-Ch3w3y/omarchy-chewey}
DEST="$HOME/.local/share/omarchy-chewey"
# Test hook overrides mirror lib/packages.sh; production names are the defaults.
GH=${OMARCHY_CHEWEY_GH:-gh}
GIT=${OMARCHY_CHEWEY_GIT:-git}
PKG_ADD=${OMARCHY_CHEWEY_PKG_ADD:-omarchy-pkg-add}
TTY=/dev/tty

err() { printf 'omarchy-chewey: entry: error: %s\n' "$*" >&2; }
note() { printf 'omarchy-chewey: entry: %s\n' "$*"; }
plan() { printf '[dry-run] entry: %s\n' "$*"; }
usage() {
  cat <<'USAGE'
Usage: bash chewey-install [--dry-run]

Downloads or updates the omarchy-chewey checkout in
~/.local/share/omarchy-chewey, then execs its bootstrap.sh.
--dry-run prints the conditional auth/package/clone/update/handoff
steps and changes nothing.

Configuration:
  OMARCHY_CHEWEY_REPO_SLUG  published owner/name (default: Ch3w3y/omarchy-chewey)
USAGE
}

DRY_RUN=0
ARGS=()
for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=1; ARGS+=("$arg") ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $arg"; usage >&2; exit 2 ;;
  esac
done

case $REPO_SLUG in
  *REPLACE-ME*)
    err "repo slug is still the unresolved placeholder; set OMARCHY_CHEWEY_REPO_SLUG to the published owner/name"
    exit 2 ;;
esac
[[ $REPO_SLUG =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
  err "repo slug '$REPO_SLUG' is not a valid owner/name pair"
  exit 2
}
CLONE_URL=https://github.com/$REPO_SLUG.git

# Entry preparation, as the logged-in user: no sudo or su here. The package
# helper may prompt for its own authorisation when github-cli is missing.
gh_present=0
command -v "$GH" >/dev/null 2>&1 && gh_present=1

if (( DRY_RUN )); then
  if (( gh_present )); then
    "$GH" auth status >/dev/null 2>&1 ||
      plan "authenticate with GitHub device flow via $TTY (gh auth login --web)"
  else
    plan "install package github-cli via $PKG_ADD"
    plan "authenticate with GitHub device flow via $TTY (gh auth login --web)"
  fi
else
  if (( ! gh_present )); then
    command -v "$PKG_ADD" >/dev/null 2>&1 || {
      err "$PKG_ADD not found; this entry script assumes stock Omarchy"; exit 1; }
    note "installing github-cli via $PKG_ADD"
    "$PKG_ADD" github-cli
    command -v "$GH" >/dev/null 2>&1 || {
      err "gh is still missing after installing github-cli"; exit 1; }
  fi
  if ! "$GH" auth status >/dev/null 2>&1; then
    # Device/web flow only. It reads from $TTY, never script stdin, and this
    # script never embeds, echoes or writes any token itself.
    note "authenticating with the GitHub device flow on $TTY"
    "$GH" auth login --hostname github.com --git-protocol https --web < "$TTY"
  fi
fi

if [[ -e $DEST && ! -d $DEST ]]; then
  err "$DEST exists but is not a directory; refusing to touch it"; exit 3
fi
if [[ ! -d $DEST ]]; then
  if (( DRY_RUN )); then
    plan "clone $CLONE_URL into $DEST"
  else
    note "cloning $CLONE_URL into $DEST"
    mkdir -p -- "${DEST%/*}"
    "$GIT" clone "$CLONE_URL" "$DEST"
  fi
else
  origin=$("$GIT" --no-optional-locks -C "$DEST" remote get-url origin 2>/dev/null || true)
  if [[ -z $origin ]]; then
    err "$DEST exists without a usable git origin; refusing to modify it"; exit 3
  fi
  if [[ $origin != "$CLONE_URL" ]]; then
    err "$DEST origin '$origin' does not match $CLONE_URL; refusing to modify it"; exit 3
  fi
  if [[ -n $("$GIT" --no-optional-locks -C "$DEST" status --porcelain) ]]; then
    err "$DEST has local changes; refusing to update it (no reset performed)"; exit 3
  fi
  if (( DRY_RUN )); then
    plan "update $DEST via git pull --ff-only"
  else
    note "updating $DEST via git pull --ff-only"
    "$GIT" -C "$DEST" pull --ff-only || {
      err "fast-forward update failed; the tree may have diverged (no reset performed)"; exit 3; }
  fi
fi

if (( DRY_RUN )); then
  plan "exec bash $DEST/bootstrap.sh ${ARGS[*]}"
  exit 0
fi

# Handoff keeps the user session: same uid, environment and terminal; the
# entry process is replaced, so nothing here persists into bootstrap.
[[ -f $DEST/bootstrap.sh ]] || {
  err "$DEST/bootstrap.sh is missing after the update; refusing to hand off"; exit 1; }
exec bash "$DEST/bootstrap.sh" "${ARGS[@]}"
