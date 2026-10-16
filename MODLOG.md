# Isaac Bot — development log

## Goal
Offline, single-player autopilot for The Binding of Isaac: Repentance+ v1.9.7.17.J460 (Steam 250900)
that plays a whole run with any character: clears rooms, dodges, picks items (with allow/deny lists
and forbidden combos), routes the floor map and takes the exit that leads to the chosen ending.

## Route (2026-10-13, kept)
- Vanilla Lua mod, no loader, no exe patching, no OS-level input. `MC_INPUT_ACTION` (13) answers
  movement/shooting/bomb/active (ButtonAction 0-9); logic in `MC_POST_UPDATE`, panel and bridge in
  `MC_POST_RENDER`.
- `mods\isaac_bot` is an NTFS symlink to `isaac-bot\mod`; edits are live after `luamod isaac_bot`.

## Layout (v0.5.0)
- `mod/main.lua` bootstrap: loads `isaacbot/<module>.lua` via `include`, wraps every callback in pcall.
- `core` settings/state/input composition, `grid` room grid + flood/A*, `danger` threat sim + dodge,
  `combat` targeting/fire/charge/actives/bombs, `items` pickup values + lists, `floor` room graph and
  exits, `brain` goal selection per update, `presets` named settings (built-in + user), `panel` F8
  mouse menu (presets bar, settings, item tiles, catalog), `bridge` file bridge, `telemetry` EV lines.
- `legacy/main_v0.3.0.lua` previous single-file version (local only, not published).
- Tools: `tools/bridge.py` (send console/bot commands), `tools/runlog.py` (EV log report),
  `tools/verify_lua.py` (parse + unknown globals + dead code), `tools/night.py` (night runs: backup,
  watchdog, relaunch), `tools/nightreport.py` (morning report -> `runs/report-*.md`),
  `tools/bench.py` (30-seed bench, daytime), `tools/deathview.py` (death replays -> PNG + timeline),
  `tools/progress.py` (progress charts over all sessions -> `runs/progress.png`).
- `replay` module: ring of the last 90 updates (3 s) the brain saw and did; frozen on each player
  hit, dumped at game over as one `replay` EV line (room map, the hit) + one `rf` line per update.
- Local git repo at the `isaac-bot` root (no remote); `runs/`, `shots/`, the bridge folder ignored.
  Keep files LF: Python `open(p, "w")` on Windows writes CRLF, use `newline=""` when editing.

## Facts verified in the real game
1. Input hook works for movement and shooting, **but door transitions query movement with
   `entity == nil`**. Returning nil there left the bot standing in an open doorway; answer nil-entity
   queries too (actions 0-9 only).
2. `RoomConfig.Doors` (desc.Data.Doors) is the mask of slots the layout *allows* (every 1x1 = 15). A
   door exists only where both neighbours allow one; build edges as mutual directed edges and add the
   current room's real doors (`Room:GetDoor`) as ground truth.
3. `include("isaacbot_bridge.cmd")` re-reads the file. The bridge file sets a global
   (`ISAACBOT_BRIDGE = {...}`) and the mod reads that. `luamod isaac_bot` through the bridge reloads
   the mod in place ("Success!").
4. `Isaac.RenderText` output was not visible; a `Font` loaded from `font/luaminioutlined.fnt` and drawn
   at `Isaac.GetScreenHeight() - 34` is.
5. The debug console pauses the game while open (`~` opens, Esc closes); `lua <code>` runs in the mod
   environment, `_G.IsaacBot` is reachable.
6. A fireplace counts as a contact-damage body, which turns the dodge simulation on in that room. The
   simulation's wall penalty then beat "walk into the door"; safe proposals now bypass it.
7. Module upvalues must be bound at module init: callbacks such as MC_POST_NEW_ROOM can fire before
   the first MC_POST_UPDATE.
8. Brimstone lasers are not reliably found by `SpawnerEntity` + `FrameCount <= 4`; the old check
   saw no attack, so the learned charge time ran up to its 150-update cap (5 s per shot). Snapshot
   player attacks (`InitSeed`, matched by `SpawnerType`/`Parent`) at release and look for a new one
   during the next 10 updates. Azazel's charge measured ~31-37 updates; learning keeps the longest
   failed hold as a floor and rescales with `MaxFireDelay`.
