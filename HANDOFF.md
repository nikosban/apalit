# HANDOFF.md

Last updated: 2026-10-31. Current state only. Development history is in `CHANGELOG.md` and Git; earlier versions of this file
(per-task verification logs, measurements, prototype records) are in Git history.

## 1. Status

The game: graybox spaceships on the X/Z plane under mouse command, with static
navigation, local avoidance and collision enforcement; a resource economy (asteroid
survey, automated mining, stations with station-controlled docking, fuel, repeating
transport assignments, a two-slot refinery, a Shipyard building Mining and Transport
ships); production combat on every ship (hull, factions, weapon loadouts on the
FF-01 warship, Commands / Tactics, faction-shared sensors
and fog of war, a minimal hostile commander); global pause and time dilation;
continuous camera zoom with Local / Tactical semantic zoom and a Strategic View;
environment rendering (sky, lighting, fog, god rays); a themed inspector UI, reusable
thruster VFX and a reusable combat flash. No component manufacturing, station construction, save system or
strategic AI.

FF-01 combat adjustments (developed on `combat_adjustments`, merged into `main` on
2026-10-27 in `13537ed`): the
FF-01 frigate in an expanded Combat Test arena, then Stage 1 global armor and damage
resolution (`f152f8b`), Stage 2 Cannon family / NC-90 Bastion (`586ac21`), Stage 3 PDC
family / PDC-20 Kestrel (`94a7a37`), Stage 4 Rocket family / RL-8 Barrage
(`baa7484`), Stage 5 Guided Missile family / GCM-4 Wayfarer (`f1a5952`),
the approved broadside launch profiles for Barrage and Wayfarer (section 4.6), and
Stage 6B: FF-01 autonomous combat positioning, continuous movement (course turns,
route aim anchor, flown-through waypoints, plume continuity) and sector-edge
containment (sections 4.1 and 4.6), the two-FF-01 Combat Test scene (section 2), and
the legacy ship cleanup: the Frigate, Gunship and Destroyer types, their hull and
variant scenes, their weapon configurations (`cannon.tres`, `gatling.tres`,
`torpedo.tres`, `missile.tres`), the combat lab with its E01–E04 / P01–P03 scenarios
and the tests that existed only for them are removed. Retained scenes and the shared
system tests now use the Miner, Transporter and FF-01; the archetype → variant →
instance architecture and every shared system are unchanged (section 3).

All listed work, including the resolved I01 combat-positioning boundary mismatch,
Stages 1–5, the final launch-profile revision, Stage 6B, the two-FF-01 Combat Test and
the legacy ship cleanup, is accepted by the owner. PDC raid sweep (2026-10-28, section
4.6 PDC entry) is on `main` and accepted by the owner after a Combat Test playtest.

UI visual authoring (issue #5, section 4.9) and shared selection/marker styles
(issue #6, section 4.8) are accepted by the owner.
Projectile/trail visual authoring and thruster relocation (issue #7, section 4.8)
are accepted by the owner, including the reported verification limitations.

## 2. Project layout and scenes

### Repository

- `project.godot`: Godot 4.7, main scene `res://game/scenes/combat_test.tscn` (owner change, 2026-10-29).
  Base canvas 1920 × 1080, stretch `canvas_items` / `expand` (2D sizes are px at
  1080p and scale with the window height); window maximized. Template defaults, not
  owner decisions: Forward Plus, Jolt Physics (unused by movement), D3D12 on Windows.
- `game/`: all production code, scenes and tests, one folder per system.
- `assets/textures/skybox/multi_nebulae_2.png`: the owner's 10000 × 5000 panorama
  (imported lossless, no mipmaps), Combat Test's sky; tracked in Git (owner decision).
- `assets/models/ships/whitebox/frigate_001.glb`: the owner's whitebox frigate mesh
  (11 meshes, 3 materials, no textures; about 8.4 × 21 u; a bare mesh, not a ship
  type, unrelated to the retired Frigate). Owner-made assets are organised by type under
  `assets/`. Not placed in any scene.
- `experiments/pdc_saturation/`: the PDC saturation / raid-sweep experiment the production
  PDC was integrated from, kept as isolated evaluation tools, not used by the game:
  `saturation_eval.gd` (headless comparison of the production Kestrel against the
  experimental control / saturation / raid_sweep variants; sets `static`, `moving`,
  `incoming`, `combined`, plus `trace`, `diagnose`, `visual`), the experimental mounts
  (`pdc_saturation.gd` extends `gatling.gd` with the pre-raid-sweep PDC order, so production
  changes never alter them; `pdc_raid_sweep.gd`), their `.tres` / `.tscn`, and
  `pdc_tracer_preview.tscn` (tracer authoring scene, defaults to the production Kestrel).
- `experiments/planned_rejoin/ship_avoidance_rejoin.gd`: the planned-rejoin experiment. The
  paused, unaccepted cause B planned-rejoin prototype: a full replacement of
  `game/avoidance/ship_avoidance.gd` as it was on 2026-10-15 (SHA-256
  4A7E9EFA…592655A). Not used by the game. It predates the 2026-10-18 direct-move
  prediction horizon, the 2026-10-22 same-course pass side, `Avoidance.forget()` and
  the step 2 re-plan, so it must be reviewed against current avoidance before any
  resumption; it is not production-ready.
- No `archive/` folder: the former local archive is outside the project (section 9);
  `/archive/` stays in `.gitignore` as a guard against recreating it.
- `AGENTS.md`, `CHANGELOG.md`, `HANDOFF.md`, `.editorconfig`, `.gitattributes`
  (text stored with LF), `.gitignore` (`.godot/`, `/android/`, `/archive/`).
- Git: branch `main` (all current work), remote `origin` = `git@github.com:nikosban/apalit.git`
  (public on GitHub, checked 2026-10-30; whether it stays public is an open owner
  decision, section 10). No commit or push conventions are decided beyond the initial setup.
  `combat_adjustments` (`9edd0fb`, fully contained in `main`) was deleted locally and on
  GitHub on 2026-10-30. `stash@{0}` (Combat Test ±150 test edits made on that branch,
  superseded by `e9dfb5b`) is kept by owner decision.

Terminology (owner-agreed): shared, self-contained pieces such as the camera rig are
"reusable scenes" (own `.tscn`, instanced into other scenes).

### Scenes

All gameplay scenes use `game/scenes/movement_lab.gd` as root script (name kept from
the lab era) and the layout contract in section 3.

- `main.tscn` (Test Arena; F6): development, regression and stress tests (32 suites
  load it). 300 × 300 sector with a plain ground, 36 sphere asteroids (seeded layout
  saved in the scene; stable `metadata/asteroid_id` 1–36), `Station`, `Station2`
  (`refinery_station.tscn`), `Shipyard` (`shipyard_station.tscn`, yaw +31°,
  owner-approved "option C"), three player ships (Miner1, Miner2, Transporter), no
  warships, no hostiles. Flat background, sun 60° up, no environment
  lighting, Strategic depth or god rays, `local_fuel_scale` 1, camera `max_zoom` 150.
  Every ship and station instance overrides only its transform (`shipyard_test`
  checks it). Station placement rule used so far: every docking, approach, holding,
  exit and deployment point ≥ 15 u from asteroid surfaces.
- `game/scenes/combat_test.tscn` (startup scene, F5; standalone since the FF-01 arena expansion, no
  longer inherits `main.tscn`): integrated combat on a 760 × 760 sector
  (`map_half_size` 380, camera and Strategic View follow ±380), the 36 Test Arena
  asteroids unchanged, no stations; `Ground` hidden (`visible = false`) and the
  `multi_nebulae_2` panorama as sky (`environment_experiment` 1, no designed lighting or
  god rays); two `ff01_unit` instances only: player `FF01` at
  (−150, 1.5, 0) facing +X and `HostileFF01` at (150, 1.5, 0) facing −X (300 u apart,
  outside the 100 u sensor range), symmetric about the sector centre. `HostileFF01`
  overrides `Combat` faction 1 / stance Aggressive (Editable Children); no
  `HostileCommander`, so it acts on its own Behavior (Aggressive pursuit of the
  nearest contact, FF-01 combat positioning).
- `game/scenes/movement_test.tscn` (root `MovementLab`, `scenario_keys` on): the
  Movement V3 test arena with grid ground and obstacle shapes under `Obstacles`
  (8 suites load it). Its ships are movement-only copies built on the hull scenes:
  `Miner`, `Transporter` (radius 3.4 in this copy) and `FF01`.
- `game/tests/reuse_arena.tscn`: the reuse test scene (section 3); not played.
- `game/tests/docking/`: `tri_station.tscn` (the owner's three-bay layout on the
  production station scripts; also used by `reuse_arena`), `station_docking_demo.tscn`
  (`main.tscn` with berth drawing), `tri_dock_demo.tscn`, `tri_dock_test.gd`.
- `game/tests/combat/fixtures/`: combat fixtures on production code.
  `encounter_arena.tscn` (two FF-01s per side) and its only variant `e05_fleet.tscn`
  (three FF-01s per side; `encounters.gd` holds E05 only),
  `combat_positioning_demo.tscn`, `turret_pitch_range.tscn`, test-only scripts. The
  combat lab and the E01–E04 / P01–P03 scenarios were removed with the legacy ships.
- `game/presentation/markers/marker_preview.tscn`: selection/highlight/Object/Tactical marker authoring scene (section 4.8).
- `game/ui/overlays/overlay_preview.tscn`: shared HUD, hover tooltip and notice authoring scene (section 4.9).
- `game/presentation/effects/thrusters/thruster_fx_preview.tscn`: thruster authoring scene.
- `game/presentation/effects/projectiles/projectile_trail_preview.tscn`: production-backed
  projectile/trail authoring scene (section 4.8).
- `game/presentation/movement_indicator/movement_indicator_preview.tscn`: movement
  indicator authoring scene (section 4.7).
- `game/presentation/effects/combat_flash/combat_flash_preview.tscn`: combat flash
  authoring scene (section 4.8).

## 3. Architecture

### Ships: archetype → variant → instance (accepted 2026-10-17)

- Archetypes `game/ships/archetypes/` (component nodes with script defaults only, no
  hull, no per-type values):
  - `warship.tscn`: Locomotion, RouteFollower, Avoidance, Scanner, Docking, Fuel,
	Weapons, Combat.
  - `mining_ship.tscn`: Locomotion, RouteFollower, Avoidance, Cargo, Extractor,
	Mining, Scanner, Docking, Fuel, Weapons, Combat.
  - `transport_ship.tscn`: Locomotion, RouteFollower, Avoidance, Cargo, Transport,
	Scanner, Docking, Fuel, Weapons, Combat.
- Variants `game/ships/<type>_unit.tscn` are the authoritative ship type
  definitions: `ff01_unit` (warship), `miner_unit` (mining ship),
  `transporter_unit` (transport ship). Each overrides the type's settings (profiles,
  radii, size class, fuel, scanner kind) and adds `Model`, an instance of the hull
  scene `game/ships/<type>.tscn` (primitive meshes, no scripts, bow −Z), last child.
  Armed variants add hardpoints under `Weapons` and `Behavior` before `Model`. Miner
  and Transporter are unarmed and damageable. The legacy Frigate, Gunship and
  Destroyer variants and hulls are removed (2026-10-27).
- `ff01_unit.tscn` (warship; hull `ff01.tscn`, a 12 × 3 × 1.1 u primitive blockout, bow
  −Z): the former Destroyer's handling and footprint (3 u/s, 25 °/s, radius 6.2, size class 3, fuel
  400 / 1.0), `Behavior`, durability `ff01_durability.tres`. Eight hardpoints under
  `Weapons`: two NC-90 Bastions (`ForwardBastionHardpoint` (0, 0.55, −3) and
  `AftBastionHardpoint` (0, 0.55, 3) yaw 180°, ±120°), four PDC-20 Kestrels (PDC
  hardpoints at (±1.3, 0.55, ±4), yaw ±45° / ±135°, ±90°), one RL-8 Barrage
  (`BarrageHardpoint` (0, 0, −5.85), vertical ejection, family rocket) and one
  GCM-4 Wayfarer (`WayfarerHardpoint` (0, 0.55, 0), level housing, four +Y vertical cells, family
  missile). Only used in `combat_test.tscn` and tests.
- Instances: scene ships and produced ships are instances of the same variants with
  only a transform. Runtime state is per instance (script variables, one
  `Inventory.new()` per Cargo and per station).
- An archetype change reaches every variant that does not override that value.
- Hull parts: code that addresses a hull part uses `Model/<part>`. Selection pick
  boxes, ring and station picking search meshes recursively, so the nested hull is
  found. Each hull has `Thrusters` (`MainEngine*` cylinders and jet boxes); they are
  hull parts by owner decision (picking, outline, ring) and stay inside `ship_radius`.
  The collision footprint is `RouteFollower.ship_radius`, not the mesh.

### Component order and processing (must be kept)

Nodes of equal physics priority run in tree order, so archetype order is part of the
contract:

| Priority | Nodes (in order) |
|---|---|
| −100 | `SimClock` (first child of the scene) |
| −50 | Sensors (after the clock, before ships act on contacts) |
| −3 | `Behavior` |
| −1 | RouteFollower, then Avoidance (Avoidance reads its RouteFollower) |
| 0 | Locomotion, then Scanner |
| 1 | Mining or Transport, then Docking, then Fuel |
| 2 | Combat (Weapons is earlier in the tree so its weapons are ready when Combat collects them); Station |
| 3 | Refinery, Shipyard, Projectiles |
| 1000 | ThrusterView (after the ships' own physics; read-only) |

There is deliberately no shared ship base scene: an inherited scene appends its nodes
after the inherited ones, which would put role components after Fuel. Inherited nodes
cannot be removed, so an archetype holds only what every variant has; a component a
variant adds goes last and only where order does not matter, otherwise it needs a new
archetype. Role components are found by node name (`Mining`, `Transport`, `Cargo`).

### Stations

- Shared behaviour: `game/stations/station.gd` and `berth.gd`, reading geometry from
  the scene: Berth children in scene order (any number), `Hold*` markers (any number),
  meshes in the `static_obstacle` group for navigation and collision, all meshes for
  picking. Root in the `station` group (`Station.GROUP`).
- Layouts: `station.tscn` (two-berth exposed-arm layout); `tri_station.tscn` (test).
- Specialized stations inherit a layout and add a capability node:
  `refinery_station.tscn` = `station.tscn` + `Refinery`; `shipyard_station.tscn` =
  `station.tscn` + `Shipyard` + `Deployment` (Marker3D). Panels and `movement_lab.gd`
  find capabilities by these node names. Storage, fuel stock, refinery slots,
  production and reservations are per station instance.

### Gameplay-scene layout contract

The scenes and scripts work only under this layout:

- Root children: `Ships`, `Stations`, `StaticNavigation`, `PlanarCollision`, `Survey`,
  `Asteroids` (with `AsteroidField`), `Selection`; combat: `SimClock`, `Contacts`,
  `Projectiles`, `Effects`, `OrdnanceTrails`; optional `CombatOrders` (turns on the
  combat layer of `movement_lab.gd`) and `Sensors` (turns on the fog of war).
- Ships are direct children of `Ships`; stations direct children of `Stations`.
  Stations cannot be under `Ships` (GroupOrders requires `Locomotion`).
- Exported NodePath defaults depend on it: ship components `../../../StaticNavigation`,
  `../../../PlanarCollision`, `../../../Survey`, `../../../Asteroids`,
  `../../../Contacts`, `../../../Projectiles`, `../../../Effects`, `../..` (Ships);
  stations `../../Ships`, `../../StaticNavigation`; Shipyard `../../../Ships`,
  `../Deployment`.
- Missing nodes: most lookups fail with an error, and a scene with ships without
  `SimClock` is an error. Silent failures: Locomotion's collision path (no collision)
  and the station's ships / navigation paths (empty occupancy, every exit side clear).
- Order under `Ships` decides the avoidance tie rule, collision order and marker pick
  ties ("later in the scene" gives way).
- Obstacles are read once at start: stations added later are not obstacles.
- Reuse is verified by `reuse_test` on `game/tests/reuse_arena.tscn`.

### Runtime ship registration

A ship added under `Ships` at run time must be registered: `ShipSelection.register_ship()`
(pick boxes, ring) and `movement_lab.register_ship()` (notices, movement indicator,
command layer, Selection, Combat `destroyed` / `removing`); both idempotent. The
Shipyard sets the transform before `add_child()` (Locomotion reads it in `_ready()`)
and emits `ship_deployed`, which `movement_lab.gd` handles in the same call. An
unregistered ship makes `ShipSelection.pick()` (called every frame by AsteroidHover)
log a script error. A scene without `movement_lab.gd` must register produced ships
itself (as `reuse_test` does). Ships are removed only by combat destruction
(section 4.6), which unregisters them.

## 4. Systems

### 4.1 Movement (`locomotion/`, `navigation/`, `avoidance/`, `collision/`)

The movement baseline is fixed (section 6): cause C with the direct-move prediction
horizon, plus the accepted same-course pass side and re-plan after a far pass.

- `ship_locomotion.gd` (`Locomotion`): the only writer of a ship's movement state and
  transform (planar position, velocity, heading, turn rate; Y kept). Bounded
  kinematics (forward / reverse / lateral acceleration ellipse, turn rate and turn
  acceleration, turn-aware braking), FACE / HOLD heading modes. Inputs: `move_to()`,
  `steer()` (route), `avoid()` (avoidance), `face(heading)` (one narrow idle-heading
  request: refused while guided or with a destination; cleared by movement, guidance
  or `place()`), `guide()`. `_apply_motion()` asks PlanarCollision before committing;
  `committed_motion` is what Fuel charges.
  - Course turn (Stage 6B): `move_to(point, allow_hold, turn_course)` under way (above
	0.5 u/s) keeps the current velocity direction as a course and turns it toward the
	destination at the ship's own turn limits (rate-limited, braking-aware, at most 60°
	ahead of the actual velocity) instead of re-aiming at once; it ends when aligned,
	on avoidance, combat control, a speed cap, no propulsion, arrival, `cancel_move()`,
	`place()` or `guide()`. Only RouteFollower requests it (below).
  - `combat_motion(heading, speed_cap, steer_point)`: Behavior's one-step combat
	heading / speed input (FF-01 only, section 4.6). `speed_limit` /
	`speed_limit_reason` are debug readouts.
  - `propulsion` (set by Fuel): false = no translation or rotation, order kept,
	`avoidance_cap` 0 so others treat the ship as waiting (stationary).
  - Guided mode (station docking): `guide(legs, limits)` flies turn-in-place or
	straight legs from rest within station limits capped by the ship's own, each
	ending at rest. While guided: no destination, `steer()` / `avoid()` ignored,
	`move_to()` refused and counted (`guided_order_errors`, error logged), other ships
	treat it as idle; target heading = actual heading at hand-back. `place()` cancels
	guidance.
- `static_navigation.gd` (`StaticNavigation`): one NavigationServer2D map per planning
  radius (ship radius + clearance margin), baked once from the direct mesh children
  of `obstacles_path` plus every mesh in `static_obstacle` (cylinders and spheres as
  circles, boxes as rotated rectangles). `map_half_size` (default 150) is the scene's
  sector; `movement_lab.sector_half_size()` reads it for MOVE validity, camera pan
  bounds and Strategic View. Routes, closest reachable point, clearance tests.
- `route_follower.gd` (`RouteFollower`): one route per order, continuous lookahead,
  per-order speed profile; holds `ship_radius`, read by other systems.
  - `order()` returns whether the order was taken (planned, or queued while the map is
	not ready). Without a route it is refused ("No route found") and nothing changes;
	a queued order that finds no route restores the previous status and request.
  - Refused while guided ("Order refused during station control", counted in
	`guided_refusals`, expected 0). `clear()` drops route, queue and status when the
	station takes over.
  - End-of-route correction (owner-retained, `route_end_test`): the destination is
	braked for at least the straight distance to it while that line is clear, so a
	ship pushed off its route near the end is not capped short of it.
  - Aim anchor (Stage 6B): the aim point walks the lookahead from `aim_progress`, which
	follows route progress at most `AIM_CATCH_UP` (2) × speed + 1 u/s ahead, so route
	corners no longer jump the aim.
  - Waypoints (Stage 6B): `order(point, through, turn_course)`; one route is chained
	through every waypoint (`waypoint_marks`, `waypoints_left()`); intermediate
	waypoints are flown through, only the last is a stop.
  - Course turn gate: only a single-ship player MOVE (`movement_lab._move_single`) asks
	for it, and `_course_room()` grants it only on a corner-free (two-point) route with
	the footprint's obstacle and sector-edge clearance (`footprint_clearance()`,
	`edge_clearance()`) at least 3 × and the route at least 2 × `lookahead_length()`;
	otherwise the order is an ordinary Move.
  - `replan()` (accepted 2026-10-23): called by Avoidance when a pass ends with the
	ship more than that encounter's separation off its path; same resolved
	destination, `requested` and `plans` unchanged (Behavior reads it as a player
	Move), no notice, counted in `replans`; skipped without a route, guided or queued.
