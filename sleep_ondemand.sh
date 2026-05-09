#!/bin/bash
# Park unfocused desktop apps to save power. Network sessions (Cursor remote
# agent, Antigravity, IMAP IDLE) need to keep their TCP keepalives flowing,
# which is why this lives in user space watching focus rather than relying
# on the kernel idle detection alone.
#
# One-time sudo for cpuset pinning (only needed if PIN_MODE != NONE):
#   sudo tee /etc/systemd/system/user@.service.d/delegate.conf <<EOF
#   [Service]
#   Delegate=cpu cpuset io memory pids
#   EOF
#   sudo systemctl daemon-reload
#   # log out and back in
# Without this, the script auto-degrades to PIN_MODE=NONE.
#
# Origin notes: https://www.perplexity.ai/search/to-optimize-the-power-manageme-wBNWVr8IRQClsvu2sFBS0w

# ─── Config ───────────────────────────────────────────────────────────
# Discovered automatically from app.slice scopes; APP_TIER below pins
# specific names to TIGHT/LOOSE, anything else falls into DEFAULT_TIER.
PROCESSES=()
DISCOVERY_INTERVAL_SEC=10   # how often the background loop rescans for new PIDs

# Hard refusal list: any process whose comm matches will never be added
# to PROCESSES regardless of where its scope sits. The app.slice filter
# already excludes session.slice / system.slice, so this is belt-and-
# braces against systemd reorganising things.
NEVER_THROTTLE_REGEX='^(gnome-shell|mutter|Xorg|Xwayland|gdm-.*|pipewire.*|wireplumber|pulseaudio|dbus-(daemon|broker)|systemd|systemd-.*|polkitd?|NetworkManager.*|wpa_supplicant|gnome-keyring.*|gvfs.*|gsd-.*|evolution-.*|bash|zsh|fish|sshd|sudo|gnome-terminal-)$'

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

# Pinning policy for hybrid CPUs.
#   LP_ONLY   — BG runs only on LP E-cores (most aggressive)
#   E_PLUS_LP — BG runs on all E-cores incl. LP
#   ALL_ON_E  — both BG and FG on E-cores (battery-saver mode)
#   NONE      — no cpuset pinning (cpu.max + uclamp only)
#   AUTO      — E_PLUS_LP if hybrid, else NONE
PIN_MODE="${PIN_MODE:-AUTO}"

# ─── Backend hooks ────────────────────────────────────────────────────
# CPUQuota/CPUWeight throttle via systemd so TCP keepalives, IMAP IDLE,
# and remote-agent heartbeats keep flowing while CPU is starved.
cpus_for_tier() {
    case "$PIN_MODE:$1" in
        LP_ONLY:BG)    echo "$LP_E_CORES" ;;
        E_PLUS_LP:BG)  echo "$ALL_E_CORES" ;;
        ALL_ON_E:*)    echo "$ALL_E_CORES" ;;
        *)             echo "" ;;            # NONE, or FG outside ALL_ON_E
    esac
}