9. Jumping/burrowed bosses (Monstro 20, Gish 43.1) fail `IsVulnerableEnemy`/collision checks while in
   the air, so they were neither enemies nor dodge bodies; the bot walked to the room centre and was
   landed on. They are now danger zones at their projected landing spot, and "hold" moves to the
   reachable cell farthest from them.
10. The bedroom (RoomType 18) door stays locked even with keys (it takes two bombs, fact 24); a door that stays locked when reached
   marks its room unreachable for the floor. Routing only takes doors that strictly shorten the
   distance to the goal (removed a 124<->125 ping-pong).
11. A closed Host (27.0) is invulnerable with CollisionDamage 0, so it was neither an enemy nor a
   threat; the blind sweep turned every 20 updates, which with a charge weapon never released. "Hold"
   now fights shut active enemies like visible ones, and the sweep finishes each charge before turning.
12. Fireplaces (EntityType 33): lit = HitPoints 5, EntityCollisionClass 4, State 1; put out = HitPoints
   1.0, EntityCollisionClass 0, State 3, the entity stays and CollisionDamage stays 1.0, so "lit" is
   `HitPoints > 1`. Variant 4 (white) cannot be put out. Only lit fireplaces block the grid and count as
   contact hazards (statics, no dodge simulation); if one blocks the path to a pickup or door, the bot
   shoots it out (mode "fire", event `fire_out`, max 2 tries per cell per room). Replaces fact 6.
13. Brimstone fired into an empty room after each fight because the charge was released when the room
   cleared. The charge is now kept held between fights (`keepCharge`), and a failed release right after
   a room change does not count for learning.
14. Azazel's Brimstone beam (laser variant 1) lives 8 updates (`Timeout` 7 -> 0). Pressing fire while
   it is on cuts it and starts a new charge, so after a release the button stays up until no new player
   laser with `Timeout > 0` remains (2 s cap). The bot also cleared input during room entry
   (`room:GetFrameCount() < 2`) and paused updates: a held charge fired there and the next press cut it
   to 2 frames. Those frames now keep the held direction pressed.
15. The fireplace static hazard counted at every simulated step froze the bot next to its firing spot
   (spot under a lit fireplace; the 16-update simulation walks past the spot into the fire): 5000
   updates holding a full charge. Statics now count only for imminent contact (first 4 updates), and a
   full charge aimed for 90 updates without lining up is released toward the target anyway.
16. A trapdoor (GridEntityType 17) that appears under the player stays closed (sprite animation
   "Closed", State 0) until the player walks away; then "Open Animation" -> "Opened" (State 1) ->
   "Player Exit". The bot stood on a closed one for 1700 updates after the Caves II boss; it now
   steps to the nearest reachable cell 110-200 units away while the trapdoor reads "Closed".

17. **After a fresh game launch `include("isaacbot_bridge.cmd")` fails**: it returns the string
   "no file 'resources/scripts/isaacbot_bridge/cmd.lua' ..." (only the game's scripts folder is
   searched; the mod folder is on the path only after a `luamod`). The bridge now has a second
   channel: `tools/bridge.py` also writes `{"bridge": {id, ts, cmds}}` into the mod's save data
   (`<game>/data/isaac_bot/save1.dat`, a JSON settings file), which the mod reads with
   `mod:LoadData()` once a second. The mod keeps the key when it saves settings. Commands whose `ts`
   (`os.time()`) is under 60 s old run even when they are the first ones seen after a launch.
18. Menus (Russian UI, keyboard): intro video -> Enter; title "press start" -> Enter; file select
   (File 1 preselected) -> Enter; main menu cursor starts on Continue when a run is saved, on New Run
   otherwise; the menu wraps around (Up from New Run goes to the last item). Character screen keeps
   the last character and difficulty; Up/Down there change the difficulty. So the watchdog sends
   Enter x5 and never arrows. Verified twice by kill + Steam relaunch.
19. The `lua` console command reports nothing when the chunk errors; wrap probes in `pcall` and log
   the error.
20. The breaker flood (rocks/fires passable) used the passable cost for the no-corner-cutting check,
   so its path slid diagonally between a rock and a lit fireplace, through neither, and `planBomb`
   found nothing to break. The bot, knocked into a 1-cell pocket (rock left/right, fire below),
   stood there for good. The corner check now uses the real cost; the bot shot out the fire at
   once. Fire-out tries also come back after 20 s instead of never.