- `ship_avoidance.gd` (`Avoidance`): closed-form prediction per pair; give-way roles
  (idle and waiting ships stand on; overtaking ship gives way; else smaller
  `size_class`; equal: later in the scene); pass (starboard head-on, astern crossing,
  away when converging) or yield; only offsets steering and caps speed. Accepted
  rules on top:
  - Obstruction correction: passing a ship that `is_stationary()` (no order or out of
	fuel, below 0.1 u/s; avoidance-held ships with an order do not count), the
	steering point is pulled back to keep the reserve (`_keep_reserve`), and the pass
	speed cap limits only travel toward the reserve.
  - Cause C: a stationary ship's yield is decided after the one applied pass; if that
	shift already clears it (`_shift_clears()`) the ship follows the pass's side
	(`_follow_pass()`), otherwise it yields.
  - Direct-move prediction horizon: the own-ship prediction runs from the route
	position and, on a direct move, stops at the end of the leg left (not after the
	straight distance from the actual position). Routed moves keep the straight
	distance horizon (`RouteFollower.remaining`).
  - Same-course pass side: an encounter with a moving ship that is neither head-on
	nor crossing records its `away` side at start; `_choose()` tries only that side
	(converging keeps its one-separation bound), else yields.
  - `forget(ship)`: called when a destroyed ship is removed.
- `planar_collision.gd` (`PlanarCollision`): read-only service; bounding circles and
  obstacle shapes, continuous sweeps, removes only the velocity into a contact (no
  bounce, push or separation), at most 3 contacts per step, sequential in scene order.
  A safety net, not traffic resolution. Sector edge (Stage 6B): four static rectangles
  (`_edges`, blockers `SectorEdgeEast/West/South/North` children) with inner faces on
  ±`StaticNavigation.map_half_size` (`navigation_path`), a sector width thick and
  closing the corners, so every Locomotion-driven ship stops or slides with its centre
  at `map_half_size − ship_radius`; a ship placed beyond the edge may only move back
  in. `_obstacles` still holds only the mesh obstacles. Ordnance is not contained.

Profiles (authoritative in `game/ships/<type>_unit.tscn`; the test arena and
`obstruction_test` keep their own movement-only copies; the three handling classes
predate the legacy cleanup, which retired the Frigate, Gunship and Destroyer that
first used them):

| | Miners | Transporter | FF-01 |
|---|---|---|---|
| max speed fwd / rev / lat (u/s) | 5 / 4 / 3 | 4.5 / 2.5 / 2 | 3 / 1.5 / 1 |
| accel fwd / rev / lat (u/s²) | 6 / 3 / 2.5 | 3 / 1.5 / 1.2 | 1.2 / 0.5 / 0.3 |
| turn rate (°/s) / turn accel (°/s²) | 120 / 240 | 60 / 90 | 25 / 20 |
| ship radius / clearance margin (u) | 1.6 / 1 | 4.1 (test arena copy 3.4) / 1 | 6.2 / 1 |
| size class | 1 | 2 | 3 |
| fuel tank / use per u | 100 / 0.25 | 200 / 0.5 | 400 / 1.0 |

### 4.2 Selection, orders and commands (`selection/`, `orders/`, `scenes/movement_lab.gd`)

- `ship_selection.gd` (`Selection`): click (hull boxes + 0.3 u), Shift-click, box drag
  (centres), green rings; never touches movement. Only live player-faction ships are
  selectable; `pick_any()` finds hostiles for targeting. `pick()` needs every child of
  `Ships` registered.
- `group_orders.gd` (`GroupOrders`), translated Group MOVE (accepted 2026-10-23): one
  solver `_solve()` shared by `assign()`, `can_assign()` and `command()`. Each ship's
  target = its position + (clicked point − centroid of the ships given); no rotation
  or reordering. Per round, targets are checked as they are (spacing footprint + 1 u
  + 0.5 u from reserved points and others' occupancy, fit on the navigable area, a
  route that ends there), largest first only to decide conflicts; only invalid ones
  are relocated on rings around their own target (up to `search_radius` 40 u, with
  `_approach_clear()`); a ship that finds nothing is excluded (keeps its order,
  assignments and commands) and its occupancy constrains a new round; at most one
  round per ship. `_find()` skips candidates beyond `RESOLVE_TOLERANCE` outside the
  sector square. Returns placed ships only; `command()` returns ships whose
  RouteFollower took the order. No group persists after dispatch. `last_stats` has
  the counters. `resolve_occupied()`: a single-ship MOVE inside a stationary ship's
  clearance goes to the nearest valid point within `resolve_margin` (5 u, provisional)
  beyond it.
