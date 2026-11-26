#!/bin/zsh
# Copies the Chrome and Firefox extension into a build folder.
# Its source is not part of this repository: it is copied at build time from
#   ${BLOCKER_EXTENSION_DIR:-${BLOCKER_SOURCE_DIR:-<this checkout's sibling folder>/adblocker}/WebExtension}
# into build/BrowserExtension (gitignored), with a SHA-256 list of every copied file beside it
# (build/BrowserExtension.sha256), checked against the source after the copy.
#
#   scripts/bundle-browser-extension.sh [destination]      # skips with a warning when the source is missing
#   scripts/bundle-browser-extension.sh --require [dest]   # fails instead
#
# Exit status: 0 copied, 3 skipped (source missing), anything else is an error.
set -euo pipefail
cd "$(dirname "$0")/.."

REQUIRE=0
if [[ "${1:-}" == "--require" ]]; then REQUIRE=1; shift; fi
DEST="${1:-build/BrowserExtension}"
DEST="${DEST%/}"
SUMS="$DEST.sha256"

# Default source: the engine repository's checkout as scripts/fetch-blocker-sources.sh finds it ($BLOCKER_SOURCE_DIR, or the
# folder next to this repository's main checkout; worktrees live elsewhere).
if [[ -z "${BLOCKER_EXTENSION_DIR:-}" ]]; then
  if [[ -z "${BLOCKER_SOURCE_DIR:-}" ]]; then
    COMMON=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "$PWD/.git")
    BLOCKER_SOURCE_DIR="$(dirname "$(dirname "$COMMON")")/adblocker"
  fi
  BLOCKER_EXTENSION_DIR="$BLOCKER_SOURCE_DIR/WebExtension"
fi
SRC="$BLOCKER_EXTENSION_DIR"

rm -rf "$DEST" "$SUMS"
if [[ ! -f "$SRC/manifest.json" ]]; then
  print -u2 ""
  print -u2 "warning: the Chrome and Firefox extension was not found at $SRC"
  print -u2 "warning: BigMac will be built WITHOUT it (the Ad & Pop-up Blocking pane says so). Set BLOCKER_EXTENSION_DIR to its folder."
  print -u2 ""
  (( REQUIRE )) && exit 1
  exit 3
fi
SRC=$(cd "$SRC" && pwd -P)

# Only the files the source repository tracks (no caches, editor files or local builds). Outside git, every regular file.
typeset -a FILES
if git -C "$SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  FILES=("${(@f)$(git -C "$SRC" ls-files --cached -- . | LC_ALL=C sort)}")
else
  FILES=("${(@f)$(cd "$SRC" && find . -type f ! -name '.DS_Store' | sed 's|^\./||' | LC_ALL=C sort)}")
fi
FILES=(${FILES:#})  # no empty names
(( ${#FILES} > 0 )) || { print -u2 "error: no files to copy in $SRC"; exit 1; }

mkdir -p "$DEST"
for f in "${FILES[@]}"; do
  [[ -f "$SRC/$f" ]] || { print -u2 "error: $SRC/$f is tracked but missing (uncommitted delete?)"; exit 1; }
  mkdir -p "$DEST/${f:h}"
  cp -X "$SRC/$f" "$DEST/$f"   # -X: no extended attributes, so code signing sees plain files
done
# Same bytes, permissions and dates on every build, so the bundle is reproducible.
find "$DEST" -type d -exec chmod 755 {} +
find "$DEST" -type f -exec chmod 644 {} +
find "$DEST" -exec touch -h -t 200001010000 {} +

# The list of what was copied, then a check of the copy against the source.
(cd "$DEST" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | tr '\n' '\0' | xargs -0 shasum -a 256) > "$SUMS"
(cd "$SRC" && shasum -a 256 -c --quiet "$OLDPWD/$SUMS") || { print -u2 "error: the copy in $DEST doesn't match $SRC"; exit 1; }
(( $(wc -l < "$SUMS") == ${#FILES} )) || { print -u2 "error: $SUMS lists $(wc -l < "$SUMS") files, expected ${#FILES}"; exit 1; }
plutil -convert xml1 -o /dev/null "$DEST/manifest.json" || { print -u2 "error: $DEST/manifest.json is not valid JSON"; exit 1; }

DIGEST=$(shasum -a 256 "$SUMS" | cut -c1-12)
print "Browser extension: ${#FILES} files from $SRC -> $DEST (list $SUMS, digest $DIGEST)"
