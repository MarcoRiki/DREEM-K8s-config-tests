#!/usr/bin/env bash
# Gets muBench and applies the testbed's changes.
#
#   1. clones https://github.com/mSvcBench/muBench into DIR if it is not there (default:
#      muBench/ one level above this repository, the place testbed/ looks for it), at
#      the latest commit of main, or at the commit the experiments used with --pinned;
#   2. uses an existing checkout at the commit it is on; with --pinned it must be at
#      the experiments' commit;
#   3. on any other commit, warns about the changed files that upstream modified since
#      the experiments' commit: the copy below replaces them with the tested version
#      and drops upstream's edits (redo the change from changes.patch if needed);
#   4. copies files/ over the checkout (same paths) and sets the executable bits the
#      changes add;
#   5. unzips Examples/Alibaba/traces-mbench.zip (the Alibaba service graphs the work
#      model was generated from), without the macOS metadata;
#   6. writes the ramp-down copies workload-<n>d.json that RunnerParameters.json lists
#      (the test scripts refresh them before every arm);
#   7. creates muBench's Python environment, .venv, with the package versions of
#      requirements-venv.txt (skip with --no-venv).
#
# The experiments ran on COMMIT below (also listed in README.md). --pinned checks it
# out, but an old commit may no longer work: the packages, images and repositories it
# fetches can have changed or gone.
#
# What files/ holds is listed in README.md; changes.patch is the code and configuration
# part as a diff, for review.
#
# Usage: ./apply-changes.sh [DIR] [--pinned] [--no-venv]

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL=https://github.com/mSvcBench/muBench.git
COMMIT=176c8f14f2740414436078d5dcd969d38dd4acd4   # main, 2025-06-12, "Update muBenchGrafanaDash.json"
COMMIT_DATE=2025-06-12
EXECUTABLE=(welcome.sh Monitoring/kubernetes-full-monitoring/monitoring-install.sh)
RAMP_DOWN=(0 1 2 3 4)

DIR=""; PINNED=false; VENV=true
for arg in "$@"; do
  case "$arg" in
    --pinned)  PINNED=true ;;
    --no-venv) VENV=false ;;
    -h|--help) awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"; exit 0 ;;
    -*)        echo "unknown option: $arg" >&2; exit 1 ;;
    *)         DIR=$arg ;;
  esac
done
DIR=${DIR:-$(cd "$HERE/../../.." && pwd)/muBench}   # one level above the repository root

if $PINNED; then
  echo "WARNING: --pinned: muBench at ${COMMIT:0:10} ($COMMIT_DATE), the commit the experiments used." >&2
  echo "WARNING: an old commit may no longer work: the packages, images and repositories it fetches can have changed or gone." >&2
fi
if [ ! -d "$DIR/.git" ]; then
  echo "cloning muBench into $DIR"
  git clone -q "$REPO_URL" "$DIR"
  if $PINNED; then git -C "$DIR" checkout -q "$COMMIT"; fi
fi
DIR="$(cd "$DIR" && pwd)"
HEAD=$(git -C "$DIR" rev-parse HEAD)
if $PINNED && [ "$HEAD" != "$COMMIT" ]; then
  echo "ERROR: $DIR is at $HEAD, not $COMMIT: git -C $DIR checkout -f $COMMIT (drops local edits), then run again" >&2
  exit 1
fi
echo "muBench at $(git -C "$DIR" log -1 --format='%h (%cs)')"
if [ "$HEAD" != "$COMMIT" ]; then
  echo "  the experiments used ${COMMIT:0:10} ($COMMIT_DATE): --pinned to get it"
  if git -C "$DIR" cat-file -e "$COMMIT^{commit}" 2>/dev/null; then
    changed=$( (cd "$HERE/files" && find . -type f | sed 's|^\./||') | while read -r f; do
      git -C "$DIR" diff --quiet "$COMMIT" HEAD -- "$f" || echo "$f"
    done)
    if [ -n "$changed" ]; then
      echo "WARNING: upstream changed these files after ${COMMIT:0:10}; the copy replaces them with the tested version" >&2
      echo "WARNING: and drops upstream's edits (git -C $DIR diff $COMMIT HEAD -- <file>, then redo changes.patch):" >&2
      printf '  %s\n' $changed >&2
    fi
  else
    echo "WARNING: ${COMMIT:0:10} is not in $DIR's history: cannot tell whether upstream changed the copied files" >&2
  fi
fi

echo "copying the changes"
(cd "$HERE/files" && find . -type f) | sort | while read -r f; do
  f=${f#./}
  install -D -m "$(stat -c %a "$HERE/files/$f")" "$HERE/files/$f" "$DIR/$f"
done
echo "  $(cd "$HERE/files" && find . -type f | wc -l) files"
for f in "${EXECUTABLE[@]}"; do chmod +x "$DIR/$f"; done

TRACES="$DIR/Examples/Alibaba"
if [ ! -d "$TRACES/traces-mbench" ]; then
  echo "unzipping Examples/Alibaba/traces-mbench.zip"
  unzip -q "$TRACES/traces-mbench.zip" -d "$TRACES" -x '__MACOSX/*' '*.DS_Store'
fi

for n in "${RAMP_DOWN[@]}"; do
  cp -f "$DIR/SimulationWorkspace/workload-$n.json" "$DIR/SimulationWorkspace/workload-${n}d.json"
done

if $VENV; then
  if [ ! -x "$DIR/.venv/bin/python3" ]; then
    echo "creating $DIR/.venv"
    python3 -m venv "$DIR/.venv"
  fi
  "$DIR/.venv/bin/pip" install -q -r "$HERE/requirements-venv.txt"
  "$DIR/.venv/bin/python3" -c 'import argcomplete, requests, yaml, kubernetes' \
    && echo "  .venv ready: $("$DIR/.venv/bin/python3" --version)"
fi
echo "muBench ready in $DIR"
