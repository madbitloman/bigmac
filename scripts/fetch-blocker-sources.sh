#!/bin/zsh
# Copies the parts of the blocking engine that BigMac's ad and pop-up blocking is built on.
# They are not part of this repository: they're copied at build time from
#   ${BLOCKER_SOURCE_DIR:-<this checkout's sibling folder>/adblocker}
# into gitignored folders, with a SHA-256 list of every copy (build/blocker.sha256) checked against the source:
#   build/blocker/Filters/                EasyList and EasyPrivacy in Safari's rule format (the content blocker's lists)
#   build/blocker/popup-guard.js          the pop-up guard of the Safari web extension
#   build/blocker/popup-guard-fixtures/   test pages for the guard (see Tests/PopupGuard/README.md)
# build/blocker.from lists where each copy came from, for the self-test.
# Without the source, BigMac is built without ad blocking and the Ad & Pop-up Blocking pane says so.
#
#   scripts/fetch-blocker-sources.sh             # before swift build (make-app.sh runs it first)
#   scripts/fetch-blocker-sources.sh --require   # fails when the source is missing
#
# Exit status: 0 (copied, or built without when the source is missing), anything else is an error.
set -euo pipefail
cd "$(dirname "$0")/.."

REQUIRE=0
[[ "${1:-}" == "--require" ]] && REQUIRE=1

# Default source: the folder next to this repository's main checkout (worktrees live elsewhere).
if [[ -z "${BLOCKER_SOURCE_DIR:-}" ]]; then
  COMMON=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "$PWD/.git")
  BLOCKER_SOURCE_DIR="$(dirname "$(dirname "$COMMON")")/adblocker"
fi

OUT=build/blocker
SUMS=build/blocker.sha256
FROM=build/blocker.from
rm -rf "$OUT" "$SUMS" "$FROM"

if [[ ! -f "$BLOCKER_SOURCE_DIR/WebExtension/popup-guard.js" ]]; then
  print -u2 ""
  print -u2 "warning: the blocking engine was not found at $BLOCKER_SOURCE_DIR"
  print -u2 "warning: BigMac will be built WITHOUT ad blocking (the Ad & Pop-up Blocking pane says so). Set BLOCKER_SOURCE_DIR to its folder."
  print -u2 ""
  (( REQUIRE )) && exit 1
  exit 0
fi
SRC=$(cd "$BLOCKER_SOURCE_DIR" && pwd -P)

# What is copied: "source path in the engine repository" -> "destination in this checkout".
typeset -a PAIRS
for f in easylist.block.json easylist.allow.json easyprivacy.block.json easyprivacy.allow.json manifest.json; do
  PAIRS+=("Filters/Generated/$f" "$OUT/Filters/$f")
done
PAIRS+=("WebExtension/popup-guard.js" "$OUT/popup-guard.js")
# The guard's test pages: every file the source repository tracks there (outside git, every regular file).
typeset -a FIXTURES
if git -C "$SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  FIXTURES=("${(@f)$(git -C "$SRC" ls-files --cached -- Tools/popup-guard/fixtures | LC_ALL=C sort)}")
else
  FIXTURES=("${(@f)$(cd "$SRC" && find Tools/popup-guard/fixtures -type f ! -name '.DS_Store' | LC_ALL=C sort)}")
fi
for f in ${FIXTURES:#}; do
  PAIRS+=("$f" "$OUT/popup-guard-fixtures/${f#Tools/popup-guard/fixtures/}")
done

mkdir -p build "$OUT"; : > "$SUMS.tmp"; : > "$FROM.tmp"
for src dest in "${PAIRS[@]}"; do
  [[ -f "$SRC/$src" ]] || { print -u2 "error: $SRC/$src is missing"; exit 1; }
  mkdir -p "${dest:h}"
  cp -X "$SRC/$src" "$dest"   # -X: no extended attributes, so code signing sees plain files
  chmod 644 "$dest"
  touch -h -t 200001010000 "$dest"   # same bytes and dates on every build
  theirs=$(shasum -a 256 "$SRC/$src" | cut -d' ' -f1)
  ours=$(shasum -a 256 "$dest" | cut -d' ' -f1)
  [[ "$theirs" == "$ours" ]] || { print -u2 "error: the copy $dest doesn't match $SRC/$src"; exit 1; }
  print -r -- "$ours  $dest" >> "$SUMS.tmp"
  print -r -- "$dest	$src" >> "$FROM.tmp"
done
mv "$SUMS.tmp" "$SUMS"; mv "$FROM.tmp" "$FROM"
shasum -a 256 -c --quiet "$SUMS" || { print -u2 "error: $SUMS doesn't match the copies"; exit 1; }
plutil -convert xml1 -o /dev/null "$OUT/Filters/manifest.json" || { print -u2 "error: $OUT/Filters/manifest.json is not valid JSON"; exit 1; }

DIGEST=$(shasum -a 256 "$SUMS" | cut -c1-12)
print "Blocker sources: $(( ${#PAIRS} / 2 )) files from $SRC (list $SUMS, digest $DIGEST)"
