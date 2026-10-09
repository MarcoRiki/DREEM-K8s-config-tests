#!/usr/bin/env bash
# Puts metal3-dev-env at the commit the experiments used and applies the testbed's changes.
#
#   1. clones https://github.com/metal3-io/metal3-dev-env into DIR if it is not there
#      (default: <repo>/metal3-dev-env), and checks out the pinned commit;
#   2. refuses to touch a checkout at another commit (--force to apply anyway);
#   3. copies files/ over the checkout (same paths) and sets the executable bits the
#      changes add.
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
# Usage: ./apply-changes.sh [DIR] [--force]

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL=https://github.com/metal3-io/metal3-dev-env.git
COMMIT=ac77fc9218022cf88be286f0c971dec10d7ea4a0   # main, 2026-08-12, "Merge pull request #1715"
EXECUTABLE=(config_example.sh disable_apparmor_driver_libvirtd.sh)

DIR=""; FORCE=false
for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=true ;;
    -h|--help) awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"; exit 0 ;;
    -*)        echo "unknown option: $arg" >&2; exit 1 ;;
    *)         DIR=$arg ;;
  esac
done
DIR=${DIR:-$HERE/../metal3-dev-env}

if [ ! -d "$DIR/.git" ]; then
  echo "cloning metal3-dev-env into $DIR"
  git clone -q "$REPO_URL" "$DIR"
  git -C "$DIR" checkout -q "$COMMIT"
fi
DIR="$(cd "$DIR" && pwd)"
HEAD=$(git -C "$DIR" rev-parse HEAD)
if [ "$HEAD" != "$COMMIT" ]; then
  $FORCE || { echo "ERROR: $DIR is at $HEAD, not $COMMIT: git -C $DIR checkout $COMMIT, or --force" >&2; exit 1; }
  echo "WARNING: applying to $HEAD instead of $COMMIT (--force)"
fi

(cd "$HERE/files" && find . -type f) | while read -r f; do
  f=${f#./}
  install -D -m "$(stat -c %a "$HERE/files/$f")" "$HERE/files/$f" "$DIR/$f"
  echo "  $f"
done
for f in "${EXECUTABLE[@]}"; do chmod +x "$DIR/$f"; done
echo "changes applied to $DIR ($(git -C "$DIR" status --short | wc -l) files differ from $COMMIT)"
