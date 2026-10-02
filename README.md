# touchbar-interface

A personal interface to the Touch Bar of one MacBook Pro (13", M1, macOS 14): a small, lightweight base for putting things on the Touch Bar and controlling it from scripts, tools and other projects. Touch Bar only; it is meant to be built on.

## Goals

- **Keep what is already there.** Apple's real control strip stays on the right, untouched; our items live between it and the esc button. No imitation buttons, no bloat.
- **Add our own buttons**, driven by scripts and services (first: a Microsoft Teams mute button that shows the real mute state).
- **Push from the command line and tmux** (alerts and status), without polling hacks.
- **Slim, native, no Rosetta, no Xcode, no auto-updaters.** Everything repeatable and documented.

## Status

| Part | State |
|---|---|
| Native arm64 build of [MTMR](https://github.com/Toxblh/MTMR) | Working, runs on the Touch Bar. Rebuild with `mtmr/build.sh`. |
| Teams mute control (debug-port method) | Proven in a live call. Code in `teams/`, see `docs/runbook-teams-debug.md`. |
| Touch Bar service (state in, buttons out) | Not started. |
| CLI/tmux alerts | Not started. |

## Layout

```
mtmr/
  build.sh        reproducible native build of MTMR (Command Line Tools only)
  patches/        our changes to upstream MTMR, as patch files
  overlay/        files added to the upstream sources (entry point, image loader, Info.plist)
teams/
  teams-cdp.py          one-shot Chrome DevTools Protocol client (Python standard library only)
  teams-mute            status | toggle | mute | unmute | discover
  teams-debug-launch.sh manual launcher with the debug flag (fallback)
  launchd/              LaunchAgent that makes every Teams launch open the debug port
experiments/            throwaway layouts and scripts used to test Touch Bar patterns
docs/
  runbook-build-mtmr.md   build, run, config, troubleshooting
  runbook-teams-debug.md  Teams debug port, mute control, LaunchAgent
  findings.md             everything learned about the Touch Bar, MTMR and Teams
build/            build output (git-ignored)
```

## Quick start

```bash
git clone https://github.com/Toxblh/MTMR.git ../MTMR && git -C ../MTMR checkout 94fc98cceff94cf69a2e7c28f726cf35ab93c461
mtmr/build.sh
open build/MTMR.app
```

Details, permissions and troubleshooting: [docs/runbook-build-mtmr.md](docs/runbook-build-mtmr.md).

## Rules for working in this repo

- **Document findings as they are made** in `docs/findings.md`: say how each fact was established (verified on the machine, read in source, or unverified).
- **Back up before changing anything** on the machine (configs, LaunchAgents, settings), and keep changes reversible.
- **No Rosetta 2, no Intel-only binaries, ever.**
- Upstream code (the MTMR clone) is never edited in place; changes live here as patches and overlays.
