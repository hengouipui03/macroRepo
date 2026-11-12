# AA Path Macro

Keep this folder together. Run AAPathMacro.ahk with AutoHotkey v2. The runtime
files are UnitSettings.ahk, Placement.ahk, PlacementArea.ahk, PlacedUnits.ahk, Learning.ahk, CardContext.ahk, MapNavigation.ahk, PathLight.ahk, BuildAudit.ahk, Discord.ahk, Endgame.ahk, MinimapVision.py,
OCRBridge.ps1 and button_positions.ini (settings.ini holds the Discord webhook
once saved); LearningTests.ahk, MapTests.ahk, MinimapVisionTests.py,
minimap-fixture.mapframe, minimap-screenshot.png, path-world-screenshot.png,
path-toggle-off.png and path-toggle-split-fx.png support validation.
Keep learning.ini when updating: it contains your learned data.

F6 starts, F7 stops/releases keys, F8 runs the overhead camera sequence, F9 tests
map preparation/navigation without voting or buying units, and F10 teaches a
button under the cursor. Start sizes Roblox to 1401 x 975 outer pixels. Coordinates scale from the live
client area. Button and placement memories are separated by window size, so
old-size positions stay saved and are not applied to the laptop size. New
positions are detected and learned at the new size; unit settings are retained.

## Saved unit settings

All six slots save automatically after edits and when the macro closes: enabled
state, name, placement count, priority, upgrade target, Hill-only, Hybrid and Money modes. Reopening restores the
same setup from unit_settings.ini. Keep that file when updating the macro.

## Lobby sequence

Play -> hold W until Play Here appears -> release W -> Play Here -> Open ->
Start -> wait for Vote Start. There is no other lobby-menu handling.

## Minimap vision (Python) and repositioning

MinimapVision.py reads the minimap with OpenCV; AHK still sends every key and
click. It needs Python 3 on PATH as pythonw.exe and:

    python -m pip install opencv-python numpy mss dxcam

AHK starts the service on first use and closes it on exit. If Python or a
package is missing, the Activity log says so and the AHK pixel reader below is
used instead.

- The minimap is found by its mint-green frame, not a fixed rectangle. The
  box is saved per window size/DPI in learning.ini ([minimap_box]) and found
  again if it stops showing a route.
- The route is traced by hue, so the darker, pulsing parts of the green line
  are kept. Enemy and boss icons on the line are recorded as covered cells, so
  gaps under them are bridged and a learned map is recognized mid-wave.
- After the overhead camera (I, tilt, O), the macro taps W then S, and D then
  A if needed. The white marker that changed is the player, even when the
  chevron is clipped by the frame or partly covered. Probing stops once the
  player is found.
- The same taps measure how W and D move the arrow on the minimap. Movement
  then uses W/S and D/A hold times solved from those measurements, so no
  heading is read from the chevron and the camera is not turned. Measurements
  are saved per map and camera profile; a matching W reading skips the D/A
  probe next time. If movement stops matching, it probes again.
- Obstacles: a move that does not shift the arrow is retried holding Space
  to jump. If still blocked, the player steps around it: 3 cells to one side,
  then the other, then backs off and steps wider (up to 18 cells), jumping on
  each step. While getting around, it aims ahead along the route rather than
  back at the obstacle. The attempt counter resets once the player is 2 cells
  further along the route; after seven failed attempts it stops.
- Getting to the path: the minimap leads first. However far the player spawns
  from the green line, it walks to the nearest route point; only the
  50-second preparation allowance, failed obstacle escapes or a lost arrow stop movement. Timer expiry continues placement at the current location.
- Lit path: the P button coordinate is saved in learning.ini for each window
  size/DPI and reused across runs. Only the first unsaved view locates the glyph;
  if that fails, the static coordinate in button_positions.ini is used and saved.
  P is grey when off and white when on; brightness is read at the saved point,
  and P is clicked (never pressed as a key: the key does nothing) by PathLight.ahk at Vote Start and again when placing starts, verified by the glyph, at most 3 clicks per check and never again once a click changed the glyph. When a lit path is read, the minimap variant is marked lit_path=1 in learning.ini; on such a variant with P on and no lit path at the start of placing, P is switched off and on once per match. P is the leftmost glyph of the P/i/FX/heart
  pill (FX can show as separate F and X), never the i next to it. Once the player is on or next to the lit
  band (or it lies straight ahead), each move keeps the minimap plan's length
  but aims at where the band crosses a circle around the player, so the player
  walks on the in-game path. P is checked for both minimap readers. If it
  stays grey after one click and the road itself is not visibly illuminated,
  preparation stops before navigation/placement.