- Command flow (`movement_lab.gd`): a right-click is resolved once into a command
  (Dock at a station, Mine an asteroid, target / Attack / Guard / Attack-Move /
  Waypoint, or Move to a point) and given per ship through `_order()` / `_execute()`,
  which return whether it was accepted (executed, or held).
  - Every command is checked before anything is cancelled. Refused (MOVE without a
	route, Dock where `Docking.can_dock()` is false, Mine where
	`MiningOperation.can_mine()` is false, Resume without a working point): notice
	only; order, mining, docking and transport unchanged. Checks are skipped while
	the map is not ready (deferred). Dock at the station the ship is already docking
	at changes nothing.
  - Accepted: MOVE pauses mining and transport (settings kept; Resume restarts) and
	cancels docking; Mine cancels docking; Dock pauses mining and transport. Only ships actually ordered
	have assignments released and `command_given(ship, kind)` emitted.
  - Single MOVE onto a stationary ship: resolved beside it ("Destination occupied by X
	- moved beside it") or refused ("No free position near X - no order given").
  - Group MOVE: with no ship under station control or docked, `GroupOrders.command()`;
	otherwise one `assign()` and each placed ship gets its own destination, held ships
	after their maneuver. Partial: "N of M ships ordered; K not ordered".
  - Held commands during station control (two-stage validation, owner decision): at
	issue only the intent is checked (`_intent_valid()`: target exists, command
	permitted); a rejected one never replaces the held one ("… - held order kept");
	newest valid wins (`Docking.hold_command()`). A held MOVE shows its marker at once.
	At release (`_release()`) it runs through the full checks from the actual
	position; refused then: notice, held command and marker cleared.
  - Docked ship (any command but Dock at its own station): checked first from the
	berth; refused: nothing changes; accepted: automation paused as by Undock, command
	held, controlled exit started, then re-checked at release.
  - `resolve_command()` / `command_available()`: read-only versions for the cursor
	(same resolution and checks, notices muted).
  - `autonomous_move()`: Behavior's positioning (one RouteFollower order, moved beside
	an occupying ship, route checked; no assignment cancelled, no notice, not a
	command; refused while docking owns the ship).
  - `player_sees()`: fog-of-war gate (section 4.6).

### 4.3 Stations and docking (`stations/`)

- `station.gd` (`Station`, static): never orders or moves ships. Storage `Inventory`
  (5000), transfer rate (50 units/s), fuel (`fuel_capacity` 2000, `fuel_stock` 1000,
  `refuel_rate` 20 units/s per docked ship), hover text (storage per resource, fuel,
  docks in use, waiting ships). `show_berths` debug drawing (off; `pick()` ignores it).
- `berth.gd` (`@tool`): Berth nodes are the only source of docking geometry (origin at
  the arm end, +Z outward; `slot_size` 14.4 × 13.4 u, sized for a 6.2 u footprint; markers
  `ParkStop`, `Handover`, `ExitBack`, `ExitA` / `ExitB`, fixed and sized for the
  largest supported ship; owner decision). The editor previews the rectangle (never
  saved or created in game).
- Three separate berth states: reservation (`slots[i].ship` / `leaving`), physical
  occupancy (`berth_occupants(i)`: collision circles overlapping the rectangle) and
  corridor clearance (`corridor_clear()`: the waiting ship's route to handover and
  parking keeps two footprints + `corridor_margin` 1 u from every leaving ship's
  remaining exit path).
- FIFO queue (one entry per ship): a berth is granted only to the first queued ship
  allowed there, only while unreserved, physically empty and with a clear corridor;
  nobody skips ahead; nearest handover first. A leaving ship keeps its reservation
  until its circle is outside the rectangle. Exit sides (`exit_sides()`): only sides
  whose legs are clear of static obstacles for that hull; `choose_exit_side()` takes
  the one farthest from the first waiting ship's route and other ships.
- `docking.gd` (`Docking`, per ship): states Not docked, Requesting Dock, Waiting for
  Dock, Approaching Station, Docked, Undocking, Waiting to Continue Transfer, Unable to
  Dock. `can_dock(station)`: at least one usable berth (route to handover, clear
  straight entry, at least one exit side).
  - Dock: granted → an ordinary order to the handover point; arrived at rest (within
	0.25 u) → `RouteFollower.clear()` and `Locomotion.guide()` entry (turn to the
	final heading, straight in) → Docked on the pose (≤ 0.25 u, ≤ 0.5°). Queued: order
	to the nearest free reachable hold; request kept. Stopped short by a contact:
	notice, Unable to Dock.
  - Undock: controlled exit (straight back, turn toward the exit side, forward to the
	exit point); control returns when it ends. No clear side: notice, stays docked.
  - Docking owns the ship's movement from the dock request until control ends.
	`under_control()`, `control_ended`; one held command (`hold_command()`,
	`held_command()`). During control `cancel()` / `dock()` are refused and counted
	(`refused_during_control`, push_error). Otherwise `cancel()` releases request,
	queue entry, hold and transfer request and never moves the ship (owner decision);
	departure is always `undock()`. `abandon()` releases records on destruction.
  - Transfers: Unload Cargo / Load (resource, amount), timed with fractions carried;
	`stop_transfer()`. Blocked transfer (storage full, no stock): keeps its request,
	leaves through the exit, waits at a hold (Waiting to Continue Transfer), docks
	again. Automated Transport instead uses `load_cargo(…, wait)` / `unload(wait)`:
	stays Docked with the reservation held in a `waiting` sub-state (section 4.4).
	Ships without `Cargo` dock without cargo actions.