21. Hit telemetry: a grid-spike hit comes with source type 0, variant = grid type (8 spikes,
   9 on/off spikes) and DamageFlag 128 (DAMAGE_SPIKES); on Hard each costs a full heart. Night
   2026-10-16: 29 spike hits, about 20 while walking to loot and 7 while walking to reward plates (the
   flood priced spikes at +60, but loot or plates behind or on spikes had no other path). Loot and
   plates now refuse any path that steps on spikes (`G.spike`, `G.pathHurts`).
22. Fireplace hits (12 that night) came mostly in fights. The dodge simulation skipped itself
   when nothing but fires was around, so fires never pushed back. It now runs when a lit fire is
   within 40 units and counts contact within 6 units; path cells next to a lit fire cost +4. Hit
   events now carry the player position (`px`, `py`) and, for fires, distance `fd` and size `fs`.
23. Poop (GridEntityType 14) blocks movement and tear line of sight, but tears break it (no bomb
   needed). The fight fell back to "walk to the enemy" and stood still when poop walled it off. Now
   the breaker flood also passes poop (cost 10), and the plan shoots the first poop on the way from a
   cell on its row or column with open floor between. Fights use poop and fire plans, never bombs.
   Loot and doors use them too.
24. Bedrooms (RoomType 18 clean, 19 dirty) only appear when the player is low on red hearts: seed
   BPL0 J8BC, `stage 2` at 3 hearts has none, at half a heart has a dirty bedroom at 85. Its door
   reports `IsLocked()` true and variant 3 (DOOR_LOCKED_CRACKED); keys do nothing, two player
   bombs dropped on the cell in front open it. The bot now treats it as a bomb door: it counts the
   room as interesting only with `useBombs` and at least the bombs still needed (2 minus bombs
   already dropped there this floor), bombs from the cell in front, steps 110-200 units away while
   the bomb is down (and resets the stuck timer), and gives up on the room after four bombs.
   Without enough bombs neither the goal choice nor `doorToward` picks it.
25. Poop or a rock on the cell right in front of a door stalled the bot in the doorway: the door route
   uses radius 1, so it "arrived" next to the poop and pushed into it until the stuck timer
   blacklisted the door, then came back 30 s later. `doorGoal` now checks that cell first and shoots
   the poop (or plans a bomb for a rock; without bombs the door is blacklisted at once).
