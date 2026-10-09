#!/usr/bin/env bash
# Gets metal3-dev-env and applies the testbed's changes.
#
#   1. clones https://github.com/metal3-io/metal3-dev-env into DIR if it is not there
#      (default: metal3-dev-env/ one level above this repository, next to it rather
#      than inside it), at the latest commit of main, or at the commit the experiments
#      used with --pinned;
#   2. uses an existing checkout at the commit it is on; with --pinned it must be at
#      the experiments' commit;
#   3. on any other commit, warns about the changed files that upstream modified since
#      the experiments' commit: the copy below replaces them with the tested version
#      and drops upstream's edits (redo the change from changes.patch if needed);
#   4. copies files/ over the checkout (same paths) and sets the executable bits the
#      changes add.
#
# The experiments ran on COMMIT below (also listed in README.md). --pinned checks it
# out, but an old commit may no longer work: the packages, images and repositories it
# fetches can have changed or gone.
#
# Changes (changes.patch is the same as a diff, for review):
#   02_configure_host.sh                       minikube with 8 GB and 8 CPUs (default 4 GB)
#   vm-setup/roles/common/defaults/main.yml    node VMs with 10 vCPUs and 32 GB (default 2 / 4 GB)
#   tests/roles/run_tests/templates/main/metal3datatemplate-template.yaml
#                                              DNS servers of the nodes: the resolvers of the
#                                              host's network (130.192.3.21, 130.192.3.24)
#                                              instead of 8.8.8.8; put your network's here
#   config_example.sh, disable_apparmor_driver_libvirtd.sh
#                                              executable bit only
#
# Usage: ./apply-changes.sh [DIR] [--pinned]

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL=https://github.com/metal3-io/metal3-dev-env.git
COMMIT=ac77fc9218022cf88be286f0c971dec10d7ea4a0   # main, 2026-08-12, "Merge pull request #1715"
COMMIT_DATE=2026-08-12
EXECUTABLE=(config_example.sh disable_apparmor_driver_libvirtd.sh)

DIR=""; PINNED=false
for arg in "$@"; do
  case "$arg" in
    --pinned)  PINNED=true ;;
    -h|--help) awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"; exit 0 ;;
    -*)        echo "unknown option: $arg" >&2; exit 1 ;;
    *)         DIR=$arg ;;
  esac
done
DIR=${DIR:-$(cd "$HERE/../../.." && pwd)/metal3-dev-env}   # one level above the repository root

if $PINNED; then
  echo "WARNING: --pinned: metal3-dev-env at ${COMMIT:0:10} ($COMMIT_DATE), the commit the experiments used." >&2
  echo "WARNING: an old commit may no longer work: the packages, images and repositories it fetches can have changed or gone." >&2
fi
if [ ! -d "$DIR/.git" ]; then
  echo "cloning metal3-dev-env into $DIR"
  git clone -q "$REPO_URL" "$DIR"
  if $PINNED; then git -C "$DIR" checkout -q "$COMMIT"; fi
fi
DIR="$(cd "$DIR" && pwd)"
HEAD=$(git -C "$DIR" rev-parse HEAD)
if $PINNED && [ "$HEAD" != "$COMMIT" ]; then
  echo "ERROR: $DIR is at $HEAD, not $COMMIT: git -C $DIR checkout -f $COMMIT (drops local edits), then run again" >&2
  exit 1
fi
echo "metal3-dev-env at $(git -C "$DIR" log -1 --format='%h (%cs)')"
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
    echo "WARNING: ${COMMIT:0:10} is not in $DIR's history: cannot tell whether upstream changed the files below" >&2
  fi
fi

(cd "$HERE/files" && find . -type f) | while read -r f; do
  f=${f#./}
  install -D -m "$(stat -c %a "$HERE/files/$f")" "$HERE/files/$f" "$DIR/$f"
  echo "  $f"
done
for f in "${EXECUTABLE[@]}"; do chmod +x "$DIR/$f"; done
echo "changes applied to $DIR ($(git -C "$DIR" status --short | wc -l) files differ from $(git -C "$DIR" rev-parse --short HEAD))"
