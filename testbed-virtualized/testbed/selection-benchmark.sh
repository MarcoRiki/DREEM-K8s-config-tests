#!/usr/bin/env bash
# DREEM's scale-down decision benchmark on this machine's CPU, with the resources DREEM's
# operator container gets in the testbed: 2.5 CPU and 4 GiB (../DREEM/values.yaml,
# operator.resources.limits). The benchmark is BenchmarkScaleDownDecision in DREEM-K8s,
# operators/internal/controller/selection_benchmark_test.go: a whole scale-down decision
# (a migration plan per candidate node, the soft criteria, TOPSIS) on synthetic clusters
# of 8, 16, 32 and 64 workers, 5 to 25 pods per worker (step 5), both profiles.
#
# The limits are applied as the kubelet applies them to the container: the benchmark runs
# in a transient systemd scope with CPUQuota and MemoryMax (cgroup), and Go sizes
# GOMAXPROCS on the CPU limit (the -N after each benchmark name: 3 for 2.5 CPU).
#
# Run it on the testbed server while NO test runs: it keeps 2.5 cores busy for about half
# an hour (the script stops if muBench's Runner is running).
#
# Usage:
#   ./selection-benchmark.sh [--binary=./selection-bench.linux-amd64 | --source=<DREEM-K8s>/operators]
#                            [--cpus=2.5] [--memory=4G] [--no-limits]
#                            [--bench=BenchmarkScaleDownDecision] [--count=1] [--out=overhead]
#
# --binary  the benchmark compiled for Linux, so the server needs no Go; build it on any
#           machine with Go, in DREEM-K8s/operators, and copy it next to this script:
#             CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go test -c -o selection-bench.linux-amd64 ./internal/controller
#           (GOARCH=arm64 for an ARM server; uname -m tells)
# --source  build it here instead, with the local Go (1.24 or later), from that folder
# --bench   a regular expression on the benchmark names, e.g.
#           'BenchmarkScaleDownDecision/nodes=(8|16|32)/' or 'BenchmarkScaleDownDecision/.*/profile=ENERGY'
# --count   repetitions of every size (to see the spread)
# --no-limits  the whole machine instead of the container's limits
#
# Output: <out>/selection_benchmark_<host>_<UTC time>.txt with the machine (CPU model,
# cores, memory, kernel, virtualization), the limits and the binary, then the benchmark
# lines (ns/op, ms/decision, B/op = bytes allocated, allocs/op) and the peak resident memory.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BINARY="$HERE/selection-bench.linux-$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')"
SOURCE=""; CPUS=2.5; MEMORY=4G; LIMITS=true
BENCH=BenchmarkScaleDownDecision; COUNT=1; OUT="$HERE/overhead"
die() { echo "ERROR: $*" >&2; exit 1; }
for arg in "$@"; do
  case "$arg" in
    --binary=*)  BINARY="${arg#--binary=}" ;;
    --source=*)  SOURCE="${arg#--source=}" ;;
    --cpus=*)    CPUS="${arg#--cpus=}" ;;
    --memory=*)  MEMORY="${arg#--memory=}" ;;
    --no-limits) LIMITS=false ;;
    --bench=*)   BENCH="${arg#--bench=}" ;;
    --count=*)   COUNT="${arg#--count=}" ;;
    --out=*)     OUT="${arg#--out=}" ;;
    -h|--help)   awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"; exit 0 ;;
    *)           die "unknown argument: $arg (see --help)" ;;
  esac
done
[[ "$CPUS" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--cpus must be a number of CPUs, e.g. 2.5"
[[ "$COUNT" =~ ^[1-9][0-9]*$ ]] || die "--count must be a positive whole number"

# the benchmark competes for the server's cores with the VMs: never during an experiment
if pgrep -f "Benchmarks/Runner/Runner.py" >/dev/null 2>&1; then
  die "muBench's Runner is running: a test is in progress. Run the benchmark when the testbed is idle"
fi

if [ -n "$SOURCE" ]; then
  command -v go >/dev/null || die "no Go to build with: use --binary (see --help)"
  BINARY="$(mktemp -d)/selection-bench"
  echo "building the benchmark from $SOURCE with $(go version)"
  (cd "$SOURCE" && CGO_ENABLED=0 go test -c -o "$BINARY" ./internal/controller)
fi
[ -f "$BINARY" ] || die "no benchmark binary at $BINARY: build it (see --help) or pass --binary / --source"
chmod +x "$BINARY"

mkdir -p "$OUT"
RESULT="$OUT/selection_benchmark_$(hostname -s)_$(date -u +%Y%m%dT%H%M%SZ).txt"
cpu_field() { lscpu 2>/dev/null | awk -F: -v k="$1" '$1 == k {sub(/^[ \t]+/, "", $2); print $2; exit}'; }
{
  echo "# DREEM scale-down decision benchmark (BenchmarkScaleDownDecision)"
  echo "# host:            $(hostname -f 2>/dev/null || hostname)"
  echo "# date:            $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# cpu:             $(cpu_field 'Model name')"
  echo "# sockets x cores x threads: $(cpu_field 'Socket(s)') x $(cpu_field 'Core(s) per socket') x $(cpu_field 'Thread(s) per core'), $(nproc) online"
  echo "# cpu max MHz:     $(cpu_field 'CPU max MHz')"
  echo "# memory:          $(free -g 2>/dev/null | awk '/^Mem:/ {print $2 " GiB"}')"
  echo "# kernel:          $(uname -r)"
  echo "# virtualization:  $(systemd-detect-virt 2>/dev/null || echo unknown)"
  if $LIMITS; then
    echo "# limits:          $CPUS CPU, $MEMORY memory (DREEM's operator container), systemd scope"
  else
    echo "# limits:          none (--no-limits)"
  fi
  echo "# binary:          $BINARY (sha256 $(sha256sum "$BINARY" | cut -c1-16))"
  echo "# command:         -test.run '^\$' -test.bench '$BENCH' -test.benchmem -test.count $COUNT"
  echo
} > "$RESULT"
cat "$RESULT"

cmd=("$BINARY" -test.run '^$' -test.bench "$BENCH" -test.benchmem -test.count "$COUNT" -test.timeout 12h)
# the peak resident memory of the whole run, when GNU time is there
if [ -x /usr/bin/time ] && /usr/bin/time -v true >/dev/null 2>&1; then
  cmd=(/usr/bin/time -v "${cmd[@]}")
fi
if $LIMITS; then
  command -v systemd-run >/dev/null || die "systemd-run is needed for the limits (or --no-limits)"
  quota=$(awk -v c="$CPUS" 'BEGIN {printf "%d%%", c * 100}')
  # a transient scope: the cgroup limits of a container, for this run only
  cmd=(sudo systemd-run --scope --quiet -p "CPUQuota=$quota" -p "MemoryMax=$MEMORY" -p "MemorySwapMax=0" -- "${cmd[@]}")
fi

echo "running (about half an hour with every size; the output also goes to $RESULT)"
set +e   # a failed run (e.g. killed at the memory limit) must still be recorded
"${cmd[@]}" 2>&1 | grep --line-buffered -E '^(Benchmark|goos|goarch|cpu|pkg|PASS|FAIL|ok|---)|Maximum resident set size|Elapsed \(wall|Command terminated|signal|killed' \
  | tee -a "$RESULT"
status=${PIPESTATUS[0]}
set -e
[ "$status" -eq 0 ] || echo "WARNING: the benchmark exited with status $status (e.g. killed at the memory limit): see above" | tee -a "$RESULT"
echo "results: $RESULT"
