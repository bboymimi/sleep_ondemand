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
POLL_INTERVAL_SEC=1         # focus-check cadence
DISCOVERY_INTERVAL_SEC=30   # how often we rescan for new app scopes

# 1 = freeze background slices via cgroup.freeze (the SIGSTOP-equivalent).
# Stops all CPU work in those processes immediately. Network keepalives,
# IMAP IDLE, and remote-agent connections will drop until the app is
# refocused. Default 0 leaves them throttled but running.
FREEZE_BG="${FREEZE_BG:-0}"

# Hard refusal list: any process whose comm matches will never be added
# to PROCESSES regardless of where its scope sits. The app.slice filter
# already excludes session.slice / system.slice, so this is belt-and-
# braces against systemd reorganising things.
# Matched against both /proc/$pid/comm (kernel-truncated to 15 chars) AND
# the friendly name extracted from the unit. Long entries below the |
# separators handle the comm-truncation case (e.g. xdg-desktop-por),
# wildcard entries handle the full friendly-name case (e.g. xdg-.*).
# Append to this from outside the script via NEVER_THROTTLE_EXTRA — set
# it to a regex fragment (no anchors, no leading |) and it gets OR'd in
# at startup. e.g.  NEVER_THROTTLE_EXTRA='myapp|tracker-.*' ./script.sh
NEVER_THROTTLE_BUILTIN='gnome-shell|mutter|Xorg|Xwayland|gdm-.*|pipewire.*|wireplumber|pulseaudio|dbus-(daemon|broker)|systemd|systemd-.*|polkitd?|NetworkManager.*|wpa_supplicant|gnome-keyring.*|gvfs.*|gsd-.*|evolution-.*|bash|zsh|fish|sshd|ssh-agent|sudo|gnome-terminal-|at-spi-bus-laun|at-spi.*|ibus-daemon|ibus.*|xdg-(desktop-por|document-po|permission-)|xdg-.*portal.*|speech-dispatch|speech-dispatcher.*|dconf-service|dconf.*|gcr-ssh-agent|gnome-remote-d|gnome-remote-desktop.*|gnome-session-.*|dbus|sharing|smartcard|color|xsettings|datetime|housekeeping|keyboard|mediakeys|power|printnotifications|rfkill|screensaverproxy|sound|wacom|a11ysettings|syncthing'
NEVER_THROTTLE_REGEX="^($NEVER_THROTTLE_BUILTIN${NEVER_THROTTLE_EXTRA:+|$NEVER_THROTTLE_EXTRA})\$"

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

LOOSE_BG_CPUQUOTA="15%"
LOOSE_BG_CPUWEIGHT=10
LOOSE_BG_CPU_IDLE=1
LOOSE_BG_UCLAMP_MAX=30

