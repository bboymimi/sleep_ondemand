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
POLL_INTERVAL_SEC=1         # focus-check cadence (xprop event wakes earlier when it fires)
DISCOVERY_INTERVAL_SEC=10   # how often we rescan for new app scopes

# Hard refusal list: any process whose comm matches will never be added
# to PROCESSES regardless of where its scope sits. The app.slice filter
# already excludes session.slice / system.slice, so this is belt-and-
# braces against systemd reorganising things.
NEVER_THROTTLE_REGEX='^(gnome-shell|mutter|Xorg|Xwayland|gdm-.*|pipewire.*|wireplumber|pulseaudio|dbus-(daemon|broker)|systemd|systemd-.*|polkitd?|NetworkManager.*|wpa_supplicant|gnome-keyring.*|gvfs.*|gsd-.*|evolution-.*|bash|zsh|fish|sshd|ssh-agent|sudo|gnome-terminal-)$'

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
    # Returns the explicit CPU list to write to cpuset.cpus. For
    # "unrestricted" (PIN_MODE=NONE, or FG outside ALL_ON_E) we return
    # the full system CPU set rather than empty, because Linux 6.17's
    # cgroup v2 cpuset silently ignores empty / whitespace writes.
    case "$PIN_MODE:$1" in
        NONE:*)        echo "" ;;            # caller skips the write entirely
        LP_ONLY:BG)    echo "$LP_E_CORES" ;;
        E_PLUS_LP:BG)  echo "$ALL_E_CORES" ;;
        ALL_ON_E:*)    echo "$ALL_E_CORES" ;;
        *)             echo "$ALL_CPUS" ;;   # FG with pinning enabled
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
        CPUQuota="${!quota}" CPUWeight="${!weight}" 2>/dev/null || true
    echo "${!idle}"   > "$dir/cpu.idle"       2>/dev/null || true
    echo "${!uclamp}" > "$dir/cpu.uclamp.max" 2>/dev/null || true
    [[ -n "$cpus" ]] && echo "$cpus" > "$dir/cpuset.cpus" 2>/dev/null
}
wake() {
    local dir; dir=$(slice_dir_for "$1")
    local cpus; cpus=$(cpus_for_tier FG)
    systemctl --user set-property "$(slice_unit_for "$1")" \
        CPUQuota="$FG_CPUQUOTA" CPUWeight="$FG_CPUWEIGHT" 2>/dev/null || true
    echo "$FG_CPU_IDLE"   > "$dir/cpu.idle"       2>/dev/null || true
    echo "$FG_UCLAMP_MAX" > "$dir/cpu.uclamp.max" 2>/dev/null || true
    [[ -n "$cpus" ]] && echo "$cpus" > "$dir/cpuset.cpus" 2>/dev/null
}

apply_tier() { :; }

# ─── CPU topology detection ───────────────────────────────────────────
# Globals populated by detect_topology(). Empty when not on a hybrid CPU.
HYBRID=0
P_CORES=""        # e.g. "0-3"
REG_E_CORES=""    # regular E-cores, e.g. "4-11"
LP_E_CORES=""     # low-power E-cores on the SoC tile, e.g. "12-13"
ALL_E_CORES=""    # union of REG_E_CORES + LP_E_CORES, e.g. "4-13"
ALL_CPUS=""       # everything, used to express "no restriction" — Linux 6.17 ignores empty writes to cpuset.cpus, so we write the full set instead

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
    ALL_CPUS=$(cat /sys/devices/system/cpu/possible 2>/dev/null)
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

