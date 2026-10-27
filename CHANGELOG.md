# CHANGELOG.md

Accepted, meaningful changes, newest first, one to two sentences per task.
`HANDOFF.md` holds only the current state. Git holds earlier versions and exact
diffs from 2026-10-20 (`d2eb056`); earlier history may exist only in the archive ZIP
or the recovery snapshots (`HANDOFF.md` section 9). References in older entries to
former `HANDOFF.md` sections or removed files may need Git history or those copies. Entries are not edited
after they are written.

## 2026-10-27 — Combat Test isolation

`armor_test` places its own FF-01s instead of relying on the authored spawns and passes 52/52; `rocket_test` and `guided_missile_test` drop one unrelated Combat Test roster/asteroid/sector assertion each (parse-checked, not run).

## 2026-10-27 — Combat Test repositioning and test cleanup

The Combat Test FF-01s move to X = −150 / +150, outside sensor range, facing as before (`9edd0fb`). `ff01_test`, `combat_scene_test` and `positioning_boundary_test` drop 18 scene-dependent assertions and place their own ships, with no gameplay changes (`e9dfb5b`); the three suites pass 45, 25 and 76 checks.

## 2026-10-27 — Legacy ship cleanup

The legacy Frigate, Gunship and Destroyer are removed with their hull and variant scenes, legacy weapon configurations, the combat lab with E01–E04 / P01–P03, and their dedicated tests; retained scenes and shared-system tests now use the Miner, Transporter and FF-01, with the ship architecture and shared systems unchanged. Known limits: `combat_positioning_test`'s detour check (sensitive to the new opponent) and the pre-existing `fleet_test` hostile-focus failure stay open, E05 balance and duration assertions only print measurements, and the `sensors.gd` `last_known()` freed-contact script error is recorded as a separate production task.

## 2026-10-27 — Combat Test: two FF-01 frigates

`combat_test.tscn` now holds only a player FF-01 at (−45, 0) and an Aggressive hostile `HostileFF01` at (45, 0), facing each other; the other warships and `HostileCommander` are removed, with asteroids, sector, camera and lighting unchanged. Verified by scene diff only; the combat suites that load this scene still expect the removed ships and were not run.

## 2026-10-27 — Stage 6B: FF-01 combat positioning and continuous movement

FF-01 gains opt-in autonomous cannon-band positioning with one-step combat heading/speed inputs, and movement becomes continuous: braking-aware course turns for single-ship MOVEs under way, a rate-limited route aim anchor, Waypoint Moves flown through as one route, and a non-flickering cruise plume. PlanarCollision now contains every ship within ±`map_half_size` through four sector-edge rectangles (course turns need 3 × lookahead of edge and obstacle clearance); `combat_positioning_test` covers it and the regression retains only the three known failures.

## 2026-10-26 — FF-01 Barrage and Wayfarer launch profiles

Owner-approved broadside launch profiles add inherited world velocity and finite post-clearance turns: Barrage clears 4 u, commits one dispersed salvo solution and ramps at 30 u/s² to 30 u/s within 70 u total travel / 4 s while retaining 60 u acquisition; Wayfarer clears 8 u and retains active guidance, avoidance and sensor rules. Focused suites pass, including 148 trajectory checks, and the final 25-suite combat regression retains only the known fleet-focus failure, with Combat Test smoke and rendered validation accepted.

## 2026-10-26 — Stage 5: Guided Missile family and GCM-4 Wayfarer

The reusable Guided Missile family installs GCM-4 Wayfarer on FF-01 with committed four-cell salvos, remembered original-target guidance, bounded obstacle avoidance, strict nine-second expiration and shared armor/interception behavior (`f1a5952`). Owner play validation accepted Stage 5; missile verification passed 71/71 and two full regressions retained only the three known baseline failures, with all six scene smoke runs passing.

## 2026-10-26 — Stage 4: Rocket family and RL-8 Barrage

A reusable unguided Rocket family (`rocket_launcher.gd`, rocket kind in `ordnance.gd`) with the RL-8 Barrage (`rl8_barrage.tres` / `.tscn`: committed 8-rocket salvos at 0.12 s on a locked world-space direction, 3° dispersion, 48 rockets, 5 s cooldown, 30 u/s over 60 u, 4 hull / penetration 8 / 1 armor) is installed on FF-01's Barrage hardpoint, and rockets are intercepted only by Gatling-family rounds (Kestrels and legacy Gatlings, under the existing missile priority rule) while cannon shells pass through them (`baa7484`). `rocket_test` passed 72/72 and two full regressions matched two baselines apart from updated FF-01 loadout checks and the three known failures; accepted by the owner after play validation.

## 2026-10-26 — Stage 3: PDC family and PDC-20 Kestrel

A reusable PDC family (`pdc.gd`, extending the Gatling mount) with the PDC-20 Kestrel (`pdc20_kestrel.tres` / `.tscn`: 0.2 hull / penetration 1, 0.08 s, 25 u, 70 u/s tracers, 40-round magazine of 400, 3 s reload, 2.5° physical dispersion) is installed on FF-01's four PDC hardpoints; mounts select independently with own-ship before ally protection, torpedoes before missiles except a missile arriving under 1.5 s and earlier, and the Gatling's selection order moved into an overridable `_defense_before()` (`94a7a37`, `pdc_test`); accepted by the owner.

