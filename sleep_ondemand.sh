#!/bin/bash
# List of managed process names
# https://www.perplexity.ai/search/to-optimize-the-power-manageme-wBNWVr8IRQClsvu2sFBS0w
PROCESSES=("chrome" "cursor" "anki" "thunderbird-bin" "obsidian" "masterpdf")

# Cleanup function to resume all processes
cleanup() {
    echo "Restoring all processes..."
    for PROC in "${PROCESSES[@]}"; do
        for PID in $(pgrep $PROC); do
            kill -CONT $PID
        done
    done
    exit 0
}

# Trap SIGINT (Ctrl+C) and SIGTERM to call cleanup
trap cleanup SIGINT SIGTERM EXIT

# Associative array to track process status
# RUNNING or STOPPED
declare -A PROC_STATUS
for PROC in "${PROCESSES[@]}"; do
    PROC_STATUS[$PROC]="UNKNOWN"
done

while true; do
    FOCUSED_PID=$(xdotool getwindowpid $(xdotool getwindowfocus))
    # Get the process name from /proc/[PID]/comm
    if [[ -n "$FOCUSED_PID" && -d "/proc/$FOCUSED_PID" ]]; then
        PROC_NAME=$(cat /proc/$FOCUSED_PID/comm)
        echo "Focused process PID: $FOCUSED_PID, Name: $PROC_NAME"
    else
        PROC_NAME=""
        echo "No focused process found or process no longer exists."
    fi
    for PROC in "${PROCESSES[@]}"; do
        if [[ "$PROC" == "$PROC_NAME" ]]; then
            if [[ "${PROC_STATUS[$PROC]}" != "RUNNING" ]]; then
                pkill -CONT -f $PROC
                echo "Wake up $PROC!"
                PROC_STATUS[$PROC]="RUNNING"
            fi
        else
            if [[ "${PROC_STATUS[$PROC]}" != "STOPPED" ]]; then
                pkill -STOP -f $PROC
                echo "Stop $PROC"
                PROC_STATUS[$PROC]="STOPPED"
            fi
        fi
    done
    sleep 1
done