park() {
    local proc=$1
    local tier=${APP_TIER[$proc]:-$DEFAULT_TIER}
    local quota="${tier}_BG_CPUQUOTA"   weight="${tier}_BG_CPUWEIGHT"
    local idle="${tier}_BG_CPU_IDLE"    uclamp="${tier}_BG_UCLAMP_MAX"
    local dir; dir=$(slice_dir_for "$proc")
    local cpus; cpus=$(cpus_for_tier BG)
    systemctl --user set-property "$(slice_unit_for "$proc")" \
        CPUQuota="${!quota}" CPUWeight="${!weight}" \
        AllowedCPUs="$cpus" 2>/dev/null || true
    echo "${!idle}"   > "$dir/cpu.idle"       2>/dev/null || true
    echo "${!uclamp}" > "$dir/cpu.uclamp.max" 2>/dev/null || true
}
wake() {
    local dir; dir=$(slice_dir_for "$1")
    local cpus; cpus=$(cpus_for_tier FG)
    systemctl --user set-property "$(slice_unit_for "$1")" \
        CPUQuota="$FG_CPUQUOTA" CPUWeight="$FG_CPUWEIGHT" \
        AllowedCPUs="$cpus" 2>/dev/null || true
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

resolve_pin_mode() {
    [[ "$PIN_MODE" == "AUTO" ]] && PIN_MODE=$( ((HYBRID)) && echo E_PLUS_LP || echo NONE )
}

check_cpuset_delegation() {
    [[ "$PIN_MODE" == "NONE" ]] && return
    local f=/sys/fs/cgroup/user.slice/user-$UID.slice/user@$UID.service/cgroup.subtree_control
    if ! grep -qw cpuset "$f" 2>/dev/null; then
        echo "warn: cpuset is not delegated to user@.service — falling back to PIN_MODE=NONE."
        echo "      Add 'Delegate=cpu cpuset io memory pids' to a"
        echo "      /etc/systemd/system/user@.service.d/delegate.conf and re-login to enable."
        PIN_MODE=NONE
    fi
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

# Walk app.slice scopes and rebuild PROCESSES. Called at startup and
# periodically. Idempotent: existing slices are reused, existing
# PROC_STATE entries preserved.
USER_APP_SLICE=/sys/fs/cgroup/user.slice/user-$UID.slice/user@$UID.service/app.slice

friendly_name_from_scope() {
    # app-gnome-cursor-1234.scope                 -> cursor
    # app-org.chromium.Chromium-NNN.scope         -> chromium  (last dotted)
    # app-codex-desktop-NNN.scope                 -> codex-desktop
    # app-gnome-codex\x2ddesktop-NNN.scope        -> codex-desktop (unescaped)
    # snap.thunderbird.thunderbird-XX.scope       -> thunderbird
    local s=$1 n
    s=${s//\\x2d/-}                       # systemd escapes hyphens
    if   [[ "$s" =~ ^app-(.+)-[0-9]+\.scope$ ]]; then
        n=${BASH_REMATCH[1]}
        n=${n##*.}                        # last dotted component (org.foo.Bar -> Bar)
        n=${n#gnome-}                     # strip launcher prefix if present
        n=${n#flatpak-}
    elif [[ "$s" =~ ^snap\.([^.]+)\..+\.scope$ ]]; then
        n=${BASH_REMATCH[1]}
    else
        return 1
    fi
    echo "${n,,}"
}

discover() {
    [[ -d "$USER_APP_SLICE" ]] || return
    declare -A seen=()
    local scope_dir scope name pid comm proc
    # Carry forward already-managed apps so that we keep flipping their
    # limits even after migrate_pids has emptied their original scope.
    for proc in "${PROCESSES[@]}"; do seen[$proc]=1; done
    for scope_dir in "$USER_APP_SLICE"/*.scope; do
        [[ -d "$scope_dir" ]] || continue
        scope=$(basename "$scope_dir")
        name=$(friendly_name_from_scope "$scope") || continue
        pid=$(head -1 "$scope_dir/cgroup.procs" 2>/dev/null)
        comm=$(cat "/proc/$pid/comm" 2>/dev/null)
        [[ -n "$comm" && "$comm" =~ $NEVER_THROTTLE_REGEX ]] && continue
        seen[$name]=1
    done
    PROCESSES=( "${!seen[@]}" )
    for proc in "${PROCESSES[@]}"; do
        [[ -z "${PROC_STATE[$proc]}" ]] && PROC_STATE[$proc]=UNKNOWN
        ensure_slice "$(slice_unit_for "$proc")"
    done
}

# ─── Lifecycle ────────────────────────────────────────────────────────
XPROP_PID=
cleanup() {
    echo "Restoring all processes..."
    [[ -n "$XPROP_PID" ]] && kill "$XPROP_PID" 2>/dev/null
    # wake() resets each slice to FG defaults (unlimited). We deliberately
    # leave the slices themselves in place so that running PIDs are not
    # orphaned back to user.slice and bounced again on next script start.
    for PROC in "${PROCESSES[@]}"; do
        wake "$PROC"
    done
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

pid_to_proc_name() {
    local pid=$1
    [[ -n "$pid" && -d "/proc/$pid" ]] || return
    cat "/proc/$pid/comm" 2>/dev/null
}

# ─── Focus state machine ─────────────────────────────────────────────
declare -A PROC_STATE  # populated by discover()

apply_focus_state() {
    local focused=$1
    for PROC in "${PROCESSES[@]}"; do
        if [[ "$PROC" == "$focused" ]]; then
            if [[ "${PROC_STATE[$PROC]}" != "FG" ]]; then
                wake "$PROC"; echo "FG: $PROC"; PROC_STATE[$PROC]="FG"
            fi
        else
            if [[ "${PROC_STATE[$PROC]}" != "BG" ]]; then
                park "$PROC"; echo "BG: $PROC"; PROC_STATE[$PROC]="BG"
            fi
        fi
    done
}

# ─── Main ────────────────────────────────────────────────────────────
detect_topology
resolve_pin_mode
check_cpuset_delegation
echo "PIN_MODE=$PIN_MODE"

ensure_slice "$SLICE_PARENT_NAME"
discover
echo "discovered: ${PROCESSES[*]}"
for proc in "${PROCESSES[@]}"; do migrate_pids "$proc"; done
LAST_DISCOVERY=$(date +%s)

# Seed the initial focus state.
INITIAL_PID=$(xdotool getwindowpid "$(xdotool getwindowfocus 2>/dev/null)" 2>/dev/null)
apply_focus_state "$(pid_to_proc_name "$INITIAL_PID")"

# xprop -spy emits a line whenever _NET_ACTIVE_WINDOW changes (≤10 ms
# focus latency). `read -t` doubles as a watchdog: if no focus event
# fires within DISCOVERY_INTERVAL_SEC the read times out, giving us a
# regular cadence to rescan app.slice and migrate newly-spawned PIDs.
# Run xprop in a coproc with `exec` so $XPROP_PID is xprop itself —
# cleanup() can kill it directly and the read unblocks immediately.
coproc XPROP { exec xprop -root -spy _NET_ACTIVE_WINDOW 2>/dev/null; }
XPROP_PID=$XPROP_PID
while true; do
    if read -t "$DISCOVERY_INTERVAL_SEC" -r line <&"${XPROP[0]}"; then
        wid=${line##* }
        if [[ "$wid" =~ ^0x[0-9a-fA-F]+$ ]]; then
            pid=$(xdotool getwindowpid "$wid" 2>/dev/null)
            apply_focus_state "$(pid_to_proc_name "$pid")"
        fi
    fi
    now=$(date +%s)
    if (( now - LAST_DISCOVERY >= DISCOVERY_INTERVAL_SEC )); then
        discover
        for proc in "${PROCESSES[@]}"; do migrate_pids "$proc"; done
        LAST_DISCOVERY=$now
    fi
done
