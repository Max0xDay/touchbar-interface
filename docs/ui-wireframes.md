# UI wireframes

How we design Touch Bar layouts here: **draw it in ASCII first, agree it, then build it.** Only the big interactions get a flow; small buttons are just listed.

Status: **DRAFT** for review. Written 2026-10-02. **Settled and verified on the real bar: Apple's real control strip stays on the right, and our items live between MTMR's esc button and that strip** (`findings.md`, "KEY FINDING"). The strip is never imitated with MTMR buttons.

## Conventions

```
+----+  the physical Touch Bar, 1085 x 30 pt. In these drawings 1 character is about 11 pt (98 characters = the whole bar).
[ x ]   a normal button                      { x }   exists only under a condition (named next to the drawing)
[ x >]  opens a sub-bar (a "group")          >>>      the centre area scrolls sideways
|       a zone boundary (not drawn on the real bar)
```

Zones, left to right. This follows what MTMR can do (`findings.md` section 1): left items fixed, centre scrolls, right items fixed.

| Zone | Owner | Behaviour |
|---|---|---|
| LEFT | MTMR | fixed: `esc` |
| CENTRE | MTMR | scrolls; items can be limited to one app (`matchAppId`) |
| RIGHT of MTMR | MTMR | fixed, always visible: status and entry points |
| CONTROL STRIP | Apple (system) | brightness, volume, mute, Siri: the original look and feel, untouched |

## M0: main screen (no app-specific items)

```
+--------------------------------------------------------------------------------------------------+
|[esc]  | [ALL APPS]                               | {MIC} [tools >]   | [sun][vol][mute] [siri]   |
+--------------------------------------------------------------------------------------------------+
 LEFT    CENTRE                                     RIGHT               CONTROL STRIP (Apple)
```

- `ALL APPS` is a placeholder for whatever should always be in the centre.
- `{MIC}` appears only while you are in a Teams call (see the mic states below).
- Tap `[tools >]` -> screen T1.

## Centre by app (only the centre changes; left, right and Apple's strip stay put)

kitty has 8 buttons in the experiment, more than fit, so the centre scrolls (`>>>`; the first four are drawn):
```
+--------------------------------------------------------------------------------------------------+
|[esc]  | [ALL APPS][tmux][split][pane] >>>        | {MIC} [tools >]   | [sun][vol][mute] [siri]   |
+--------------------------------------------------------------------------------------------------+
```

Finder:
```
+--------------------------------------------------------------------------------------------------+
|[esc]  | [ALL APPS][FINDER][new][tag]             | {MIC} [tools >]   | [sun][vol][mute] [siri]   |
+--------------------------------------------------------------------------------------------------+
```

Teams:
```
+--------------------------------------------------------------------------------------------------+
|[esc]  | [ALL APPS][TEAMS][chat][cal]             | {MIC} [tools >]   | [sun][vol][mute] [siri]   |
+--------------------------------------------------------------------------------------------------+
```

VS Code:
```
+--------------------------------------------------------------------------------------------------+
|[esc]  | [ALL APPS][CODE][build][test][git]       | {MIC} [tools >]   | [sun][vol][mute] [siri]   |
+--------------------------------------------------------------------------------------------------+
```

Rule: switching apps swaps the centre items. Nothing else moves. Button names here are placeholders from experiment lab-1; the real set is still to be decided.

## T1: tools sub-bar (opens from `[tools >]`)

The sub-bar replaces the whole bar until closed.

```
+--------------------------------------------------------------------------------------------------+
| [tool 1][tool 2][tool 3]                                                                   [ X ] |
+--------------------------------------------------------------------------------------------------+
```

- Tap `[ X ]` -> back to the screen you came from.
- `tool 1..3` are placeholders. Nothing is decided about what lives here.

## Flow: Teams mic button (the one big interaction)

States of `{MIC}` (colours are MTMR background colours; the label also changes so the state is readable without colour):

| State | Looks like | When |
|---|---|---|
| hidden | nothing | not in a call |
| unmuted | green `[ MIC ]` | in a call, mic on |
| muted | red `[MUTED]` | in a call, mic off |
| unknown | yellow `[MIC?]` | Teams is running but its mute state cannot be read (debug port closed, selectors out of date) |

```
not in call --(join call)--> unmuted --(tap MIC)--> muted
                                ^                     |
                                +-----(tap MIC)-------+
any call state --(leave call)--> hidden
any state --(mute or unmute inside Teams)--> follows within the polling interval (1 s)
```

How it is built: an MTMR script button polls `teams/teams-mute status` every second; empty output hides the button; tap runs `teams/teams-mute toggle`. See `runbook-teams-debug.md`.

## Open questions for these drawings

1. The bar feels slightly janky (user report); find out whether it is rebuild-on-app-switch, script polling, or something else.
2. What goes in the centre for each app, and what goes under `[tools >]`?
3. Which other interactions deserve a flow like the mic button (alerts from tmux, for example)?
