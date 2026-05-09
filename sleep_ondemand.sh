#!/bin/bash
# Park unfocused desktop apps to save power. Network sessions (Cursor remote
# agent, Antigravity, IMAP IDLE) need to keep their TCP keepalives flowing,
# which is why this lives in user space watching focus rather than relying
# on the kernel idle detection alone.
#
# Origin notes: https://www.perplexity.ai/search/to-optimize-the-power-manageme-wBNWVr8IRQClsvu2sFBS0w

# ─── Config ───────────────────────────────────────────────────────────
PROCESSES=("chrome" "cursor" "thunderbird-bin" "obsidian" "masterpdf" "antigravity")
POLL_INTERVAL_SEC=1

FG_CPUQUOTA=""           # `set-property CPUQuota=` resets to infinity (unlimited)
FG_CPUWEIGHT=100
FG_CPU_IDLE=0            # 0 = normal scheduling
FG_UCLAMP_MAX=max        # full P-state range (turbo allowed)

# Per-app tier. LOOSE: enough headroom for network keepalives, language
# servers, IMAP IDLE long-polls. TIGHT: local-only apps with no network
# heartbeat to keep alive.
declare -A APP_TIER=(
    [chrome]=TIGHT
    [obsidian]=TIGHT
    [masterpdf]=TIGHT
    [cursor]=LOOSE
    [thunderbird-bin]=LOOSE
    [antigravity]=LOOSE
)
DEFAULT_TIER=LOOSE       # used for any process not in APP_TIER

LOOSE_BG_CPUQUOTA="5%"
LOOSE_BG_CPUWEIGHT=10
LOOSE_BG_CPU_IDLE=1
LOOSE_BG_UCLAMP_MAX=30

TIGHT_BG_CPUQUOTA="1%"
TIGHT_BG_CPUWEIGHT=1
TIGHT_BG_CPU_IDLE=1
TIGHT_BG_UCLAMP_MAX=20

# ─── Backend hooks ────────────────────────────────────────────────────
# CPUQuota/CPUWeight throttle via systemd so TCP keepalives, IMAP IDLE,
# and remote-agent heartbeats keep flowing while CPU is starved.
park() {
    local proc=$1
    local tier=${APP_TIER[$proc]:-$DEFAULT_TIER}
    local quota="${tier}_BG_CPUQUOTA"   weight="${tier}_BG_CPUWEIGHT"
    local idle="${tier}_BG_CPU_IDLE"    uclamp="${tier}_BG_UCLAMP_MAX"
    local dir; dir=$(slice_dir_for "$proc")
    systemctl --user set-property "$(slice_unit_for "$proc")" \
        CPUQuota="${!quota}" CPUWeight="${!weight}" 2>/dev/null || true
    echo "${!idle}"   > "$dir/cpu.idle"       2>/dev/null || true
    echo "${!uclamp}" > "$dir/cpu.uclamp.max" 2>/dev/null || true
}
wake() {
    local dir; dir=$(slice_dir_for "$1")
    systemctl --user set-property "$(slice_unit_for "$1")" \
        CPUQuota="$FG_CPUQUOTA" CPUWeight="$FG_CPUWEIGHT" 2>/dev/null || true
    echo "$FG_CPU_IDLE"   > "$dir/cpu.idle"       2>/dev/null || true
    echo "$FG_UCLAMP_MAX" > "$dir/cpu.uclamp.max" 2>/dev/null || true
}

apply_tier() { :; }

# ─── CPU topology detection ───────────────────────────────────────────
# Globals populated by detect_topology(). Empty when not on a hybrid CPU.
HYBRID=0
P_CORES=""        # e.g. "0-3"
REG_E_CORES=""    # regular E-cores, e.g. "4-11"
LP_E_CORES=""     # low-power E-cores on the SoC tile, e.g. "12-13"
ALL_E_CORES=""    # union of REG_E_CORES + LP_E_CORES, e.g. "4-13"