- Each preparation writes minimap-debug.png (route magenta, heart circled red,
  player candidates circled blue). Placement with the lit path visible writes
  path-debug.png (band magenta, placement points circled orange).

## Minimap navigation

The fallback navigation reader uses the fixed bottom-right minimap. The top-right
P check is independent of which minimap reader succeeded; both readers check it
before camera setup and navigation. A missing fallback arrow cannot skip P.
The Python worker must remain available to confirm P and locate placement edges.

The green line is traced into a connected drawing. The larger white heart is the
base; the small white chevron supplies the player's position and heading. Their
components are classified separately. The reader supports the actual open-legged
chevron in the supplied Future City screenshot. Small gaps covered by enemy or
player icons can be bridged; nearby parallel lanes are kept separate.

The destination is chosen automatically to balance nearby route coverage with
travel cost. This is a practical placement-location heuristic, not a proven
global optimum. Destinations saved earlier from the removed Map tab are still
used for their map variant.

Each route layout is saved as a separate variant in learning.ini. Recognized
variants reuse their drawing and saved destination, including during small icon
occlusions. The drawing is retained if a marker temporarily disappears. Player
position updates during navigation.

Once Vote Start appears, the macro draws/recognizes the minimap and starts a
fixed 50-second preparation allowance. It holds I, tilts downward, lets the
mouse settle, and holds O to establish an overhead view. Full camera holds are
five seconds each when the remaining preparation budget permits. It then joins
the nearest path point and follows connected shortest-path waypoints toward the
destination. It reads the arrow before turning and again after movement, adapting
forward pulse duration to observed speed. It stops rather than cutting across a
bend or making random forward/backward probes. Walking uses the remaining
preparation time without a separate 24-second cap. If the timer expires before
the destination, movement keys are released and normal placement starts at the
current location. The same visible path-edge checks and per-slot Hill preference
apply; no vote-to-lose or reset is performed. Non-timeout tracking/navigation
errors and F7 still stop the run.

There are no settings or spawn-menu clicks in normal map preparation.
P is clicked once if the path is not already lit; repeated checks cannot toggle
it off again in the same game.
F8 remains available for a manual overhead-camera reset. If voting has already
auto-started by arrival, the macro proceeds from the mapped destination.

## Ordered placement beside the player and path

Placement begins at the closest suitable point beside the illuminated path
near the player, then follows one continuous side of that path in adjacent
steps. Cursor movement is smooth, including between placement attempts and
when closing unit panels. Each attempt presses the configured slot, reads the slot's
"n/max" counter and the Yen while holding the unit (no click when Yen is short), sends
one left click and reads the counter and Yen again to see whether it bought a unit;
a miss pauses briefly before moving to the next neighbouring spot. A confirmed
unit is recorded for upgrades, and the next unit starts at the next free spot
beside that unit on the same line. A rescan continues beside the newest edge
unit (onward along the edge, then back along it), not beside the player. After
three unsuccessful clicks on the same edge, the whole stretch those clicks walked
(48 reference pixels either way of each miss) is blocked for this game, so a
building wall is blocked end to end, and the next tries go to the opposite side
or another edge. If there is no valid opposite-side position, it rescans another
path edge. Counters and
blocked sections survive retries and rescans. Normal placement aims 12 reference
pixels outside the detected road and accepts only an 8–18 pixel edge gap; saved
coordinates for the first row must fit that tighter gap too.
Units are placed in pairs. Row 1 is the path edge; row 2 is ONE partner spot
straight behind a row-1 unit (one unit spacing away from the road). The newest
edge unit gets one try at its partner; otherwise the unit goes along the edge
beside the newest edge unit. So: edge, behind, edge, behind, ... A failed
partner try closes only that spot (never the edge) and the same unit continues
along the edge. Each unit's row and partner are recorded, so a row-2 unit never
anchors anything, whatever its distance to the road. When one side of the edge
is used up, open partner spots behind older edge units are filled, oldest first,
before crossing the road. Saved second-row coordinates require a nearby saved
first-row anchor. Hill and Money units are never anchors. A successful opposite-side placement becomes the side used for following copies. It does not scatter clicks
around the screen, or fall back to unrelated ground when the nearby line ends.
Failed placement coordinates are remembered in memory for the current game,
across copies, slots, card interruptions and rescans. After an actual placement
click is refused (the slot counter did not rise), that ground/Hill coordinate
and its surrounding 14-reference-pixel-radius area are skipped for the rest
of the game. This blocks neighbouring grid points and coordinate jitter, not
just exact coordinate repeats.
Hill and ground keep separate rejection lists. Rescans exclude rejected ground
coordinates and occupied unit positions before selecting a new nearby path edge.
No-click cancellations and interrupted confirmation waits do not blacklist a
spot. A late confirmed purchase removes its coordinate from the failed list.
The next game's placement preparation clears this temporary list; it is never
saved into reusable map profiles.

