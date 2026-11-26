#!/bin/zsh
# Checks that this repository tracks no copy of a file from the blocking engine's repository, in any of its versions: the git
# blob hash of every file here against every file in the whole history of
#   ${BLOCKER_SOURCE_DIR:-<this checkout's sibling folder>/adblocker}
# Run it before every push. Its files reach BigMac only through scripts/fetch-blocker-sources.sh, at build time.
#
#   scripts/check-no-private-copies.sh                     # every file tracked at HEAD
#   scripts/check-no-private-copies.sh origin/main..HEAD   # every file added or changed by the commits in a range
#
# Prints one line per copy ("<commit> <path here> = <path there>") and then "matches: <count>".
# Exit status: 0 no copies, 1 copies found, 2 the engine repository's git checkout isn't there.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${BLOCKER_SOURCE_DIR:-}" ]]; then
  COMMON=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "$PWD/.git")
  BLOCKER_SOURCE_DIR="$(dirname "$(dirname "$COMMON")")/adblocker"
fi
if ! git -C "$BLOCKER_SOURCE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  print -u2 "the engine repository's git checkout wasn't found at $BLOCKER_SOURCE_DIR (set BLOCKER_SOURCE_DIR); nothing was checked."
  exit 2
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Theirs: every blob reachable from any ref, with one path it had ("<blob> <path>").
git -C "$BLOCKER_SOURCE_DIR" rev-list --all --objects \
  | git -C "$BLOCKER_SOURCE_DIR" cat-file --batch-check='%(objecttype) %(objectname) %(rest)' \
  | awk '$1 == "blob" { $1 = ""; sub(/^ /, ""); print }' | LC_ALL=C sort -u -k1,1 > "$TMP/theirs"
(( $(wc -l < "$TMP/theirs") > 0 )) || { print -u2 "error: no files found in $BLOCKER_SOURCE_DIR's history"; exit 1; }

# Ours: "<blob> <commit> <path>" for every file at HEAD, or every file a commit in the range added or changed.
if [[ -z "${1:-}" ]]; then
  git ls-tree -r --full-tree HEAD | awk -F'\t' '{ split($1, f, " "); if (f[2] == "blob") print f[3] " HEAD " $2 }' > "$TMP/ours"
else
  git log -m --raw --no-abbrev --no-renames --format='commit %h' "$1" | awk -F'\t' '
    /^commit / { commit = $1; sub(/^commit /, "", commit); next }
    /^:/ { split($1, f, " "); if (f[4] !~ /^0+$/) print f[4] " " commit " " $2 }' > "$TMP/ours"
fi
LC_ALL=C sort -k1,1 "$TMP/ours" > "$TMP/ours.sorted"

LC_ALL=C join -j1 "$TMP/ours.sorted" "$TMP/theirs" | awk '{ blob = $1; commit = $2; $1 = ""; $2 = ""; sub(/^  /, ""); print commit " " $0 }' \
  | sed -E 's/ ([^ ]+)$/ = \1/' > "$TMP/matches"
cat "$TMP/matches"
COUNT=$(wc -l < "$TMP/matches" | tr -d ' ')
print "matches: $COUNT"
(( COUNT == 0 ))