# Expand a CPU range like "4-13" or "0,2,4-7" to a space-separated list.
seq_from_range() {
    local out=""
    local IFS=,
    for chunk in $1; do
        if [[ "$chunk" == *-* ]]; then
            out+="$(seq "${chunk%-*}" "${chunk#*-}") "
        else
            out+="$chunk "
        fi
    done
    echo "${out% }"
}

detect_topology() {
    [[ -d /sys/devices/cpu_core && -d /sys/devices/cpu_atom ]] || {
        echo "topology: not a hybrid CPU; cpuset pinning disabled"
        return
    }
    HYBRID=1
    P_CORES=$(cat /sys/devices/cpu_core/cpus)
    local atoms; atoms=$(cat /sys/devices/cpu_atom/cpus)

    # Atoms with the lowest cpuinfo_max_freq are LP E-cores (the SoC
    # tile cluster on Meteor Lake runs at ~2.1 GHz vs ~3.8 GHz for
    # compute-tile E-cores).
    local cpu min_freq=2147483647
    declare -A freq
    for cpu in $(seq_from_range "$atoms"); do
        local f
        f=$(cat "/sys/devices/system/cpu/cpu$cpu/cpufreq/cpuinfo_max_freq" 2>/dev/null) \
            || f=0
        freq[$cpu]=$f
        (( f > 0 && f < min_freq )) && min_freq=$f
    done
    local lp="" reg=""
    for cpu in $(seq_from_range "$atoms"); do
        if (( freq[$cpu] == min_freq )); then
            lp+="$cpu,"
        else
            reg+="$cpu,"
        fi
    done
    LP_E_CORES=${lp%,}
    REG_E_CORES=${reg%,}
    ALL_E_CORES="${REG_E_CORES}${REG_E_CORES:+,}${LP_E_CORES}"
    echo "topology: hybrid CPU detected — P=$P_CORES regE=$REG_E_CORES LP-E=$LP_E_CORES"
}

# ─── Slice scaffolding ────────────────────────────────────────────────
# systemd's slice naming uses '-' as a hierarchy separator: "a-b-c.slice"
# is read as a.slice/a-b.slice/a-b-c.slice. Process names containing
# hyphens (thunderbird-bin) get sanitised to underscores so we land at
# exactly two levels: sondemand.slice/sondemand-<proc>.slice.
SLICE_PARENT_NAME=sondemand.slice
SLICE_ROOT_DIR=/sys/fs/cgroup/user.slice/user-$UID.slice/user@$UID.service/$SLICE_PARENT_NAME

slice_unit_for() { echo "sondemand-${1//-/_}.slice"; }
slice_dir_for()  { echo "$SLICE_ROOT_DIR/$(slice_unit_for "$1")"; }

ensure_slice() {
    local unit=$1
    systemctl --user -q is-active "$unit" 2>/dev/null && return 0
    # Transient scope inside the slice; the scope exits but the slice
    # persists, which is what we want.
    systemd-run --user --quiet --scope --slice="$unit" \
        --unit="cgcreate-$$-$RANDOM" -- /bin/true >/dev/null 2>&1 || true
}

setup_slices() {
    ensure_slice "$SLICE_PARENT_NAME"
    for proc in "${PROCESSES[@]}"; do
        ensure_slice "$(slice_unit_for "$proc")"
    done
}

migrate_pids() {
    local proc=$1
    local dir; dir=$(slice_dir_for "$proc")
    [[ -d "$dir" ]] || return 0
    declare -A in_slice
    local p
    while read -r p; do in_slice[$p]=1; done < "$dir/cgroup.procs"
    while read -r p; do
        [[ -z "$p" || -n "${in_slice[$p]}" ]] && continue
        echo "$p" > "$dir/cgroup.procs" 2>/dev/null || true
    done < <(pgrep -f "$proc" 2>/dev/null)
}

# ─── Lifecycle ────────────────────────────────────────────────────────
cleanup() {
    echo "Restoring all processes..."
    # wake() resets each slice to FG defaults (unlimited). We deliberately
    # leave the slices themselves in place so that running PIDs are not
    # orphaned back to user.slice and bounced again on next script start.
    for PROC in "${PROCESSES[@]}"; do
        wake "$PROC"
    done
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

get_focused_proc_name() {
    local wid pid
    wid=$(xdotool getwindowfocus 2>/dev/null) || return
    pid=$(xdotool getwindowpid "$wid" 2>/dev/null) || return
    [[ -n "$pid" && -d "/proc/$pid" ]] || return
    cat "/proc/$pid/comm"
}

# ─── Main loop ────────────────────────────────────────────────────────
detect_topology
setup_slices

declare -A PROC_STATE
for PROC in "${PROCESSES[@]}"; do
    PROC_STATE[$PROC]="UNKNOWN"
done

while true; do
    FOCUSED=$(get_focused_proc_name)
    if [[ -n "$FOCUSED" ]]; then
        echo "Focused: $FOCUSED"
    else
        echo "No focused process."
    fi

    for PROC in "${PROCESSES[@]}"; do
        migrate_pids "$PROC"
        if [[ "$PROC" == "$FOCUSED" ]]; then
            if [[ "${PROC_STATE[$PROC]}" != "FG" ]]; then
                wake "$PROC"
                echo "FG: $PROC"
                PROC_STATE[$PROC]="FG"
            fi
        else
            if [[ "${PROC_STATE[$PROC]}" != "BG" ]]; then
                park "$PROC"
                echo "BG: $PROC"
                PROC_STATE[$PROC]="BG"
            fi
        fi
    done
    sleep "$POLL_INTERVAL_SEC"
done