26. A golden chest in a corner with rocks on its two open sides (reachable only corner to corner)
   had the bot pushing into the diagonal gap: loot routing used radius 1, so the diagonal cell
   counted as "there", and the flood never cuts corners. Loot now needs its own cell reachable (or a
   side neighbour within 30 units when it lies on a blocked cell's edge); otherwise the breaker plan
   runs, and rocks are bombed for value >= 7, or value >= 4 (chests) with at least 2 bombs. With no
   bombs the pickup is skipped.
27. Enemy Brimstone (EntityLaser variant 1, SpawnerType = shooter) hurts on the frame it appears, so
   dodging the beam itself is too late. Vis 39.0 sits 28 updates in State 9 before the beam,
   Double Vis 39.1 30 updates, Gluttony 49.0 28 (learned). The beam lives Timeout 31 and then
   fades with Timeout going negative to about -18, and the fading beam still hurts (hit 39 updates
   after spawn). `GetEndPoint()` carries the beam's height offset (21 units up), so the line goes
   from Position along `AngleDegrees`. The danger layer now marks the 4 lines out of a known
   shooter in attack states 8-12 from 6 updates before the expected beam until its laser appears
   (wind-up learned per type.variant, event `brim_learn`). Marking them for the whole wind-up
   made the bot never stand in line long enough to shoot (2 Vis alive after 45 s).
28. F8 menu (panel.lua, immediate mode, mouse): the render screen is 426x240 units at 1280x720
   (scale 3). Font probe (`Font:Load` + `GetStringWidthUTF8` of a Cyrillic sample): only
   `font/cjk/lanapixel.fnt` (lh 13, used at scale 0.692), `font/teammeatex/teammeatex10.fnt` and
   `font/pftempestasevencondensed.fnt` draw Cyrillic; terminus/luaminioutlined/droid give width 0.
   lanapixel draws a dark shadow, so dark text on gold is unreadable: selected states use dark gold
   with white text.
29. The game HUD is drawn after MC_POST_RENDER, over any mod overlay: the menu hides it with
   `Game():GetHUD():SetVisible(false)` while open and restores it on close.
30. Item icons: `gfx/005.100_collectible.anm2` layer 1 with `ItemConfig.GfxFileName`; the art is
   centred 22 sheet px above the layer origin and about 22 px tall, so a box of size s renders at
   (x + s/2, y + s/2 + 22*k) with scale k = s/22.
31. Input while the menu is open: MC_INPUT_ACTION returns false/0 for movement, shooting, bomb,
   item, pill/card, drop, map and pause actions (0-11, 13, 16-19, 32), so typing in the search box
   does not move Isaac. Keyboard text comes from `Input.IsButtonPressed(key, 0)` per key (no text
   event in the API); the RU layout maps US keys to ЙЦУКЕН in Lua.
32. Testing without the mouse: the game does not redraw while unfocused (screenshots are stale)
   and `um win drive click` refuses while the Claude window is in front. Working pattern: a
   background `um win drive focus "sleep N" untop` holds focus, `bot menu click X Y` (screen units)
   fakes a press/release over 3 frames, then `um win shot`. Bridge commands sent in one call run in
   the same frame, so each fake click needs its own call.
33. `RoomDescriptor.GridIndex` is the top-left cell of the room's bounding box. For an L room
   missing that corner (shape 9, LTL) it is an empty cell, and `GetRoomByIdx(thatCell)` returns a
   blank descriptor (GridIndex/SafeGridIndex/ListIndex -1, VisitedCount 0, Data nil). Look rooms
   up by `SafeGridIndex` (always inside the room). Before the fix such a room counted as never
   visited forever; `chooseGoalRoom` picked the room the bot stood in, `routeFloor` returned nil and
   the bot stood still until the 6-minute fast mode (night run 2026-10-16, stage 4 room gi 81).
   The status line kept the last mode ("off" after F9), so the stall looked like a disabled bot.
34. `Room:GetGridPosition(0)` is the centre of cell 0, (40,120) in a 1x1 room; cells are 40 units;
   `GetTopLeftPos()` is (60,140).
35. Console `seed ABCD EFGH` starts a new run with that seed and keeps the character and
   difficulty of the current run (Isaac/Hard stayed Isaac/Hard). It works from the game-over
   screen as well (the bench restarts with it after each death). `restart <char>` after a seeded
   run keeps the seed (after a bench every run would have been the last bench seed).
   `Seeds:ClearStartSeed()` before `restart` gives a random seed, but the game then holds that
   seed too (the next plain `restart` repeated it), so the mod clears before every plain restart
   (`B.unseed`, also for bridge `restart`); the game logs a harmless "[ASSERT] Game Start Seed
   was not set." each time. Verified: seed -> 4 restarts gave 4 different seeds.
   `Seeds:IsCustomRun()` is useless for "clean": it stays true for every console-started run.
   The mod tracks it itself: `seed` (bridge or bench) sets `st.seedNext`, MC_POST_GAME_STARTED
   turns it into `st.seeded` = `st.cheat` (that reset used to clear the bridge's cheat flag).
36. Game logic (and the bot) keeps running while the window is unfocused; only a pause menu stops
   it. Bridge commands need no focus, so the bench runs in the background.

## Night runs (v0.5.0)
- `python tools/night.py --until 09:00 --char 0` (started detached with `Start-Process`, output in
  `runs/night-console.log`). Backs up the saves as `isaac-night-steam` / `isaac-night-mygames`
  (newest 7 kept), keeps the PC awake, copies every EV line to `runs/night-<stamp>.jsonl`
  (log.txt is rewritten on each launch), and acts on the mod heartbeat (`hb`, once a minute, also
  while paused): paused -> focus, then Esc; bot off -> `bot on`; same room 8 min or no new floor
  30 min -> `bot newrun`; dead without restart -> `bot newrun`; log silent 5 min (2.5 after a win)
  -> menu keys once, then kill by exact PID + Steam relaunch + menu keys, max 5 per night.
- Clean run = Hard and no console command other than `restart` (any `lua` probe or `luamod`
  through the bridge sets `cheat`; the flag is in hb/death/win events).
- `python tools/nightreport.py [night.jsonl]` -> `runs/report-<stamp>.md` (Russian): clean win %,
  per-character results, deaths by floor and last hit source, stuck/abandon counts, watchdog actions.

## Seed bench and death replays (v0.5.0)
- `python tools/bench.py [--cap N] [--n K] [--tag T]`: `restart 0`, then `bot bench <cap> <seeds>`;
  the mod plays each seed of `tools/bench_seeds.txt` (30, Hard, Isaac) and starts the next one
  itself after death, win or passing floor `cap` (`bench_cap`), then `bench_done`. Settings keep
  the bench across a relaunch. Watchdog in daytime mode (`night.py --day`): no window focus, Esc,
  menu keys or relaunch unless the user has been idle for 60 s (GetLastInputInfo).
  Summary `runs/bench-<stamp>.md/.json`: mean floor reached, share reaching 3/5/8, wins, per-seed
  result with the previous bench, git commit + dirty flag.
- Acceptance rule (user, 2026-10-16): a change stays if the bench mean floor does not drop.
- `python tools/deathview.py [jsonl|log.txt]` draws `runs/deaths/<stem>-<n>.png`.

## Verification log
- 2026-10-15: v0.4.0 loaded, bot fought rooms (screenshots `shots/s3.png`). Stuck in a 1x2 room with a
  fireplace (doors blacklisted -> "unreachable" spam 1800x). Fixed facts 1, 2, 6 + badRooms expiry +
  boss fallback. After reload: 40 rooms, Basement II boss, Catacombs I as The Lost, 7 items, no
  stuck events.
- 2026-10-15 (later): user reported a loop (fact 10, fixed). Deaths: The Lost to Gish, Isaac to
  Monstro, both in "hold" (fact 9, fixed). Auto-restart picked Isaac after `luamod` (start
  character lost on reload; now falls back to the player on screen). User reported charge attacks
  not working; Azazel confirmed with hold=150 (fact 8, fixed): after reload, Cellar I -> Caves I in
  ~3 min with no failed charges after convergence.
  Then "бот застрял" next to a Host in Caves I (fact 11, fixed: Host killed, bot moved on). Azazel died
  in Caves I to type 220 in a normal fight; auto-restart picked Azazel (start-character fix verified).

- 2026-10-15 (evening): user reported wasted Brimstone shots and fireplaces treated as unbreakable
  enemies (facts 12, 13). Test: penny walled in by 3 lit fireplaces via the bridge -> bot shot out the
  one on its path (`fire_out` cell 32), took the penny (coins 0 -> 1), left the others; screenshot
  `shots/f3.png`. Charge log: hold converged 40.3 -> 34.8, one fail after a MaxFireDelay change, relearned.

- 2026-10-16: user reported Brimstone beams cut short by the next charge (fact 14) and then "бот застрял"
  (fact 15, Horf room with two lit fireplaces). Per-frame laser probe (MC_POST_LASER_UPDATE via the
  bridge): before, every room entry produced a 2-frame beam; after, 36/36 beams ran the full 8 frames;
  bot cleared the Basement I boss and went on to Basement II.

- 2026-10-16 (later): "бот застрял" again: closed trapdoor under the bot in the Caves II boss room
  (fact 16). After reload: Closed -> bot walked to 160,210 -> Opened -> Player Exit -> Necropolis XL.

- 2026-10-16 (night): v0.5.0 heartbeat seen in log.txt; watchdog pause handling worked live (focus,
  Esc, run resumed); kill + relaunch + menu keys -> run continued (twice). First night start found two
  blockers: bridge dead after a fresh launch (fact 17, fixed) and the bot walled in by a fire (fact 20,
  fixed, `fire_out` right after reload). Night restarted 01:49 until 09:00 as Isaac on Hard.

- 2026-10-16 (morning): night report: 51 runs, 0/50 clean wins, deaths mostly on floors 1-2 (28/41),
  9 runs abandoned stuck, infrastructure ran 7 h without a crash. In-game test (console scene,
  cheat run): a poop wall across the start room with a Gaper behind it, a coin ringed by spikes, a lit
  fire on the way. The bot shot through the top poop, killed the Gaper, left the spiked coin, no
  fire or spike hits.

- 2026-10-16 (day): user report "bedroom door needs 2 bombs" and "stuck forever in a doorway
  blocked by poop". Console scenes (cheat runs): poop on the cells in front of all four start-room
  doors -> `door_blocked` cell 22, `poop_out` 45 ticks later, through the door. Seed BPL0 J8BC
  floor 2 at half a heart (dirty bedroom at 85, other rooms marked bad for the test): with 1 bomb
  the bot left through another door and never touched the bedroom door; with 3 bombs
  `bomb_door` n=1 at 4630, n=2 at 4750, entered room 85 (type 19) at 4817, no stuck events.
  User report: golden chest wedged between two rocks (fact 26). Scene in the start room: chest
  5.60.1 at cell 16, rocks at 17 and 31, 1 key. With 1 bomb the bot ignored it and left, no stuck
  events; with 3 bombs `bomb_rock` cell 17, chest opened, item Dry Baby taken. Night restarted
  10:04 until 08:00 next day (`--no-backup`, the 09:53 backups stand).
- 2026-10-16 (day): user report "the bot cannot dodge enemy Brimstone". Night logs: 23 of 435 hits
  had DAMAGE_LASER (Vis, Gluttony, Forsaken, Frail), 4 deaths. Console scenes (cheat runs, +12
  hearts): 3 Vis (one Double) 33 beams, 0 laser hits, room cleared; Gluttony 12 beams, 0 laser
  hits, killed (about 60 s). Before the fading-beam fix, 2 Vis: 4 hits from 12 beams. Night
  restarted 10:23 until 08:00 next day (`--no-backup`), log `runs/night-20261016-1023.jsonl`.
- 2026-10-16 (day): new F8 menu (variant C sidebar, presets, item pictures, "?" tips; facts
  28-32). Night stopped 10:43 for the test. Checked in game through fake clicks and keys
  (screenshots `%TEMP%/claude/menu*.png`, `m6-m20.png`): Cyrillic text, catalog with icons and
  Russian names, search "118" -> Сера, typed "голов" in RU layout -> 12 items, Enter -> tile 1 in
  priorities, pinned "?" tip, preset dropdown with summaries and icons, "изменён" marker, Save as
  "Стандарт (мой)" (name form, toast, new row), "…" menu, delete with confirm, reset changes,
  a behaviour switch on/off, game HUD hidden. No ERROR lines. Not yet checked: real mouse buttons,
  tile drag, scrollbar drag, rename, startup preset after a relaunch, F7/F8/F9 keys.
  Settings left as preset Стандарт, unchanged. Night restarted 10:58 until 08:00 next day
  (`--no-backup`).
- 2026-10-16 bot stall ("бот завис"): cause in fact 33. Fix: floor rooms keep `safe` =
  SafeGridIndex for `F.desc`/`roomOfIndex`; `chooseGoalRoom` never returns the current room;
  brain sets mode "idle" each tick (and "gamepause"), and after 10 s idle in a clear room takes
  any exit door and logs an `idle` event with the goal it would have chosen. verify_lua PASS on
  brain/floor/panel; `luamod` in the running night: no ERROR, bot walks rooms again; probe shows
  every room (incl. LTR/LBR) resolving to its own descriptor with VisitedCount. No LTL on that
  floor, so the original case is not replayed yet. That run is marked cheat (lua probes).
- 2026-10-16 death replay + seed bench. Night watchdog stopped (it focused the window by day).
  Smoke bench `bench.py --n 3 --cap 2 --tag smoke` (runs/bench-20261016-1149): run_start carries
  `bench`/`seed`, Hard kept; seed 1 died on floor 1 -> `replay` + 90 `rf` lines dumped, `seed`
  from the game-over screen started seed 2; seed 2 looped between rooms on floor 2 (abandoned
  with `bot newrun floor`), seed 3 hit `bench_cap` on floor 3, then `bench_done` and the summary.
  Found and fixed on the way: plain restarts after the bench kept the bench seed (fact 35);
  hb `paused` is also true during room transitions (age 0), which made the watchdog focus the
  window (now only paused with age > 0 counts); bench floor limit 15 min.
  First findings from the data, not fixed yet (need the baseline bench first):
  1. Q6SD SYX8 floor 1, Gemini (79): pinned in the top-right corner for the whole 3 s, wants
     left, `D.choose` picks up-right into the wall at risk ~100. Inside a body every option
     scores the same 12/step, so the overlap penalty has no gradient out of the body.
  2. N3H2 E1FR floor 2: room 88, `stuck` going to door2 at (120-140, 190-217), then boss room
     100 and rooms 89/75/64 marked unreachable, the bot bounces 84-71-85-86-87 for 6+ min.

## Goals and decisions (user grilling, 2026-10-16)
- Done = any ending (any final cutscene/credits), on **Hard** difficulty.
- All 34 characters eventually, tainted included. Item choice with synergies.
- Order: 1) one character (Isaac) to any ending on Hard; 2) the other regular characters;
  3) synergy-aware item choice; 4) tainted characters one at a time (own control logic).
