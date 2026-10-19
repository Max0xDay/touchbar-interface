# Notification layout maths

The real Touch Bar host measures **1004 × 30 points (pt)**.
The container uses **1085 pt only as a fallback** before usable bounds exist.
The template fixtures below deliberately use 1085 pt; the actual layout uses the measured host width.

My TouchBar My Rules (MTMR) uses the solver only if a `notification` item exists.
Patch `0003-layout-solver.patch` replaces stack geometry with `NotificationLayoutView` and the AppKit-free `NotificationLayoutSolver`.
Without a notification item, `BasicView` retains the upstream stack and gestures.
Patch `0004-live-buttons.patch` adds live identifiers and visibility updates without a bar reload.

## Geometry and constant text size

- `W` denotes the custom item's host width, or its own bounds width if host bounds are unavailable.
  The container uses 1085 if neither width is finite and positive.
- Every item has height 30 pt; adjacent items within an edge group have an 8 pt gap.
  The left group starts at zero; the right group ends at `W`.
- `Lw` and `Rw` equal their group widths, including `8 * max(0, count - 1)` for gaps.
- Nominal notification width is `N0 = W - 2 * max(Lw, Rw) - 2 * padding`.
  Final notification origin is `x = (W - N) / 2`, with equal bar-edge margins.
- One-line text uses the 15 pt regular monospaced system font.
  The measured glyph advance on macOS 14.7.6 is `9.2724609375` pt.
  Standalone AppKit tests compare that constant with the font.
- Each side retains a 12 pt inner inset.
  The label centres vertically and recalculates capacity after a width change.
- One-line text without an icon uses `capacity = min(maxChars, floor(max(0, N - 24) / glyphWidth))`.
  Longer text retains `capacity - 1` characters and an ellipsis.
  Capacity one displays only an ellipsis; capacity zero displays blank text.
- Whitespace collapses to single spaces.
  Native tail truncation also handles wider Unicode glyphs.
  The character budget does not imply equal widths for all Unicode graphemes.
- Preferred width is `Npref = max(120, ceil(maxChars * glyphWidth + 24))`.
  Forty characters require 395 pt; the actual layout's 36 characters require 358 pt.

Icons occupy 30 pt visually, but the text calculation reserves an 18 pt slot and a 6 pt gap.
Two-line entries use a 12 pt semibold heading and a 10 pt grey body.
Those entries use measured proportional text and native truncation rather than the monospaced character budget.

Notification arrival, selection, and expiry do not affect solver inputs.
Text animation changes opacity and transform, not geometry.
A reload creates a new container; a width or live visibility change recalculates geometry.

### Actual layout

The left group contains universal control at 30 pt and a 1 pt spacer: `Lw = 30 + 8 + 1 = 39`.
The right group contains App Controls at 340 pt, including its switcher: `Rw = 340`.
The actual layout contains no left Teams buttons or separate exit item.

```text
W = 1004; padding = 16; maxChars = 36; minWidth = 358
Universal control: (x=0, width=30)
Spacer:            (x=38, width=1)
Notification:      (x=356, width=292), centre=502
App Controls:      (x=664, width=340), trailing edge=1004
```

The notification width is `1004 - 2 * 340 - 32 = 292`, below the 358 pt minimum.
The solver logs a warning but preserves the right group and the fixed control.
A right zone at most `(1004 - 358 - 32) / 2 = 307` pt preserves the minimum.
The particle region occupies `x=0` through the notification origin, independently of button geometry.

## Left-only scaling

If `N0 >= minWidth`, every button keeps its nominal width.
The solver applies an optional `maxWidth` cap afterward.

If `N0 < minWidth`, only left buttons can shrink.
The target group width is `floor((W - minWidth - 2 * padding) / 2)`.
The solver apportions reductions according to each button's available reduction, `width - buttonMinWidth`.
The solver stops at the target, at the right-group width, or after all available reductions.
The right group never shrinks or disappears.

A left button's default minimum is 60% of nominal width, rounded to a whole point.
Explicit minima cannot exceed nominal width.
Universal control, exit buttons in custom layouts, and blank spacers keep fixed widths.
A spacer is borderless, blank, and free of images, backgrounds, and actions.
An item without explicit width uses its initial fitting width.

