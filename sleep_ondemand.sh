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
BG_CPUQUOTA="5%"
BG_CPUWEIGHT=10
BG_CPU_IDLE=1            # 1 = SCHED_IDLE: never preempts foreground

# ─── Backend hooks ────────────────────────────────────────────────────
# CPUQuota/CPUWeight throttle via systemd so TCP keepalives, IMAP IDLE,
# and remote-agent heartbeats keep flowing while CPU is starved.
park() {
    local dir; dir=$(slice_dir_for "$1")
    systemctl --user set-property "$(slice_unit_for "$1")" \
        CPUQuota="$BG_CPUQUOTA" CPUWeight="$BG_CPUWEIGHT" 2>/dev/null || true
    echo "$BG_CPU_IDLE" > "$dir/cpu.idle" 2>/dev/null || true
}
wake() {
    local dir; dir=$(slice_dir_for "$1")
    systemctl --user set-property "$(slice_unit_for "$1")" \
        CPUQuota="$FG_CPUQUOTA" CPUWeight="$FG_CPUWEIGHT" 2>/dev/null || true
    echo "$FG_CPU_IDLE" > "$dir/cpu.idle" 2>/dev/null || true
}

detect_topology() { :; }
apply_tier()      { :; }

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