- Synergies: our own table of ~100 key synergies/anti-synergies, written in our own words from wiki
  facts, plus rules by item tags and weapon type. No copied wiki text.
- The bot may read anything the API exposes (full map, secret rooms, "?" items, unidentified pills).
- Testing: console jumps (`stage`, `giveitem`) allowed for debugging; only clean runs count toward
  win statistics.
- Night runs while the user is away; morning summary from log.txt (win %, deaths by cause/floor,
  stuck events). Runs on the user's **main save** (they accepted unlocks/stats/streak changes):
  dated `um backup` snapshot of the saves before every night, keep the last 7.
- Watchdog: if log.txt is silent for 5 min, close isaac-ng.exe by exact PID and relaunch through
  Steam (`steam://rungameid/250900`), max 5 relaunches per night.

## Decisions, second grilling (2026-10-16, after night 1: 0/50 clean wins, 28/41 deaths on floors 1-2)
- Metric: done is still a clean Hard win, but every night also reports mean death floor and the
  share of runs reaching floors 3/5/8; every bot change is judged by these numbers.
- First target: early deaths. First add a death replay (last ~3 s before death: player, enemies,
  projectiles, the bot's chosen move and reason), then fix causes by frequency.
- Daytime runs allowed in the background (mod-driven, no mouse/keyboard takeover; the watchdog
  must not steal focus while the user is at the PC).
- Two modes: daytime bench = fixed set of 30 seeds on Hard (via `seed`, not counted as clean),
  for exact version A/B; nights = clean random runs for the main metric.
- Autonomy: I accept a change myself if the bench mean death floor does not drop, otherwise
  revert; the user gets a short summary (what was tried, kept, numbers before/after). Local git
  repo in `isaac-bot` (no remote) for the rollbacks.
- Isaac counts as ready at >= 10% clean wins on Hard over a night (>= 5 of ~50); then the other
  regular characters.

## Publishing decisions (user grilling, 2026-10-16)
- Publish on GitHub now, as a prototype, with honest numbers (0 clean wins yet, mean floor ~2.3).
- MIT license, "Copyright (c) 2026 netlesha"; repo name `isaac-bot`.
- Commit author email rewritten to the GitHub noreply address before the first push (the id comes
  from GitHub once the user has signed in with `gh auth login --web`).
- Contents: everything except `legacy/` (mod, tools, README, MODLOG, kb_note). `runs/`, `shots/`
  stay ignored; the progress chart goes to `docs/progress.png`.
- README in English, Russian copy in `README.ru.md`; a "How it was made" section says it was built
  with Claude Code.
- Steam Workshop: not now; the user will bring it up.
- The push and repo creation happen only after the user's explicit go-ahead.

## Known limits
- Not handled: pills/cards, secret/super secret rooms, crawlspaces, alt path (Downpour/Mines door,
  knife pieces), T.Cain crafting, T.Forgotten/Soul and Jacob & Esau control specifics, Greed mode.
- Character support is generic (stats-driven: weapon type, flight, health type); Lost/Keeper adjust
  dodge weight and pickup values.

## Restore
- Saves backed up with `um backup create` as `isaac-steam-saves` and `isaac-mygames`;
  restore with `um backup restore isaac-steam-saves` (and `isaac-mygames`). Night snapshots:
  `isaac-night-steam` / `isaac-night-mygames` (zips in `~/.universal-modder/backups/<name>/`).
- Stop a night run: `um win kill <pid of python tools/night.py>` (PID printed at start; or Ctrl+C).
- Disable the mod: create `mod/disable.it` or remove the `mods\isaac_bot` symlink.
