# sleep_ondemand

Throttles the desktop apps you're not using so they stop draining the battery
in the background. Whatever window has focus runs normally. Everything else is
slowed down with cgroup v2 until you switch back to it. On AC power it leaves
everything alone.

It started as a ~50-line loop that sent SIGSTOP to a fixed list of apps when
they lost focus, and SIGCONT when they got it back. That saved power, but
anything holding a connection open (Cursor's remote agent, Thunderbird's IMAP
IDLE) lost it every time, and switching back meant waiting for a reconnect.
These days background apps are slowed down instead of stopped. Stopping is
still there as an option, see [FREEZE_BG](#freeze_bg).

On my ThinkPad X1 Carbon Gen 12 (Core Ultra 7 165U), idle drain with Chrome
open went from about 10.3 W to 7.7-8.0 W. That's a single measurement, taken
with tighter quotas than the current defaults, so treat it as a rough number.

## How it works

Once a second it checks the active window (`_NET_ACTIVE_WINDOW`, via xdotool)
and works out which app it belongs to. So an app you switch to can stay
throttled for up to a second.

Every 30 seconds it scans the units in your systemd user session
(`app.slice`, `session.slice`, `background.slice`) and moves each app's
processes into a slice of its own:

```
user@1000.service/sondemand.slice/sondemand-chrome.slice
user@1000.service/sondemand.slice/sondemand-obsidian.slice
...
```

When an app loses focus, its slice gets:

- a `CPUQuota`, set through `systemctl --user set-property`
- a lower `cpu.weight` and `cpu.idle=1` (SCHED_IDLE), so any normal task preempts it
- a `cpu.uclamp.max` cap, hinting that it doesn't need a fast CPU
- `cpuset.cpus` limited to the E-cores, on Intel hybrid CPUs (see below)
- `cgroup.freeze=1`, only with `FREEZE_BG=1`

All of it is undone when the app gets focus back.

Desktop components are never throttled: gnome-shell, Xorg, pipewire, dbus,
the portals, ibus, the settings daemons, shells, ssh-agent, syncthing and a
few more. The list is `NEVER_THROTTLE_BUILTIN` near the top of the script.

Chromium-based apps can end up in scopes named after Chromium rather than the
app, so for Chrome, Chromium and Antigravity the script goes by
`/proc/<pid>/exe` instead. If you use another Chromium-based browser, add its
install path to `friendly_name_from_exe()`.

## Running it

You need:

- cgroup v2 and a systemd user session (any recent distro has both)
- an X11 session, since xdotool can't see native Wayland windows
- `xdotool`, plus `taskset` from util-linux if CPU pinning is on

`on_ac_power` is used for the AC check if it's installed. Otherwise the script
reads `/sys/class/power_supply` itself.

Run it as your normal user from a terminal in the desktop session:

```sh
./sleep_ondemand.sh
```

At startup it prints what it found (`discovered: ...`), and after that one
line per state change, like `BG: chrome (throttled)` or
`FG: cursor (unthrottled via Focus)`. Ctrl-C puts every slice back to normal.

A few settings can come from the environment:

```
FREEZE_BG=1                    also freeze background apps
PIN_MODE=LP_ONLY               where to pin background apps, see below
NEVER_THROTTLE_EXTRA='a|b.*'   regex of extra app names to leave alone
```

For example:

```sh
NEVER_THROTTLE_EXTRA='spotify|tracker-.*' FREEZE_BG=1 ./sleep_ondemand.sh
```

The rest (poll intervals, tier limits, which app goes in which tier) lives in
the config block at the top of the script.

## Tiers

Apps that keep a network connection alive need a little CPU in the background
to send heartbeats. Apps that don't can be squeezed harder. `APP_TIER` decides
which is which, and anything not listed there is LOOSE.

| tier  | CPUQuota | uclamp.max | apps                                 |
|-------|----------|------------|--------------------------------------|
| TIGHT | 10%      | 20%        | chrome, obsidian, masterpdf          |
| LOOSE | 15%      | 30%        | cursor, thunderbird-bin, antigravity |

`CPUQuota` is a percentage of one CPU.

## Pinning to E-cores

On Intel CPUs with P- and E-cores (detected through `/sys/devices/cpu_core`
and `/sys/devices/cpu_atom`), background apps can be kept off the P-cores so
those stay idle. The E-cores with the lowest max frequency are taken as the
LP E-cores. On Meteor Lake those are the two on the SoC tile.

`PIN_MODE` picks the policy:

```
AUTO        E_PLUS_LP on a hybrid CPU, NONE otherwise (default)
E_PLUS_LP   background apps on all E-cores, LP ones included
LP_ONLY     background apps on the LP E-cores only
ALL_ON_E    everything on E-cores, the focused app too
NONE        no pinning
```

Pinning needs the cpuset controller delegated to your user's systemd
instance. That takes root once:

```sh
sudo mkdir -p /etc/systemd/system/user@.service.d
sudo tee /etc/systemd/system/user@.service.d/delegate.conf <<EOF
[Service]
Delegate=cpu cpuset io memory pids
EOF
sudo systemctl daemon-reload
```

Then log out and back in. Without it the script prints a warning and runs with
`PIN_MODE=NONE`.

## FREEZE_BG

With `FREEZE_BG=1` background apps are also frozen through `cgroup.freeze`,
which is more or less SIGSTOP for a whole cgroup. Nothing in them runs until
you switch back. That saves the most power, but connections time out and apps
have to reconnect when you return. I turn it on when I'm walking away from the
laptop.

Mutter pings a window when it gets focus and shows "not responding" if the app
doesn't answer within 5 seconds. A frozen app can't answer, and once that
dialog has focus the app never looks focused, so it would never get thawed.
To avoid that, whenever the shell itself has focus (the overview, that dialog)
frozen apps are thawed but stay throttled, and get frozen again on the next
real focus change.

## Gotchas

- Check the `discovered:` line at startup. If the terminal or tmux you started
  the script from is listed, the script moves itself into that slice and ends
  up throttling itself, or freezing itself with `FREEZE_BG=1`. Snap's tmux
  does this, since it gets its own scope under `app.slice`. Add it to
  `NEVER_THROTTLE_EXTRA`. GNOME Terminal is fine.
- It also picks up systemd user services you run yourself, so exclude the
  ones that need full speed in the background.
- If the script gets SIGKILLed, the slices keep whatever limits they had. Run
  it again and Ctrl-C it to reset them.
- I've only run it on my own laptop: Ubuntu 24.04, kernel 6.17, GNOME on Xorg.
