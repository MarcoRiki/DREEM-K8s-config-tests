#!/usr/bin/env bash
# A campaign: --runs repetitions of the selected configurations, one after the other. Each
# repetition replays a trace of its own, and all the arms of a repetition the same one.
#
# Usage:
#   ./run-campaign.sh --runs=3 [--first-rep=1] [--configs=all | --configs=DREEM-Energy,CA,...]
#                     [--seed=1000] [--order=rotate|fixed] [--pause=60]
#                     [--stop-on-failure] [--no-export] [--dry-run]
#                     [--base-hosts=<bmh>,<bmh>,<bmh>]
#                     [--anchors=... --latency=... --delay=... --probe-rate=... --repair=...
#                      --repair-interval=... --skip-provision --force]
#
# Configurations (--configs: comma-separated, any case; default all, in this order):
#   DREEM-Energy      test.sh, arm ENERGY
#   DREEM-QoS         test.sh, arm QOS
#   Static-8          test.sh, arm BASELINE
#   Static-6          test.sh, arm BASELINE_N with --nodes=6 (BASELINE_6)
#   CA                test_CA.sh
#   Karpenter         test_Karpenter.sh (--base-hosts goes to it only)
#   Random-Unchecked  test_DREEM_extra.sh --selectionPolicy=RANDOM --hardCheck=FALSE
#   TOPSIS-Unchecked  test_DREEM_extra.sh --selectionPolicy=TOPSIS --profile=ENERGY --hardCheck=FALSE
#   Menouer           test_DREEM_extra.sh --selectionPolicy=MENOUER --hardCheck=FALSE
# The paper's abbreviations (DE, DQ, S8, S6, CA, KP, RU, TU, MN) and the arm names
# (ENERGY, BASELINE_6, RANDOM_nochecks, ...) work too.
#
# Repetitions: --first-rep to --first-rep + --runs - 1, in Result/<scenario>/rep<r>/ as
# when the test scripts are called by hand.
#
# Trace: repetition r replays the trace drawn with seed --seed + r (default 1000 + r), the
# same for all its arms: the first arm records it in rep<r>/load_record.json and the others
# check they replay the same files (run-lib.sh, prepare_load). A repetition that already
# recorded a seed keeps it.
#
# Order: test.sh's configurations run in one call (one fleet restore), the others in one
# call each. With --order=rotate (default) the calls, and the arms inside test.sh's call,
# are rotated by the repetition number, so every repetition starts from another
# configuration; --order=fixed keeps the order above.
#
# Resume: an arm the repetition already finished (<ARM>_window.json) is skipped, so the same
# command takes a stopped campaign up again; --force runs it again and replaces it. A failed
# call is reported and the campaign goes on with the next one (every test script restores
# the fleet first), unless --stop-on-failure; the exit status is 1 if an arm failed.
#
# Export: at the end of each repetition, export-metrics.py exports the dashboard data of its
# arms (Prometheus keeps 10 days, a campaign can last longer); --no-export skips it.
#
# The other flags go to every test script unchanged. --dry-run prints the plan and stops.
# What the campaign did goes to Result/<scenario>/campaign_<start>.log.

set -euo pipefail
# shellcheck source=run-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-lib.sh"

ALL_CONFIGS=(DREEM-Energy DREEM-QoS Static-8 Static-6 CA Karpenter Random-Unchecked TOPSIS-Unchecked Menouer)
declare -A ARM_OF=([DREEM-Energy]=ENERGY [DREEM-QoS]=QOS [Static-8]=BASELINE [Static-6]=BASELINE_6
                   [CA]=CA [Karpenter]=KARPENTER [Random-Unchecked]=RANDOM_nochecks
                   [TOPSIS-Unchecked]=TOPSIS_ENERGY_nochecks [Menouer]=MENOUER_nochecks)
# the configurations test.sh runs, with the arm --arms takes
declare -A TESTSH_ARM_OF=([DREEM-Energy]=ENERGY [DREEM-QoS]=QOS [Static-8]=BASELINE [Static-6]=BASELINE_N)
declare -A CALL_OF=([CA]="test_CA.sh" [Karpenter]="test_Karpenter.sh"
                    [Random-Unchecked]="test_DREEM_extra.sh --selectionPolicy=RANDOM --hardCheck=FALSE"
                    [TOPSIS-Unchecked]="test_DREEM_extra.sh --selectionPolicy=TOPSIS --profile=ENERGY --hardCheck=FALSE"
                    [Menouer]="test_DREEM_extra.sh --selectionPolicy=MENOUER --hardCheck=FALSE")
