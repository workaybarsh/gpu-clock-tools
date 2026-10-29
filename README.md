# gpu-clock-tools

Two small, dependency-free Windows tools for keeping an NVIDIA card at a
sane, sustained clock instead of letting it run wide open 24/7.

| Tool | What it does |
|------|--------------|
| **`tuner/gpu-tune.ps1`** | Finds the highest **safe** clock for a temperature target by measuring the card, then locks it. |
| **`watchdog/gpu-clock-watchdog.ps1`** | Holds a clock ceiling **while a GPU workload is running** and releases it when the work stops. |

They are independent - each works on its own - but they work best together.

```text
tuner:     measure the card  ->  find the safe clock  ->  write gpu-profile.json
                                                                    |
watchdog:  read the profile  ->  detect GPU work  ->  hold the ceiling
                                 ->  work stops  ->  release + exit
```

> ## ⚠️ Disclaimer
>
> **You are responsible for your own hardware. If anything happens to your card,
> we accept no liability.**
>
> These tools change clock limits on your GPU at your own risk. They come with
> no warranty of any kind. Verify temperatures yourself, know your hardware, and
> read the full text in [DISCLAIMER.md](DISCLAIMER.md) before using them.

---

## Requirements

- Windows 10 / 11
- NVIDIA GPU with a driver installed (`nvidia-smi` lives in `C:\Windows\System32`)
- **Volta or newer** for clock locking - GTX 10 series and older are not supported
- Administrator rights (reads work without, writes do not)
- PowerShell 5.1+ (built into Windows)

---

## Quick start

### Watchdog (the usual daily use)

1. Edit the `SETTINGS` block at the top of `watchdog/run.bat`
2. Double click it (it asks for administrator rights itself)

It will detect whatever is using the GPU, hold the clock ceiling while it runs,
and release it when the work ends.

```powershell
# auto-detect the GPU consumer, use the clock from gpu-profile.json
.\watchdog\gpu-clock-watchdog.ps1

# explicit values
.\watchdog\gpu-clock-watchdog.ps1 -TargetClock 1900
.\watchdog\gpu-clock-watchdog.ps1 -Percent 76

# force a specific process to be the workload
.\watchdog\gpu-clock-watchdog.ps1 -Percent 76 -ProcessName YOUR_MINER

# hold while *any* GPU load exists, no process tracking
.\watchdog\gpu-clock-watchdog.ps1 -LoadOnly -LoadThreshold 30
```

### Tuner (find the right value once per card)

**Run this while your workload is already running** - the tuner measures real
thermal behaviour, so an idle card would simply look "already cool enough".

```powershell
.\tuner\gpu-tune.ps1 -Mode Detect          # card, architecture, support (read-only)
.\tuner\gpu-tune.ps1 -Mode Auto -TargetTemp 65
```

`Auto` steps the clock down 100 MHz at a time until the card sits at or below
the target, then steps back up 50 MHz to find the highest acceptable point. It
takes 5-10 minutes, writes the result to `gpu-profile.json`, and then
**hands over to the watchdog** so the found clock is held while the work
continues and released when it stops.

If you would rather just set the ceiling yourself and skip the search:

```powershell
.\tuner\gpu-tune.ps1 -Mode Percent -Percent 76     # try 76% right away, then watch
.\tuner\gpu-tune.ps1 -Mode Fixed -Clock 1900
```

Main tuner options:

| Option | Default | Meaning |
|--------|---------|---------|
| `-Mode` | `Detect` | `Detect`, `Status`, `Auto`, `Fixed`, `Percent`, `Clear` |
| `-TargetTemp` | `65` | Temperature goal for `Auto` |
| `-MaxTemp` / `-MaxFan` | `80` / `85` | Emergency ceilings |
| `-StepCoarse` / `-StepFine` | `100` / `50` | Search step sizes in MHz |
| `-SettleSeconds` / `-StepSeconds` | `90` / `120` | How long to wait at stock / per step |
| `-After` | `Watch` | `Watch` hands over to the watchdog, `Keep` leaves the lock, `Release` drops it |
| `-DryRun` | | Never write to the GPU |

---

## Install (optional, one click)

The repo works as-is: double click `launch.bat`. If you want it in the Start
menu like a normal app:

```text
install.bat            -> copies to %LOCALAPPDATA%\gpu-clock-tools\app
                          and adds "GPU Clock Tools" to the Start menu
install.bat -Desktop   -> also adds a desktop shortcut
```

`launch.bat` is the one-click menu: detect, auto tune, watchdog, clear, status.

### Removal with no trace

