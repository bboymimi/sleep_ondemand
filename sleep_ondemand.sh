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

# ─── Backend hooks ────────────────────────────────────────────────────
park() { pkill -STOP -f "$1"; }
wake() { pkill -CONT -f "$1"; }

detect_topology() { :; }
apply_tier()      { :; }

# ─── Lifecycle ────────────────────────────────────────────────────────
cleanup() {
    echo "Restoring all processes..."
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

declare -A PROC_STATUS
for PROC in "${PROCESSES[@]}"; do
    PROC_STATUS[$PROC]="UNKNOWN"
done

while true; do
    FOCUSED=$(get_focused_proc_name)
    if [[ -n "$FOCUSED" ]]; then
        echo "Focused: $FOCUSED"
    else
        echo "No focused process."
    fi

    for PROC in "${PROCESSES[@]}"; do
        if [[ "$PROC" == "$FOCUSED" ]]; then
            if [[ "${PROC_STATUS[$PROC]}" != "RUNNING" ]]; then
                wake "$PROC"
                echo "Wake up $PROC!"
                PROC_STATUS[$PROC]="RUNNING"
            fi
        else
            if [[ "${PROC_STATUS[$PROC]}" != "STOPPED" ]]; then
                park "$PROC"
                echo "Stop $PROC"
                PROC_STATUS[$PROC]="STOPPED"
            fi
        fi
    done
    sleep "$POLL_INTERVAL_SEC"
done