Configured slots and copies are tried in order. A blocked copy waits ten seconds
while later slots continue; it stays pending rather than reporting a partial
build as complete. Upgrades use the F manager, and F is only pressed once every
unit is placed, so no upgrades run while the build is incomplete.
Temporarily unavailable Hill units remain pending too. The full upgrade phase
starts only when every enabled slot has its configured number of confirmed
copies; the status lists the exact missing counts during retries.
All new placement points must lie within a circle of radius 180 reference pixels
around the stopped player. The debug image shows that circle. Six consecutive failed purchase clicks, across slots, trigger DOWN/baseward
relocation before another purchase. Recovery/selection clicks are not additional
purchase attempts. A successful placement or an actual relocation resets the
streak; rescans, switching slots, and declined relocation do not reset it.
The connected minimap route is divided by route length into three checkpoints
at 25%, 50%, and 75%, from its entrance toward the base. The first placement
destination is checkpoint 1. Six consecutive failed purchase attempts advance
to checkpoint 2, then checkpoint 3 along the drawn path. Checkpoint travel does
not depend on old units staying on screen: upgrades select their purchase
numbers in the F manager. At checkpoint 3, six misses refresh the local search
and placement continues until the build is complete or the match ends.

Unit selection and placement clicks, keys and cursor travel use 150 ms holds
and action intervals, including F-manager navigation. Other UI actions, P,
Vote Start retain their existing 300 ms timing; manager Upg clicks use the 150 ms unit timing. Redundant preview
cancellations are skipped. Menu clicks no longer add multi-second fixed pauses.
Panel confirmation, OCR, loading, calibrated movement and camera holds retain
their necessary observation/hold time. Between placements, the Level Modifiers
panel is read with OCR at most every 30 seconds (it only changes with cards,
whose effects are added as they are chosen) and never once the F manager covers
it; once the unit panel has been recognised on this device, a missed panel no
longer re-runs the OCR layout learning after each failed purchase. Stale panels and
late purchase confirmations are still checked before another placement. Every missed neighbouring spot
is followed by cancelling the old preview before pressing the slot again, so a rejected
spot cannot toggle placement off and turn the following click into unit selection.
The old unit panel must be closed before each new placement click. Counts
advance from newly registered placements, with per-slot confirmed/target logs;
before buying, a selection-only click rejects spots which already open an
existing model. Each purchase is bound to its slot and next copy number. The slot counter
(then the Yen drop, then a side panel with no recorded unit nearby) confirms placement;
the panel alone never does, and placement does not read or require UPG 0. Panels
obscured by cards never count. After cards close, one shared recovery function probes
the same evidence for the exact pending purchase, without clicking the field or buying
again, then records it. A purchase that stays unknown after a few probes counts as a failed
attempt without blacklisting its spot (see MACRO_BEHAVIOUR.md).
duplicate recorded coordinates and a panel open before the click do not count. Every confirmed placement cancels
the preview and clicks empty game space above/outside the card area to dismiss
the unit panel, including when cards overlap it. Cards pause placement and restore
the selected unit afterward. F7 releases input.