# Hyphen → underscore is one-way lossy (an app literally named foo_bar would
# round-trip as foo-bar), but no managed app currently has underscores in
# its friendly name.
slice_unit_for() { echo "sondemand-${1//-/_}.slice"; }
slice_dir_for()  { echo "$SLICE_ROOT_DIR/$(slice_unit_for "$1")"; }
friendly_name_from_our_slice() {
    # "/…/sondemand-foo_bar.slice" or "sondemand-foo_bar.slice" → "foo-bar"
    local s=${1##*/}; s=${s%.slice}; s=${s#sondemand-}
    echo "${s//_/-}"
}

ensure_slice() {
    local unit=$1
    systemctl --user -q is-active "$unit" 2>/dev/null && return 0
    # Transient scope inside the slice; the scope exits but the slice
    # persists, which is what we want.
    systemd-run --user --quiet --scope --slice="$unit" \
        --unit="cgcreate-$$-$RANDOM" -- /bin/true >/dev/null 2>&1 || true
}

# systemd doesn't auto-propagate cpuset to the parent slice's
# subtree_control, so per-app slices have no cpuset.cpus files until we
# enable it here. Idempotent: writing "+cpuset" to a subtree_control that
# already has it is a no-op.
enable_cpuset_subtree() {
    [[ "$PIN_MODE" == "NONE" ]] && return
    local f=$SLICE_ROOT_DIR/cgroup.subtree_control
    [[ -w "$f" ]] || return
    grep -qw cpuset "$f" 2>/dev/null && return
    echo "+cpuset" > "$f" 2>/dev/null || true
}

migrate_pids() {
    # Anchors PID identity to the launching app.slice scope, not cmdline
    # (chromium forks re-exec via /proc/self/exe so cmdline matching fails).
    local proc=$1
    local our_dir; our_dir=$(slice_dir_for "$proc")
    [[ -d "$our_dir" ]] || return 0
    declare -A in_our_slice
    local p
    while read -r p; do in_our_slice[$p]=1; done < "$our_dir/cgroup.procs"

    local scope_dir scope_name name
    for scope_dir in "$USER_APP_SLICE"/*.scope; do
        [[ -d "$scope_dir" ]] || continue
        scope_name=$(basename "$scope_dir")
        name=$(friendly_name_from_scope "$scope_name") || continue
        [[ "$name" == "$proc" ]] || continue
        while read -r p; do
            [[ -z "$p" || -n "${in_our_slice[$p]}" ]] && continue
            echo "$p" > "$our_dir/cgroup.procs" 2>/dev/null || true
        done < "$scope_dir/cgroup.procs"
    done
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
    declare -A seen=()
    local proc
    # Carry forward already-managed apps so that we keep flipping their
    # limits even after migrate_pids has emptied their original scope.
    for proc in "${PROCESSES[@]}"; do seen[$proc]=1; done

    # New app scopes under user app.slice.
    if [[ -d "$USER_APP_SLICE" ]]; then
        local scope_dir scope name pid comm
        for scope_dir in "$USER_APP_SLICE"/*.scope; do
            [[ -d "$scope_dir" ]] || continue
            scope=$(basename "$scope_dir")
            name=$(friendly_name_from_scope "$scope") || continue
            pid=$(head -1 "$scope_dir/cgroup.procs" 2>/dev/null)
            comm=$(cat "/proc/$pid/comm" 2>/dev/null)
            [[ -n "$comm" && "$comm" =~ $NEVER_THROTTLE_REGEX ]] && continue
            seen[$name]=1
        done
    fi

    # Recover in-flight apps already adopted in a prior session — their
    # app.slice scope has been drained. cgroup.procs reports stat-size 0
    # even when populated, so peek at the first line instead of `-s`.
    if [[ -d "$SLICE_ROOT_DIR" ]]; then
        local slice_dir first
        for slice_dir in "$SLICE_ROOT_DIR"/sondemand-*.slice; do
            [[ -d "$slice_dir" ]] || continue
            read -r first < "$slice_dir/cgroup.procs" 2>/dev/null || continue
            [[ -z "$first" ]] && continue
            seen[$(friendly_name_from_our_slice "$slice_dir")]=1
        done
    fi

    PROCESSES=( "${!seen[@]}" )
    for proc in "${PROCESSES[@]}"; do
        [[ -z "${PROC_STATE[$proc]}" ]] && PROC_STATE[$proc]=UNKNOWN
        ensure_slice "$(slice_unit_for "$proc")"
    done
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

pid_to_proc_name() {
    # Anchor friendly name to the PID's current sondemand-* slice when
    # possible — comm is misleading for chromium forks (antigravity → "chrome").
    local pid=$1 line cg comm
    [[ -n "$pid" && -d "/proc/$pid" ]] || return
    read -r line < "/proc/$pid/cgroup" 2>/dev/null
    cg=${line#*::}                                 # cgroup v2 is single-line "0::<path>"
    if [[ "$cg" == *"/sondemand.slice/sondemand-"*".slice" ]]; then
        friendly_name_from_our_slice "$cg"
        return
    fi
    read -r comm < "/proc/$pid/comm" 2>/dev/null && echo "$comm"
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
enable_cpuset_subtree
discover
echo "discovered: ${PROCESSES[*]}"
for proc in "${PROCESSES[@]}"; do migrate_pids "$proc"; done
LAST_DISCOVERY=$(date +%s)

LAST_WID=
refresh_focus() {
    local wid pid
    wid=$(xdotool getwindowfocus 2>/dev/null) || return
    [[ "$wid" == "$LAST_WID" ]] && return
    LAST_WID=$wid
    pid=$(xdotool getwindowpid "$wid" 2>/dev/null) || return
    apply_focus_state "$(pid_to_proc_name "$pid")"
}

refresh_focus            # seed initial state

# Plain poll loop. Tried xprop -spy on _NET_ACTIVE_WINDOW for snappier
# wake-up, but mutter on some GNOME/X11 setups leaves that property at
# 0x0 indefinitely, so events never fire. Polling at POLL_INTERVAL_SEC
# is the authoritative source; xdotool getwindowfocus uses XGetInputFocus
# which actually tracks focus on those setups.
while true; do
    sleep "$POLL_INTERVAL_SEC"
    refresh_focus
    now=$(date +%s)
    if (( now - LAST_DISCOVERY >= DISCOVERY_INTERVAL_SEC )); then
        discover
        for proc in "${PROCESSES[@]}"; do migrate_pids "$proc"; done
        LAST_DISCOVERY=$now
    fi
done