The solver accepts a notification width below the requested minimum and logs a warning per solve.
Text truncates without a smaller font.
Largest fractional remainders determine integer reductions; ties follow configured order.
Padding rounds to whole points, minimum rounds upward, and maximum rounds downward.
Integral `W` normally requires notification width with matching parity, so origins remain integral.
Fractional widths or a strict 120 pt cap can require fractional origins to preserve the centre.

### Infeasible widths (tagged exceptional policy)

If the width after scaling falls below 120, the solver reserves a centred 120 pt floor.
An odd integral bar can use 121 pt if the cap permits that width.
If `W < 120`, the notification uses `W`.
The solver reduces padding if necessary and retains only a fitting prefix of left items.

Keep `W >= 2 * (Rw + padding) + 120` to avoid an impossible right-side fit.
Below that threshold, the fixed right group can overlap the notification or extend beyond the clipped container.
The solver preserves right widths, order, and trailing edge even for these exceptional inputs.
Source comments explicitly identify this exceptional policy.

## Options

All dimensions use points.

| Location | Option | Default or rule |
|---|---|---|
| Notification | `maxChars` | The default is 40; valid integers span 1–1000. |
| Notification | `defaultSeconds` | The default is 8; the value must be positive and at most 86400. |
| Notification | `padding` | The default is 16; the finite outer padding must be nonnegative. |
| Notification | `minWidth` | The default is `Npref`; an explicit finite value must be at least 120. |
| Notification | `maxWidth` | No cap applies by default; the rounded cap must equal or exceed the rounded minimum. |
| Notification | `fadeSeconds` | The default is 0.35; valid finite values span 0–2. Zero disables notification and visibility transitions. |
| Left item | `minWidth` | The default is 60% of nominal width. Fixed items ignore the minimum. |
| Right item | `minWidth` | The container ignores the minimum for geometry; decoding still rejects negative or malformed values. |
| Button | `keepSlotWhenHidden` | The default is false; true reserves width and gaps for an invisible button. |

The decoder rejects contradictory maximum and minimum values after rounding.
An even cap on an odd bar can lose one point to preserve integral centring.

```json
{"type":"notification","maxChars":40,"fadeSeconds":0.35,"minWidth":300,"maxWidth":500}
```

## Worked examples (tested)

These examples represent template-style fixtures, not the actual layout.
All examples use `W=1085`, padding 16, `maxChars=40`, and preferred width 395.
The right group is `100 + 8 + 100 = 208`, with origins 877 and 985.

### (a) Three left icons

The group width is `Lw = 30 + 1 + 3 * 75 + 4 * 8 = 288`.
The nominal notification width is `1085 - 2 * 288 - 32 = 477`, so no button shrinks.

```text
Left (x,width): (0,30) (38,1) (47,75) (130,75) (213,75)
Notification:  (304,477), centre=542.5, margins=304/304, capacity=40
Right:         (877,100) (985,100)
```

The spacer leaves a 17 pt gap after the template exit button.
The notification has gaps of 16 pt on the left and 96 pt on the right.
The bar-edge margins remain equal.

### (b) Four left icons (explicit test fixture, not layouts/template.json)

The group width is `Lw = 30 + 1 + 4 * 75 + 5 * 8 = 371`.
The nominal notification width is 311; the target left width is 329.
A 42 pt reduction across four 30 pt capacities produces button widths 64, 64, 65, and 65.

```text
Left (x,width): (0,30) (38,1) (47,64) (119,64) (191,65) (264,65)
Lw=329; Rw=208
Notification:  (345,395), centre=542.5, margins=345/345, capacity=40
Right:         (877,100) (985,100), trailing edge=1085
```

### (c) Exhausted left capacity: six icons

The nominal left width is `30 + 1 + 6 * 75 + 7 * 8 = 537`.
The nominal notification width is -21, which the container never renders.
The target left width remains 329, but available reduction totals only 180 pt.
Every icon reaches 45 pt, so `Lw=357` and `N=339`.

The notification occupies `(373,339)` with equal margins of 373 pt.
The capacity is 33 characters, so longer text uses 32 characters and an ellipsis.
The font remains 15 pt, and the right group still ends at 1085.

