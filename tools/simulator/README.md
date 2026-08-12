# BaseOS simulator

Boots the whole system outside Minecraft so a change can be verified in seconds
instead of a world reload. It runs the *real* project files under a real Lua 5.4
VM ([wasmoon](https://www.npmjs.com/package/wasmoon)) against a mocked
ComputerCraft: Tweaked API.

Nothing in this folder is copied to the computer in game.

## Usage

```bash
cd tools/simulator
npm install
npm test                                 # run every scenario
node run.js                              # dashboard walkthrough on an 82x25 monitor
node run.js scenarios/farm.lua           # real farm module against a real barrel
node run.js scenarios/power.lua          # many energy devices + the list pager
node run.js scenarios/resilience.lua     # no monitor + forced alert
node run.js scenarios/modal.lua          # confirm dialog + log viewer
node run.js scenarios/installer.lua      # install from a fake GitHub, then boot
node run.js scenarios/updater.lua        # full update cycle, including the prompt
node run.js scenarios/render.lua         # print one frame, for eyeballing layout
MAX_EVENTS=200 node run.js               # let the scheduler run longer
SNAPSHOT=3 node run.js                   # print only the third snapshot
MONITOR_W=57 MONITOR_H=24 node run.js scenarios/render.lua   # 3x2 monitor
```

Every scenario fails (non-zero exit) if the log contains an `[ERROR]` line, so
they double as a regression check. `dashboard.lua` additionally asserts the
result of each interaction, and locates buttons **by label**: a layout change
moves the touch instead of silently missing it.

## What the mock covers

`fs`, `term`, `window`, `peripheral`, `colors`, `textutils`, `os` (timers,
events, epoch, computer id), a stub `rednet` and `shell`. Virtual time only
advances when the code asks for it (`os.epoch`), so a run of ~100 events covers
roughly half a minute of simulated uptime.

## What it does *not* cover

* Real mod peripherals. The mock provides a monitor, redstone and an output
  barrel that fills while its control side is powered (enough to drive the farm
  module end to end); adapters for ME Bridge, Powah and friends must still be
  verified in game.
* Exact `window` blitting and colour output - the mock writes straight through
  to the parent terminal and records characters only, not colours.
* Rednet between computers.

## Adding a scenario

Drop a `.lua` file into `scenarios/`. Useful helpers exposed by the mock:

| Helper | Purpose |
| --- | --- |
| `__TEST.ui.touch("STOP")` | a touch on the component with that label |
| `__TEST.ui.back()` | a touch on the header back button |
| `__TEST.ui.screenName()` | which screen is on top of the stack |
| `__TEST.injectAt(eventIndex, producer)` | deliver `producer()`'s event as the Nth event |
| `__TEST.errors()` | failures inside scenario hooks (BaseOS would hide them) |
| `__TEST.crashed()` | true if startup.lua printed its crash banner |
| `__TEST.touchAt(eventIndex, x, y)` | deliver a `monitor_touch` as the Nth event |
| `__TEST.queueEventAt(eventIndex, name, ...)` | deliver an arbitrary event |
| `__TEST.detach(name)` | remove a peripheral and fire `peripheral_detach` |
| `__TEST.removePeripheral(name)` | remove a peripheral before boot |
| `__TEST.snapshots()` | captured monitor/terminal frames |
| `__TEST.files` | the virtual filesystem, including `data/baseos.log` |
| `BASEOS.loaded["core.scheduler"]` | any loaded BaseOS module, for assertions |
