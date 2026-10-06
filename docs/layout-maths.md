# Notification layout maths

Applies only when a `notification` item is present. Patch `0003-layout-solver.patch` replaces `0002`'s notification stack sizing with `NotificationLayoutView` and the AppKit-free `NotificationLayoutSolver`. Without a notification, `BasicView` keeps upstream's `NSStackView`, spacing and gestures; the scrolling-centre path is unchanged.

## Rules

- `W` is the single custom item's host bounds width at runtime, otherwise its view bounds width. Unavailable bounds use a tagged **1085 pt** initial/fallback estimate. The host is assumed to span the whole modal bar; physical verification is still needed.
- Re-solve on config reload (a new container) and on width changes. Notification text, arrival, expiry and selection are not solver inputs. Existing notification queue, socket and gestures are unchanged.
- All item heights are **30 pt**. Left/right items retain configured order and **8 pt** inter-item spacing. Left starts at `x = 0`; right ends at `x = W`.
- For either group, `groupWidth = sum(itemWidths) + 8 * max(0, count - 1)`. Call these `Lw` and `Rw`.
- Available notification width: `N = W - 2 * max(Lw, Rw) - 2 * padding`. Apply optional `maxWidth`; position at `x = (W - N) / 2`. Both bar-edge margins are `(W - N) / 2`, not the midpoint of the leftover gap between unequal groups.
- Text is centred inside the fixed notification frame. Its existing **12 pt inner label inset** is separate from the new outer `padding` option.

### Shrinking

Only start if the uncapped available notification width is below `minWidth`:

1. Shrink left buttons proportionally to their available reductions (`width - buttonMinWidth`). Stop as soon as `N >= minWidth`; if the unchanged right group prevents that, exhaust the left reductions first.
2. If still short, do the same for right buttons. If the left minima prevent reaching the target, exhaust the right reductions.
3. If still short, allow `N < minWidth`, normally no lower than **120 pt**, and log a warning. Logging happens once per width solve, not per text update.

Exit buttons never shrink. A spacer is a borderless blank button with no image, background or actions; it never shrinks. Widths without an explicit `width` use the view's fitting width captured when the container is created.

Widths/padding are rounded to whole points; notification minimum rounds up, cap rounds down. Reductions use largest fractional remainders, with configured order breaking ties. For integral `W`, choose the notification width with `W`'s parity, rounding down by at most one extra point, so its origin and margins are integral too. Fractional `W`, or a strict 120 pt cap on odd `W`, require fractional origins to preserve exact edges/centre and the floor; these choices are tagged.

Configured 3:1 / 2.5:1 button ratios are nominal: shrinking keeps height 30 and may drop below 2.5:1. This is intentional.

### Infeasible widths (tagged policy)

Fixed buttons, minimum button widths, two padding gaps and a 120 pt centre cannot fit every possible `W`. In that case:

- Reserve a centred 120 pt floor (121 on odd integral `W` when the cap permits it).
- Hide whole overflow items, retaining a fitting prefix at the left edge and suffix at the right edge. Never narrow an exit/spacer or go below a button's minimum.
- Reduce outer padding only if even the floor plus both padding gaps cannot fit.
- If `W < 120`, use `N = W` (rounded down for fractional widths) and hide edge items that cannot fit. No frame has negative width, lies outside the bar, or overlaps another visible frame.

This is an explicit last-resort interpretation of the otherwise impossible floor/tiny-width requirements, not a hardware observation.

## Options

All dimensions are points. `layouts/main.json` needs no changes.

| Where | Option | Default / rule |
|---|---|---|
| `notification` | `padding` | 16; finite, nonnegative outer padding |
| `notification` | `minWidth` | 240; finite, at least 120; starts the shrink stages |
| `notification` | `maxWidth` | No cap; finite, at least `minWidth` after rounding |
| Left/right item | `minWidth` | 60% of nominal width, rounded; explicit values are nonnegative, capped at nominal width; ignored for exits/spacers |