- Guided limits: `guide_speed` 1.5 u/s, `guide_accel` 1.0 u/s², turn rate / accel
  30 °/s / 30 °/s² (capped by each ship's own).
- Docking is bow-in only; docking heads are visual only (not obstacles).

### 4.4 Economy

- Resources (`cargo/inventory.gd`, `Inventory`): `RAW` = iron, nickel, silicon,
  cobalt, gold, titanium, ice; `INGOTS` one per mineral; `RESOURCES` all 13 in a fixed
  order (lists, displays, transfer-all order). One capacity, never exceeded;
  `transfer_to()` moves whole units. `Cargo` (per ship) owns an Inventory of 1000.
  All game state is session only (no save system).
- Asteroid field (`resources/asteroid_field.gd`, on `Asteroids`): one deposit per
  `asteroid_id`: family MINERALS (six minerals, whole percents ≥ 1, sum 100) or ICE,
  reserves 500–5000. Generated from `session_seed` (0 = new seed, printed as
  `Asteroid field seed: N`); each deposit depends only on seed and id; 65 % minerals.
  `extract(id, n)` is the only writer of reserves and returns {resource: units}: each
  unit is the resource furthest below its share of what the deposit has given
  (integer arithmetic, ties in MINERALS order), so the split depends only on how much
  was extracted, not tick rate, chunk size or miner.
- Survey (`survey/`): `Survey` is the one owner of fleet knowledge per asteroid
  (UNKNOWN, IDENTIFIED, ANALYZED; never downgraded) and of scans in progress (pulse
  30 u/s, analysis 2.5 s, DATA UPLOADED 1.2 s; a higher scan raises an analysis in
  place). `Scanner` per ship: `kind` GENERIC (family) or MINING (also composition and
  live reserves), radius 50 u, cooldown 3 s; uses no fuel. Current kinds: Miners
  Mining, all others Generic (see section 10). `SurveyView` draws pulse, grid sweep,
  progress and DATA UPLOADED; mining never changes the survey.
- Mining (`mining/`): `Extractor` 20 units/s within 4.5 u of the asteroid outline,
  time-integrated with fractions carried, never beyond reserves or free cargo.
  `MiningOperation` (`Mining`) runs the automated cycle: saved `target` and `base`
  (null = nearest); working point (16 candidates on outline + 3.75 u, ship's side
  first, must fit the map, be free of other ships and routable; none: Unreachable).
  The Miner must face the asteroid: `Locomotion.face()` at the working point,
  extraction only within `ALIGN_TOLERANCE` 1° of the bearing to its centre (status
  stays "Mining" while turning, owner choice). Full cargo or depletion → dock at the
  chosen base if `can_dock()` (never silently changed; else waits), else the nearest
  dockable station; unload, refuel until full (or station empty), undock, back to a
  new working point; depletion ends with one final return, then DEPLETED.
  `assign()`, `cancel()` (pauses, settings kept), `resume()` / `can_resume()` (refused
  with a notice when `can_mine()` is false), `set_base()` never cancels;
  `activity()` builds the panel text. `MiningView`: beam while `extracting`.
- Fuel (`fuel/fuel.gd`): use = `consumption` × scene `local_fuel_scale` × length of
  `committed_motion` (after collision): standing, blocked and rotating ships use none.
  At 0 propulsion off ("out of fuel - stopped"); any fuel turns it back on. Warnings at
  15 / 10 / 5 % once each, re-armed above the threshold. Docked: takes
  `min(rate × delta, free tank, station stock)`; the station loses exactly what the
  tank gains. Produced ships start with a full tank without station fuel.
- Transport (`transport/transport_operation.gd`, `Transport`): saved `load_station`,
  `unload_station`, per-resource `required` and `percent` (percent of total hold
  capacity, rounded down; units and percent mix). Cycle: dock at load station, load
  missing resources until every requirement is met and refuelled, undock, dock at the
  destination, unload everything aboard, refuel, return. Cargo not required is
  carried and delivered, never discarded.
  - Persistent docking (owner decision): loading waits docked until the whole quota is
	aboard (switching to another missing resource in stock), unloading until
	everything is delivered; one notice per wait; berth congestion is intended, no
	eviction or auto-resolution. Fuel refuels during the wait.
  - Configuration edits: a setter given the same value does nothing; changing or
	clearing a station, or every requirement reaching zero, pauses an active operation
	once with a notice, never redirecting a trip (docked or in the entry: stays
	docked, `stop_transfer()`; undocking: finishes; otherwise `Docking.cancel()`);
	other requirement edits are live (a running load is resized; a lower requirement
	never unloads). An invalid configuration written without setters pauses before any
	dock request. `set_requirement()` and `apply_requirements(amounts, as_percent)`
	reject (notice, nothing changed) when the total would exceed the hold.
  - A valid manual departure (Undock, MOVE, Dock elsewhere) pauses; only Resume
	restarts it, without repeating completed transfers. `activity()` builds the text.
- Refinery (`refining/refinery.gd`, child of a `refinery_station`): two slots, each a
  mineral (none by default) and Enabled (off). An enabled slot accumulates rate ×
  delta while its mineral is in stock and completes a unit by removing one raw unit
  and adding one ingot (consumed only on completion; no losses). Disabling or changing
  the mineral resets the partial unit. Slots run in order on shared stock; raw and
  ingots share station storage; no reservations (refining and loading take stock in
  simulation order). `processed`; `assignment_processed` (reset only on mineral
  change). Rates (provisional): Iron 4, Nickel 3, Silicon 2.5, Cobalt 2, Titanium 1.5,
  Gold 1 units/s.
- Shipyard (`shipyard/shipyard.gd`, child of a `shipyard_station`): one slot, no
  queue. `RECIPES` (provisional): Mining Ship = 200 iron, 100 nickel, 50 silicon
  ingots, 60 s → `miner_unit.tscn`, series "Miner"; Transport Ship = 300 iron,
  100 titanium, 50 cobalt ingots, 90 s → `transporter_unit.tscn`. States IDLE →
  WAITING → CONSTRUCTING → (AWAITING_DEPLOYMENT) → IDLE. `order(id)` only while idle;
  waiting consumes and reserves nothing; the whole recipe is removed in one tick once
  present. `cancel()` only while waiting; no cancel or refund during construction.
  Deployment at `Deployment` (position and yaw) only when no child of `Ships` is
  closer than both radii + `DEPLOY_MARGIN` 1 u (`deployment_clear()`); otherwise the
  ship is held outside the tree and deploys in the first clear tick (no pushing, no
  berth use). Name: `_next_name()` (1 + highest number in use). Produced ships are
  player-owned, idle, fully fuelled, and follow the "later in the scene" tie rules.
  The Shipyard builds no warships.

### 4.5 Simulation time (`time/`)

- `sim_clock.gd` (`SimClock`, first child of every gameplay scene): the one simulation
  clock (`SimClock.now()`), summing physics delta.
- `time_control.gd` (`TimeControl`, added by `movement_lab.gd`): the only owner of
  `SceneTree.paused` and `Engine.time_scale`. Pause, 0.25x / 1x / 2x, 0.25x while
  attack-target selection is open (the chosen speed is restored after).
- Every simulation system runs on physics time, so pause and speed apply to all.
  `movement_lab.gd` sets simulation children PAUSABLE and input, camera, selection,
  panels and presentation (`ALWAYS_NODES`) always processing; camera, notices and
  command cursor divide the time scale out. Orders given while paused take effect at
  once; nothing advances until resumed.

### 4.6 Combat (`combat/`, `weapons/`, `sensors/`, `behavior/`)

Combat behaviour is frozen as accepted (section 6).

- `combat_ship.gd` (`Combat`, every ship): the one owner of hull health
  (`combat_rules.tres`: 150 for every ship without a durability) and, Stage 1, armor:
  an optional `durability` (`durability_config.gd`: `max_hull`, `max_armor`,
  `armor_resistance`; an invalid one is rejected as a whole). FF-01: hull 160, armor
  condition 100, resistance 30; no other ship has one. One global formula
  (`resolve_hit()`, from the pre-impact condition): hull damage = base × p / (p +
  resistance × condition / max), armor condition reduced by the hit's armor damage;
  unconfigured penetration (null, every legacy weapon) bypasses armor; non-finite
  inputs are rejected (`hit_input_error()`). It also owns faction (0 player, 1 hostile), manual /
  automatic target and threats; steps the ship's weapons. Targeting is strict: a
  manual target is the only offensive target; without one, Defensive takes confirmed
  threats (attacks on itself or allies within 30 u, 10 s persistence), Aggressive the
  nearest hostile in contact within its longest usable range, Passive nothing. No
  friendly fire. Destruction: weapons off, references cleared on every ship,
  propulsion off, route / avoidance / fuel / scanner / docking / mining / transport
  stopped, `Docking.abandon()`, deselected; a 2 s hulk, then removal
  (`Avoidance.forget()`, contacts and Selection unregistered) and free.
- FF-01 autonomous combat positioning (Stage 6B, `ship_behavior.gd` `_combat_engage()`,
  the only engagement implementation; values editable in the Behavior's
  "Autonomous combat positioning" group on `ff01_unit.tscn`): cannon-derived band 27–45 u (nominal
  38.25), tangential 1.5 u/s, decisions 0.5 s, orders 1.0 s, 20 u transition width;
  travel owns the heading and weapon facing may adjust it by at most 8°
  (`COMBAT_ALIGNED_DEG` 25 keeps full throttle near the bow, `COMBAT_CAP_EASE` 0.5
  eases the speed cap). On straight legs it steers along the live course. An
  interrupted Attack moves a live designation to the manual target. Waypoint Moves
  fly one chained route through every waypoint.
- `combat_orders.gd` (`CombatOrders`): the one combat command interface (move,
  target, tactic, Attack, Guard, Attack-Move, Waypoint, Cancel) for player
  input, the commander and tests.
- `projectile_system.gd` (`Projectiles`): rounds and guided ordnance, hits against
  hull boxes, asteroids, stations and hostile ordnance (point defense). `ordnance.gd`,
  `combat_effects.gd`, `ordnance_trails.gd`. `combat_obstacles.gd`: station parts for
  projectile obstruction, line of fire, missile avoidance and firing positions;
  stations without a `take_hit()` component (all current ones) block fire undamaged.
- Weapons (`game/weapons/`): `weapon.gd` holds the shared firing authorization
  (owner, ammunition, target, contact, tactic, range, coverage, alignment, reload,
  cooldown, solution, clear path); `turret.gd` (cannon), `gatling.gd` (point defense
  under every tactic, then offense), `launcher.gd` (tube, cells, salvos),
  `hardpoint.gd`, configs, `weapon_geometry.gd` (placeholder meshes). The legacy
  configurations (`cannon.tres`, `gatling.tres`, `torpedo.tres`, `missile.tres`) were
  removed with the legacy ships; these scripts and the torpedo / missile ordnance
  kinds stay shared.
  Weapon families on FF-01 (one script per family, values in the variant's `.tres`,
  instanced through the variant's `.tscn`):
  - Cannon (Stage 2, `turret.gd` + `nc90_bastion.tres/.tscn`): NC-90 Bastion, 12 hull /
	penetration 20 / armor damage 6, 2.5 s, 75 u (effective 45), 40 u/s, 40 rounds,
	shell dispersion 0.5° (`Weapon.disperse()`: uniform over the cone's solid angle,
	per-mount seeded `rng`).
  - PDC (Stage 3, raid sweep accepted 2026-10-28; `pdc.gd` extends `gatling.gd`,
	`pdc_config.gd` extends `weapon_config.gd`, `pdc20_kestrel.tres/.tscn`): PDC-20
	Kestrel, 0.2 / penetration 1 / 0, 75 u, cooldown 0.0333 s (30 rds/s), 70 u/s, lifetime
	1.35 s, travel × 1.25, magazine 120 of 1200, reload 3 s, 0.75° per-round dispersion.
	Defensive order: own ship, then allies; torpedoes before missiles, except a missile
	(or rocket) arriving under 1.5 s and earlier; then impact time, ordnance id. Raid
	sweep (point defense only): each mount fires 4-round micro-bursts
	(`rounds_per_target`) and then takes the next engageable threat in its own list
	(`gatling.gd` `_defense_candidates()`, re-read every 0.25 s `raid_refresh_interval`),
	wrapping, never the same threat twice in a row while another is engageable; a single
	threat keeps being fired at; `target_switch_delay` 0. Committed prediction: on a new
	threat the turret follows the live solution until aligned, then commits the threat's
	position / velocity and one shared aim error (≤ 1.5°, re-committed every 0.5 s);
	offense keeps the per-tick solution. Rounds stay zero-radius; missed rounds fly to
	lifetime / travel. Tracer look: shared `pdc20_kestrel_tracer.tres` (BoxMesh
	0.02 × 0.02 × 0.2 u, emission-only material, near-white (0.88, 0.97, 0.96) × 32,
	alpha 0.85; owner's values), passed to `Projectiles.spawn()` by `Weapon._round_mesh()` (null = style bar).
	Mounts select independently; all values editable in the `.tres` (Prediction, Raid
	sweep, Visual groups).
  - Rocket (`rocket_launcher.gd` + `rl8_barrage.tres/.tscn`): RL-8 Barrage retains
	its eight cell origins (4 × 2, ship-frame x ±0.15 / ±0.45, y ±0.15, z −6.28).
	It ejects world +Y to 4 u above release, at 8 u/s nominal ejection/transition
	speed with inherited ship velocity; after clearance, nose and actual velocity
	turn toward one locked salvo intercept point at up to 100°/s for at most 1.5 s.
	Alignment or timeout freezes the achieved world-space velocity ray; a continuous
	30 u/s² ramp reaches 30 u/s, then straight unguided flight continues. No target
	updates, reacquisition or obstacle avoidance follow commitment. The initial
	first-order lead includes an approximate launch/acceleration delay.
	A whole salvo needs eight rounds and a valid target/aim point within 60 u of the
	fire-control muzzle; no bow alignment is required. Eight independently dispersed
	rockets (3°) launch every 0.12 s from their current cell positions; only owner
	destruction cancels pending launches. One round per release; 48 rounds, 5 s
	cooldown after the eighth. Lifetime 4 s and 70 u maximum total path both include
	clearance, turning and acceleration; acquisition remains 60 u. Damage unchanged:
	4 hull / penetration 8 / armor damage 1; interception radius 0.3, model 0.6 × 0.06 u.
	Salvo/layout exports live on `rl8_barrage.tscn`; flight, acceleration, timeout,
	technical limits and model values are editable in the `.tres` ordnance resource.
  - Guided Missile (`guided_missile_launcher.gd` extends `launcher.gd`,
	`guided_missile_config.gd` extends `weapon_config.gd`, `gcm4_wayfarer.tres/.tscn`):
	GCM-4 Wayfarer has four cells / four missiles per committed salvo, 12 missiles,
	launches at 0 / 0.2 / 0.4 / 0.6 s on the first eligible physics ticks; 6 s cooldown
	after the final launch. Cell origins: (±0.25, 0.922, ±0.35) in the ship frame.
	Ejection is world +Y at 5 u/s plus inherited ship velocity until 8 u above release;
	the existing drifting orientation turns at 75°/s, for at most 1.5 s after clearance,
	then existing powered guidance resumes on alignment (15° threshold) or timeout.
	Active tracking, original-target identity, sensor loss, same-target reacquisition,
	bounded obstacle avoidance and momentum-based overshoot recovery are preserved.
	Salvos retain the original target and latest legitimately observed position;
	without contact missiles use last-known position, never hidden target data.
	Only owner destruction cancels pending releases; one round is used per release.
	Max speed 32 u/s, acceleration 18 u/s², powered nose turn 40°/s, acquisition 90 u.
	Lifetime is exactly 9 s from release: impacts before the deadline count, those
	at/after it do not; 30 s / 400 u are secondary bounds. Impact: 35 hull /
	penetration 45 / armor damage 2 (first fresh FF-01 hit: 139 hull, 98 armor).
	One successful PDC hit destroys it. All layout and launch/flight/model values
	are editable in its `.tres` (flight/model in `ordnance`). Both families render
	their actual simulated positions, retain launching-ship collision exclusion and
	physical interception; missile ordnance without a launch profile keeps zero
	`transition_timeout` (legacy flight). No current ship carries torpedoes.
  - Interception: torpedoes and missiles are destroyed by any hostile round; rockets
	only by rounds spawned with `intercepts_rockets` (Gatling family: Kestrels);
	cannon shells pass through rockets.
- Sensors: `sensors.gd` (`Sensors`): faction-shared detection within 100 u with a
  line clear of asteroids, every 0.2 s of simulation time, 8 s last-known memory;
  stations ignored. `contact_board.gd` (`Contacts`): contact = detection. Line of fire
  is separate. Fog of war: `movement_lab.player_sees()` decides what of a hostile is
  drawn, picked, targeted and inspected; `presentation/fog_view.gd` tints uncovered
  space and hides hostile rounds, ordnance, trails and effects outside coverage
  (shader `COVERAGE` shared with Strategic View; up to 128 asteroid occluders and 16
  sensors, beyond that `overflow` and a warning).
- Behavior (`ship_behavior.gd`, `Behavior`, FF-01 of both factions): precedence command (Move, Attack, Guard, Attack-Move, Waypoint, Dock,
  Cancel) > tactic (Aggressive pursues its target in contact; Defensive answers
  attackers from its defended area with local line-of-fire repositioning, 12 u limit,
  no pursuit, area not drawn; Passive nothing, point defense still fires). Aggressive
  pursuit, Attack and Attack-Move encounters position by the cannon-derived combat band;
  every eligible installed weapon checks and fires on its own (no weapon profiles).
  Guard and explicit movement override autonomous positioning.
- Combat positioning (I01 resolved, accepted 2026-10-25): `_position_ok()` and
  `_unusable_reason()` share `_inside_sector()`, reading `StaticNavigation.map_half_size`
  through the RouteFollower's configured `navigation_path` (required dependency, no
  fallback). Ship footprint, optional margin, asteroid and station clearance are
  unchanged; the independent E05 fixture controller keeps its own 135 u limit.
- Movement ownership: Locomotion is the only executor. Behavior moves only through
  `movement_lab.autonomous_move()`. Player commands are announced by
  `command_given()` from `_execute()` (a held command is recorded when released);
  Behavior takes a MOVE there as the player's Move. While docking owns the ship,
  Behavior holds the Dock command and requests nothing.
- `hostile_commander.gd` (`HostileCommander`): gives its faction's armed ships a
  tactic, Guard and Attack-Move objectives through CombatOrders once their map is
  ready. No strategic AI. Kept as shared code; no scene instances it since the
  legacy cleanup.
- Not migrated from the prototype (decision): heading lock, fixed forward cannon,
  v0.2 scenarios.

### 4.7 Camera and views (`camera/`, `presentation/`)

- `camera_rig.gd` / `camera_rig.tscn`: pan W/A/S/D, rotate Q/E or middle drag; pan
  bounds = the sector square, set at start by `movement_lab.gd` (rig default
  300 × 300). Zoom 5–40 by default, `max_zoom` 150 in `main.tscn`, `combat_test.tscn`
  and `encounter_arena`. The wheel sets `zoom_target` (× / ÷ 1.1 per notch,
  `InputEventMouseButton.factor` honoured, ≤ 10 notches per event); `zoom_distance`
  follows in log space (95 % in `zoom_smoothing_time` 0.25 s, real time); the ground
  point under the cursor stays under it (bounds win; pan, rotate or an outside move
  drop the anchor). Pitch = `pitch_for(rendered distance)`: 40° up to 20 u, smoothstep
  in log distance to 60° at 100 u (exported). Wheel ignored over a UI control. Snap:
  write `zoom_distance` and call `_apply_zoom()`. `zoom_level()`: 0–1, log on the fixed
  5–150 range. `follow()` exists but nothing triggers it.
- Tactical (`tactical_markers.gd`): `emphasis()` 0 Local – 1 Tactical, smoothstep on
  zoom distance 30–100 (exported). Models are never hidden for zoom (`model_shown()`
  is fog only). Screen-space markers fade in at constant size (sizes in the script,
  px at 1080 lines; `marker_scale`, separate `hit_radius` 14 px): ships in faction
  tint with the ObjectMarkers category shapes (hostile with an outer outline,
  brackets when selected), stations a square with a centre dot, every asteroid a
  small diamond in survey colour (one batched array). Selection ring, hull bars and
  ObjectMarkers ship icons fade with 1 − emphasis. Picking: an interactive ship marker
  (emphasis ≥ `interactive_emphasis` 0.5; nearest centre, ties by Ships order), else
  the hull; stations and asteroids keep model picks.
- Movement indicator (issue #3; `presentation/movement_indicator/`): one
  `movement_indicator.tscn` (`MovementIndicator`, CanvasLayer 0, mouse ignored, in
  `ALWAYS_NODES`) per gameplay scene (Test Arena, Combat Test, Movement Test, encounter
  arena) is the only drawing of selected ships' movement orders. Display only:
  `movement_lab._process()` passes `set_entries()` per selected ship {ship, from,
  destination (held MOVE point, WAITING request or Locomotion destination), requested
  (connector), route (Strategic `order_lines()` route while the handoff runs)} and
  the handoff `progress` as `route_blend` (straight line cross-faded into the route, one
  symbol). Line, detached arc (facing the incoming line) and circle lie on the ground
  plane, projected through the current camera (perspective ellipse, round top-down);
  sizes are fixed physical screen px (`get_screen_transform()` scale), the symbol's
  width across the screen at the destination; drawn over the 3D view and under the
  ship markers and panels. Lines and connector stop `destination_gap_world` (export on
  `movement_lab.gd`, 0.25 u) beyond the whole symbol; a line that does not clear it is
  omitted, the symbol stays. Shared look, edited once for every scene:
  `movement_indicator_style.tres` (`color` #838A91, line 2 px, circle 28 px, stroke 2
  px, arc 28 px, offset 8 px, sweep 90°; provisional, owner to tune). F6 preview: the
  production renderer and camera rig with editable sample orders (Ships, Destination,
  Requested, Via markers); keys 1–4 zoom 5 / 40 / 150 / Strategic scale; in the editor
  the rig camera keeps its authored zoom 15 pose. `layout()` / `entries()` are the
  query API used by tests.
- Strategic View (`strategic_view.gd`): one more outward notch at the rig's maximum
  hands over (0.45 s) to a fixed top-down camera framing the sector on render layer
  20; an inward notch returns to the exact saved pose. Layer 20: simplified lit
  asteroid spheres (the sun is also put on layer 20), overlay (contours, shadow bands,
  dust; experiment E adds formation density and haze), FogView's material. Screen
  space: selected waypoint and Attack-Move lines (routes are the movement indicator's),
  cluster and per-family resource markers with radial
  expansion (groups ≤ 6), refused-command boundary. Picking: markers only; no input
  completes during a handoff.
- `tactical_grid.gd`: withdrawn; created only with `tactical_grid_available` (kept
  for a later return). `weapon_envelopes.gd` (Alt, target selection),
  `combat_overlay.gd` (target lines; F10 arcs), `behavior_view.gd` (guard positions,
  waypoint and Attack-Move lines).

### 4.8 Presentation and environment (`presentation/`, `survey/`, `mining/`)

- `world_highlight.gd` + `highlight_fill` / `highlight_outline.gdshader` (stencil):
  selected ships and station cyan, hover pale, constant screen width; asteroids get a
  copied material with the highlight as next pass (survey grid and shared material
  untouched).
- `object_markers.gd`: 7 px markers on hover or selection only: triangle combat
  ships, octagon ships with Cargo, square stations, diamond asteroids (survey colours:
  grey unknown, amber minerals, blue ice). Shape points shared with tactical markers.
- Shared selection/marker appearance (`presentation/markers/`, issue #6):
  `interaction_style.tres` owns selected cyan (WorldHighlight/ObjectMarkers), selection
  green (rings/Tactical brackets), the two distinct hover colors, highlight alpha/width,
  ring dimensions and the drag StyleBox. `marker_style.tres` owns marker-only colors,
  alpha, tint treatment and strokes; faction and survey palettes remain with CombatShip
  and SurveyView. Each of ShipSelection, WorldHighlight, ObjectMarkers and TacticalMarkers
  deep-copies its referenced resources at `_ready()`: save source edits and restart
  F6/project to apply them. Existing visuals and later ship registrations use that run's
  snapshots; runtime materials/state never modify source resources. Shape generation,
  geometry/picking rules, stencil passes, culling, emphasis and contact-memory stroke
  remain in their existing owners; no per-marker nodes or new renderer.
- F6 `markers/marker_preview.tscn` uses the production Test Arena/renderers with frozen
  simulation: keys 1–5 isolate All / Ring and drag / Highlight / Object / Tactical;
  6–9 zoom 5 / 40 / 100 / 150; 0 toggles Strategic. Sample family/zoom/hover are exports
  on MarkerPreview. Deferred from this batch: scan-feedback and mining-beam authoring,
  behavior/weapon/combat guidance styles, Strategic/contact-memory styles and debug
  overlays. Sensor grid and Movement Indicator remain unchanged, with no relocation.
- `command_cursor.gd`: shows what a right-click would do (Move, Mine, Dock,
  Unavailable, arrow) from `resolve_command()` / `command_available()`; cached per
  target / 2 u cell, refreshed every 0.5 s; a group is checked with
  `GroupOrders.can_assign()` after 0.25 s rest. OS cursor shapes are placeholders.
- Projectile/trail appearance (issue #7): `presentation/effects/projectiles/`
  `projectile_visual_style.tres` owns fallback shell/tracer dimensions and tint blends;
  `presentation/effects/ordnance_trails/ordnance_trail_style.tres` owns ribbon widths,
  RGB, opacity and tail-width ratio. `Projectiles.visual_style` and `OrdnanceTrails.style`
  take private startup snapshots: save source edits and restart F6/game to apply.
  Fallback meshes/materials are cached per Projectiles instance and faction/style;
  the Kestrel's custom mesh bypasses fallback styling. Existing one-node rounds,
  single-surface ImmediateMesh trails, histories, age/fade/reveal and physics stay in
  their original renderers. Unknown projectile styles keep shell-sized geometry with
  non-shell tint; unknown trail kinds (including rocket) keep width 0.1 and white.
  F6 `projectile_trail_preview.tscn` uses Combat Test and production spawn/launch APIs,
  both factions and a preview-only torpedo configuration; 1/2/3 zoom 5/40/150, normal
  camera/time controls, playback/interval/zoom exports on ProjectileTrailPreview.
  Fog/environment/Strategic/god-ray shader extraction and ordnance modeling are deferred;
  existing SectorProfile authoring, Combat Flash and #6 systems remain unchanged.
- Thrusters (`presentation/effects/thrusters/`): two reusable GPU-particle scenes in world
  space with one shader `plasma.gdshader` (per-instance brightness and size are
  instance uniforms, so no shared material is written).
  - `main_thruster_fx.tscn` (`Core`, `Exhaust`, `Trail`, `Glow`; `thrust` 0..1,
	`powered`); `directional_thruster_fx.tscn` (`Exhaust`; `thrust`; `continuous` on by
	owner choice, else pulses at `pulse_frequency` as emission windows, never restarts).
  - Shared look, edited once for every user: `main_thruster_settings.tres`,
	`directional_thruster_settings.tres`, the `*_process.tres` and `plasma_*.tres` /
	`nozzle_glow.tres` resources. Per instance only `nozzle_scale` and
	`length_multiplier`. Scripts are `@tool`.
  - `thruster_view.gd` (`ThrusterView`): reads every ship each physics tick, never
	writes; places one main effect per `MainEngine*` and one directional effect per
	jet box of the hull's `Thrusters`, under itself (never under a ship), sized from
	the parts. Jet intensity = ship-frame acceleration share of its limit (smoothed
	0.08 s, zero without propulsion). Main states: BOOST 0.5 + 0.5 × intensity, THRUST
	0.5, IDLE 0 with glow, NONE 0 without; blended 0.15 s. A ship cruising forward
	keeps THRUST through minor braking (retro below `CRUISE_BRAKE` 0.35), dimmed in
	proportion, so the plume does not flicker (Stage 6B). API: `state_of`,
	`intensity_of`, `plume_of`, `plumes_of`, `jet_of`, `emitters_of`.
  - Ordnance: `WeaponGeometry.build_ordnance()` adds effects to torpedo and missile
	nozzles and missile attitude mounts; `ordnance.gd` drives them; sizes in
	`OrdnanceConfig`. The `OrdnanceTrails` ribbon is kept (owner choice).
- Combat flash (issue #4; `presentation/effects/combat_flash/`): every muzzle flash,
  impact, burst and destruction flash is one `combat_flash.tscn` (`MeshInstance3D`, shared
  radius-1 sphere, unshaded alpha material local to the scene, no shadows) grown linearly
  from `radius` to `radius` × `growth` and faded linearly to transparent over `lifetime`,
  then freed. `game/combat/combat_effects.gd` (node `Effects`, `@tool` for the preview) is
  the only spawner: public API `muzzle_flash()`, `impact()`, `burst()`, `destruction()`,
  `active_count()` unchanged; it keeps positions and offsets (muzzle +0.08 u × size along
  the direction, destruction +0.5 u Y) and passes caller colours and sizes per flash.
  Flashes are direct children of `Effects` (FogView hides them outside coverage; never
  under a ship), process in idle frames and inherit its pausable mode. Shared look, edited
  once for every scene (Inspector on `Effects` or the files): `combat_flash_style.gd`
  presets `muzzle.tres` (0.12 u, 1.6×, 0.09 s, caller colour blended 0.6 to
  (1, 0.95, 0.7)), `impact.tres` (0.18 u, 3×, 0.25 s, (1, 0.65, 0.25)), `impact_soft.tres`
  (0.12 u, 2×, 0.18 s, (0.7, 0.75, 0.8)), `burst.tres` (1 u × caller radius, 2.2×, 0.3 s,
  caller colour), `destruction.tres` (1 u, 4×, 0.8 s, (1, 0.5, 0.15)); a flash reads its
  preset once at start, so edits reach new flashes. F6 preview: the production spawner
  replays eleven samples every 1.2 s (also in the editor; unowned children); keys 1–3 zoom
  5 / 40 / 150. No pooling (E05 measured within noise).
- Environment (`sector_environment.gd`, `SectorEnvironment`; profile
  `sector_profile.gd` / `warm_sector.tres`): key light, ambient, background, ground;
  rocks, debris and dust pockets around formations. Sky `environment_experiment`: A
  flat, B the panorama (rotation X 90°, energy 1), C sky-sampled (comparison only).
  `lighting_experiment_d` (with B): designed radiance for ambient and reflections.
  `god_rays.gd` (`god_rays_enabled`): up to 8 shafts and 4 shadow bands from the
  largest formations, fainter at Tactical, not in Strategic. The Test Arena keeps A
  with none of these; Combat Test uses B only; no scene turns on D, E or god rays
  (in-game switches and root exports; `sector_environment_test` turns them on in
  Combat Test).
- Sensor grid overlay (`presentation/sensor_grid/`; accepted 2026-10-29):
  `sensor_grid_overlay.tscn` (`SensorGridOverlay`, one `MeshInstance3D` quad), added by
  the arena's combat layer next to `FogView` in scenes with `Sensors` (in `ALWAYS_NODES`).
  Shown under `selection().selected[0]` at y 0.04 (the quad world-axis aligned), radius
  `Sensors.sensor_range`; the grid and its rectangles turn with the ship's heading (instance
  parameter `grid_axis`, the ship's X axis, set every frame). `sensor_grid.gdshader` draws,
  from one signed distance field, the fill, grid, intersection rectangles and two outlines
  (inner at the boundary, outer `outer_offset` beyond). Every visual value is a uniform in
  the shared `sensor_grid_material.tres` (Inspector; owner-tuned: overall opacity 0.32,
  grid 4.625 u, rectangles 0.8 u capped at 2 px, inner outline 2 px, outer 1 px, gap 2 u); line widths are px at 1080 lines, spacing, offsets and
  rectangles world units. Cutouts are line-of-sight shadows from the ship (accepted
  2026-10-29): every static obstacle footprint from `PlanarCollision.obstacles()`
  (circles, rotated boxes) reaching the overlay, grown by `cutout_clearance` 1 u, casts
  its footprint plus the cone between its two tangent rays from the ship, out past the
  quad. Circles are exact in the shader (rounded pinch); boxes are convex polygons built
  by the script (corners sampled, 8 points). The shadows are unioned (plain minimum) and
  subtracted from the circle, meeting it with `cutout_blend` 1.5 u. The overlay draws
  with a runtime copy of the material (shadow arrays written per frame; the shared file
  is never written). Presentation only.

### 4.9 UI (`ui/`)

- Foundation: `ui/theme/apalit_theme.tres` (HeaderLabel, SectionHeader, MutedLabel,
  WarningLabel, SegmentButton, HullLossLabel, ArmorLossLabel, ProductionRequirements),
  `resource_icons.gd` (generated placeholders),
  `ui/components/` (`panel_shell`, `section`, `refinery_slot`, `resource_tile`,
  `resource_row`, `segmented_control`): display-only scenes that emit signals;
  gameplay stays in its systems. No UI framework or state manager.
- Inspector: `panel_shell` fixed 340 px, bottom right (16 px margin), fixed header,
  scrolling body up to the screen height − 96 px. Ship panel (`ship_panel`, exactly
  one ship): Header (editable name, class), Status (activity, dock with queue
  position, fuel bar and warnings, hull bar with "DESTROYED" for a hulk, armor
  condition bar hidden when `max_armor` is 0; a drop flashes the bar red / amber and
  shows the burst "−N": 1 s window, 0.5 s fade, real time, `loss_hold` / `loss_fade`
  exports, reset on selection), Combat (armed ships: tactic selector,
  command, target, weapons and ammunition), Cargo
  (tiles), Actions (Scan Area, mining base selector and Start / Resume, transport,
  Undock, Unload / Load). Start / Resume buttons are disabled only while the station
  moves the ship; from docked they are held and run after the exit (Start Transport at
  its loading station loads in place). Station panel (`station_panel`; selected by
  left-click via `AsteroidHover.station_at()`, cleared by a click elsewhere or ship
  selection): Header, Status (fuel bar, health placeholder), Storage, Refinery slots,
  Ship Production (recipes with required / available / missing, Order, Cancel while
  waiting, progress while constructing, obstruction while awaiting deployment, "Last
  completed"). Never shown together.
- `display_name.gd` (`DisplayName.of()`, `rename()`, `class_of()`): metadata
  `display_name` / `display_class`; renaming changes only panels, hover and notices,
  never node names, registration or Shipyard numbering.
- `transport_editor.tscn/.gd`: edits a draft of loading requirements (tabs Ore,
  Ingots (Ice shared with Ore), Components disabled); nothing is live until Apply
  (`Transport.apply_requirements()`, all or nothing); Cancel discards the draft.
- Shared overlay visuals (`ui/overlays/`, issue #5): `combat_hud/combat_hud_view.tscn`
  authors result, speed and target-inspection labels and draws all hull bars on one
  canvas surface. `combat_hud.gd` retains world projection, fog/target eligibility,
  tactical fade decisions, static text APIs and the fixture subclass's `_label()` helper;
  the view receives projected positions and display data only. Hull-bar appearance is
  Inspector-editable in `combat_hud/hull_bar_style.tres`; inspection cursor offset/margin
  are exports on CombatHudView. No per-ship UI nodes.
- `asteroid_hover.gd` (layer 2) retains survey/station text, picking, GUI suppression
  and edge clamping; its panel/label are `overlays/hover_tooltip/hover_tooltip.tscn`
  (`cursor_offset` metadata on HoverTooltip). `overlays/notice/notice.tscn` is the single
  `NoticeUI/Notice` definition in Test Arena, Combat Test, Movement Test and the encounter
  fixture; notification replacement and two-second real-time timing stay in `movement_lab.gd`.
- F6 authoring: `overlays/overlay_preview.tscn` instances all three production visuals;
  keys 1–4 isolate All / HUD / Hover / Notice. Sample states are Inspector exports on
  OverlayPreview. There is no additional panel preview; inspect production panels in Test Arena.
- Color authority: `apalit_theme.tres` HullLossLabel / ArmorLossLabel `font_color`
  drives both loss text and scripted bar modulation; ProductionRequirements `available`
  / `missing` colors are explicitly formatted into production BBCode. The two-argument
  static `_ingot_lines()` fallback reads that same shared theme. Original colors and
  feedback timing are retained; controls keep runtime state separate from shared styles.
  Existing meters, inventory components and procedural icons remain; custom cursor art
  and editable icon palette/geometry are deferred from this batch.
- Debug panel (`debug/`, top left, off at launch): Movement, Navigation, Avoidance
  Debug (collision contacts under Avoidance).

## 5. Controls

| Input | Action |
|---|---|
| Left-click ship / Shift-click / ground | Select / add-remove / clear (Shift keeps) |
| Left-drag > 5 px | Box selection (Shift adds) |
| Left-click station | Select station, open its panel |
| Right-click ground | MOVE (one ship) or translated group MOVE (several; partial orders possible). Over a stationary ship: beside it; over a moving ship: the point |
| Right-click asteroid (one Miner) | Mine it (scanned or not); several ships: group MOVE |
| Right-click station (one ship) | Dock |
| Right-click visible hostile | Target it |
| Ctrl + right-click | Hostile: Attack; friendly ship: Guard; ground: Attack-Move |
| Shift + right-click ground | Add a waypoint |
| T | Attack-target selection (0.25x; left-click a hostile; Esc or right-click elsewhere cancels) |
| X / Backspace | Cancel command / clear manual target |
| F1 / F2 / F3 | Passive / Defensive / Aggressive |
| Alt (hold) / F10 | Weapon ranges / combat debug overlay |
| Space; − / = | Pause; speed 0.25x / 1x / 2x |
| W/A/S/D, Q/E or middle drag, wheel | Pan, rotate, zoom to cursor (not over UI); past max: Strategic View |
| F8 / F7 / F6 / F9 (in game) | Development switches: sky A/B/C, environment lighting, Strategic depth, god rays |
| 4–9, 0, − | Avoidance scenarios (test arena with `scenario_keys` only) |

Orders belong to the ships and persist after deselection; a new MOVE replaces the old
one, keeping momentum. A ship without fuel still takes orders. Hovering outlines and
marks an object; panel header names are renamable by click; Configure opens the
transport editor. No keyboard shortcuts are shown in the UI. Editor F5 / F6 (run
project / current scene) are editor keys, distinct from the in-game F6 switch.

## 6. Owner decisions and frozen areas

Design principles (owner, 2026-10-11, carried forward from the original game):

- Fantasy: the player is an admiral commanding WWII-style warships in space; heavy
  capital and cargo ships, no fighters.
- The player gives intentions (where); the autopilot owns speed, braking, turning and
  waiting; no player speed orders.
- Collision is a safety net the player should almost never see; a contact keeps the
  order.
- No drag (momentum is planned around); flip-and-burn only for transit between
  sectors.
- No reversing out of deadlocks (decided for the original traffic system; not
  re-confirmed since).
- The developer's own play is the validation (solo hobby project).
- Later work, each started only when its trigger arrives (status of the first and
  last since their triggers: see section 10):
  - Facing control (heading separate from travel): trigger combat prototype.
  - Nearby-ship spatial grid: at about 20 ships; replaces all-pairs checks.
  - Formations: after groups; keep shape, shared internal speed cap, blocked slots
	resolve, break and rejoin. Locked formations are to be designed separately; no
	leader, shared speed or formation persistence exists.
  - Transit between sectors: physical, interceptable, flip-and-burn, arrive slowed.
  - Larger maps: with weapon ranges and sectors; missile range must leave room for
	an approach phase.

Frozen or not authorized without the owner:

- Movement baseline: cause C + direct-move prediction horizon (+ same-course pass
  side and re-plan, accepted 2026-10-22/23). Cause B, planned rejoin (paused) and
  parked-ship navigation are not to be reopened. Parked navigation (2026-10-15,
  not integrated): routes around parked ships worked, but synchronous rebakes cost
  about 119 ms per park or departure on `main.tscn`, stale routes need invalidation and
  local avoidance is still required; asynchronous or incremental updates were not
  evaluated.
- Group MOVE projected slot ordering (step 3) was rejected and reverted.
- No further movement or docking refinements; docking durations and the 6.2 u
  footprint (former Destroyer, now FF-01) wait for the owner (radius and collision
  geometry unchanged by decision).
- Combat: no tuning, new mechanics or hostile AI changes; I01's
  accepted boundary correction authorizes no further combat tuning. Exception: the
  owner's staged FF-01 weapon tasks and launch profiles (all accepted), each
  authorized separately; their values are approved v0.1 playtest values, not to be
  rebalanced without the owner. Rocket threat priority beyond the missile rule is not
  designed.
- Solar Map and multi-sector architecture: anticipated, not authorized or planned.
- Components, upgrades and equipment swapping are placeholders (transport editor
  Components tab disabled).
- Station traffic (owner, Option A): no serialized docking traffic, no deadlock
  recovery.
- Transport Start always goes to the loading station first, also with cargo aboard.
- New work follows the strict reusability policy in `AGENTS.md`.

Provisional values (wait for owner iteration): asteroid generation, 65 % mineral
share and reserves; scanner radius, cooldown and survey timings; extractor rate and
range; cargo 1000; station storage 5000, transfer 50/s, fuel stock and refuel rate;
fuel tanks and consumption; `local_fuel_scale` 0.1; refining rates; Shipyard recipes
and times; `resolve_margin` 5 u; docking durations (accepted baseline); mineral
distribution, logistics balance, models and UI polish.

## 7. Known limitations

### Movement and traffic

- Cause B (open, paused): on a single-leg move Locomotion brakes for the straight
  distance to the unshifted destination, so a ship ending just past a stationary ship
  overshoots about 4.4 u and backs up once (`obstruction_test` known failures).
- Only one passing shift is applied: if it does not clear a second stationary ship the
  ship yields, also where a larger shift would clear both. Moving or avoidance-held
  ships are outside the cause C correction. If the pulled-back steering line would
  cut an obstacle, the old steering is kept and the ship may wait at the reserve.
- Own-ship prediction starts at the route position: a ship far off its leg does not
  see ships beside its actual position, and once its route position reaches the end
  of a direct leg no stationary ship is an encounter; it can then be held by collision
  against parked ships (stalled, no overlap; the main source of high contact counts in
  stalling group layouts). A ship held at a pass shift near its destination by a real
  conflict still shuttles (cause B).
- Traffic stalls: ships can wait permanently with their orders (no time limit or
  recovery; mutual give-way; passes capped to 0 among parked ships). Collision
  prevents penetration but resolves no deadlock. No stall notice for the player.
- Avoidance: late detection of ships accelerating from rest on crossing paths; unsafe
  passes possible (move across not swept against the passed ship); the pass speed cap
  keeps its following floor. Example (test arena, observed with the retired Gunship;
  not re-checked): Miner (90, −5) → (115, −5) crossing 15 u ahead of a Gunship
  (115, 40) → (115, −40): contacts and reversals, both arrive.
- Collision: conservative bounding circles (FF-01 stopped up to ~5 u
  from their hull sides, also at the sector edge); ships starting overlapped stay overlapped; slow creep in sustained contact;
  the ship processed first may gain up to one tick of movement.
- Sphere obstacles use the full radius whatever the plane height; uniform scale assumed
  (only X read); 32-gon outlines give small bends around large asteroids.
- Sector edge: enforced only in scenes with a PlanarCollision (not
  `station_docking_demo`, `tri_station`); ships pressing into it show the creep and
  braking-plume effects of any sustained contact. Course turns are skipped within
  3 × lookahead of an obstacle or the edge (FF-01 at cruise: 30 u).
- FF-01 (formerly Destroyer) mid-route redirect aim line enters the reserve
  (`navigation_test` known failure; no footprint overlap).
- Movement cost (lab): mean 0.21 ms per tick with 6 ships, 0.70 ms with 12, p99 up to
  2.05 ms; avoidance 21–40 µs per ship per tick, growing with ship count.
- The yield fallback is verified once, not a permanent test scenario.

### Orders and Group MOVE

- Refusals are rare in play and verified only with forced conditions. An order queued
  while the map is not ready (start-up) leaves the previous order running unsteered
  until planned; a refused order given while another is queued drops the queued one.
  Automated callers (`Docking.dock()`, `MiningOperation.assign()`) keep their UNABLE /
  UNREACHABLE states.
- Group MOVE keeps each ship's current spread, also for widely separated selections;
  Attack-Move and Waypoint groups use the centroid of their Behavior ships only; a
  stored destination is the route's resolved end (within 0.25 u).
- Not investigated (observed with the retired Gunship and Destroyer, now the
  Transporter and FF-01 in `group_rotation_test`; not re-checked): in case 4 the
  Gunship passes the slower Destroyer up to 10.5 u off its path and then drifts into the parked Miner2 (2
  contacts, all arrive); a 4-ship group (Gunship, Destroyer, Miner1, Miner2) MOVE 45 u
  to the side of its travel stalls ships (9–14 of 40 over 10 runs; present before step
  2; slot-side switching not established as the cause); some formerly spinning ships
  end in the mutual give-way stall (`group_rotation_test` (23.5, 4.0)).
- Group assignment cost: median 0.1–0.5 ms, p90 2–3.5 ms, worst about 59 ms (6 ships
  over dense asteroids) and up to 46 ms at the sector edge.
- Cursor: a cached result can be 0.5 s old; a group shows Move for its first 0.25 s on
  a cell. Not investigated: with an artificial 40 u no-route zone a group click gave
  "No route found" instead of the group notice.
- Held commands: real right-clicks cannot produce an invalid intent (intent refusal is
  tested through `_order()`); a group MOVE with held ships plans every destination from
  current positions (re-checked at release); a command accepted for a docked ship can
  be refused after the exit (ship left at its exit point); a group MOVE including
  docked ships undocks each.

### Stations and docking

- A 6.2 u circular footprint (FF-01; observed with the retired Destroyer) keeps a ship
  out of bays its hull appears to fit (e.g. the 10 u tri-dock bays) and makes exits long. At Station's west berth its
  ExitA is blocked by an asteroid, so it always leaves by ExitB (a ship waiting on that
  side waits until the exit ends).
- No recovery: an entry or exit stopped by a contact, or running out of fuel
  mid-maneuver, stays where it is (an entry stopped short ends Unable to Dock inside
  the rectangle, keeping the berth occupied); an idle ship parked inside a rectangle
  blocks that berth with no notice. Undocking an empty ship from an empty station
  leaves it inside the rectangle.
- Ships leaving under control are seen by others as idle (they give way; predicted
  along current velocity).
- Ships moving around a station on crossing routes under ordinary movement can still
  deadlock permanently (player clears it with a new order); several ships ordered off
  together from a clustered spawn can stall before the station.
- `cancel()` on a docked ship (no production path) releases the request without moving
  it. Undock with no clear exit side keeps the ship docked (every current berth has a
  clear side for every class).
- Typing in the Load amount box may also pan the camera (W/A/S/D read directly; not
  checked).
- Tri-dock layout: overlapping hub / back-block outlines log navigation edge warnings
  (expected in `tri_dock_test`, its demo and `reuse_test`).

### Economy

- Fuel: a ship stops dead in the tick its tank empties (that tick still completes,
  ≤ 0.08 u); refuelling only by docking (no rescue), so a ship emptied en route stays
  there ("Approaching Station" on a docking approach); refuel rate is per docked ship;
  no fuel production: the station's 1000 lasts about 30 Miner round trips to the
  farthest asteroids, then Miners leave without a full tank and strand.
- Mining: two Miners on the same asteroid stall permanently after about 12 cycles
  (mutual give-way); ships left on the spawn cluster can stop a departing Miner;
  storage 5000 fills after about five loads (Miners then wait) and a waiting Miner
  docks again for each bit of storage freed; an out-of-fuel Miner cannot turn, so a
  misaligned one does not extract until refuelled; alignment is to the asteroid's
  centre.
- Transport (30-minute soaks): asteroid 19 beside the Station ↔ Station2 route
  deadlocked a Miner and the Transporter in 2 of 5 runs; Transporter and Miner graze
  repeatedly converging on Station's west approach (no stall); the earlier
  short-of-route-end stall and hold-to-slot stall are addressed (end-of-route
  correction, station docking) but not re-soaked. A quota that cannot complete (e.g.
  a refinery consuming the same mineral) or a hold filled by unrequired cargo
  ("Requirements Exceed Capacity") waits docked indefinitely, holding the berth;
  congestion is not shown. A transport paused by an edit while travelling finishes its
  current order and parks there; one paused while docked stays docked until Undock;
  clearing the only requirement before setting another pauses it. Stations removed at
  run time are not handled (no code removes stations).
- Refining: no stock reservations (a transporter loading at the refinery station
  competes with the slots); only refinery stations refine (in the scenes, Station2).
- Shipyard: one order at a time, no queue, repeat or batch. Miners on "Nearest
  station" can unload raw minerals at the Shipyard (stored, never an input; shares the
  5000 storage, so it can block ingot deliveries). The deployment point is 2.01 u
  beyond the clearance a 6.2 u ship (measured with the retired Destroyer) at Hold3 /
  Hold4 needs from a deploying Transporter, so a ship drifting off those holds can
  hold a deployment (automatic retry). Such a ship at Hold3 is 3.79 u from the map edge. No long soak with many
  produced ships. Warship production would need its own recipe.
- Survey: the live-cursor hover path is checked only in rendered runs; % / DATA
  UPLOADED labels of close asteroids can overlap at maximum zoom; markers draw under
  the debug panel; analyzed ice hover shows "Asteroid Ice" and reserves only.

### Combat

- Aggressive hostiles acquire civilian player ships like any player ship.
- Stations block fire but take no damage; sensors ignore stations; weapon envelopes
  draw asteroid shadows only. Every hull is 150, civilian ships included, except FF-01
  (160 with armor); the HUD shows hull only, not armor.
- A ship destroyed during a controlled entry or exit stays as a 2 s hulk where it was;
  its station records are released at once and the berth is granted again only when
  physically empty.
- Placeholders: Target cursor (OS four-arrow), hostile marker outer outline, weapon
  meshes, hull tint (player blue, hostile red).
- Sensor defect O21 (resolved 2026-10-27): `last_known()` loops with a `Variant`
  variable, so its `is_instance_valid()` guard skips freed contacts instead of raising
  "Trying to assign invalid previously freed instance" before the next `evaluate()`.
  Verified only by a temporary headless reproduction (detection, loss, destruction,
  removal, lookup): error before, none after, the other lost contact still listed;
  no suites were run.
- Move command results O22 (resolved 2026-10-27): single-ship `issue_move()` (so
  `CombatOrders.move()`) returns `_order()`'s result (executed, queued or held for
  station control: true; refused: false) instead of inferring it from an older active
  destination; `_move_single()` no longer reports a moved-aside order RouteFollower took
  as "Order not accepted". Verified only by a temporary reproduction (refused and valid
  replacement, moved aside, held during docking); no suites were run. Out of scope:
  `hostile_fleet`'s candidate loop now sees real refusals, unverified.
- Weapon-profile removal (2026-10-27) test limits: their Behavior ships now use FF-01
  positioning. Whole-suite runs (2026-10-30): `e05_behavior_test`, `ff01_test` and
  `combat_scene_test` pass; `command_test` and `positioning_boundary_test` fail (section 8
  known failures). The checks that depended on the deleted engagement path now verify state:
  C11 (engaged target is only the manual target), E05 V1 (every accepted combat
  objective was for a hostile in contact), V8 (no request after contact loss; the
  deleted path's "pursuit stopped" stop is gone) and `_case_engagement` (objective
  beyond 135, routable, `_position_ok` and line of fire; band and fallback criteria
  removed). Each passed in a focused run only.
- Legacy-cleanup test limits: `combat_positioning_test`'s "authored asteroids produce
  a real navigation detour" check fails with the FF-01 opponent (routes reach 2 points,
  3 required). Before the cleanup it passed with a single 3-point route, at its
  threshold, with near-identical trajectories; no fixture mismatch was shown, so the
  assertion is kept unchanged. Obstacle clearance holds (minimum 1.89 u). E05 fleet
  balance, outcome and battle-duration assertions (`fleet_test` V1 / V6, `time_test`
  C7) were tuned for the retired fleet and now only print their measurements.
- Wayfarer avoidance remains bounded and can fail physically; overshoot recovery
  depends on its remaining nine-second flight time. It never switches target identity.
- Barrage is a committed saturation weapon: abrupt maneuvers can evade its approximate
  initial lead, and physical 3° dispersion can miss thin hulls. At a 60 u muzzle
  distance, five seeds gave 17/40 hits per broadside; dispersion-free controls hit
  8/8 per side (65.75–66.75 u total travel, 3.57–3.60 s). Misses expired at the
  70 u path cap before 4 s; fresh attacks beyond 60 u were rejected, while committed
  rockets continued beyond that acquisition radius. These values are owner-approved;
  no further tuning is requested. The Alt envelope still uses the hardpoint's unused
  15° cone and the F10 overlay draws no rocket wedge.

### Camera, views and presentation

- Camera: near the bounds the clamp lets the cursor point drift; a large wheel burst
  can tilt up to about 8° per frame; a panel opening under a still cursor may not
  block the first wheel step (inferred); scenes that zoom to 40 show about 48°. In
  headless runs the visible rect is reported as 1152 × 648 (unverified since the
  1920 × 1080 base canvas; section 10).
- Tactical: hull bars are hidden at full emphasis; asteroids under about 1 u radius
  can be smaller than their marker at zoom 150 (an edge click misses); diamonds overlap
  below about 1.8 u spacing; the hull-bar and ObjectMarkers icon fades have no
  automated check. Recorded marker-size note "nominal × 0.75 of a 648-line canvas" is
  unverified since the 1080-line base canvas (section 10).
- Environment switches (observed in the removed Sector Showcase): god rays are a
  restrained stylized stand-in (usually one or two shafts in view; shadow bands faint, shade `opacity` 0.4); Local / Tactical fog still tints the
  starfield (only Strategic fog skips sky pixels); the Strategic sun-layer fix also
  lights the Test Arena's Strategic spheres; Strategic framing fits the sector rotated
  by the rig's 45° yaw; environment lighting is subtle (+4–6 %), energies exposed on
  SectorEnvironment.
- Sensor grid overlay: in shadows narrower than twice the 2 u outline gap the outer
  outline starts only where the wedge has widened (a thin line inside the cutout); a
  visible sliver between two nearly touching shadows keeps its own outlines (it is in
  line of sight); an obstacle whose grown footprint contains the ship casts no shadow;
  off-centre asteroids look shifted from their shadows (perspective, meshes above the
  plane); at most 64 circle and 8 box shadows (nearest the ship kept); box shadows not
  seen (no stations in Combat Test); obstacles added after start are not cut
  (PlanarCollision reads them once); no automated tests (owner decision).
- Movement indicator: strokes are constant px (not foreshortened); the arc follows the
  world direction of the incoming line, so it can appear on any screen side; at zoom 5
  the 40° pitch flattens the circle to about 0.64 of its width; the editor preview
  shows only the rig's authored zoom 15 pose; editor-time redraw on a style change and
  live rendered gameplay were not verified by tests; several selected ships are not
  covered by an automated check.
- Combat flash: editor-time preview replay and preset-edit responsiveness are not
  covered by tests; Combat Test performance was not measured separately (E05 was the
  high-load case).
- Thrusters: a teleported ship (`place()`) can flash its jets for a tick; particles
  pause with the game but do not follow time dilation.
- `SectorEnvironment.apply_lighting()` writes Ground's shared mesh/material color
  without localizing it. Cross-instance contamination is an unverified risk, deferred
  from issue #7; Environment itself is duplicated.
- UI: at 1280 × 720 long names clip in editor rows and the Ingots list scrolls; a wide
  notice can overlap the debug toggles; icons are placeholders; two overlapping
  highlighted objects share the stencil (no outline between them); asteroid hover fill
  barely visible; the 7 px octagon reads almost as a circle.

### Architecture and tooling

- Reuse depends on the layout contract (section 3); inherited scenes cannot remove
  archetype components and added components run last. The test arena and
  `obstruction_test` keep their own movement-only ship copies. `reuse_test` depends on
  `game/tests/docking/tri_station.tscn`; its station-fuel check asserts only that stock
  fell, not exact amounts.
- Docked ships count as parked for avoidance.
- Nested overrides need Editable Children: Godot 4.7.2 saves a property override on a
  node inside an instanced scene (the hostiles' `Ships/Hostile…/Combat`) only if that
  instance has Editable Children (`[editable path="…"]` in the `.tscn`); otherwise
  any save drops it, though loading applies it. The hostile overrides were
  hand-written without it, so editor saves of the former Sector Showcase stripped them
  (2026-10-22 and 2026-10-25). Reproduced headless (load, pack, save to `user://`, reload: all
  three lost; with `[editable]` all three kept, nodes and properties otherwise
  identical). Fixed by `[editable]` entries; `HostileFF01` in `combat_test.tscn`
  keeps one. Any new override on a nested
  instance's child needs the same. `sector_environment_test` and `combat_scene_test`
  catch lost overrides at run time, not at save time. Not yet verified through an
  actual editor save.
- The owner's editor state (`.godot/editor/` layout and caches) still names retired
  experiment files; the editor may report once that it cannot reopen them, and headless
  `--import` logs "Cannot load shader: res://experiments/movement_v3/…". Project files
  are unaffected.
- The playable scenes still use the lab-era script name `movement_lab.gd`; experiment-era
  export names await an owner decision (section 10).

## 8. Testing and environment

- Godot is not on PATH. Console executable:
  `C:\Users\Nikos\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe`
  (4.7.2.stable). Git 2.55.0 and GitHub CLI 2.102.0 installed; `gh` logged in as
  `nikosban`, pushes use SSH.
- Suites: 40 in `game/tests/`, 23 in `game/tests/combat/`, `game/tests/docking/tri_dock_test.gd`
  (64 total). Run: `<godot console> --headless --path . -s res://game/tests/<name>.gd`.
- `--fixed-fps 60` is required for every combat suite and for `shipyard_runtime_test`,
  `reuse_test` (uninterrupted loop as fast as possible), `camera_test`,
  `tactical_view_test`, `strategic_view_test` (fails its boundary-fade check without
  it) and `sector_environment_test`. The 2026-10-23 full run used it for every suite.
- Scene runs: `--headless --path . --fixed-fps 60 --quit-after N [scene]` (600 frames)
  for `main.tscn`, `game/tests/docking/station_docking_demo.tscn`,
  `game/tests/docking/tri_dock_demo.tscn`, `game/scenes/combat_test.tscn`.
- Regression protocol: run the suites and scene runs twice before a change, then
  compare logs line by line, treating as variance only lines that also differ between
  the two baseline runs. Known variance: asteroid seed lines (unseeded fields, e.g.
  `shipyard_runtime_test` B10's asteroid and base), timing values, navigation map-ready
  frame, tri-dock warning order. Expected error lines: `guided_locomotion_test` check
  10 guard, `station_docking_test` deliberate `cancel()`, tri-dock navigation edge
  warnings. Verification scope follows `AGENTS.md` steps C and D. No runner script is
  kept.
- Movement indicator (2026-10-30, `--fixed-fps 60`): the 12 affected suites, the new
  `movement_indicator_test` (33 checks) and five 600-frame scene runs (the four above
  plus `movement_test.tscn`) compared against two pre-change baselines: all pass, no
  script errors, differences only object IDs, seeds and reworded checks.
  `movement_indicator_test` runs Combat Test in a bare 1920 × 1080 SubViewport (one
  canvas unit = one screen px) and logs one expected Godot warning (SubViewport outside
  a container). The headless window is 64 × 64 (screen scale 0.033), so in other
  headless suites the px-sized symbol is about 30 u across and lines are usually
  omitted; `selection_test` checks the omission rule instead of a drawn line.
- Combat flash (2026-10-30, `--fixed-fps 60`): `combat/combat_flash_test` (42 checks:
  every variant against the pre-extraction formula frame by frame, isolation, preset
  propagation, pause and time scale, `active_count()`, cleanup and reset, fog, preview);
  11 affected suites and the `main.tscn` / `combat_test.tscn` scene runs against two
  pre-change baselines: differences only on lines that also differ between baselines, only
  the known `fleet_test` failures. Rendered parity against the old procedural flash in
  Combat Test at zoom 5 / 40 / 150: 72 captures pixel-identical. Rendered E05, 2400 frames,
  old / new alternated twice: mean 4.03–4.09 / 4.05–4.13 ms, p95 10.8–11.1 / 11.0–11.1 ms
  (within noise). Note: `process_frame` is emitted before nodes process, so a test observes
  a flash one frame before it ages.
- UI authoring (issue #5, 2026-10-30, Godot 4.7.2, `--fixed-fps 60`): two
  pre-change baselines of eight affected suites and four 600-frame scene runs all passed.
  After migration: `selection_test` 41, `command_cursor_test` 12, `survey_test` 50,
  `combat/time_test` 37, `transport_editor_test` 13 and `shipyard_test` 42 checks passed;
  `ui_qol_test` 24 (11 added checks for theme consumption, both static helper forms,
  propagation, isolation and feedback semantics) passed. Existing output matched the
  baselines except the documented W1 intermittency: `combat/weapon_info_test` 12/13,
  one PDC tracking-angle mismatch (32.3° / 32.4°); no script errors. Test Arena,
  Combat Test, Movement Test and E05 600-frame smoke runs loaded without errors;
  Test Arena/Combat Test were also checked after the panel-color batch. The overlay
  preview loaded headless. Rendered baseline Test Arena/ship panel was inspected, but
  Computer Use was stopped before the combined post-change 1920×1080 / 1280×720 smoke
  pass; rendered parity, preview isolation and live interactions remain unverified by
  the agent. Owner accepted with this limitation. Godot generated three overlay script
  `.uid` files; a generated untracked runtime-log folder was removed, and later logs
  were directed into the ignored `.godot/` cache. No full-project regression for this task.
- Selection/marker styles (issue #6, 2026-10-30, Godot 4.7.2, `--fixed-fps 60`):
  two pre-change baselines; post-change `selection_test` 45, `world_highlight_test` 19,
  `object_markers_test` 15, `tactical_view_test` 30, `strategic_view_test` 30,
  `combat/fog_test` 19 and `shipyard_runtime_test` 25 checks passed (183 total, 15 added).
  Test Arena, Combat Test, Movement Test and E05 600-frame smoke runs loaded successfully.
  No script errors; WorldHighlight's early navigation-map synchronization error occurs
  in both baselines too. Log differences are added checks/counts, object IDs, source
  trace lines and baseline-varying seeds/timings. An isolated prototype was verified
  before production changes, then removed. With matched Test Arena states at 1920×1080
  and 1280×720, six production captures are byte-identical to the originals; all 120
  stable frames per state retain 825 nodes and draw calls 573 / 477 / 401 at zoom
  20 / sqrt(3000) / 100 (particle visuals hidden to isolate stable marker rendering).
  Eligible asteroid populations/batching and exact pick probes match. Rendered preview
  isolation, saved style edit/restart, drag, GUI selection/wheel blocking, scan/upload
  and asteroid highlight coexistence, beam presentation fixture, target guidance/pause,
  lost contacts and Strategic handoff were checked at both resolutions. Full mining
  gameplay and native Inspector interaction were not retested; no full-project regression.
  Rendered/editor probes logged environment user/cache-path errors (shader caching
  unavailable), while D3D12 Forward+ rendering completed. Godot generated three marker
  script `.uid` files; generated untracked editor artifacts were removed. Verification
  evidence remains only in the ignored `.godot/` cache.
- VFX authoring (issue #7, accepted 2026-10-31; Godot 4.7.2, `--fixed-fps 60`):
  two pre-change baselines, then nine targeted suites pass 423 checks (15 added):
  `thruster_view_test` 22; combat `cannon_test` 52, `pdc_test` 74, `rocket_test` 71,
  `guided_missile_test` 75, `launch_profiles_test` 48, `fog_test` 19, `time_test` 37,
  `combat_scene_test` 25. Final logs have no script errors or errors; added cannon
  fixture teardown was corrected and rerun. Four gameplay scenes and both affected
  previews load; all 24 relocated files match after path substitution with UIDs retained.
  Six matched 1920x1080 D3D12 captures (zoom 5/40/150, Strategic, hidden/revealed effects)
  are byte-identical with particles hidden; full-particle preview rendered separately.
  Saved edits reach preview and Combat Test; three resets pass pause, time-scale and
  cleanup probes. Three paired E05 runs (600 warm-up + 1800 measured frames, zoom 150)
  meet median p95 <=105%: 14.063 -> 14.329 ms (+1.89%); particle-isolated comparison
  12.970 -> 12.257 ms (-5.50%). Every paired effect/node/draw/surface count matches.
  Timing spread persists after isolation; no speedup claimed. Native Inspector interaction,
  disabled environment experiments and full-project regression were not retested.
  Import refresh resolves relocated UIDs; editor tab history may still log the old shader
  path. Godot generated three planned script UIDs; evidence remains in `.godot/issue7/`.
  Detailed results: https://github.com/nikosban/apalit/issues/7#issuecomment-6535372112.
- Full regression (2026-10-30, Godot 4.7.2, `--fixed-fps 60`; all 62 suites and the four
  600-frame scene runs once, the changed suites twice): every scene run loads without
  errors; no suite logs a script error; the only failures are the known ones below.
  Suites changed on 2026-10-30: `pdc_test` 74, `rocket_test` 70, `cannon_test` 45,
  `ff01_test` 45, `combat_scene_test` 25 checks pass; `weapon_info_test` 13 (W1
  intermittent, below); `guided_missile_test` 68 needed no change. `pdc_test` section R
  checks the raid sweep on live mounts against torpedoes no round can destroy (4-round
  bursts cycled through the defensive order and wrapping, a removed threat ending its
  burst, a single threat fired at continuously, independent mounts, one round per shot,
  commitments). Selection cases in `pdc_test` / `rocket_test` reset each mount's PDC state
  (`_fresh_sweep()`, copied from a fresh `pdc.gd` instance), so each pick is a fresh
  mount's. Bastion and PDC offense fixtures disable the other weapon families.
- Harnesses count only `_check()` results: a script error silently skips the rest of a
  case and the suite can still print PASS, so a run is valid only if its log also has
  no `SCRIPT ERROR`.
- Barrage measurement (2026-10-26, owner-accepted): five seeded muzzle-distance salvos
  per broadside, 39/40 hits at 25 u, 27/40 at 45 u, 20/40 at 55 u, 17/40 at 60 u.
  Logs: `barrage_travel70_verification_2026-10-26/` in the external archive (section 9).
- `combat/positioning_boundary_test.gd`: 66/67 (Attack-Move leash, known failures
  below), covering configured sector
  sizes, the follower's navigation reference, footprint and clearance margins, Guard,
  engagement, Defensive positioning and group waypoints. I01 verification compared
  28 existing suites and four scene smoke runs against two pre-change baselines:
  25 suites and all smoke runs passed, with only the three known failing suites below;
  no new errors or warnings. P02 and integrated combat measurement changes are accepted,
  reproducible boundary effects. Logs: `i01_verification_2026-10-25/` in the external archive (section 9).
- `combat/combat_positioning_test.gd` (Stage 6B, fixtures `combat_positioning_harness.gd`,
  `combat_positioning_demo.tscn`): 39/40 by default since the weapon-profile removal
  (detour check, section 7; the profile-selection check and `baseline` mode are removed); `-- movement` 18/18 (route,
  waypoint and combat continuity), `-- redirect` 23/23 (repeated MOVE commands, open
  and routed; `trace` prints 60 Hz traces). Final Stage 6B regression: only the three
  known failures below; `obstruction_test` check 4's crossing scenario is shifted
  inward (`_start_inside()`) so every ship starts inside the sector.
- Known open failures (2026-10-30; none caused by the test corrections of that date):
  - `navigation_test` 1 (FF-01, formerly Destroyer, redirect aim line).
  - `obstruction_test` 10/12 (the two cause B overshoot checks).
  - `fleet_test` hostile focus (hostile shots off the controller's focus; present since
	the 2026-10-24 Destroyer hull redesign).
  - `combat_positioning_test` 39/40 detour (section 7).
  - `command_test` 21/23: "Aggressive: an enemy 78 u off the route causes no detour" and
	"Move keeps an independent target; … re-targeting ends the Attack and stays"; both
	also fail before the PDC raid sweep (`b17c227`); origin not investigated.
  - `positioning_boundary_test` 66/67: Attack-Move leash ("newly valid stations outside
	the Attack-Move leash do not replace destination travel"; CHANGELOG 2026-10-29).
  - Intermittent since the PDC raid sweep (75 u Kestrels fire far more in the E05
	battles; verified against `b17c227`): `fleet_test` "node count does not grow across
	resets" (snapshots include 109–158 Kestrel rounds in flight, spread 85–168 against a
	120 limit, failed 3 of 5 runs; before: 26 in flight, spread 0–1; orphans stay 0) and
	`weapon_info_test` W1 (1 of about 164,000 weapon-ticks in 1 of 4 runs: a Kestrel's
	"Tracking (38.1° off)" from assess() against "38.2° off" from the authorization, the
	angle measured from the muzzle before and after the turret turn and rounded). Test
	and production unchanged; fixing either needs an owner decision.
- Headless input injection: `push_input(event, true)` (local coordinates); in a `-s`
  script add scenes after the first `process_frame`. `mining_test`, `survey_test` and
  `docking_test` step physics manually and switch off `Fuel`.
- Owner rule: never terminate Godot processes by executable name or wildcard; only a
  process the agent launched, by its PID. If another editor or game instance
  interferes, stop and report it (the owner's editor may hold unsaved work).

## 9. Archive and recovery

- External archive (outside the project, not in Git; moved out of `res://archive/` on
  2026-10-30, issue #1): `C:\Users\Nikos\Documents\archive\apalit_archive\` (1,481
  files: the pre-V3 ZIP and the 2026-10-25/26 verification folders). Per-file SHA-256
  manifest: `C:\Users\Nikos\Documents\archive\apalit_archive.sha256`. Second verified
  copy: `C:\Users\Nikos\Documents\apalit_archive\` (also contains an accidental
  duplicate in its `archive\` subfolder). Agents do not write to these locations
  (`AGENTS.md`); the owner manages them.
- Archived verification helpers are records, not runnable tools: several
  (`ownership_roundtrip.gd`, `roundtrip_ff01.gd`, `render_ff01.gd`) use
  `res://archive/…` paths. To rerun one, restore its folder as `archive/<folder>/` in a
  disposable copy of the project, never in the working project.
- `apalit_pre_v3_integration_2026-10-14.zip` (in the external archive; 846,971
  bytes, SHA-256 5C83748EEBD7C13CC019C98079E6D58CF63CF505B9B52F08EDAB15E8646272FC, 112
  files): the original game before Movement V3. Manifest:
  `apalit_pre_v3_integration_2026-10-14.sha256.txt` beside it. Restore: check the
  SHA-256, extract into an empty folder, open in Godot 4.7, compare against the
  manifest.
- Future verification logs: agents write them to a temporary in-project folder that is
  Git-ignored and Godot-excluded (`.gdignore`), never `archive/`; the owner moves logs
  worth keeping to the external archive and deletes the temporary copies. The folder's
  name is undecided and it does not exist yet (section 10).
- Recovery snapshots (outside the project; found 2026-10-30, both ZIP hashes match) in
  `C:\Users\Nikos\Documents\archive\apalit_backups\` with a `.manifest.txt`
  each: `apalit_pre_combat_migration_2026-10-19.zip` (892 files, SHA-256
  A2D28390CC75B47BBBD86D3A42AE2B61D7B14B3F535EAF385DFE10C62F8B9D48; runnable combat
  prototype and every experiment) and `apalit_post_combat_migration_2026-10-20.zip`
  (1025 files, SHA-256 46B17C1E0DDB00CB3EF3ED55CBDAADA1FFB291A4AA20244EB7FD8C54484B609D;
  every retired experiment), plus `baseline_logs_2026-10-19/`. Restore: extract into an
  empty folder, run `<godot console> --headless --path <folder> --import`, open in Godot.
- History of everything since 2026-10-20 (code, scenes, earlier HANDOFF versions with
  verification logs and investigation records) is in Git.

## 10. Next task and open items

Issue #7 is accepted; no next task is selected. The earlier read-only architecture
inventory brief remains unstarted. New work follows `AGENTS.md`.

Open follow-ups (not started): the two intermittent PDC-exposed test failures and the
`command_test` failures (section 8 known failures); cleanup of `stash@{0}`.

Open owner decisions:

- Permanent sector size and fuel balance (`local_fuel_scale` 0.1 is a prototype value).
- Final movement indicator tuning: `movement_indicator_style.tres` values and the 0.25 u
  destination gap (section 4.7; provisional defaults).
- Renaming the experiment-era exports (`environment_experiment`, `lighting_experiment_d`,
  `strategic_experiment_e`).
- Commit and push conventions.
- Whether the GitHub repository stays public (it is public; checked 2026-10-30).
- Name of the temporary in-project verification-log folder (section 9); creating it, its
  `.gdignore` and its `.gitignore` entry need approval.

Open, not investigated: the rendering frame spikes and the Group MOVE avoidance cases
(section 7).

Unresolved documentation questions (from the 2026-10-25 audit; recorded as found,
not decided):

- Headless visible rect (1152 × 648) and the Phase B marker-size note (× 0.75 of a
  648-line canvas): possibly obsolete since the 1920 × 1080 base canvas; not verified.
- Design triggers: the combat prototype (facing-control trigger) has happened and
  the heading lock was not migrated by decision; Combat Test (760 u) partly meets the
  larger-maps trigger. Their status is undecided.
- Scanner configuration: Miners' Mining Scanner was recorded as a "temporary testing
  configuration" and the Transporter's Generic Scanner as "owner to confirm".