TIGHT_BG_CPUQUOTA="10%"
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
is_on_ac() {
    # 1. Try standard on_ac_power utility
    if command -v on_ac_power >/dev/null 2>&1; then
        on_ac_power
        return $?
    fi

    # 2. Try direct sysfs check for standard AC directory
    if [[ -f /sys/class/power_supply/AC/online ]]; then
        [[ "$(cat /sys/class/power_supply/AC/online 2>/dev/null)" == "1" ]] && return 0
        return 1
    fi

    # 3. Fallback: Search all power supplies of type Mains
    local psy
    for psy in /sys/class/power_supply/*; do
        if [[ -f "$psy/type" && -f "$psy/online" ]]; then
            if [[ "$(cat "$psy/type" 2>/dev/null)" == "Mains" ]]; then
                [[ "$(cat "$psy/online" 2>/dev/null)" == "1" ]] && return 0
            fi
        fi
    done

    # Default fallback: assume on battery (return 1) so sleep-on-demand remains active
    return 1
}

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
    # CPUQuota stays via systemd (only it understands the % syntax).
    # cpu.weight must be written before cpu.idle: SCHED_IDLE locks the
    # weight to 1 and rejects subsequent writes. systemctl-cached state
    # also drifts from the kernel, so direct writes are the source of
    # truth here.
    systemctl --user set-property "$(slice_unit_for "$proc")" \
        CPUQuota="${!quota}" 2>/dev/null || true
    echo "${!weight}" > "$dir/cpu.weight"     2>/dev/null || true
    echo "${!idle}"   > "$dir/cpu.idle"       2>/dev/null || true
    echo "${!uclamp}" > "$dir/cpu.uclamp.max" 2>/dev/null || true
    [[ -n "$cpus" ]] && echo "$cpus" > "$dir/cpuset.cpus" 2>/dev/null
    # Freeze last so any preceding writes still applied while running.
    [[ "$FREEZE_BG" == "1" ]] && echo 1 > "$dir/cgroup.freeze" 2>/dev/null
}
wake() {
    local dir; dir=$(slice_dir_for "$1")
    local cpus; cpus=$(cpus_for_tier FG)
    # Thaw first — frozen processes can't receive subsequent writes /
    # signals, and taskset would block. Idempotent if already thawed.
    echo 0 > "$dir/cgroup.freeze" 2>/dev/null || true
    systemctl --user set-property "$(slice_unit_for "$1")" \
        CPUQuota="$FG_CPUQUOTA" 2>/dev/null || true
    # Clear cpu.idle first so the SCHED_IDLE weight-lock releases, then
    # the cpu.weight write actually takes effect.
    echo "$FG_CPU_IDLE"   > "$dir/cpu.idle"       2>/dev/null || true
    echo "$FG_CPUWEIGHT"  > "$dir/cpu.weight"     2>/dev/null || true
    echo "$FG_UCLAMP_MAX" > "$dir/cpu.uclamp.max" 2>/dev/null || true
    if [[ -n "$cpus" ]]; then
        echo "$cpus" > "$dir/cpuset.cpus" 2>/dev/null
        # cgroup cpuset widening doesn't propagate to threads that are
        # currently blocked (they keep the narrower mask until next
        # schedule). Force-update each thread's affinity so the focused
        # app can immediately use all cores.
        local p
        while read -r p; do
            [[ -z "$p" ]] && continue
            taskset -apc "$cpus" "$p" >/dev/null 2>&1
        done < "$dir/cgroup.procs"
    fi
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

# The name helpers below return through $REPLY instead of stdout: they
# run once per PID on every discovery pass, and each $(...) is a fork.
# At ~200 PIDs the forks added up to 8-17 s per pass, during which the
# focus loop was blind and a frozen app could miss mutter's 5 s ping.
friendly_name_from_our_slice() {
    # "/…/sondemand-foo_bar.slice" or "sondemand-foo_bar.slice" → "foo-bar"
    local s=${1##*/}; s=${s%.slice}; s=${s#sondemand-}
    REPLY=${s//_/-}
}

ensure_slice() {
    local unit=$1
    systemctl --user -q is-active "$unit" 2>/dev/null && return 0
    # Transient scope inside the slice; the scope exits but the slice
    # persists, which is what we want.
    systemd-run --user --quiet --scope --slice="$unit" \
        --unit="cgcreate-$$-$RANDOM" -- /bin/true >/dev/null 2>&1 || true
}

# Ensure cpuset is propagated all the way down from user@.service to our
# sondemand.slice. systemd's Delegate=cpuset directive is supposed to
# populate user@.service/cgroup.subtree_control automatically on start,
# but on some distros / systemd versions it doesn't, leaving cpuset
# unavailable to descendants. Walk each level and add cpuset where it's
# missing. Idempotent: writing "+cpuset" to a subtree_control that
# already has it is a no-op.
enable_cpuset_subtree() {
    [[ "$PIN_MODE" == "NONE" ]] && return
    local f
    for f in \
        /sys/fs/cgroup/user.slice/user-$UID.slice/user@$UID.service/cgroup.subtree_control \
        "$SLICE_ROOT_DIR/cgroup.subtree_control"
    do
        [[ -w "$f" ]] || continue
        grep -qw cpuset "$f" 2>/dev/null && continue
        echo "+cpuset" > "$f" 2>/dev/null || true
    done
}

migrate_pids() {
    # Anchors PID identity to either /proc/$pid/exe (for chromium-family
    # apps) or the launching app.slice scope name. Also rectifies PIDs
    # that ended up in the wrong sondemand slice (e.g. a chrome PID in
    # sondemand-antigravity.slice — they share the chromium scope-name
    # space, so misclassification is easy).
    # One pass over every source cgroup for all managed apps at once;
    # the old one-pass-per-app walk was O(apps × PIDs).
    declare -A managed=()
    local proc
    for proc in "${PROCESSES[@]}"; do managed[$proc]=1; done

    # Pull from app.slice / session.slice / background.slice units that
    # resolve to a managed friendly name.
    local slice_root unit_dir p first dst
    for slice_root in "${DISCOVERY_SLICES[@]}"; do
        [[ -d "$slice_root" ]] || continue
        for unit_dir in "$slice_root"/*.scope "$slice_root"/*.service; do
            [[ -d "$unit_dir" ]] || continue
            # Already-drained scopes are the common case; skip them
            # before paying for name resolution.
            first=
            read -r first < "$unit_dir/cgroup.procs" 2>/dev/null
            [[ -z "$first" ]] && continue
            friendly_name_from_scope "${unit_dir##*/}" "$unit_dir" || continue
            [[ -n "${managed[$REPLY]}" ]] || continue
            dst="$SLICE_ROOT_DIR/sondemand-${REPLY//-/_}.slice"
            [[ -d "$dst" ]] || continue
            while read -r p; do
                [[ -z "$p" ]] && continue
                echo "$p" > "$dst/cgroup.procs" 2>/dev/null || true
            done < "$unit_dir/cgroup.procs"
        done
    done

    # Rectify: pull from sibling sondemand-*.slice any PID whose exe says
    # it actually belongs to another managed app. Limited to chromium-
    # family binaries — other apps have unambiguous scope→name mappings.
    # Rescue: same for cgroups outside our discovery walk — typically
    # chrome processes that gnome-shell or xdg-desktop-portal forked
    # directly instead of going through the app.slice scope launcher.
    local src
    for src in "$SLICE_ROOT_DIR"/sondemand-*.slice "${RESCUE_CGROUPS[@]}"; do
        [[ -d "$src" ]] || continue
        while read -r p; do
            [[ -z "$p" ]] && continue
            friendly_name_from_exe "$p" || continue
            [[ -n "${managed[$REPLY]}" ]] || continue
            dst="$SLICE_ROOT_DIR/sondemand-${REPLY//-/_}.slice"
            [[ "$dst" != "$src" && -d "$dst" ]] || continue
            echo "$p" > "$dst/cgroup.procs" 2>/dev/null || true
        done < "$src/cgroup.procs"
    done
}