The cap/minimum validation is a tagged conservative choice: contradictory caps are rejected, not silently preferred. On odd `W`, an exact even cap equal to the minimum may lose one point for integral centring; the below-minimum warning still applies. Preset decoding otherwise keeps upstream's existing error behavior.

Example notification options:

```json
{"type":"notification","padding":16,"minWidth":240,"maxWidth":500}
```

Example button minimum:

```json
{"type":"staticButton","title":"","align":"left","width":75,"minWidth":50}
```

## Current `layouts/main.json`

Use the user-reported full bar width **1085 x 30 pt** as the solver test input; this new container has not been run on the real bar.

| Value | Calculation | Points |
|---|---|---:|
| `W` | Full bar width | 1085 |
| `Lw` | Exit 30 + spacer 1 + three icons `3 * 75` + four gaps `4 * 8` | 288 |
| `Rw` | Two temp buttons `2 * 100` + one gap 8 | 208 |
| `padding` | Default | 16 |
| `N` | `1085 - 2 * 288 - 2 * 16` | **477** |
| Left bar-edge margin | `(1085 - 477) / 2` | **304** |
| Right bar-edge margin | Same | **304** |
| Gap after left group | `304 - 288` | 16 |
| Gap before right group | `(1085 - 208) - (304 + 477)` | 96 |

Frames (`x`, `width`), all height 30:

```text
Left:         (0,30) (38,1) (47,75) (130,75) (213,75)
Notification: (304,477)                       centre X = 542.5
Right:        (877,100) (985,100)              last edge = 1085
```

The 1 pt spacer preserves the **17 pt** visual gap between exit and the first icon. The notification's margins to the **bar edges** are equal; its gaps to the unequal button groups are deliberately different.

## Worked shrink example: six left icons

Keep the exit, spacer and two right temp buttons; increase the left icons from three to six, still 75 pt each.

```text
W = 1085; padding = 16; notification minWidth = 240
Initial Lw = 30 + 1 + 6*75 + 7*8 = 537
Rw = 2*100 + 8 = 208
Initial N = 1085 - 2*537 - 32 = -21 (not a rendered frame)
Each icon minimum = round(75*0.6) = 45; total reduction capacity = 6*30 = 180
Target Lw <= floor((1085 - 240 - 32)/2) = 406
Required reduction = 537 - 406 = 131
Icon widths after proportional integer allocation = 53,53,53,53,53,54
Final Lw = 30 + 1 + 5*53 + 54 + 7*8 = 406
Final Rw = 208 (right buttons did not shrink)
Final N = 1085 - 2*406 - 32 = 241
Margins = (1085 - 241)/2 = 422 on both sides
Gap after left = 16; gap before right = 214
```

241 rather than 240 keeps exact centring with whole-point origins on the odd-width bar. The shrinking icons are about 1.77:1 / 1.8:1, still 30 pt high.

## Verification and rollback

```bash
mtmr/build.sh
lipo -archs build/MTMR.app/Contents/MacOS/MTMR
python3 mtmr/tests/test-notifications.py
git -C /Users/maxday/Workspace/projects/maxlaptopmtmr/MTMR status --porcelain
```

Resume verification: the clean arm64 build and all seven runner cases pass after completing item `minWidth` rejection logging. Patch `0003` was regenerated by diff and applies with zero fuzz after `0001` + `0002`.

The runner compiles a pure Swift solver target and a separate standalone AppKit view harness. The latter checks bounds changes, text-independent frames, decoded options and the unchanged stack path, without creating `NSApplication`/`NSTouchBar`, accessing the controller singleton or live settings, or launching MTMR.app. Queue/socket tests keep using temporary sockets. See [findings.md](findings.md) for build/test evidence and remaining hardware checks.

Rollback: restore the preceding `NotificationTouchBarItem.swift` and test runner, omit patch `0003` and its two new solver/container overlays, and rebuild with `0001` + `0002`. Existing build globbing copies overlays and applies numbered patches; `mtmr/build.sh` itself is unchanged. Nothing here changes the live layout, defaults, permissions or LaunchAgents.