STATIC_N=6   # Static-6: BASELINE_N with this many workers on

config_name() {   # name as typed -> configuration; fails if unknown
  local n=${1,,}
  case "${n//_/-}" in
    dreem-energy|energy|de)                     echo DREEM-Energy ;;
    dreem-qos|qos|dq)                           echo DREEM-QoS ;;
    static-8|static8|baseline|s8)               echo Static-8 ;;
    static-6|static6|baseline-6|s6)             echo Static-6 ;;
    ca|cluster-autoscaler)                      echo CA ;;
    karpenter|kp)                               echo Karpenter ;;
    random-unchecked|random-nochecks|ru)        echo Random-Unchecked ;;
    topsis-unchecked|topsis-energy-nochecks|tu) echo TOPSIS-Unchecked ;;
    menouer|menouer-nochecks|mn)                echo Menouer ;;
    *) return 1 ;;
  esac
}

# --- arguments -------------------------------------------------------------------------------

RUNS=""; FIRST_REP=1; CONFIGS=all; SEED_BASE=1000; ORDER=rotate; PAUSE=60
STOP_ON_FAILURE=false; EXPORT=true; DRY_RUN=false; FORCE_ALL=false
BASE_HOSTS=(); SHARED=()
for arg in "$@"; do
  case "$arg" in
    --runs=*)          RUNS="${arg#--runs=}" ;;
    --first-rep=*)     FIRST_REP="${arg#--first-rep=}" ;;
    --configs=*)       CONFIGS="${arg#--configs=}" ;;
    --seed=*)          SEED_BASE="${arg#--seed=}" ;;
    --order=*)         ORDER="${arg#--order=}" ;;
    --pause=*)         PAUSE="${arg#--pause=}" ;;
    --stop-on-failure) STOP_ON_FAILURE=true ;;
    --no-export)       EXPORT=false ;;
    --dry-run)         DRY_RUN=true ;;
    --base-hosts=*)    BASE_HOSTS=("$arg") ;;
    --force)           FORCE_ALL=true; SHARED+=("$arg") ;;
    --rep=*|--arms=*|--nodes=*|--remove=*|--no-chain|--selectionPolicy=*|--hardCheck=*|--profile=*|--menouer*)
                       die "$arg: the campaign sets it for each configuration (see --help)" ;;
    -h|--help)         usage; exit 0 ;;
    *)                 SHARED+=("$arg") ;;   # checked by parse_args below, as in the test scripts
  esac
done
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || die "--runs=<number of repetitions> is required (see --help)"
[[ "$FIRST_REP" =~ ^[0-9]+$ ]] || die "--first-rep must be a whole number"
[[ "$SEED_BASE" =~ ^[0-9]+$ ]] || die "--seed must be a whole number"
[[ "$PAUSE" =~ ^[0-9]+$ ]]     || die "--pause must be a number of seconds"
case "$ORDER" in rotate|fixed) ;; *) die "--order must be rotate or fixed" ;; esac

SELECTED=()
if [ "${CONFIGS,,}" = all ]; then
  SELECTED=("${ALL_CONFIGS[@]}")