# Walk app.slice / session.slice / background.slice for managed apps.
# Called at startup and periodically. Idempotent: existing slices are
# reused, existing PROC_STATE entries preserved.
USER_APP_SLICE=/sys/fs/cgroup/user.slice/user-$UID.slice/user@$UID.service/app.slice
USER_SESSION_SLICE=/sys/fs/cgroup/user.slice/user-$UID.slice/user@$UID.service/session.slice
USER_BG_SLICE=/sys/fs/cgroup/user.slice/user-$UID.slice/user@$UID.service/background.slice
DISCOVERY_SLICES=("$USER_APP_SLICE" "$USER_SESSION_SLICE" "$USER_BG_SLICE")

# Cgroups that aren't in DISCOVERY_SLICES but are known to occasionally
# host chromium-family PIDs (chrome forked directly by these services
# instead of through gnome-shell's normal app-launch path). migrate_pids
# walks these and rescues PIDs whose exe matches a managed app.
RESCUE_CGROUPS=(
    "$USER_SESSION_SLICE/org.gnome.Shell@x11.service"
    "$USER_SESSION_SLICE/xdg-desktop-portal.service"
)

# Map a PID's executable path to a stable friendly name for chromium-
# family apps that gnome-shell tends to bucket into ambiguous scopes.
# Returns non-zero if the binary doesn't match any known pattern.
# readlink is the one fork we can't avoid, so results are cached per PID,
# keyed on "<starttime> <comm>" from /proc/$pid/stat: starttime catches
# PID reuse, comm catches a wrapper script exec'ing the real binary.
declare -A EXE_NAME_CACHE=()   # pid -> "<starttime> <comm>|<name or empty>"
friendly_name_from_exe() {
    local pid=$1 stat key exe
    REPLY=
    [[ -n "$pid" ]] || return 1
    read -r stat < "/proc/$pid/stat" 2>/dev/null || return 1
    # stat is "pid (comm) state ppid ...": comm may contain spaces, so
    # split only after the last ')'. starttime is field 22 overall.
    local -a f
    read -ra f <<< "${stat##*) }"
    key="${f[19]} ${stat#*(}"; key=${key%)*}
    local hit=${EXE_NAME_CACHE[$pid]}
    if [[ -n "$hit" && "${hit%|*}" == "$key" ]]; then
        REPLY=${hit##*|}
    else
        exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
        exe=${exe% (deleted)}
        case "$exe" in
            */antigravity/*)             REPLY=antigravity ;;
            */google/chrome/*)           REPLY=chrome ;;
            /usr/lib/chromium*/*|/usr/bin/chromium*|/snap/chromium/*) REPLY=chromium ;;
        esac
        EXE_NAME_CACHE[$pid]="$key|$REPLY"
    fi
    [[ -n "$REPLY" ]]
}

prune_exe_cache() {
    local pid
    for pid in "${!EXE_NAME_CACHE[@]}"; do
        [[ -d "/proc/$pid" ]] || unset "EXE_NAME_CACHE[$pid]"
    done
}

friendly_name_from_scope() {
    # First try the main PID's binary — chrome / antigravity / chromium
    # all share the "app-org.chromium.Chromium-*.scope" naming on GNOME,
    # so we can't tell them apart by scope name alone. Falling back to
    # unit-name parsing handles every other app.
    # $1 = unit basename (e.g. app-gnome-cursor-1234.scope or
    # syncthing.service or tracker-miner-fs-3.service). $2 = optional
    # cgroup directory (so we can read the main PID's exe).
    local s=$1 cgdir=${2:-$USER_APP_SLICE/$1} n pid=
    s=${s//\\x2d/-}                       # systemd escapes hyphens
    read -r pid < "$cgdir/cgroup.procs" 2>/dev/null
    [[ -n "$pid" ]] && friendly_name_from_exe "$pid" && return 0
    REPLY=
    if   [[ "$s" =~ ^app-(.+)-[0-9]+\.scope$ ]]; then
        n=${BASH_REMATCH[1]}
        n=${n##*.}                        # last dotted component (org.foo.Bar -> Bar)
        n=${n#gnome-}                     # strip launcher prefix if present
        n=${n#flatpak-}
    elif [[ "$s" =~ ^snap\.([^.]+)\..+\.scope$ ]]; then
        n=${BASH_REMATCH[1]}
    elif [[ "$s" =~ ^(.+)\.service$ ]]; then
        n=${BASH_REMATCH[1]}
        n=${n##*.}                        # org.gnome.SettingsDaemon.X -> X
        n=${n%@*}                         # Shell@x11 -> Shell
    else
        return 1
    fi
    REPLY=${n,,}
}

discover() {
    declare -A seen=()
    local proc
    # Carry forward already-managed apps so that we keep flipping their
    # limits even after migrate_pids has emptied their original scope.
    for proc in "${PROCESSES[@]}"; do seen[$proc]=1; done

    # New units under app.slice / session.slice / background.slice.
    # We pick up both .scope (gnome-shell-launched apps) and .service
    # (user systemd services like syncthing, tracker-miner, codex-update).
    local slice_root unit_dir unit name pid comm
    for slice_root in "${DISCOVERY_SLICES[@]}"; do
        [[ -d "$slice_root" ]] || continue
        for unit_dir in "$slice_root"/*.scope "$slice_root"/*.service; do
            [[ -d "$unit_dir" ]] || continue
            unit=${unit_dir##*/}
            friendly_name_from_scope "$unit" "$unit_dir" || continue
            name=$REPLY
            # Filter by friendly name AND main PID's comm — comm gets
            # kernel-truncated to 15 chars so the regex needs both
            # forms to be safe.
            [[ "$name" =~ $NEVER_THROTTLE_REGEX ]] && continue
            pid= comm=
            read -r pid < "$unit_dir/cgroup.procs" 2>/dev/null
            [[ -n "$pid" ]] && read -r comm < "/proc/$pid/comm" 2>/dev/null
            [[ -n "$comm" && "$comm" =~ $NEVER_THROTTLE_REGEX ]] && continue
            seen[$name]=1
        done
    done

    # Recover in-flight apps already adopted in a prior session — their
    # app.slice scope has been drained. cgroup.procs reports stat-size 0
    # even when populated, so peek at the first line instead of `-s`.
    # Also pull exe-based names from each PID inside, so chromium-family
    # binaries that ended up in the wrong slice (e.g. chrome PIDs stuck
    # in sondemand-antigravity.slice) get a chrome.slice spawned and
    # migrate_pids can rectify them.
    if [[ -d "$SLICE_ROOT_DIR" ]]; then
        local slice_dir first p slice_name
        for slice_dir in "$SLICE_ROOT_DIR"/sondemand-*.slice; do
            [[ -d "$slice_dir" ]] || continue
            read -r first < "$slice_dir/cgroup.procs" 2>/dev/null || continue
            [[ -z "$first" ]] && continue
            friendly_name_from_our_slice "$slice_dir"
            slice_name=$REPLY
            # If the policy now forbids this name (regex strengthened
            # since the slice was created), thaw and skip it.
            if [[ "$slice_name" =~ $NEVER_THROTTLE_REGEX ]]; then
                echo 0 > "$slice_dir/cgroup.freeze" 2>/dev/null
                continue
            fi
            seen[$slice_name]=1
            while read -r p; do
                [[ -z "$p" ]] && continue
                friendly_name_from_exe "$p" && seen[$REPLY]=1
            done < "$slice_dir/cgroup.procs"
        done
    fi

    PROCESSES=( "${!seen[@]}" )
    for proc in "${PROCESSES[@]}"; do
        [[ -z "${PROC_STATE[$proc]}" ]] && PROC_STATE[$proc]=UNKNOWN
        # The slice's cgroup dir exists iff systemd has it realised, so
        # only shell out to systemctl for slices that are missing.
        [[ -d "$SLICE_ROOT_DIR/sondemand-${proc//-/_}.slice" ]] ||
            ensure_slice "$(slice_unit_for "$proc")"
    done
    prune_exe_cache
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
    # 1. exe-based lookup catches the chromium-family ambiguity
    #    (chrome and antigravity both have comm=chrome).
    # 2. Then sondemand-slice membership for everything else managed.
    # 3. Then comm for unmanaged windows (terminal, gnome-shell, etc).
    # Result in $REPLY (empty if the PID is gone).
    local pid=$1 line cg
    REPLY=
    [[ -n "$pid" && -d "/proc/$pid" ]] || return
    friendly_name_from_exe "$pid" && return
    read -r line < "/proc/$pid/cgroup" 2>/dev/null
    cg=${line#*::}
    if [[ "$cg" == *"/sondemand.slice/sondemand-"*".slice" ]]; then
        friendly_name_from_our_slice "$cg"
        return
    fi
    read -r REPLY < "/proc/$pid/comm" 2>/dev/null
}

