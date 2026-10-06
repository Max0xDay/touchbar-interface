# Notification layout maths

Applies only when a `notification` item is present. Patch `0003-layout-solver.patch` replaces `0002`'s stack sizing with `NotificationLayoutView` and the AppKit-free `NotificationLayoutSolver`. Without a notification, `BasicView` keeps upstream's stack and gestures. The overlays implement direct-touch swipes and animated text. Patch `0004-live-buttons.patch` adds ids/live state hooks; visibility updates re-solve the same container without rebuilding the bar.

## Geometry and constant text size

- `W` is the custom item's host bounds width, otherwise its view bounds width. Unavailable bounds use a tagged **1085 pt** fallback. The host spanning the modal bar still needs hardware confirmation.
- All item heights are **30 pt**, inter-item gaps **8 pt**. Left starts at `x=0`; right ends at `x=W`, always at configured widths. Right-item `minWidth` is ignored by the container (malformed/negative values are still rejected by existing decoding).
- `Lw` / `Rw` = sum of group widths plus `8 * max(0, count-1)`.
- Nominal notification width: `N0 = W - 2*max(Lw,Rw) - 2*padding`. Position the final notification at `x=(W-N)/2`, exactly centred on `W/2` with equal bar-edge margins.
- **15 pt regular monospaced system font**, never shrunk: it leaves comfortable vertical room in a 30 pt bar. Its measured glyph advance on macOS 14.7.6 is **9.2724609375 pt**. This measurement is tagged in `NotificationTextMetrics` and checked against AppKit by the standalone tests.
- Retain **12 pt inner inset** on either side. The label spans the area width minus these insets, with a font-height frame vertically centred in the area. Every width change recomputes its frame and capacity.
- `capacity = min(maxChars, floor(max(0, N-24)/glyphWidth))`. Longer text becomes `capacity-1` characters plus `…`; capacity 1 gives only `…`, capacity 0 gives blank. Whitespace is normalized. Native tail truncation also handles wider Unicode glyphs. The monospaced advance is a character-budget estimate, not a promise that arbitrary Unicode graphemes have identical widths.
- Preferred width: `Npref = ceil(maxChars * glyphWidth + 24)`, with the **120 pt floor** also applying to the default minimum. For 40 characters, **Npref=395**.

Text/arrival/expiry/selection are not solver inputs. Reload creates a new container; width changes re-solve it. Text animations affect only the label layer's opacity and transform. Live-button visibility changes update geometry as described below.

## Left-only scaling

If `N0 >= minWidth`, no buttons shrink. Apply optional `maxWidth` to N afterward.

Otherwise shrink **only left buttons**, proportionally to their available reductions (`width - buttonMinWidth`), toward the target group width `floor((W-minWidth-2*padding)/2)`. Never shrink the left group below `Rw`: doing so cannot increase N. Stop at the target, at `Lw=Rw`, or when left reductions are exhausted, whichever is reached first. The right group is never shrunk or hidden.

Left-button minimum defaults to 60% of nominal width, rounded to a whole point. Exit and spacer never shrink. A spacer is a borderless blank button with no image, background or actions. Widths without explicit `width` use fitting size at container creation. Below the notification minimum, accept smaller N and truncate text without changing font size; a warning logs once per width solve.

Allocation uses largest fractional remainders, ties resolved in configured order. Widths/padding are whole points; minimum rounds up, cap down. Integral W normally uses an N of the same parity so origins are integral. Fractional W, or a strict 120 cap on odd W, uses fractional origins to retain the exact centre and floor.

### Infeasible widths (tagged exceptional policy)

If nominal N after left scaling is below 120, reserve a centred 120 pt floor (121 on odd integral W when permitted), and hide only overflowing left items, keeping a fitting prefix. Reduce outer padding if the floor alone leaves insufficient margin. If `W<120`, the area uses W instead.

**The right group always keeps its widths/order and its trailing edge at W.** Below `W = 2*(Rw+padding)+120`, a centred 120 pt floor, an untouched right group and non-overlap cannot all coexist. Right buttons may then overlap the notification or extend beyond the clipped container. This is an explicit tagged interpretation for impossible inputs, not a supported physical layout; do not configure such widths. Earlier documentation's right-shrink/hide policy is superseded by the user decision.

## Options

All dimensions are points. `layouts/template.json` needs no changes.

