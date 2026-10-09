#!/usr/bin/env bash
# Puts muBench at the commit the experiments used and applies the testbed's changes.
#
#   1. clones https://github.com/mSvcBench/muBench into DIR if it is not there (default:
#      <repo>/muBench, the place testbed/ looks for it), and checks out the pinned commit;
#   2. refuses to touch a checkout at another commit (--force to apply anyway);
#   3. copies files/ over the checkout (same paths) and sets the executable bits the
#      changes add;
#   4. unzips Examples/Alibaba/traces-mbench.zip (the Alibaba service graphs the work
#      model was generated from), without the macOS metadata;
#   5. writes the ramp-down copies workload-<n>d.json that RunnerParameters.json lists
#      (the test scripts refresh them before every arm);
#   6. creates muBench's Python environment, .venv, with the package versions of
#      requirements-venv.txt (skip with --no-venv).
#
# What files/ holds is listed in README.md; changes.patch is the code and configuration
# part as a diff, for review.
#
# Usage: ./apply-changes.sh [DIR] [--force] [--no-venv]

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL=https://github.com/mSvcBench/muBench.git
COMMIT=176c8f14f2740414436078d5dcd969d38dd4acd4   # main, 2025-06-12, "Update muBenchGrafanaDash.json"
EXECUTABLE=(welcome.sh Monitoring/kubernetes-full-monitoring/monitoring-install.sh)
RAMP_DOWN=(0 1 2 3 4)

DIR=""; FORCE=false; VENV=true
for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=true ;;
    --no-venv) VENV=false ;;
    -h|--help) awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"; exit 0 ;;
    -*)        echo "unknown option: $arg" >&2; exit 1 ;;
    *)         DIR=$arg ;;
  esac
done
DIR=${DIR:-$HERE/../muBench}

if [ ! -d "$DIR/.git" ]; then
  echo "cloning muBench into $DIR"
  git clone -q "$REPO_URL" "$DIR"
  git -C "$DIR" checkout -q "$COMMIT"
fi
DIR="$(cd "$DIR" && pwd)"
HEAD=$(git -C "$DIR" rev-parse HEAD)
if [ "$HEAD" != "$COMMIT" ]; then
  $FORCE || { echo "ERROR: $DIR is at $HEAD, not $COMMIT: git -C $DIR checkout $COMMIT, or --force" >&2; exit 1; }
  echo "WARNING: applying to $HEAD instead of $COMMIT (--force)"
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