The ordered line stays within a local area around the overhead-view player.
A visible nearby illuminated path is required. Detection accepts the saturated
yellow-green path under sandstorm lighting as well as the pale green version;
vote controls, the green health bar and the minimap are excluded by position. A single visible edge spot is
enough to start; no six-point minimum or separate 90-pixel start gate blocks
the slot-click loop. Starts still stay within the local player area and next
attempts follow the same edge. Failed searches log whether the path or its
nearby edge was missing and save placement-search-debug.png for diagnosis.
Unit settings still autosave in
unit_settings.ini, and other menu buttons keep their normal pacing.

## Two-path maps

When the minimap shows a second, purple enemy path (for example Shibuya
District), vision reports every point where it meets the green route: each
crossing and the merge before the heart. Only long purple lines count, so the
purple boss and other purple icons are never taken for a path. Checkpoint 1 is
the first crossing the enemies reach (furthest from the base along the route);
after six failed purchases the macro moves on to the next meeting point toward
the base. With fewer than three meeting points, the remaining checkpoints are
spread along the route from the last one to the base. Meeting points are saved
with the learned minimap variant, so enemy icons covering a crossing on a later
read do not lose it. One-path maps keep the 25/50/75% checkpoints.

## Money units

A slot marked Money (exclusive with Hill-only and Hybrid) is still placed on the
path edge, at the free edge spot farthest from every placed unit (or farthest
from the player when it is placed first). Its footprint is about three units
across, so other units keep 48 reference pixels from its centre instead of 24.
It never anchors a partner or the edge line; the line keeps growing from the
last ordinary edge unit. Placement order still follows the slot priorities.

## Hill-only and Hybrid placement

Each slot has mutually exclusive Hill-only and Hybrid checkboxes, saved in
unit_settings.ini. Leave both off for normal path-side ground placement.
Both modes select the slot and look for newly highlighted green Hill terrain,
starting inside the green surface nearest the illuminated path. Natural green
scenery, HUD and cyan range rings are excluded.

Hill-only units require a confirmed highlighted Hill surface. If no usable
Hill terrain or free Hill space exists, those copies remain unplaced and later
units continue (retried every 10 s); Hill-only units never fall back to ground.
Every other unit is retried until it is placed before any later unit starts,
so the build order holds.

When a purchase fails, one OCR pass reads the Yen counter above the toolbar and
the cost printed under each slot portrait. If Yen was below that unit's cost,
the miss is not counted toward relocation and the spot stays usable; the macro
re-reads Yen about once a second (at most 20 s) and then places the same unit.
Costs are saved by unit name in learning.ini [UnitCosts] once two reads agree.
Successful placements are never slowed by this check. Hybrid units try
Hill terrain first, then use normal path-side placement when Hill is unavailable.
Confirmed Hill placements are recorded and upgraded using the same numbered
positions and priority rules as other placements.

## Recorded placements and upgrades

Upgrades are read and clicked on the unit's tile in the F manager; the side
panel's UPG heading and R are no longer used. Lit bar segments under the tile
(bright green or yellow; a dark body, with or without a white outline, is not done) are the
upgrade level. Like holding R, the macro keeps clicking the tile's Upg button
until the unit reaches MAX or its target; there is no failure counter, and
clicks that buy nothing (not enough Yen) are simply repeated. A MAX target is
clicked every 0.3 s (even with an unreadable bar); a finite target waits up to
2 s for each new segment, so a slow bar cannot overshoot it. MAX needs the grey
Max button and every segment lit (or a Max button that stays for 4 s); a level
jump nobody clicked for, or a MAX, must read the same twice 0.25 s apart, so a
manager that is still opening cannot end a unit early.
The first tile seen for each slot teaches that slot's portrait colours; a tile
that clearly looks like a different slot is never clicked. Unreadable bars,
missing tiles or a portrait mismatch defer only that unit for 10, 20, 40, then
60 seconds while other units continue; any confirmed upgrade resets the back-off.
One diagnostic screenshot per unit per match is saved as cache\upg-tile-<id>.bmp.
Target edits in the UI update already-recorded units immediately; only target 99
requests MAX.