| Where | Option | Default / rule |
|---|---|---|
| Notification | `maxChars` | 40; integer 1...1000 |
| Notification | `defaultSeconds` | 8; positive, at most 86400 |
| Notification | `padding` | 16; finite, nonnegative outer padding |
| Notification | `minWidth` | `max(120,Npref)`; explicit finite value at least 120 overrides it |
| Notification | `maxWidth` | No cap; finite, at least `minWidth` after rounding |
| Notification | `fadeSeconds` | 0.35; finite 0...2; 0 disables all animations |
| Left item | `minWidth` | 60% of nominal, rounded; nonnegative explicit values capped at nominal; ignored for exits/spacers |
| Right item | `minWidth` | Ignored for sizing; right widths always remain configured |
| Button | `keepSlotWhenHidden` | false; true reserves the invisible button's width/position/gaps |

Contradictory `maxWidth < minWidth` is rejected (existing tagged conservative policy). An exact even cap on odd W may lose a point for integral centring. Example:

```json
{"type":"notification","maxChars":40,"fadeSeconds":0.35,"minWidth":300,"maxWidth":500}
```

## Worked examples (tested)

All use W=1085, padding=16, maxChars=40, 15 pt font, glyphWidth=9.2724609375 and Npref=395. The right group is always `100+8+100=208`, at `(877,100)` and `(985,100)`, ending at 1085.

### (a) Three left icons

`Lw=30+1+3*75+4*8=288`. N0=`1085-2*288-32=477`, above 395, so nothing shrinks.

```text
Left (x,width): (0,30) (38,1) (47,75) (130,75) (213,75)
Notification:  (304,477), centre 542.5, margins 304/304, capacity 40
Right:         (877,100) (985,100)
```

The 1 pt spacer retains the 17 pt gap after exit. Gaps to the notification are 16 left / 96 right; bar-edge margins remain equal.

### (b) Four left icons (explicit test fixture, not layouts/template.json)

`Lw=30+1+4*75+5*8=371`, N0=`1085-742-32=311`. Target left width=`floor((1085-395-32)/2)=329`. Reduce by 42 pt, proportionally across four 30 pt capacities. Integer allocation gives icon widths **64,64,65,65** (reductions 11,11,10,10).

```text
Left (x,width): (0,30) (38,1) (47,64) (119,64) (191,65) (264,65)
Lw=329; Rw=208 unchanged
Notification:  (345,395), centre 542.5, margins 345/345, capacity 40
Right:         (877,100) (985,100), trailing edge 1085
```

### (c) Exhausted left capacity: six icons

`Lw=30+1+6*75+7*8=537`, N0=-21 (not rendered). Target Lw is still 329, requiring 208 pt reduction, but the six icons have only `6*(75-45)=180` pt capacity. All reach **45 pt**, leaving Lw=357.

N=`1085-2*357-32=339`, below preferred 395 but above the floor. The notification is `(373,339)`, with margins 373/373 and capacity `floor((339-24)/9.2724609375)=33`. Font remains 15 pt; longer text is 32 characters plus ellipsis. Right remains exactly 100/100, ending at 1085.

A separate test with Lw=408 and Rw=288 on W=800 stops left shrinking at 288; N=192. Shrinking further could not help. Right widths remain 140/140.

## Live visibility: collapse by default (patch 0004)

`visible:false` disables taps and targets alpha 0. By default the hidden button is
removed from the **solver inputs**, not from the bar/view hierarchy. Solve with the
remaining visible items, keeping 8 pt gaps only between them and each group pinned
to its edge. Showing reintroduces the original nominal width and order. Notification
width may change because `max(Lw,Rw)` changes; it always stays centred on W/2. Right
buttons never shrink; hiding a left button does not move the right group.

`keepSlotWhenHidden:true` is the opt-in exception: alpha/taps change but its slot
stays in the solver inputs. All frames remain identical. There is no
`collapseWhenHidden` option. Widths/minima and the pure solver's arithmetic are
unchanged; the container simply filters inputs and maps solved frames back to views.

### Three icons → hide the first (worked example, tested)

At W=1085, before hiding: `Lw=288`, `Rw=208`, `N=477`, notification `(304,477)`.
After hiding the first icon, exit/spacer stay:

