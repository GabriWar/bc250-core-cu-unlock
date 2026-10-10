#!/usr/bin/env bash
#
# test-cores.sh -- per-physical-core health sweep for the BC-250.
#
# Checks whether the cores enabled by bc250-8core-unlock are actually good
# silicon or were disabled for a reason. Which cores are new depends on the
# board's factory mask (0x77 -> cores 3 and 7, 0x7D -> cores 1 and 7, ...).
# It is read from the file bc250-8core-unlock records at unlock time, or can be
# given explicitly:  NEW_CORES="1 7" ./test-cores.sh
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

# which cores were enabled by the unlock (cleared bits of the factory mask)
ORIG_MASK_FILE=/var/lib/bc250-8core-unlock/factory-mask
if [ -z "${NEW_CORES:-}" ]; then
    if [ -r "$ORIG_MASK_FILE" ]; then
        orig=$(( $(head -n1 "$ORIG_MASK_FILE") & 0xff ))
        for i in 0 1 2 3 4 5 6 7; do
            (( (orig >> i) & 1 )) || NEW_CORES="${NEW_CORES:-}${NEW_CORES:+ }$i"
        done
        echo "factory mask $(printf '0x%02X' "$orig") (from $ORIG_MASK_FILE) -> new cores: $NEW_CORES"
    else
        NEW_CORES="3 7"
        echo "no recorded factory mask -- assuming 0x77 (new cores: 3 7)."
        echo "if your board started from a different mask, set NEW_CORES, e.g. NEW_CORES=\"1 7\""
    fi
fi
is_new() { case " $NEW_CORES " in *" $1 "*) return 0 ;; esac; return 1; }

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
    tag=""; is_new "$core" && tag="NEW"
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
    tag=""; is_new "$core" && tag="   <-- NEW"
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
