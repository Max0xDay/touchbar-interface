# Ideas (ordered, nothing committed to build)

Ranked by value for a normal working day, then effort. Status: idea only. Nothing here is designed or built unless marked.

1. **Teams mic button** (fixed, right of our zone). Green unmuted, red muted, yellow unreadable, hidden outside a call, tap toggles. Mechanism proven (`teams/teams-mute`); experiment in `experiments/`.
2. **Shell and tmux alerts.** A finished or failed command shows a coloured, labelled button ("build ok", "tests failed"); tap clears it. Needs a small state file the shell writes and a script button reads (MTMR has no push interface).
3. **Session status light** (Copilot / Claude sessions: idle, working, waiting for input). Depends on what the cliui project can expose.
4. **tmux and kitty centre items** (per-app via `matchAppId`): new window, split, next/previous pane, copy mode. Calls `tmux` directly.
5. **Keep-awake toggle** (wakiewakie): shows on/off, tap flips.
6. **Meeting helper:** join the next meeting, time until it starts.
7. **`tools >` group** for rare actions: lock screen, clear clipboard, open repo in VS Code.
8. **Finder and VS Code centre items** (per-app): copy path, new file, build, test, git.

Shared building block for 1, 2, 3 and 5: "state in, coloured labelled button out". This is what the always-running service would provide.

## Your ideas

(add here)