```text
Lw = 30+1+2*75+3*8 = 205
Rw = 100+8+100 = 208
N  = 1085-2*max(205,208)-32 = 637
Left visible: (0,30) (38,1) (47,75) (130,75)
Notification: (224,637), centre 542.5
Right:        (877,100) (985,100), unchanged
```

The other two icons slide into the first two icon slots. N grows by 160 pt as Lw
falls below Rw; any further left-width reduction cannot grow N past the right-group
bound. Showing the mic restores the original `(47,75) (130,75) (213,75)` icon frames
and `(304,477)` notification. `keepSlotWhenHidden:true` instead retains Lw=288/N=477.

All affected frame/alpha changes use coordinated **0.2 s ease-in-out** layer
animations, disabled under Reduce Motion or `fadeSeconds=0`. Frames and model alpha
are immediately set to the latest solver result. New changes sample presentation
geometry, cancel old animations and restart; no asynchronous completion writes
stale frames. Tests compare every visible group/notification frame to the pure
solution, centring, right pins, keep-slot stability and rapid hide/show restoration.
Physical animation appearance and host-layer behavior remain tagged/unverified.

## Touches, animations and diagnostics

`NotificationAreaView` is the transparent, full-area hit target: its hit-test override returns itself rather than the label; `allowedTouchTypes=.direct` and `wantsRestingTouches=true`. Direct began/moved/ended/cancelled callbacks replace the one-finger pan recognizer. Expiry pauses at begin and resumes at end/cancel/detachment. A dominant horizontal movement of at least **20 pt** selects once per touch: **left=next, right=previous**, wrapping endlessly in both directions. The physical bar reports no vertical movement. Selection happens during movement so reaching the edge does not lose the swipe.

The old item view is actually reparented into the container, not replaced. Label hit-targeting and pan-recognition thresholds on a 30 pt strip are the suspected failure, not a confirmed hardware diagnosis; the direct-touch path bypasses both. Existing ancestor multi-finger recognizers and the no-notification stack path are unchanged.

New text fades in over `fadeSeconds`, ease-out, with a subtle **3 pt upward settling slide** (starts 3 pt below rest). Expiry to blank fades out for **0.25 s**, ease-in. Switching entries fades the old text out for **0.12 s**, then reveals the new text. Reduce Motion uses only **0.15 s fades**, no slide; `fadeSeconds=0` takes precedence and disables everything. Pending completions are cancelled and generation-checked; presentation opacity is sampled before cancelling layer animations. Latest text wins, including rapid clear/update sequences and geometry changes. Model opacity/transform are always set to final values so cancelled animations cannot leave half-faded text.

`NotificationDebug.enabled` defaults to **true for now; turn it off after hardware diagnosis**. Cheap `NSLog` messages prefixed `MTMR-notif:` are in `NotificationAreaView.swift` (event state, direct-touch count, locations/translations, area/label frames, hierarchy at creation/attachment and first window attachment) and `NotificationLayoutView.swift` (container size, notification frame, label frame per solve). No notification content is logged.

User-run observation command (not run by the agent):

```bash
/usr/bin/log show --predicate 'process == "MTMR"' --last 5m
```

## Verification and rollback

```bash
MTMR_CHECKOUT=/Users/maxday/Workspace/projects/maxlaptopmtmr/MTMR mtmr/build.sh
lipo -archs build/MTMR.app/Contents/MacOS/MTMR
bash mtmr/tests/run-tests.sh
git -C /Users/maxday/Workspace/projects/maxlaptopmtmr/MTMR status --porcelain
```

The runner compiles the pure solver, standalone AppKit views and temporary socket harnesses without launching MTMR.app or creating a Touch Bar. It tests widths, preferred/default/explicit minima, right preservation, capacity/truncation, font metrics, label centring after resizing, hit-testing, swipe-direction thresholds, fade durations, rapid cancellation, expiry-to-blank, zero-duration animation and unchanged no-notification stack behavior. Actual touch delivery, animation appearance and Reduce Motion on hardware still need user verification.

Rollback: restore the previous overlay/test/docs files from the task's `/tmp/mtmr-notification-fix.fNoEGQ/` backup and rebuild. The backup also holds the preceding app bundle. That historical rollback predates patch 0004; live-button rollback and protocol details are in [live-buttons.md](live-buttons.md). Live config, defaults, permissions and LaunchAgents remain untouched by the live-button task. Do not launch or replace the running app as part of rollback without user approval.