# ─── Focus state machine ─────────────────────────────────────────────
# PROC_STATE: UNKNOWN → FG / BG. With FREEZE_BG=1 a BG app can also go
# to THAWED: still throttled, but runnable (see apply_focus_state).
declare -A PROC_STATE  # populated by discover()

# Focus owners that are the compositor itself rather than an app.
SHELL_FOCUS_REGEX='^(gnome-shell|mutter)$'

apply_focus_state() {
    local focused=$1
    local on_ac=0
    if is_on_ac; then
        on_ac=1
    fi

    # Mutter pings a window when it gains focus and shows "not
    # responding" if there's no reply within check-alive-timeout (5 s).
    # Once that dialog is up it owns focus, _NET_ACTIVE_WINDOW goes to
    # 0 and we'd never see the frozen app become active, so it would
    # never be thawed. Same for the overview: the user is about to pick
    # an app we can't identify yet. So when focus sits on the shell (or
    # on nothing), thaw every frozen app while keeping its throttles;
    # the ping is answered, the dialog goes away, and the next real
    # focus change re-freezes whatever stays in the background.
    local shell_focus=0
    if [[ "$FREEZE_BG" == "1" ]] &&
       [[ -z "$focused" || "$focused" =~ $SHELL_FOCUS_REGEX ]]; then
        shell_focus=1
    fi

    for PROC in "${PROCESSES[@]}"; do
        if (( on_ac )) || [[ "$PROC" == "$focused" ]]; then
            if [[ "${PROC_STATE[$PROC]}" != "FG" ]]; then
                wake "$PROC"
                if (( on_ac )); then
                    echo "FG: $PROC (unthrottled via AC)"
                else
                    echo "FG: $PROC (unthrottled via Focus)"
                fi
                PROC_STATE[$PROC]="FG"
            fi
        elif (( shell_focus )); then
            [[ "${PROC_STATE[$PROC]}" == "FG" ]] && continue
            # Also covers UNKNOWN slices left frozen by a killed run.
            echo 0 > "$(slice_dir_for "$PROC")/cgroup.freeze" 2>/dev/null || true
            if [[ "${PROC_STATE[$PROC]}" == "BG" ]]; then
                echo "THAW: $PROC (shell has focus; still throttled)"
                PROC_STATE[$PROC]="THAWED"
            fi
        else
            case "${PROC_STATE[$PROC]}" in
                BG) ;;
                THAWED)
                    # Throttles from the earlier park() are still in
                    # place; only the freeze needs restoring.
                    echo 1 > "$(slice_dir_for "$PROC")/cgroup.freeze" 2>/dev/null
                    echo "BG: $PROC (re-frozen)"; PROC_STATE[$PROC]="BG" ;;
                *)
                    park "$PROC"; echo "BG: $PROC (throttled)"; PROC_STATE[$PROC]="BG" ;;
            esac
        fi
    done
}

