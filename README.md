<img src="assets/dranik-logo.svg" width="132" align="right" alt="">

# dranik-battery

[![CI](https://github.com/tmaxell/dranik-battery/actions/workflows/ci.yml/badge.svg)](https://github.com/tmaxell/dranik-battery/actions/workflows/ci.yml)

Keeps a Mac laptop's battery below a chosen charge level, so it does not spend
months sitting at 100 %. A root daemon, a command-line client and a menu bar app,
with no dependencies beyond the system frameworks.

A *dranik* is a fried potato pancake. The one in the mark is browned to 80 % and
no further, which is the whole idea.

```
$ dranik daemon
  Limit           75–80 %
  Gate            closed
  Reason          charge 80% reached the 80% limit
  Charger says    inhibited
  Sleep policy    holdLimit
  Thermal cutoff  40 °C
```

## Status

Working and in daily use. The gate closes, current falls to zero, and the
hardware confirms the inhibit with its own flag rather than the software taking
its own word for it.

Two multi-day soak runs have each found real defects — a watchdog that reopened
the gate after every sleep, and a pair of unrelated verification hiccups that
disabled charge limiting for two days. Both are fixed, and both are now regression
tests. See `dranik soak`.

## Requirements

| | |
|---|---|
| Hardware | Apple Silicon Mac. Intel is not supported and is not planned |
| macOS | 14.0+ |
| Build | Swift 6 from Command Line Tools, or Xcode. `swift-tools-version: 5.10` builds under either |

Xcode is not required for anything, including the menu bar app: SwiftUI ships in
the Command Line Tools SDK, and the app bundle is assembled from an `Info.plist`
and one binary.

## Install

```bash
make install
```

Not under `sudo` — the target elevates only the install script. The script
refuses to install on a machine where it cannot find a charge-control key it
recognises.

The default is a limit of 80 % resuming at 75 %.

```bash
make uninstall
```

Stops the daemon, waits for the hardware to react, **verifies the gate is open**,
and refuses to remove anything if it is not.

## Use

```bash
dranik daemon              # what the daemon is doing right now
dranik limit 75            # change the limit without restarting anything
dranik limit 80 70         # limit and resume point
dranik off                 # stop managing charging
dranik retrust             # trust the gate again after a failed verification
dranik status              # battery state; needs no daemon
dranik soak --since 24h    # did the daemon behave over the last day
make logs                  # follow its decisions
```

Settings live in `/Library/Application Support/dranik/config.json`; after editing
it, run `dranik reload`.

| Key | Meaning |
|---|---|
| `upperLimit` | 50–100. Exactly 100 means "do not manage charging at all" |
| `lowerLimit` | The level at which charging resumes. The band is what stops the gate flapping |
| `thermalCutoff` | °C above which charging is held off |
| `sleepPolicy` | `holdLimit`, `allowCharge` or `chargeIfLow` — see below |
| `preventIdleSleepWhileCharging` | Hold off idle sleep while charging towards the limit. Off by default |

### The menu bar app

```bash
make install-app     # into /Applications, started at login
make app-run         # just run the build from .build, installing nothing
make uninstall-app   # remove the app; the daemon is left alone
```

One status item and one popover: the charge with the limit marked on it, one
sentence saying why the machine is or is not charging, a slider and a switch.
Everything else stays in the CLI on purpose.

The app needs no root, no Developer ID and no Xcode. The daemon already opened
its socket to the `admin` group, so the app talks to it as an ordinary user
process. All of the logic stays in the daemon — the app only displays and asks.

```bash
DranikApp --check    # what the app can see right now, as text
```

### What happens during sleep

The daemon does not run while the machine sleeps, and the gate's position
survives sleep — both measured. So whatever the daemon leaves behind is what the
machine does all night, and there is no option that costs nothing:

| `sleepPolicy` | Overnight | The cost |
|---|---|---|
| `holdLimit` (default) | Gate closed | A lidded laptop on a charger **will not charge** |
| `allowCharge` | Gate open | Charges to 100 %; the limit does not apply overnight |
| `chargeIfLow` | Closed unless already below the resume point | A flat battery charges, possibly past the limit |

`holdLimit` is the default because a default should do exactly what the limit
promises.

**One caveat, established by measurement.** macOS very often does not announce
that it is going to sleep: over ten hours of use, 8 announced sleeps against 31
unannounced ones, median fifteen minutes each. The daemon learns about that kind
of sleep only afterwards, on waking.

In practice `holdLimit` closes the gate **when it gets the chance**. If the
machine sleeps unannounced while the battery is charging inside the band, it can
end up above the limit — bounded by how long it slept. If the gate was already
closed when sleep began, nothing is lost: that state survives.

If this matters to you, turn on `preventIdleSleepWhileCharging`: the machine will
not fall asleep through idleness while charging towards the limit. Closing the
lid will still put it to sleep.

### Checking it over time

`dranik daemon` answers "what now". But a charge limiter is a thing that has to
keep working, and some of its failures are visible only across an interval. A
watchdog that reopened the gate after every sleep was invisible at any single
moment; it turned up while reading three days of logs at once.

```bash
dranik soak --since 3d
```

It reads the daemon's own records and gives a verdict: how often the gate moved,
how many restarts there were, whether the watchdog fired, how many verification
checks passed against how many failed, and whether the daemon stopped trusting
the gate. Non-zero exit if it finds something serious.

Note that the window is bounded by what the system log still holds, which is
usually shorter than a week. The report prints the span it actually covered.

## Safety

The only real risk is leaving the gate shut and walking away. Against that:

- Below 20 % the gate opens **unconditionally**, whatever the limit, the
  temperature, or anything else says.
- A reading older than 90 seconds counts as no reading at all — the gate opens.
- `SIGTERM` opens the gate before exiting.
- A watchdog on a separate SMC connection catches a wedged controller, opens the
  gate, and exits non-zero so launchd restarts it.
- If verification contradicts a write twice in a row and close together, charge
  limiting is switched off and said loudly: `fault` in the log, in
  `dranik daemon`, and in the popover. Coming back is `dranik retrust` — a
  deliberate act, never a timer, because a limit that silently does nothing is
  worse than no limit.
- The daemon re-reads the gate's actual position **before every decision** rather
  than trusting its own memory.
- After a write it checks that the hardware really reacted, using the charger's
  own flag rather than reading the key back.
- **A reboot always clears the gate** — measured. The worst case is bounded by
  one restart.

If something goes wrong:

```bash
dranik off              # stop limiting
sudo make uninstall     # remove it entirely
sudo reboot             # clears the SMC regardless
```

## How it works

On Apple Silicon, charging is controlled by the SMC. Some firmware exposes a
hardware limit key (`CHWA`); this project does not rely on one, because it is
absent on plenty of machines — `dranik status` reports whether yours has it. The
threshold is held by the daemon instead: it closes and opens the software charge
gate (`CHTE`, or `CH0B`/`CH0C` on older firmware) as the charge crosses the edges
of the band. Which keys exist is decided by probing at runtime, with the whole
`KeyInfoData` validated against a known-good reference — never by assuming a chip
generation.

```
Sources/
  CDranikSMC/       SMCParamStruct layout in C — the compiler guarantees it
  CDranikPower/     Power message constants, derived from Apple's headers by the preprocessor
  DranikSMC/        AppleSMC access: probing, reading, guarded writes
  DranikPower/      Public IOKit: battery snapshots, power events with no polling loop
  DranikCore/       Decisions. No IOKit, no clock, no filesystem — which is why it is testable whole
  DranikDaemon/     The daemon: controller, actuator, watchdog, control socket
  DranikApp/        The menu bar app. Decides nothing; displays only
  dranik/           CLI
  dranikd/          Daemon entry point
tools/              The measurement tools the facts above came from
assets/             Logo and app icon: one SVG each, and the .icns built from them
```

The daemon is event-driven: `notify(3)` for charge and power-source changes,
`IORegisterForSystemPower` for sleep and wake, and a long-interval safety net
rather than a polling loop. Idle cost, measured over a week of uptime: about 1.6
seconds of CPU per day for the daemon and 4.7 for the app.

## Development

```bash
make build
make test              # 224 tests, 703 assertions
make ui-drill          # the app against a daemon that misbehaves on purpose
make ui-snapshots      # render every popover state to PNG, light and dark
make daemon-dry-run    # the whole decision cycle, writing nothing
make icon              # re-render the .icns after editing the artwork
make test-ci           # the suite minus the groups that need this machine
```

Every push builds on GitHub Actions: compile, the suite, the UI drill, and the
app bundle, which is uploaded as an artifact. CI runs `make test-ci` rather than
`make test` — three test groups read the SMC and the battery of the machine they
run on, and "a charge gate is detected" is an assertion about *this* hardware.
On a builder without one it would fail while saying nothing about the code.

The app icon is committed as `assets/Dranik.icns`, so building the app never
needs a renderer. `make icon` regenerates it from `assets/dranik-icon.svg` and is
the only thing here that wants a non-system tool (`rsvg-convert`).

`make ui-drill` starts a real control server on a temporary socket and feeds the
app reports a healthy daemon will not produce — a gate it no longer trusts,
hardware with no gate at all, a stale reading, a socket it cannot open — then
reads back what the app made of each. A test cannot look at a screen; it can look
at text.

`make ui-snapshots` renders the popover into an off-screen window and saves each
state as an image, including the switch and the slider, which SwiftUI's own
`ImageRenderer` replaces with placeholders. It is the only way to look at "the
gate stopped responding" without waiting for it to actually happen.

The test suite is an ordinary executable rather than `swift test`: XCTest lives
in Xcode, and it cannot be imported when `xcode-select` points at the Command
Line Tools. The assertions are named after XCTest's so that moving over would be
mechanical.

No test changes SMC state. The ones that try to write assert that the guards
refuse **before** anything reaches the kernel.

## Prior art

Several projects solve the same problem, and reading them was worth more than
copying them would have been: [AlDente](https://github.com/AppHouseKitchen/AlDente-Charge-Limiter),
[Battery Toolkit](https://github.com/mhaeuser/Battery-Toolkit),
[BatFi](https://github.com/rurza/BatFi) and [batt](https://github.com/charlie0129/batt).
The techniques taken from them — probing keys instead of assuming them,
validating a key's full descriptor before writing, and the handling of sleep and
wake — are noted in the source where they are used.

## Licence

[MIT](LICENSE). No code was taken from any of the projects above.