else
  declare -A WANTED=()
  for c in ${CONFIGS//,/ }; do
    name=$(config_name "$c") || die "unknown configuration '$c' (see --help)"
    WANTED[$name]=1
  done
  for c in "${ALL_CONFIGS[@]}"; do [ -z "${WANTED[$c]:-}" ] || SELECTED+=("$c"); done
fi
[ "${#SELECTED[@]}" -gt 0 ] || die "no configuration selected"

# --- helpers ---------------------------------------------------------------------------------

run_dir_of() {   # rep: its result folder, as the test scripts compute it (checks the shared flags too)
  ( mkdir() { :; }   # the plan creates no folder: the test scripts do
    parse_args "${SHARED[@]}" "--rep=$1"
    echo "$RUN_DIR" )
}

finished() { [ -e "$1/${2}_window.json" ]; }   # folder arm

rotated() {   # k item...: the items rotated left by k
  local k=$1; shift
  [ "$#" -gt 0 ] || return 0
  local items=("$@")
  k=$((k % $#))
  echo "${items[@]:k}" "${items[@]:0:k}"
}

build_cmd() {   # rep seed call [test.sh configurations...]: sets CMD and CALL_ARMS
  local rep=$1 seed=$2 call=$3 c parts=() arms=()
  shift 3
  CALL_ARMS=()
  if [ "$call" = test.sh ]; then
    for c in "$@"; do arms+=("${TESTSH_ARM_OF[$c]}"); CALL_ARMS+=("${ARM_OF[$c]}"); done
    CMD=(bash "$TESTBED/test.sh" "--rep=$rep" "--seed=$seed" --no-chain "--arms=${arms[*]}")
    [[ " ${arms[*]} " != *" BASELINE_N "* ]] || CMD+=("--nodes=$STATIC_N")
  else
    read -ra parts <<<"${CALL_OF[$call]}"
    CMD=(bash "$TESTBED/${parts[0]}" "--rep=$rep" "--seed=$seed" "${parts[@]:1}")
    [ "$call" != Karpenter ] || CMD+=("${BASE_HOSTS[@]}")
    CALL_ARMS=("${ARM_OF[$call]}")
  fi
  CMD+=("${SHARED[@]}")
}

LOG=""
note() {   # to the terminal and to the campaign log
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
  [ -z "$LOG" ] || printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"
}

export_rep() {   # rep folder: the dashboard data of its arms (export-metrics.py skips CSVs it already wrote)
  local rep=$1 dir=$2 last wait_s
  $EXPORT || return 0
  compgen -G "$dir/*_window.json" >/dev/null || return 0
  # export-metrics.py reads up to 300 s after each window (--after): wait for the last one
  last=$(jq -rs 'map(.end) | max' "$dir"/*_window.json)
  wait_s=$(( $(date -ud "$last" +%s) + 330 - $(date -u +%s) ))
  if [ "$wait_s" -gt 0 ]; then note "rep$rep: export in ${wait_s}s, after the last window's tail"; sleep "$wait_s"; fi
  if python3 "$TESTBED/export-metrics.py" --run-dir "$dir"; then
    note "rep$rep: dashboard data exported"
  else
    note "WARNING: rep$rep: export failed, run it by hand within 10 days: python3 export-metrics.py --run-dir $dir"
  fi
}

# --- plan ------------------------------------------------------------------------------------

REPS=(); declare -A PLAN_SEED=() PLAN_DIR=() PLAN_CALLS=() PLAN_TESTSH=() PLAN_SKIPPED=()
TO_RUN=0
for ((i = 0; i < RUNS; i++)); do
  rep=$((FIRST_REP + i)); REPS+=("$rep")
  dir=$(run_dir_of "$rep")
  seed=$((SEED_BASE + rep))
  pending=(); skipped=(); testsh=(); calls=()
  for c in "${SELECTED[@]}"; do
    if finished "$dir" "${ARM_OF[$c]}" && ! $FORCE_ALL; then skipped+=("$c"); else pending+=("$c"); fi
  done
  if [ -e "$dir/$LOAD_RECORD" ]; then
    recorded=$(jq -r '.seed // ""' "$dir/$LOAD_RECORD")
    if [ "${#pending[@]}" -gt 0 ]; then
      [ -n "$recorded" ] || die "rep$rep recorded a trace without a seed ($dir/$LOAD_RECORD): start the campaign after it (--first-rep=$((rep + 1)))"
      [ "$recorded" = "$seed" ] || echo "rep$rep keeps the seed it recorded, $recorded (--seed=$SEED_BASE would give $seed)"
    fi
    seed=${recorded:-$seed}
  elif [ "${#pending[@]}" -gt 0 ] && compgen -G "$dir/*_window.json" >/dev/null; then
    die "rep$rep holds arms run before the trace was recorded: their trace cannot be matched. Start after it (--first-rep=$((rep + 1)))"
  fi
  for c in "${pending[@]}"; do
    if [ -n "${TESTSH_ARM_OF[$c]:-}" ]; then testsh+=("$c"); else calls+=("$c"); fi
  done
  [ "${#testsh[@]}" -eq 0 ] || calls=(test.sh "${calls[@]}")
  if [ "$ORDER" = rotate ]; then
    read -ra calls  <<<"$(rotated "$rep" "${calls[@]}")"
    read -ra testsh <<<"$(rotated "$rep" "${testsh[@]}")"
  fi
  PLAN_DIR[$rep]=$dir; PLAN_SEED[$rep]=$seed
  PLAN_CALLS[$rep]="${calls[*]}"; PLAN_TESTSH[$rep]="${testsh[*]}"; PLAN_SKIPPED[$rep]="${skipped[*]}"
  TO_RUN=$((TO_RUN + ${#pending[@]}))
done

SCENARIO_DIR=$(dirname "${PLAN_DIR[$FIRST_REP]}")
print_plan() {
  local rep call n
  echo "Campaign: $RUNS repetition(s), rep$FIRST_REP to rep$((FIRST_REP + RUNS - 1)), in $SCENARIO_DIR"
  echo "configurations: ${SELECTED[*]}; order $ORDER; $TO_RUN arm(s) to run"
  for rep in "${REPS[@]}"; do
    echo
    echo "rep$rep  seed ${PLAN_SEED[$rep]}${PLAN_SKIPPED[$rep]:+  already finished: ${PLAN_SKIPPED[$rep]}}"
    n=0
    for call in ${PLAN_CALLS[$rep]}; do
      n=$((n + 1))
      # shellcheck disable=SC2086
      build_cmd "$rep" "${PLAN_SEED[$rep]}" "$call" ${PLAN_TESTSH[$rep]}
      printf '  %d. %-28s %s\n' "$n" "${CALL_ARMS[*]}" "$(printf '%q ' "${CMD[@]#"$TESTBED/"}")"
    done
    [ "$n" -gt 0 ] || echo "  nothing to run"
  done
  echo
}
print_plan
$DRY_RUN && exit 0
[ "$TO_RUN" -gt 0 ] || { echo "Nothing to run."; exit 0; }

# --- run -------------------------------------------------------------------------------------

check_python
check_clusters || exit 1
mkdir -p "$SCENARIO_DIR"
LOG="$SCENARIO_DIR/campaign_$(date -u +%Y%m%dT%H%M%SZ).log"
note "campaign started: $(printf '%q ' "$0" "$@")"
print_plan >> "$LOG"

DONE=(); FAILED=(); first_call=true; stop=false
for rep in "${REPS[@]}"; do
  dir=${PLAN_DIR[$rep]}
  [ -n "${PLAN_CALLS[$rep]}" ] || { note "rep$rep: nothing to run"; continue; }
  note "rep$rep: seed ${PLAN_SEED[$rep]}, calls in order: ${PLAN_CALLS[$rep]}"
  for call in ${PLAN_CALLS[$rep]}; do
    $first_call || { note "pause ${PAUSE}s"; sleep "$PAUSE"; }
    first_call=false
    # shellcheck disable=SC2086
    build_cmd "$rep" "${PLAN_SEED[$rep]}" "$call" ${PLAN_TESTSH[$rep]}
    note "rep$rep: ${CALL_ARMS[*]}: $(printf '%q ' "${CMD[@]}")"
    rc=0
    (cd "$TESTBED" && "${CMD[@]}") || rc=$?
    for arm in "${CALL_ARMS[@]}"; do
      if finished "$dir" "$arm"; then
        DONE+=("rep$rep/$arm"); note "rep$rep: $arm finished"
      else
        FAILED+=("rep$rep/$arm"); note "rep$rep: $arm FAILED (exit $rc), logs in $dir/logs/"
      fi
    done
    if [ "$rc" -ne 0 ] && $STOP_ON_FAILURE; then
      note "stopping (--stop-on-failure); the same command resumes from the arms not finished"
      stop=true
      break
    fi
  done
  export_rep "$rep" "$dir"   # also when stopping: what finished is exported
  ! $stop || break
done

note "campaign over: ${#DONE[@]} arm(s) finished, ${#FAILED[@]} failed${FAILED[*]:+: ${FAILED[*]}}"
RUN_DIR=${PLAN_DIR[${REPS[-1]}]}
base_latency_hint
echo "campaign log: $LOG"
[ "${#FAILED[@]}" -eq 0 ]