## 2026-10-26 — Stage 2: Cannon family and NC-90 Bastion

A reusable Cannon family (`turret.gd` with per-mount seeded `Weapon.disperse()`, uniform over the cone's solid angle) with the NC-90 Bastion (`nc90_bastion.tres` / `.tscn`: 12 hull / penetration 20 / armor damage 6, 2.5 s, 75 u with 45 u effective range, 40 rounds, 0.5° dispersion) is installed on FF-01's forward and aft centerline hardpoints, and `take_hit()` now rejects non-finite damage inputs (`586ac21`, `cannon_test`); accepted by the owner.

## 2026-10-26 — Stage 1: Global armor and damage resolution

Ships may carry a `DurabilityConfig` (hull, armor condition, armor resistance; FF-01: 160 / 100 / 30 in `ff01_durability.tres`), and every hit resolves through one global formula from the pre-impact condition (hull damage = base × p / (p + resistance × condition / max), armor condition reduced by the hit's armor damage), while unconfigured penetration keeps legacy weapons bypassing armor and every other ship at hull 150 (`f152f8b`, `armor_test`); accepted by the owner.

## 2026-10-26 — Combat Test arena cleanup and expansion

`combat_test.tscn` became a standalone 760 × 760 arena (navigation, command bounds, camera, Strategic View and ground at ±380) with the 36 Test Arena asteroids unchanged, no stations and only the six armed ships plus FF-01, instead of inheriting `main.tscn` (`4006e65`); the unarmed Frigate panel check moved from it to the Test Arena (`090d1f2`); accepted by the owner.

## 2026-10-26 — FF-01 Frigate blockout

New `ff01.tscn` primitive hull (12 × 3 × 1.1 u, bow −Z) and `ff01_unit.tscn` warship variant (Destroyer handling and footprint, `Behavior`) with eight empty, named hardpoints for the planned loadout (two cannon, four PDC, Barrage and Wayfarer), placed in the Combat Test arena and covered by `ff01_test` (`4006e65`); accepted by the owner.

## 2026-10-25 — I01 combat-positioning boundary mismatch resolved

Combat positioning and edge diagnostics now share the configured StaticNavigation boundary resolved through RouteFollower's `navigation_path`, replacing the production 135 u limit while preserving footprint and clearance semantics, movement and combat rules, and the independent E05 fixture boundary; accepted by the owner, with no further combat tuning authorized by this fix. Verification passed all 76 new boundary checks and compared 28 existing suites plus four scene smoke runs against two pre-change baselines: only the known navigation, obstruction and fleet-focus failures remain open, and P02 and integrated battle measurement changes were reproduced as boundary effects.

## 2026-10-25 — Hostile Combat overrides kept on save

The hostile `Combat` overrides were lost on editor saves because Godot saves overrides on nested instance children only with Editable Children; `[editable]` entries for the three hostiles in `sector_showcase.tscn` and `combat_test.tscn` fix it (reproduced and verified headless); accepted by the owner.

## 2026-10-25 — Whitebox frigate mesh added

The owner's `frigate_001.glb` was copied into the new `assets/models/ships/whitebox/` folder (assets organised by type); it is not yet used by any scene; accepted by the owner.

## 2026-10-25 — Camera pitch refinement

The camera rig's pitch now runs from 40° (up to 20 u) to 60° (from 100 u) instead of 45° to 80°, for a more oblique tactical view; FOV, zoom distances, interpolation and the Strategic View transition are unchanged, and `camera_test` asserts both defaults and the log-midpoint pitch; accepted by the owner after comparing 30°, 40° and 45° close pitches in the Showcase.

## 2026-10-25 — Session start and historical lookup

`AGENTS.md` session start now reads `AGENTS.md` and `HANDOFF.md` and consults `CHANGELOG.md` and Git history only when historical context is relevant, and the CHANGELOG header states that HANDOFF is current state only, Git holds history from 2026-10-20 and earlier history may exist only in the archive; accepted by the owner.

## 2026-10-25 — HANDOFF restructured to current state

`HANDOFF.md` was rewritten from a phase-by-phase history (2,402 lines) into a current-state reference organised by system (about 1,000 lines): architecture contracts, processing order, ownership and command semantics, frozen areas, known limitations and test baseline; verification logs and prototype records were removed (kept in Git history) and outdated statements corrected against the code; accepted by the owner.

## 2026-10-25 — Workflow: inspection, decisions and verification

`AGENTS.md` now treats decisions accepted in `HANDOFF.md` as confirmed (obsolete cube prototype line removed), widens step A to interacting code where relevant, lets findings and plan share one response when nothing blocks, puts regression risks and verification scope in the plan, matches verification to the type of change, and separates owner decisions (behavior, visual design, architecture, scope, substantive implementation) from routine coding details; accepted by the owner.

## 2026-10-24 — Reusable thruster VFX

Replaced the cone plumes and drawn jets with two reusable GPU-particle scenes in `game/presentation/thrusters/` (main thruster: core, plume, trail and idle glow; directional: neutral continuous stream, pulses optional), driven by `ThrusterView` on ships and by the ordnance on missiles and torpedoes (ribbon trails kept), with shared Inspector-tunable resources, a preview scene and the strict reusability policy added to `AGENTS.md`; accepted by the owner.

## 2026-10-24 — Showcase glow and volumetric fog

The owner turned on glow and a warm volumetric fog (anisotropy 0.9, length 12.69) in the Sector Showcase's WorldEnvironment (`sector_environment_test` 39/39); accepted by the owner.

## 2026-10-24 — Destroyer hull redesign fixes

On the owner's redesigned Destroyer hull, mirrored the bows and two main engines (now inside `ship_radius`), set the side jets flush on the widened Spine, lowered the missile cells and cannon onto the Spine top and gave every `MainEngine*` cylinder its own plume, with `thruster_view_test` and `salvo_test` updated (`fleet_test` hostile focus now a known failure); accepted by the owner.

## 2026-10-24 — Workflow: editability question

`AGENTS.md` step B now asks, when a result includes values judged by look or feel, whether to expose them in the Godot editor, give a manual refinement guide, or neither, and step D reports where the agreed editable values live; accepted by the owner.

## 2026-10-24 — Repository cleanup

Removed the unused `ui_palette.gd` and the empty `.claude/`, corrected HANDOFF (startup scene, Playable list, suite count) and added the missing `--fixed-fps 60` to `strategic_view_test` and `sector_environment_test` in the documented test commands (`strategic_view_test` 30/30 with it); accepted by the owner.

## 2026-10-24 — Showcase sky panorama replaced

The Showcase sky (sky modes B, C and environment lighting D) now uses `multi_nebulae_2.png` (10000 × 5000, tracked in Git) instead of the local-only `HDR_galactic_plane_1.hdr`, which is deleted; rotation and brightness unchanged (`sector_environment_test` 39/39); accepted by the owner.

## 2026-10-23 — Ordinary Group MOVE keeps the group's shape

Group MOVE now translates every selected ship's current position by the displacement from the group's centroid to the clicked point, relocates only ships whose translated destination is invalid, and lets the others move when some ships cannot be placed (those keep their orders; notice "N of M ships ordered"); the old placement-order search is removed, the cursor uses the same solver with a sector-boundary filter, and `_order()` / `_execute()` report acceptance (step 3, projected slot ordering, was rejected and reverted); accepted by the owner.

## 2026-10-23 — Group MOVE collision fix, step 2: re-plan after a far pass

When an avoidance pass ends with the ship more than a separation off its path, its order is planned again from where it is (`RouteFollower.replan()`, same destination, not a new player order), so it no longer drives blind into the parked ship (Showcase probe contacts 172 → 42 of 40 runs); accepted by the owner.

## 2026-10-23 — Command cursor group check without the placement-order search

The command cursor now checks a group MOVE with `GroupOrders.can_assign()` (the first placement only, the same accept / refuse answer on 704 of 704 probe points) instead of the full `assign()`, removing the hover freezes over a moving group (Showcase: 74 → 0 frames over 33 ms in 40 s); clicks unchanged; accepted by the owner.

## 2026-10-22 — Group MOVE collision fix, step 1: same-course pass side

Avoidance now passes a ship moving the same general way only on the side away from it (else it yields), so a giving-way ship no longer swings across the other's track (`ship_avoidance.gd`; Showcase probe runs with contact 28 → 10 of 40); accepted by the owner.

## 2026-10-22 — Sector Showcase hostile faction restored

Restored the three hostile ships' `Combat` overrides (faction 1, Aggressive) in `sector_showcase.tscn`, lost in an editor re-save, so they are fogged and engaged again (`sector_environment_test` 39/39); accepted by the owner.

## 2026-10-22 — Sector Showcase and environment rendering

New `sector_showcase.tscn` (760 u sector shared by navigation, commands, camera and Strategic View; local fuel scale 0.1; no ground; authored formations, hostiles and a depth backdrop), a 1080-line UI canvas with smaller markers and a separate click radius, the tactical grid withdrawn, and in the Showcase the HDR sky, designed sky lighting, Strategic formation depth with sky-safe fog, a lit Strategic layer and lightweight god rays with shadow bands (`sector_environment_test` 39 checks); merged to `main` by the owner, the HDR panorama kept local only.

## 2026-10-21 — Environmental lighting and fog prototype

A warm sector profile (`warm_sector.tres`) now sets the light, ambient fill, background and fog colour, with per-formation dust and debris (`SectorEnvironment`), a tinted, edgeless fog softened only on the covered side, and Strategic tinted shadows (new `sector_environment_test`); merged to `main` by the owner.

## 2026-10-21 — Phase C: Strategic View

A separate top-down Strategic View entered past the Tactical zoom limit (exact Tactical pose restored on return), with simplified asteroids, contours, directional shadows, cluster and resource markers with radial expansion, Strategic fog and marker-only picking (`strategic_view.gd`, new `strategic_view_test`); accepted by the owner.

## 2026-10-21 — Phase B: Local / Tactical semantic zoom

Ship models now stay visible at every zoom while tactical markers fade in over them with one continuous Tactical emphasis (zoom distance 30–100), joined by station and individual asteroid markers; picking checks interactive ship markers then hulls, and the ring, hull bars, object icons and grid follow the same value (new `tactical_view_test`, adapted strategic and combat scene checks); accepted by the owner.

## 2026-10-20 — Camera Phase A: continuous zoom

Wheel zoom is now smooth and cursor-anchored, the camera pitch follows the rendered zoom (45° to 80° between 20 and 100 u), and the wheel no longer zooms over UI panels (`camera_rig.gd`, new `camera_test`, adapted strategic, time and selection checks); accepted by the owner.

## 2026-10-20 — Defended-area ring hidden

Stopped drawing the Defensive defended-area ring (`behavior_view.gd`); the 12 u repositioning limit is unchanged. Accepted by the owner.

## 2026-10-20 — Strategic marker heading tick removed

Removed the white heading tick drawn beside every ship marker at strategic zoom (`tactical_markers.gd`); accepted by the owner.

## 2026-10-20 — Git repository and GitHub remote

The project is now a Git repository on branch `main`, pushed to the private GitHub repository `nikosban/apalit` (SSH remote) with an initial commit of 348 files; `archive/` was added to `.gitignore` and stays local only.

## 2026-10-20 — Stale editor cache cleanup

Removed 61 stale `.godot/` cache files (about 5.2 MB: editor state for deleted or moved scenes and imported textures of deleted PNGs) and the deleted `experiments/station_docking/tri_station.tscn` entry from `scene_groups_cache.cfg`; live entries and the editor's general caches were kept.

## 2026-10-20 — Orphan UID cleanup

A file inventory audit found four `.uid` files in `game/tests/combat/fixtures/` (`combat_camera_rig`, `combat_locomotion`, `combat_selection`, `combat_thruster_view`) whose scripts no longer exist and whose UIDs nothing referenced; they were deleted, leaving one `.uid` per script and shader (143).

## 2026-10-20 — Production combat integration and repository consolidation

The play-tested combat and fleet behaviour (four weapon families with hardpoints, ammunition, salvos and point defense, hull damage on every ship, Commands, Tactics and Weapon Profiles on the armed Gunship and Destroyer, faction-shared sensors and fog of war, global pause and time dilation for the whole simulation, strategic zoom and tactical UI, a minimal hostile commander) now runs in production on the existing movement, docking, selection and economy systems, with autonomous positioning separated from player commands and the held-command defect fixed; accepted by the owner after gameplay testing, with the ported combat suites unchanged and three new production suites. The superseded combat prototype, Movement V3, parked-navigation and station-docking experiments and `_migration_tmp/` were deleted (671 files) after a verified post-migration snapshot, the docking regression files moved to `game/tests/docking/`, three unused code paths were removed, and every regression run before and twice after the cleanup matched (known navigation and obstruction failures unchanged). Details: `HANDOFF.md`.

## 2026-10-18 — Movement V3: Direct-move prediction horizon (group MOVE rotation)

On a direct move, avoidance now ends its own-ship prediction where the leg ends instead of after the straight distance from a displaced ship, which ran past the destination and kept a pass against an idle ship parked beyond it, so ships (most often a Miner after a group MOVE) shuttled and spun beside their destination indefinitely; in a 336-click group MOVE sweep rotating stalls fell from 19 to 1 and stalled ships from 189 to 141, with every regression suite unchanged and a new `group_rotation_test`. Accepted with known deviations (more collision contacts in layouts that still stall, some ex-spinning ships now in the known mutual give-way stall). Details: `HANDOFF.md`.

## 2026-10-18 — UX and quality-of-life round

Fixed the transport configuration and refinery counter defects. Added:
- commands given during docking maneuvers are validated in two stages, and the latest valid one is kept;
- Miners face their asteroid before extracting;
- automated transports wait in their berth until loading or unloading is complete;
- a themed right-hand inspector with editable display names, and a draft transport editor with one atomic Apply;
- hover and selection outlines, hover/selected-only object markers and context cursors;
- black thruster parts with a three-state main plume and directional jets on every ship type.

Accepted package by package and as a whole round, with nine new test suites and owner-approved assertion migrations; every regression suite matches the baseline (known navigation and obstruction failures unchanged). Details: `HANDOFF.md`.

## 2026-10-17 — Reusable ships and stations architecture

Every ship type is now defined once as a variant scene (hull under `Model`, its own settings) inheriting one of three functional archetypes (Warship, Mining Ship, Transport Ship), all starting ships in `main.tscn` and the Shipyard's produced ships are instances of those same variants, and Refinery and Shipyard became reusable station scenes on the unchanged `station.tscn` layout, with every model, component setting and behaviour preserved. Accepted after gameplay testing, with the configuration dump and every regression suite matching the baseline (known navigation and obstruction failures unchanged) and a new reuse test proving cross-scene reuse and independent instances under the documented scene layout contract. Details: `HANDOFF.md`.

## 2026-10-17 — Phase 4: Ship Production

A third station, the Shipyard, uses the existing docking and station storage to build one Mining Ship (200 iron, 100 nickel, 50 silicon ingots, 60 s) or Transport Ship (300 iron, 100 titanium, 50 cobalt ingots, 90 s) per order from complete unit scenes: orders wait without consuming or reserving anything, the whole recipe is consumed at once when present, and the finished ship deploys idle and fully fueled at an authored marker only when its footprint is clear (otherwise it waits), joining selection and the command layer through new runtime registration; a Ship Production section in the station panel shows recipes, shortages, progress and blocked deployment. Accepted after gameplay testing, with the new deterministic and uninterrupted-game-loop suites passing and every regression suite matching the baseline (known navigation and obstruction failures unchanged); recipes and durations are provisional. Details: `HANDOFF.md`.

## 2026-10-16 — Phase 3: Refining

Metal Chunks were replaced by individually stored Iron, Nickel, Silicon, Cobalt, Gold, Titanium and Ice, mined deterministically in each asteroid's fixed proportions; transport requirements can be units or percentages of the hold (edits exceeding it rejected), and Station2 gained a two-slot refinery turning raw minerals 1 for 1 into ingots, configured from a new station selection and panel. Accepted after gameplay testing with every regression suite passing (known navigation and obstruction failures unchanged); mineral distribution, refining rates, logistics balance, models and UI polish remain subject to future iteration. Details: `HANDOFF.md`.

## 2026-10-16 — Phase 2.5: Station-controlled docking (stage 2b)

Docking now uses the stations' editor-authored berths: ships navigate to a handover point, the station guides them in and out at a fixed heading through Locomotion, berths are granted from the FIFO queue only when physically clear and the waiting ship's corridor is free (removing the hand-over deadlocks), and player commands given during a maneuver or while docked are held or validated before the controlled exit, with group destinations kept and Mining / Transport unchanged. Accepted after gameplay testing; durations are a baseline, the Destroyer's circular footprint remains a known limitation, and no further docking refinements are authorized. Details: `HANDOFF.md`.

## 2026-10-15 — Phase 2.5: Station docking integration, stage 2a (passive berth geometry)

Both stations now carry editor-authored Berth nodes (Destroyer-sized parking rectangles, parking pose and heading, handover, back-out and two fixed exit points) with an on-demand occupancy query and an optional debug drawing, which production docking does not use yet; `berth_test` (12/12) confirms the authored parking points equal today's docking positions and records that Station's west-berth ExitA is blocked by an asteroid for the Destroyer, and every other suite is unchanged. Details: `HANDOFF.md`.

## 2026-10-15 — Phase 2.5: Station docking integration, stage 1 (guided Locomotion)

Locomotion gained a guided mode (station-defined turn and straight legs within limits capped by each ship's own, no route or avoidance input, heading held at hand-back, collision and fuel unchanged) that nothing in the game uses yet, verified by a new `guided_locomotion_test` (10/10) with every other suite identical to the pre-change baseline apart from timings. Details: `HANDOFF.md`.

## 2026-10-15 — Experiment: Station-controlled docking prototype (not integrated)

An isolated prototype (`experiments/station_docking/`) where the station guides ships through a fixed entry and exit via Locomotion, with authored parking rectangles that keep reservation, physical occupancy and corridor clearance apart, and deferred player commands, docked every class at 0.00° with no contacts and removed the reproduced hand-over deadlocks on the exposed-arm station and a recessed tri-dock test station; it is slower than production, and the Destroyer's collision circle does not fit the tri-dock bays. Details: `HANDOFF.md`.

## 2026-10-15 — Phase 2.5: Transport configuration consistency

Changing or clearing a station, or setting every requirement to zero, during an active transport assignment now pauses it once with a notice (docked: stays docked, transfer stopped; undocking: finishes; otherwise the dock request is released; cargo, fuel and configuration kept), and an invalid configuration never reaches docking; before, it caused per-tick script errors, endless same-station or empty round trips, or cargo delivered back to its source. Details: `HANDOFF.md`.

## 2026-10-15 — Phase 2.5: Rejected-order consistency

A refused player command (MOVE without a route, Mine without a reachable working position, Dock without a reachable docking position, Resume) now only shows a notice and leaves the ship's order, route and assignments unchanged, and Dock on the station a ship is already docking at changes nothing; before, refusals replaced targets, released docks while the ship stayed in its slot, paused mining, or left a ship steering at a frozen aim point without avoidance. Details: `HANDOFF.md`.

## 2026-10-15 — Investigation: Parked-ship navigation (not integrated)

An isolated experiment (`experiments/parked_navigation/`) showed that routes plan correctly around already-parked ships, but synchronous rebaking costs about 119 ms per park/departure on the game map, routes planned before a ship parks need invalidation and replanning, and local avoidance is still required; asynchronous or incremental updates were not evaluated. Production avoidance was restored to the accepted cause C version and the paused cause B planned-rejoin prototype kept in `experiments/planned_rejoin/`. Details: `HANDOFF.md`.

## 2026-10-15 — Movement V3: Multiple stationary ships (cause C)

A ship now passes two stationary ships when the passing shift it applies already clears the second one (no contradictory yield, the second encounter takes the same passing side), so 14 of 14 passable two-ship layouts arrive instead of 5, while gaps too narrow to pass still hold short. Details: `HANDOFF.md`.

## 2026-10-15 — Movement V3: Ship obstruction correction

Ships now pass a stationary ship from close range (ShipAvoidance: the passing steering point keeps the reserve and the pass speed cap limits only travel toward the stationary ship, 75 of 75 previously stalling approaches arrive), and a single-ship MOVE onto or beside a stationary ship goes to the nearest valid point outside its clearance (notice; refused with a notice and nothing cancelled if none within 5 u). Two stationary ships close together and the direct-move overshoot past a stationary ship remain open movement issues. Details: `HANDOFF.md`.

## 2026-10-14 — Phase 2, Stage 6: Transport logistics

A Transporter graybox (Gunship handling, 4.1 u radius) and a second station at (−108, 6) were added; a transport assignment (load at, unload at, Metal / Ice Chunk quantities) now repeats load → deliver → return unattended through the existing docking, timed transfers and refueling, waiting nearby for missing stock or destination storage, configured and resumed from the ship panel, with manual orders pausing it. Logistics soaks exposed Movement V3 stalls (a ship pushed sideways near its route's end stops short; deadlocks beside asteroid 19 and at docking hand-overs), recorded as known limitations. Details: `HANDOFF.md`.

## 2026-10-14 — Phase 2, Stage 5: Automated mining

A Miner's asteroid assignment now runs the whole cycle unattended: mine until full, return to its chosen base or the nearest station it can dock at through the existing docking queue, unload with the timed transfer, refuel, and go back to the same asteroid, with a final return on depletion; the panel adds a base selector, the operation's status and Start / Resume Mining, and manual orders pause the operation while keeping its settings. Two Miners sharing one asteroid can still stall permanently (Movement V3 mutual give-way), recorded as a known limitation. Details: `HANDOFF.md`.

## 2026-10-14 — Phase 2, Stage 4: Fuel & resupply

Every ship now has a fuel tank used by the distance it actually moves (after collision), with Low Fuel / Fuel Warning / Critical Fuel notices at 15 / 10 / 5 %, complete immobilization at zero (no translation or rotation, order kept, reported to avoidance as stationary so others pass it), and automatic refueling from the station's separate fuel stock while docked, shown in the ship panel and station hover. With fuel available movement is unchanged. Details: `HANDOFF.md`.

## 2026-10-14 — Phase 2, Stage 3: Stations & docking

One graybox station (a static obstacle for navigation and collision) with two external docking arms now serves every ship class: right-click it with one ship selected to dock bow-in through RouteFollower orders only, with two shared slots, a first-in-first-out queue and holding positions, Undock, station storage and timed manual Unload / Load of raw cargo that keeps its request when blocked. Traffic deadlocks under heavy simultaneous station traffic (Movement V3 mutual give-way) are accepted as a known limitation (owner: Option A). Details: `HANDOFF.md`.

## 2026-10-14 — Phase 2, Stage 2: Mining and cargo

Two Miner graybox ships (Frigate handling, Mining Scanner) now mine an asteroid on a right-click: one validated working position, one route order, then extraction into a capacity-limited cargo of raw lots (Metal Chunks keep their asteroid's composition, Ice Chunks are ice) until the cargo is full or the asteroid depleted, with a beam and panel status; a manual MOVE cancels the assignment and keeps its target. The Frigate, Gunship and Destroyer now carry Generic Scanners. Details: `HANDOFF.md`.

## 2026-10-14 — Phase 2, Stage 1: Asteroid resources and scanning

Every asteroid now has a fixed resource deposit (minerals: six whole-percent minerals, or ice 100 %; finite reserves; stable ids; reproducible session seed), and the Frigate (Generic Scanner) and Gunship (Mining Scanner) reveal it into a fleet-wide survey through Scan Area: pulse, surface-analysis grid with progress, DATA UPLOADED and three persistent asteroid markers, plus hover information and a selected-ship panel. Movement V3 unchanged. Details: `HANDOFF.md`.

## 2026-10-14 — Final legacy cleanup

Removed the original game's remaining documents (`Refine/`, `tech_docs/`), its older baseline ZIP and the unused `asteroid.tscn`, all preserved in the verified archive; the owner design decisions that still apply were kept in `HANDOFF.md`. No gameplay change. Details: `HANDOFF.md` → Archive, Design decisions carried forward.

## 2026-10-14 — Stage 7: Movement V3 becomes the game

After archiving the original game (`archive/apalit_pre_v3_integration_2026-10-14.zip`, verified), Movement V3 was copied into `res://game/` and became the game: `main.tscn` is now a playable scene with the three V3 ships in a field of 36 sphere asteroids (read as circles by navigation and collision), the former lab is the test arena `game/scenes/movement_test.tscn`, and the old movement scripts and scenes were removed. The experiment stays unchanged as the reference. Details: `HANDOFF.md`.

## 2026-10-14 — Movement V3 experiment, stage 6: Collision enforcement

Ships in the lab can no longer move into other ships or obstacles: a read-only planar collision service constrains each Locomotion step (bounding circles, rotated boxes, continuous sweeps, only the velocity into a contact removed, orders kept), with identical movement when nothing is touched and every earlier suite unchanged; Movement V3 is now the approved movement baseline. Carried forward: collision does not resolve traffic deadlocks, conservative circles (Destroyer), surface creep, plus the stage 3–5 limitations. Details: `HANDOFF.md` → Movement V3 experiment.

## 2026-10-13 — Movement V3 experiment, stage 5: Selection, orders and group movement

Ships in the lab are now selected by click, Shift-click and box drag and keep their right-click MOVE orders independently of the selection, and a group MOVE gives every selected ship its own reachable destination once per command (largest first, approach-aware, preferring fewer departure conflicts, all or none), with avoidance extended by overtaking, converging and crossing-yield rules. Carried forward: no physical collision enforcement, late detection of ships accelerating from rest and some unsafe passes still possible in avoidance, plus the stage 3–4 limitations. Details: `HANDOFF.md` → Movement V3 experiment.

## 2026-10-13 — Movement V3 experiment, stage 4: Local avoidance

Ships in the lab now pass or yield to each other with a small per-ship avoidance step that only offsets steering and caps speed through the same locomotion (smaller ship gives way, starboard in head-on, astern in crossings, idle ships held around), with no contacts and at least 1 u clearance in every tested encounter; the Frigate's top speed is now 5 u/s. Carried forward: the Destroyer mid-route redirect aim-line failure, no physical collision response, the yield fallback not yet a permanent test, and the camera start zoom. Details: `HANDOFF.md` → Movement V3 experiment.

## 2026-10-13 — Movement V3 experiment, stage 3: Static navigation

Ships in the lab now route around fixed obstacles (NavigationServer2D, one map per ship size, one route per order, followed with a continuous lookahead through the same locomotion), plan corner and arrival speeds ahead, brake without overshooting, and ease into small course changes; top speeds are now 6 / 4.5 / 3 u/s. Still open: one Destroyer mid-route redirect brings its aim line inside the clearance reserve for a few ticks (no hull overlap), and the Frigate's speed is to be lowered in stage 4. Details: `HANDOFF.md` → Movement V3 experiment.

## 2026-10-13 — Movement V3 experiment, stage 2: Locomotion

Ships in the lab now move with one shared bounded-kinematics controller (per-ship profiles, forward/reverse/lateral limits, turn-aware braking, facing their destination except for short corrections), commanded by temporary 1/2/3 + right-click input with a Movement Debug HUD and headless tests. Deferred: the Frigate feels too fast and the Destroyer may face a few degrees off its marker. Details: `HANDOFF.md` → Movement V3 experiment.

## 2026-10-13 — Movement V3 experiment, stage 1: Isolated lab

Added the disposable `experiments/movement_v3/` folder with a standalone lab scene (grid, lighting, copied camera rig) and three graybox ships (Frigate 3 u, Gunship 6 u, Destroyer 12 u), with no movement and no changes to existing files; debug tools are deferred until the new systems exist. Details: `HANDOFF.md` → Movement V3 experiment, `experiments/movement_v3/README.md`.

## 2026-10-13 — Movement refinement milestone closed (S4-I7 not accepted)

A fix for traffic holds while turning (S4-I7: ships stopping straight along their velocity) cured its target collisions but added contacts and stalled orders in the 30-ship stress run, so it was kept aside in `Refine/experimental/S4-I7/` and the game was restored to the verified post-S4-I1 baseline. The movement refinement is closed with stage 4 not yet safety-accepted; the remaining traffic bugs and improvements are a backlog to be taken up from observed gameplay. Details: `HANDOFF.md` → Next task, `Refine/TASKS.md`.

## 2026-10-13 — S4-I1: Head-on late blocker

A give-way ship braking to a stop inside another ship's path is now treated as an obstacle at the point where it will rest, so the other ship holds short of it: the S4-I1 head-on completes both orders with no contact, both original soak contacts are gone and the 30-ship stress test has none, with Scenario 2 unchanged. Traffic holds while turning (a mid-arc hold contact in the soak and an imprecise stop point across corners) remain a stage 4 safety blocker under S4-I7, the next task. Details: `HANDOFF.md` → Next task, `Refine/TASKS.md`.

## 2026-10-13 — Fantasy alignment pass closed: stage 4 verification (S4-T4)

Stage 4 was verified (acceptance 7 of 7, Scenario 2 accepted on replay) and a provisionally retained latest-arrival correction now lets a head-on give-way ship pass with one small alteration (Scenario 2: 8.23 u off its route instead of 69 u), closing the movement refinement pass with thruster braking, persistent orders, arcs and course alteration in place. Outstanding as follow-up tasks: the S4-I1 head-on late blocker (safety; soak ship contacts 2 → 4 since the correction), traffic performance (about 2.9 ms per frame at 30 ships against 1 ms), destination congestion and the other S4-I items; the manual profiler check is pending. Details: `HANDOFF.md` → Next task, `Refine/TASKS.md`.

## 2026-10-12 — Fantasy alignment pass, stage 4 (S4-T2, S4-T3): Course alteration

In crossing and head-on conflicts the give-way ship (head-on: both) now bends around the other with one validated thruster-arc course alteration instead of holding, monitored every step and replaced by the normal holds as soon as it stops being valid, with no weaving and a checked resume after a hold; stage 4 verification (S4-T4) and a pre-existing head-on late-blocker contact (S4-I1) remain open. Details: `HANDOFF.md` → Next task, `Refine/TASKS.md`.

## 2026-10-12 — Fantasy alignment pass, stage 3: Arcs

Moving ships now turn on their directional thrusters with the main engines dark, flying course changes and route corners as predictable constant-speed arcs (corners sharper than 90° stop and pivot), with corner speeds and braking legs planned so they can always be flown and validated before an order is given. Details: `HANDOFF.md` → Ship propulsion, Route planning, `Refine/TASKS.md`.

## 2026-10-11 — Fantasy alignment pass, stage 2: Orders never die

Main now keeps every order in a record until arrival: blocked or taken destinations are moved to the nearest reachable point (refused only beyond 40 u), contacts and failed replans leave the order waiting and rechecking instead of cancelling it, and the player is told when a ship makes no progress for 5 minutes or at once when two ships block each other. Details: `HANDOFF.md` → Orders, `Refine/TASKS.md`.

## 2026-10-11 — Fantasy alignment pass, stage 1: Thruster braking

Ships now brake only with their directional thrusters, nose held and no flip, in two modes (MANEUVER, CRUISE), with every stopping estimate and caller switched together (stop from top speed ≈ 124 u); braking through route corners (D15) remains a tracked limitation for stages 2–3. Details: `HANDOFF.md` → Ship propulsion, `Refine/TASKS.md`.

## 2026-10-11 — Task 17: Dynamic ship navigation

Ships now give way to each other (the later arrival holds short using normal braking), reroute once around idle or waiting ships, and otherwise wait with the order kept, rechecking every 20 s and notifying the player after 5 minutes of waiting. Details: `HANDOFF.md` → Ship traffic.

## 2026-10-11 — Task 16: Asteroid pathfinding

Move orders now route around asteroids (AStarGrid2D with 1 u path clearance) and the ships follow the route with the existing propulsion, braking early for corners; unreachable or unsafe orders are refused with a 2 s notification, and a route failure gets one automatic recovery. Details: `HANDOFF.md` → Route planning and autopilot.

## 2026-10-11 — Task 15: Ship-to-ship collision

Ships now stop on contact with each other (1.7 u spheres, resolved after all
ships move; moving ships stop and report `blocked`, stationary ships are
untouched), and a "Collision Debug" toggle shows each ship's collision ring.
Details: `HANDOFF.md` → Ship-to-ship collision.

## 2026-10-10 — Flip recovery fix

A new order during the braking flip or roll no longer snaps the ship model
level; it now rotates back smoothly at `rotation_speed` (visual only).
Details: `HANDOFF.md` → Braking flip.

## 2026-10-10 — Task 14: Ship-to-asteroid collision

Asteroids now have convex-hull collision, and ships sweep a 1.7 u sphere each
step, stopping at contact with the order cancelled (`blocked`, not
`arrived`). Details: `HANDOFF.md` → Asteroid collision, Asteroids.

## 2026-10-10 — Task 13: Multiple ships and selection

Added two more ship instances (three in total) with click, Shift-click, and
box selection, and right-click orders sent to every selected ship, each moving
independently. Details: `HANDOFF.md` → Unit and selection.

## 2026-10-10 — Braking flip visual

The BRAKE turn is now shown as a nose-down pitch followed by a 180° roll
back upright (visual only; movement unchanged). Details: `HANDOFF.md` →
Braking flip.

## 2026-10-10 — Task 12.5: Thruster visual effects

Added blue-white exhaust plumes and directional jets that show the thrust
the movement component actually applies (main engines, translation, and
rotation), smoothed to avoid flicker. Details: `HANDOFF.md` → Ship, Thruster
effects.

## 2026-10-10 — Task 12: Ship model and asteroid clusters

Replaced the cube ship with a flat elongated body, two rear main thrusters,
and 16 directional thruster cubes, and added three fixed, visual-only
asteroid clusters (3, 8, and 12 asteroids). Details: `HANDOFF.md` → Ship,
Asteroids.

## 2026-10-10 — Task 11: Heavy-ship propulsion

Lowered main thrust and braking to 0.3 u/s² and directional thrust to 0.2,
widened the directional braking range to 60 u, and gave CURVE its own
`turn_acceleration` (0.5) independent of the main engine. Details:
`HANDOFF.md` → Ship propulsion.

## 2026-10-10 — Task 10: Course changes

Raised directional thrusters to 1.0 u/s² and the maneuvering speed to 3 u/s,
and added a CURVE phase so MAIN-mode course changes bend with a 45° nose lead
instead of a retrograde flip when the target is outside the turning circle.
Details: `HANDOFF.md` → Ship propulsion.

## 2026-10-10 — Task 09: Movement debug tools

Added a "Movement Debug" toggle (off at launch) that shows a speed/mode/phase
HUD, the range circles, the debug label, and a ship-to-destination line.
Details: `HANDOFF.md` → Movement debug.

## 2026-10-10 — Task 08: Larger playable area

Enlarged the playable area from 100 × 100 to 300 × 300 (ground mesh,
`map_bounds`, camera rig `bounds`), still centred on the origin.

## 2026-10-10 — Task 07: Map bounds for move orders

Added `map_bounds` (100 × 100 on X/Z) to `main.gd`; right-click move orders
outside it are silently ignored. Details: `HANDOFF.md` → Unit and selection.

## 2026-10-10 — Task 06: Reusable ship scenes

Split the cube into a reusable `ship.tscn` unit and a `ship_movement.tscn`
component that moves its parent; behavior unchanged. Also introduced this
changelog. Details: `HANDOFF.md` → Ship, Ship movement.

## 2026-10-10 — Task 05: Directional braking range

Added a medium-distance mode (HYBRID) between two ship-centred range
circles: the main thruster accelerates, directional thrusters brake without
a flip, falling back to main braking when needed. Details: `HANDOFF.md` →
Ship propulsion.

## 2026-10-10 — Task 04: Ship propulsion and movement

Replaced constant-speed movement with main and directional thrusters,
inertia, rotation, braking, and course-change handling, plus debug range
circle, label, and nose. Details: `HANDOFF.md` → Ship propulsion.

## 2026-10-10 — Task 03: Camera controls

Added the reusable camera rig scene with pan, rotate, zoom, and
focus/follow. Details: `HANDOFF.md` → Camera.

## 2026-10-10 — Task 02: Single-unit selection and movement

Added the hovering cube with left-click selection, right-click move orders,
and a destination marker; window set to maximized. Details: `HANDOFF.md` →
Unit and selection.
