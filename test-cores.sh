#!/usr/bin/env bash
#
# test-cores.sh -- per-physical-core health sweep for the BC-250.
#
# Cores 3 and 7 are the ones unlocked by bc250-8core-unlock. This checks whether
# they are actually good silicon or were disabled for a reason.
#
# stress-ng --verify validates the RESULT of each computation, so a marginal
# core shows up as verify failures, not merely as lower throughput. That is the
# signal that matters -- a core that is quietly wrong is far worse than a slow one.
#
# Usage:  ./test-cores.sh [seconds_per_core]     (default 20)
#
# Requires: stress-ng, and 8 cores already visible (run the unlock first).

set -uo pipefail

DUR=${1:-20}

command -v stress-ng >/dev/null || { echo "error: stress-ng not installed" >&2; exit 1; }

# first SMT sibling of each physical core
declare -A CPU_OF_CORE
for c in /sys/devices/system/cpu/cpu[0-9]*; do
    n=${c##*/cpu}
    id=$(cat "$c/topology/core_id" 2>/dev/null) || continue
    [ -n "${CPU_OF_CORE[$id]:-}" ] || CPU_OF_CORE[$id]=$n
done

CORES=$(printf '%s\n' "${!CPU_OF_CORE[@]}" | sort -n)
NCORES=$(echo "$CORES" | wc -l)
echo "detected $NCORES physical cores"
[ "$NCORES" -lt 8 ] && echo "note: fewer than 8 cores -- unlock not applied or not re-enumerated yet"
echo

echo "=== per-core sweep (${DUR}s each, 1 thread pinned per physical core) ==="
printf "%-6s %-7s %14s %8s %8s %7s\n" "core" "cpu" "bogo-ops/s" "passed" "failed" "new?"
echo "------------------------------------------------------------"

declare -A RESULT
for core in $CORES; do
    cpu=${CPU_OF_CORE[$core]}
    out=$(taskset -c "$cpu" stress-ng --cpu 1 --cpu-method all --verify \
          --metrics-brief -t "${DUR}s" 2>&1)
    ops=$(echo "$out"  | awk '$4=="cpu" && NF>=10 {print $9}' | tail -1)
    pass=$(echo "$out" | grep -oP 'passed:\s*\K\d+' | tail -1)
    fail=$(echo "$out" | grep -oP 'failed:\s*\K\d+' | tail -1)
    tag=""; case $core in 3|7) tag="NEW" ;; esac
    RESULT[$core]=$ops
    printf "%-6s %-7s %14s %8s %8s %7s\n" \
        "$core" "cpu$cpu" "${ops:-?}" "${pass:-?}" "${fail:-?}" "$tag"
done

echo
echo "=== deviation from median ==="
med=$(printf '%s\n' "${RESULT[@]}" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
echo "median = $med bogo-ops/s"
for core in $CORES; do
    v=${RESULT[$core]}
    pct=$(awk -v v="$v" -v m="$med" 'BEGIN{ if (m+0>0) printf "%+.1f", (v-m)/m*100; else printf "?" }')
    tag=""; case $core in 3|7) tag="   <-- NEW" ;; esac
    printf "  core %s: %10s  (%6s%%)%s\n" "$core" "$v" "$pct" "$tag"
done

echo
echo "=== all-core sustained run (${DUR}s, all threads) ==="
stress-ng --cpu 0 --cpu-method all --verify --metrics-brief -t "${DUR}s" 2>&1 \
    | grep -E 'passed:|failed:|untrustworthy'

echo
echo "=== machine-check events ==="
if command -v dmesg >/dev/null; then
    n=$(dmesg 2>/dev/null | grep -icE 'Machine Check Exception|mce:.*(error|corrected)')
    echo "  hardware error entries in dmesg: ${n:-?}  (run as root if this reads 0 unexpectedly)"
fi

cat <<'EOF'

Interpretation:
  * failures > 0 on any core      -> that core produces WRONG results. Do not use.
  * one core far below the median -> marginal silicon; re-test at stock clocks.
  * spread within ~1%             -> normal binning, the cores are fine.
EOF