A separate fixture starts with `Lw=408` and `Rw=288` at `W=800`.
Left reduction stops at 288; the notification width is 192.
The two right buttons remain 140 pt each.

## Live visibility: collapse by default (patch 0004)

`visible:false` disables actions and sets alpha to zero.
By default, the container removes the button from solver inputs while retaining the view hierarchy.
Remaining visible buttons retain order and 8 pt gaps.
Each edge group remains pinned to its edge, and the notification remains centred.
The container sets the faded view's `isHidden` flag after the transition.

`keepSlotWhenHidden:true` preserves the invisible button's width, position, and gaps.
No `collapseWhenHidden` option exists.
The container filters inputs and maps frames back to views without a change to solver arithmetic.

### Three icons → hide the first (worked example, tested)

The template-style fixture starts with `Lw=288`, `Rw=208`, and `N=477` at `W=1085`.
After the first icon hides, the template exit and spacer remain:

```text
Lw = 30+1+2*75+3*8 = 205
Rw = 100+8+100 = 208
N  = 1085-2*max(205,208)-32 = 637
Left visible: (0,30) (38,1) (47,75) (130,75)
Notification: (224,637), centre=542.5
Right:        (877,100) (985,100)
```

The other icons move into the first two slots.
The notification gains 160 pt, then the right-group width limits further growth.
Show restores the original frames; `keepSlotWhenHidden:true` instead preserves `Lw=288` and `N=477` throughout.

Affected frames and alpha use coordinated 0.2-second ease-in-out animations.
Reduce Motion or `fadeSeconds:0` disables those animations.
Model values immediately reflect the latest solution.
Rapid updates sample presentation geometry and cancel earlier animations.
Tests check pure geometry, centring, right pins, reserved slots, and rapid visibility changes.
Hardware appearance remains a separate check.

## Touches, animations and diagnostics

`NotificationAreaView` receives hits across the full area and keeps those hits away from its labels.
The view accepts direct touches and resting touches.
Touch begin pauses all notification deadlines; release, cancellation, or detachment resumes the deadlines.
A dominant horizontal movement of at least 20 pt selects one entry per touch.
Left selects next; right selects previous; both directions wrap.
The physical bar reports no vertical movement.

A tap without a swipe recalls the newest hidden live entry if the area is empty.
Display expiry leaves hidden entries untouched and never automatically advances the queue.
[Layouts](layouts.md#notification-queue) defines the 8-second display limit and unread dot.
The container reparents original item views and retains ancestor gestures and the no-notification stack path.

New text fades in over `fadeSeconds` with ease-out and a 3 pt upward slide from below.
Expiry fades out over 0.25 seconds with ease-in.
Entry changes fade out over 0.12 seconds before the new entry appears.
Reduce Motion uses 0.15-second fades without the slide.
`fadeSeconds:0` disables these transitions.
Generation checks and presentation-opacity samples protect rapid updates from stale animation completions.

`NotificationDebug.enabled` currently defaults to true.
`MTMR-notif:` logs include touch counts, coordinates, hierarchy, and area/container/label frames.
These debug messages exclude notification text.

```bash
/usr/bin/log show --predicate 'process == "MTMR"' --last 5m
```

## Verification and rollback

```bash
MTMR_CHECKOUT=/path/to/MTMR mtmr/build.sh
lipo -archs build/MTMR.app/Contents/MacOS/MTMR
bash mtmr/tests/run-tests.sh
git -C /path/to/MTMR status --porcelain
```

The runner checks the pure solver, standalone views, and temporary socket harnesses without an installed layout change.
The view harness requires a prior build because the harness compiles prepared sources and bridge objects.
The fixture coverage includes widths, minima, right preservation, text capacity, font metrics, swipes, and transition cancellation.
A known stale notification assertion prevents a clean full-suite result; see [the build runbook](runbook-build-mtmr.md#build).
Physical touch delivery, animation appearance, and Reduce Motion require hardware checks.

To roll back, restore the earlier patches and overlay sources from version control.
Rebuild the app afterward.
Restore a layout separately through `tbctl layout` or an in-place backup write.
Builds and tests leave live configuration, permissions, and LaunchAgents unchanged.