```text
uninstall.bat          -> stops running instances, releases any clock lock,
                          deletes the shortcut, the profile and the app folder
```

After that run **nothing** is left behind: no scheduled tasks, no services, no
registry entries, no autostart. The only thing an uninstall cannot undo is the
driver's own behaviour, which is out of this tool's control.

---

## How the watchdog detects the workload

This is the interesting part. Three options, best one is automatic:

| Method | How | Use when |
|--------|-----|----------|
| **Auto** (default) | Samples the Windows **GPU Engine** performance counters, groups utilization by PID, picks the top consumer | Almost always |
| `-ProcessName` | Watches named processes | A launcher spawns the real worker, or you want it explicit |
| `-LoadOnly` | Watches total GPU utilization only | Any workload, no process identity needed |

Auto mode uses `\GPU Engine(*)\Utilization Percentage`, whose instances look
like `pid_12345_luid_0x..._eng_0_engtype_3d`. Summing those per PID gives a real
per-process GPU utilization on Windows, which `nvidia-smi` does **not** provide
(`--query-compute-apps` lists every process with a graphics context, including
Explorer and the Start menu, and reports `[N/A]` for memory on GeForce cards).

If the top consumer changes - the miner restarts, a new PID appears - the
watchdog picks up the new one on the next poll.

---

## Where the clock value comes from

First match wins:

1. `-TargetClock <MHz>`
2. `-Percent <n>` - percentage of the card's maximum clock
3. `gpu-profile.json` written by the tuner

Default location: `%LOCALAPPDATA%\gpu-clock-tools\gpu-profile.json`

---

## Lock life cycle

| Event | Watchdog | Tuner (`-After Watch`, default) |
|-------|----------|-------------------------------|
| Workload ends | **Released** (`-rgc`) and exits | **Released** (handed to the watchdog) |
| Ctrl+C / window closed | Released | Released |
| `-KeepLock` passed | Kept | - |
| `-After Keep` | - | Kept until `-Mode Clear` |
| `-Mode Clear` | - | Released |
| Sleep (S3) | Re-applied within `RefreshSeconds` | Same (watchdog re-applies) |
| Reboot / shutdown | Lost (driver memory) | Lost |
| Driver update / TDR | Re-applied while running | Re-applied while running |

Nothing is written to disk except `gpu-profile.json`. Nothing starts at boot.

---

## Safety behaviour

Both tools lower the clock further if the card gets too hot:

| Trigger | Action |
|---------|--------|
| Temperature >= `MaxTemp` (80 C) | Cut another `SafetyStep` MHz |
| Fan >= `MaxFan` (85%) | Cut another `SafetyStep` MHz |
| Failure to apply the lock | Report and stop, leaving the card alone |

Neither tool ever sets a clock above the card's maximum.

---

## Supported cards

| Card | Clock lock |
|------|------------|
| GTX 16 series, RTX 20 / 30 / 40 / 50 desktop | Yes |
| Tesla / Quadro / RTX Pro, Volta and newer | Yes |
| GTX 10 series (Pascal) - 1050/1060/1070/1080, GT 1030 | **No** |
| GTX 900 / 700 (Maxwell / Kepler) | **No** |
| Pre-Volta Tesla / Quadro (P100, P4000, M40) | **No** |
| Laptop dGPUs | Usually yes, OEM power management may override |
| RTX 50 (Blackwell) | Accepted, but arbitration may keep the card lower |
| MIG-enabled A100/H100 | Yes, applied to the whole GPU |
| vGPU guest, WSL2, Jetson | **No** |
| AMD / Intel | **No** - `nvidia-smi` does not exist there |

Run `gpu-tune -Mode Detect` first: it reports the architecture and a support
verdict without writing anything.

---

## Troubleshooting

**"The current user does not have permission to change clocks"**
Not elevated. The `run.bat` launchers self-elevate; from a shell, start it as
administrator.

**"Setting locked GPU clocks is not supported for GPU ..."**
Pre-Volta card, or a locked-down laptop/vGPU. Nothing to do; use vendor tools.

**The command succeeds but the clock does not change**
Power/thermal arbitration won. Check that no other tuning tool (MSI Afterburner,
NVIDIA App tuning) is writing to the same NVML path - last writer wins.

**The watchdog exits immediately**
It found no GPU work for `MissLimit` polls. Either the workload is not running or
it uses less GPU than `-LoadThreshold`. Lower the threshold or pass
`-ProcessName`.

**The tuner says "no lock needed"**
The card is already at or below `TargetTemp` under the current load. Use a lower
target if you want a cooler card.

---

## License

MIT - see [LICENSE](LICENSE).