# ─── Main ────────────────────────────────────────────────────────────
detect_topology
resolve_pin_mode

# Order matters: create our parent slice and push cpuset down through
# user@.service AND sondemand.slice BEFORE the delegation check, so
# the check sees the freshly-enabled controller and AUTO mode doesn't
# fall back to NONE on every boot.
ensure_slice "$SLICE_PARENT_NAME"
enable_cpuset_subtree
check_cpuset_delegation
echo "PIN_MODE=$PIN_MODE"

discover
echo "discovered: ${PROCESSES[*]}"
migrate_pids
LAST_DISCOVERY=$(date +%s)

is_on_ac && LAST_AC_STATUS=1 || LAST_AC_STATUS=0
echo "Initial power state: AC online=$LAST_AC_STATUS"

LAST_WID=
refresh_focus() {
    local wid pid
    # Prefer EWMH _NET_ACTIVE_WINDOW (the WM's notion of the active app)
    # over X11 input focus. On GNOME-on-X11, XGetInputFocus often
    # returns the gnome-shell stage window when the user has focused a
    # real app, which makes the script think gnome-shell is foreground
    # and never wake the actual app. Fallback to getwindowfocus only if
    # _NET_ACTIVE_WINDOW is unset or 0 (some compositors leave it blank).
    wid=$(xdotool getactivewindow 2>/dev/null)
    [[ -z "$wid" || "$wid" == "0" ]] && wid=$(xdotool getwindowfocus 2>/dev/null)
    [[ -z "$wid" ]] && return
    [[ "$wid" == "$LAST_WID" ]] && return
    LAST_WID=$wid
    REPLY=
    pid=$(xdotool getwindowpid "$wid" 2>/dev/null) && pid_to_proc_name "$pid"
    # An unattributable window only matters when something may be frozen
    # behind it (apply_focus_state treats it like shell focus).
    [[ -z "$REPLY" && "$FREEZE_BG" != "1" ]] && return
    apply_focus_state "$REPLY"
}

refresh_focus            # seed initial state

# Plain poll loop. Tried xprop -spy on _NET_ACTIVE_WINDOW for snappier
# wake-up, but mutter on some GNOME/X11 setups leaves that property at
# 0x0 indefinitely, so events never fire. Polling at POLL_INTERVAL_SEC
# is the authoritative source; xdotool getwindowfocus uses XGetInputFocus
# which actually tracks focus on those setups.
while true; do
    sleep "$POLL_INTERVAL_SEC"

    current_ac=0
    if is_on_ac; then
        current_ac=1
    fi

    if [[ "$current_ac" != "$LAST_AC_STATUS" ]]; then
        echo "Power state transition: AC online=$current_ac (was $LAST_AC_STATUS)"
        LAST_AC_STATUS=$current_ac
        LAST_WID= # Force refresh_focus to run apply_focus_state
    fi

    refresh_focus
    now=$(date +%s)
    if (( now - LAST_DISCOVERY >= DISCOVERY_INTERVAL_SEC )); then
        discover
        migrate_pids
        LAST_DISCOVERY=$now
    fi
done