Every confirmed purchase receives a number (#1, #2, ...), its exact position,
slot, priority and upgrade target. The current numbered build is written to
placement_run.ini. Upgrades find each recorded purchase number's tile in the F unit manager
and process the lowest unfinished
priority first; equal priorities follow placement number. Cards are the only
time the F manager is closed (one F, only when it is confirmed open). After the
card the manager is reopened and the top-priority unit's tile is found again
before any click. Counts advance only when a new lit segment appears or the
grey Max button shows. Unaffordable clicks stay pending at the same priority.

Confirmed positions are also saved by map pattern in placement_layouts.ini and
by matching camera/player/window profile in learning.ini. Saved positions are
matched to the visible path-side line before reuse. Saved coordinates cannot
start another row beside a misplaced unit; each must be within six reference
pixels of a point on the same ordered path edge. Every stored map coordinate
must itself be directly beside the path. Map-level layouts must match the
current local path view before reuse. Defeat/Replay controls require actual
end-screen labels; green terrain is not an end screen.

## Endgame and automatic replay

A visible green Next button in the result modal triggers endgame handling for
both wins and losses. The title is read separately for accurate result reporting;
it is not required to trigger Next. Placements, upgrades and idle clicks pause.
The macro clicks the visible Next caption, then clicks game space five times
with 300 ms pauses between clicks to dismiss rewards. Delayed reward overlays
are dismissed again while the endgame transition remains active.

Once the paired Return to lobby and Replay buttons appear, focused OCR reads
the Replay button and clicks it once. Return to lobby is never selected.
The macro then waits up to three minutes for the next Vote Start, without
restarting the lobby flow. Once that new Vote Start is visible, the old endgame
state is cleared and the minimap/camera/build preparation runs again, whether
the replay leads to the same map or a different map. F7 stops every stage.

## Idle keep-alive

Once the build's upgrade targets are all complete, the running macro clicks
its existing click-away point in Roblox every five minutes. It uses smooth
movement, focuses Roblox before sending any input, and skips the click while
cards, a unit panel, or an end screen are open. Card handling and resumed
upgrading restart the idle period. F7 stops keep-alive input immediately;
there is no background click timer after the macro stops.

## Cards

A centre card's approximate tall outline and dark interior signal a card
choice. Card borders, frames and artwork do not determine buff/debuff type.
Windows OCR returns individual word boxes; pixels within those boxes determine
green beneficial words versus red harmful words. Effect-word colour is the first hard filter. If exactly one card has green
effect words, select it immediately; if two or three have green effects,
compare only those green cards. Red cards never compete with verified green
effects, even when their text suggests a different kind. A green Speed reduction
remains eligible if OCR misses its minus sign. Percentage-only green effect
lines count too; shared reward percentages do not. White titles still supply
buff names and tiers. Shared portal/pearl rewards are excluded from effect
classification. OCR enlarges text before recognition and returns original-size
coordinates. Ambiguous red/unknown text is retried rather than clicked blindly.

- Buffs: Double Attack first (it beats every tier of every other buff). Then
  Attack, Cooldown and Range by tier: the higher tier wins first (Cooldown II
  and Range II beat Attack I), and within one tier Attack, then Cooldown, then
  Range. Then Random Blessings (II before I), then any other green card,
  readable (for example green -Enemy Speed) or unreadable, then Yen, and Boss
  Damage last. Boss-only damage is never classified as general Attack or
  physical/magical resistance.
- Three unreadable cards of one colour (all green or all red words): the
  middle card is chosen.
- Card positions are measured once per card screen (`cardboxes` in
  MinimapVision.py) from the dark card panels, so the Level Modifiers panel
  next to the right card never adds its colours or words to that card. Without
  a detection the fixed 800x600 layout is used.
  Green Health buffs remain ahead of every red debuff.
- Green first above everything: a single card with green words is chosen
  immediately from its pixels, before OCR.
- Debuffs are judged on the total after taking the card, read from the Level
  Modifiers panel once per card screen: shield, explosive death, then health
  up to 300%, resistance up to 150 per type, regen up to 2%. Past those caps,
  the card that ends least far past its own cap wins (health on a tie), then
  regen past 2%, then an unreadable red card; positive Speed never. Between
  resistance cards, with balanced preferences, a shared physical+magical
  debuff (e.g. 50+50) beats a sole physical or sole magical one (75, 100, ...).
  The right panel is read only as match context and is never selectable.
- Physical/magical resistance amounts are parsed independently, including
  separate OCR lines, and added. With balanced preferences, 50+50=100 beats
  150 on a single type. The first digit of a bare number cannot be mistaken
  for a card tier. Equal totals prefer the smaller highest individual increase: 50 physical + 50 magical beats 100 of one type, regardless of accumulated resistance. Projected current resistance totals break ties only after both the total and highest increase match.
- On the Cards tab, Magic team prefers physical resistance to avoid harming
  magical damage; Physical team prefers magical resistance. Both off uses the
  balanced comparison. The preference saves in card_preferences.ini.
- Red Speed effects are blocked in selection, confirmation and fallback.
  Green Speed reductions are buffs and cannot be rejected by an OCR sign guess.
  An all-red-Speed offer is left unclicked. Plus and minus signs are preserved:
  +15% unit Cooldown is harmful; -15% unit Cooldown and -20% enemy Speed are
  beneficial. Unicode minus variants and a separated minus word are supported;
  the signed number is written in the decision log.

During placement and upgrades, cards are checked throughout cursor movement,
waits and pauses as well as before each input. Placement cancels with Q and
resumes the same unfinished slot/copy/spot. Upgrade interruptions click a safe
empty point to close the panel, select the card, then reopen the same recorded
unit with its priority and target intact. A pending purchase hidden by cards
is checked with a selection-only click before another copy is bought. A card decision is locked
for the current choice screen. Confirmation retries preserve ordinary green
choices, but newly verified green words override a previous red choice. A locked
Yen or Boss Damage choice yields to a better green buff, including unreadable
green words or green Speed. OCR changes cannot switch Cooldown to Yen. The decision
resets only after the screen has been absent continuously, or a fresh match begins. An open unit preview is closed
first (Q), and the chosen card remains locked until the choice closes.
Shared reward lines (such as "+30% SummerPearls") are ignored; common effect
keywords remain readable. Current OCR is read across all three cards for every
new offer so an old memory cannot hide a negative sign. Visual memory is a
fallback when current text cannot be read. Equal-stat buffs prefer a larger
amount, debuffs a smaller one. Regen ranks after health and resistance and is
taken only while the regen total stays at or under 2%.
Secret portal/drop-rate rewards are kept separate from the effect amount.
They never override a green buff. With
only debuffs and two ordinary alternatives, the ordinary choices are preferred
in the existing debuff order. All-secret choices keep the same debuff order.
Previously learned OCR cards are read once again to retain secret rewards;
placement memories and learned files are preserved. When effect text stays
unclear, a green-word buff, then the easiest readable debuff, then an
unreadable non-Speed card is selected; an all-Speed offer is left unclicked. Card memory refreshes for the
new policy and stores each resistance amount independently.

## Discord results

Paste a webhook URL in the Discord tab (Server Settings → Integrations →
Webhooks → New Webhook → Copy Webhook URL), press Save, and use Send test
message to check it. When a match ends, "Result: WIN" or "Result: LOSS" is
posted once with a screenshot of the Roblox window, taken before the end-screen
button is clicked. Victory and Defeat titles determine the result; both have
Next, so Next/Replay alone never implies a win or loss. The URL is kept only in settings.ini here; only
discord.com webhook URLs are accepted.

## Validation

    AutoHotkey64.exe /ErrorStdOut=UTF-8 AAPathMacro.ahk --self-test
    AutoHotkey64.exe /ErrorStdOut=UTF-8 AAPathMacro.ahk --startup-check

    python MinimapVisionTests.py

These modes send no game input. The minimap tests use only a cropped fixture from
the supplied Future City image: real route tracing, player/heart separation,
heading, enemy-icon gaps, no corner cutting, variant memory and hidden-marker
handling. The self-test also starts MinimapVision.py and checks it against the fixture and
minimap-screenshot.png (same map mid-wave): marker positions, recognition of the
learned map under enemy icons, and the W/S/D/A solve. MinimapVisionTests.py
checks movement detection, an arrow clipped at the frame edge or half covered,
and frame location. Both suites also read path-world-screenshot.png (P lit) and
path-toggle-off.png (P grey): toggle state, the lit band including chevron
gaps, follow points along it, and placement points that are beside it on both
sides and never on it or on the player. The full rotating-map run, the P click,
walking from a far spawn to the line, walking on the lit path in overhead view
and live placement remain unverified.

The P path toggle uses its persisted coordinate without repeated glyph searches.
It is clicked at most once during preparation when not confirmed on. Missing
glyph reads cannot block the saved-coordinate click; the lit road can confirm
success. Delayed confirmation never sends another toggle.

Before each ground placement input, a fresh unselected world scan must confirm
the coordinate is within 8–18 reference pixels of the road. Second rows require
a current first-row anchor and a road gap of 22–48 pixels. Stale candidates,
cyan-only rings and blue regions without nearby lime road evidence are rejected.
Run NavyPlacementTests.py, ToolbarTargetTests.py and UpgradeRegressionTests.py
for the screenshot, saved P coordinate and tile-upgrade regressions.
VisionRecoveryTests.py verifies black-frame fallback, the placement circle and
camera translation. UnitPanelRegressionTests.py checks a second device layout.
The shared screen reader rejects blank/wrong-size frames, falls back from DX
capture to MSS, and recreates MSS once before reporting a capture failure.
Capture failures never count as failed purchases or authorize movement.


Purchase confirmation recovery keeps unresolved purchases across path rescans. An opened side unit panel confirms the pending purchase immediately, regardless of whether its upgrade number is readable; selection-only recovery handles a delayed panel without buying again. Delayed panels are rechecked at the exact purchase coordinate. A failed spot advances only after two completed selection-only probes find no model and no panel has ever been seen. The configured count and copy number are checked again immediately before each purchase mouse-down. Run PlacementConfirmationTests.py for the four-versus-five regression.


Build audit: when placement believes the build is complete (and when the F unit manager keeps disagreeing with the record) the macro reads every enabled slot's `n/max` counter and corrects its record: ghost entries are removed newest first, a purchase it missed is recorded with no position, and a slot that is already full is never clicked. See MACRO_BEHAVIOUR.md section 5a. BuildAuditTests.py covers it.

## Unit manager selection

F opens Unit Overview. The newest unit is top-left and the list reads left to
right, top to bottom, so #1 is in the bottom row. With an even unit count the
bottom row is #1 right, #2 left; with an odd count #1 is ALONE at the bottom
left, and each row above holds the next even purchase on the right and odd on
the left. Odd or even comes from the recorded unit count, and the bottom row on
screen must agree before any tile is used.
Before selecting a recorded unit, the macro scrolls downward to the list bottom and
confirms it is stationary. Upward scrolling uses one wheel notch at a time and
checks the new row positions; reaching the top without the unit is reported as
"fewer units than recorded". While the list has not moved, the last tile found
is reused without scrolling. Upgrades click only the tile's Upg button (and the
portrait, if the game needs the unit selected first); Sell X and targeting
buttons are never clicked. F opens the manager only
after every unit is placed; it stays open while upgrades remain, except while a
card is chosen (closed for the card, then reopened), and is closed once every
upgrade target is reached or when left open from the last match. Upgrades
follow strict priority: a lower priority waits until the higher one is done. F is sent only after three consecutive "closed"
readings, never twice within 2.5 s, and two unconfirmed presses lock F for 20 s.
Click-aways use (497,168), left of the open manager. See MACRO_BEHAVIOUR.md.

Validation: CheckpointManagerTests.py exercises route quarters, purchase-order
selection through twenty entries in the game's newest-first layout, odd counts
(#1 alone bottom-left), bottom reset, and one-notch upward scrolling.
UnitManagerVisionTests.py checks the supplied screenshot at multiple sizes, rejects
portrait click areas hidden by the viewport, and reads segments (lit vs white
outline), the grey Max button, the Upg click point and portrait colours.
ActionPacingTests.py covers 150 ms unit actions
and unchanged 300 ms general controls. PlacementConfirmationTests.py checks
panel-only confirmation, placement caps and continued placement at checkpoint 3.
CardPriorityTests.py checks green Speed and unreadable green ahead of Yen/Boss,
all offer positions, and confirmation retries with fresh effect colours.
