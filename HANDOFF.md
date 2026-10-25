# HANDOFF.md

Last updated: 2026-10-25. Current state only. Development history is in `CHANGELOG.md` and Git; earlier versions of this file
(per-task verification logs, measurements, prototype records) are in Git history.

## 1. Status

The game: graybox spaceships on the X/Z plane under mouse command, with static
navigation, local avoidance and collision enforcement; a resource economy (asteroid
survey, automated mining, stations with station-controlled docking, fuel, repeating
transport assignments, a two-slot refinery, a Shipyard building Mining and Transport
ships); production combat on every ship (hull, factions, weapon loadouts on the
Gunship and Destroyer, Commands / Tactics / Weapon Profiles, faction-shared sensors
and fog of war, a minimal hostile commander); global pause and time dilation;
continuous camera zoom with Local / Tactical semantic zoom and a Strategic View; a
Sector Showcase scene with environment rendering; a themed inspector UI and reusable
thruster VFX. No component manufacturing, station construction, save system or
strategic AI.

All listed work is accepted by the owner. No task is in progress (see section 10).

## 2. Project layout and scenes

### Repository

- `project.godot`: Godot 4.7, main scene `res://game/scenes/sector_showcase.tscn`.
  Base canvas 1920 × 1080, stretch `canvas_items` / `expand` (2D sizes are px at
  1080p and scale with the window height); window maximized. Template defaults, not
  owner decisions: Forward Plus, Jolt Physics (unused by movement), D3D12 on Windows.
- `game/`: all production code, scenes and tests, one folder per system.
- `assets/textures/skybox/multi_nebulae_2.png`: the owner's 10000 × 5000 panorama
  (imported lossless, no mipmaps), the Showcase sky; tracked in Git (owner decision).
- `assets/models/ships/whitebox/frigate_001.glb`: the owner's whitebox frigate mesh
  (11 meshes, 3 materials, no textures; about 8.4 × 21 u, far larger than the
  Frigate's 1.6 u ship radius). Owner-made assets are organised by type under
  `assets/`. Not referenced by any scene; import not yet verified in the editor.
- `experiments/planned_rejoin/ship_avoidance_rejoin.gd`: the only experiment. The
  paused, unaccepted cause B planned-rejoin prototype: a full replacement of
  `game/avoidance/ship_avoidance.gd` as it was on 2026-10-15 (SHA-256
  4A7E9EFA…592655A). Not used by the game. It predates the 2026-10-18 direct-move
  prediction horizon, the 2026-10-22 same-course pass side, `Avoidance.forget()` and
  the step 2 re-plan, so it must be reviewed against current avoidance before any
  resumption; it is not production-ready.
- `archive/`: local only, ignored by Git (section 9).
- `AGENTS.md`, `CHANGELOG.md`, `HANDOFF.md`, `.editorconfig`, `.gitattributes`
  (text stored with LF), `.gitignore` (`.godot/`, `/android/`, `/archive/`).
- Git: branch `main`, remote `origin` = `git@github.com:nikosban/apalit.git`
  (private). No commit or push conventions are decided beyond the initial setup.

Terminology (owner-agreed): shared, self-contained pieces such as the camera rig are
"reusable scenes" (own `.tscn`, instanced into other scenes).

### Scenes

All gameplay scenes use `game/scenes/movement_lab.gd` as root script (name kept from
the lab era) and the layout contract in section 3.

- `game/scenes/sector_showcase.tscn` (startup scene, F5): visual and scale
  evaluation. 760 × 760 sector (`StaticNavigation.map_half_size` 380),
  `local_fuel_scale` 0.1, no ground, resource seed 2026; west station group
  (Station, Station2, Shipyard), the six player ships, authored asteroid formations
  (33 asteroids), a hostile Destroyer and two Gunships (their `Combat` overrides:
  faction 1, stance Aggressive) under a `HostileCommander`, a `Backdrop`. Root
  exports: `environment_experiment` 1, `lighting_experiment_d`,
  `strategic_experiment_e`, `god_rays_enabled` true; own DirectionalLight3D 30° up.
  Its WorldEnvironment glow and volumetric fog (albedo (0.9, 0.648, 0.54), anisotropy
  0.9, length 12.69) are set by the owner in the scene; no script sets them.
  A 720 u crossing at 1x takes 147 s (Frigate) to about 255 s (Destroyer), about 18%
  of a tank.
- `main.tscn` (Test Arena; F6): development, regression and stress tests (32 suites
  load it). 300 × 300 sector with a plain ground, 36 sphere asteroids (seeded layout
  saved in the scene; stable `metadata/asteroid_id` 1–36), `Station`, `Station2`
  (`refinery_station.tscn`), `Shipyard` (`shipyard_station.tscn`, yaw +31°,
  owner-approved "option C"), six player ships (Frigate, Gunship, Destroyer, Miner1,
  Miner2, Transporter), no hostiles. Flat background, sun 60° up, no environment
  lighting, Strategic depth or god rays, `local_fuel_scale` 1, camera `max_zoom` 150.
  Every ship and station instance overrides only its transform (`shipyard_test`
  checks it). Station placement rule used so far: every docking, approach, holding,
  exit and deployment point ≥ 15 u from asteroid surfaces.
- `game/scenes/combat_test.tscn` (inherits `main.tscn`; F6): integrated combat; a
  second player Gunship and a hostile fleet east, beyond sensor range, under a
  `HostileCommander` (Gunships Guard the Destroyer, which Attack-Moves west).
- `game/scenes/movement_test.tscn` (root `MovementLab`, `scenario_keys` on): the
  Movement V3 test arena with grid ground and obstacle shapes under `Obstacles`
  (8 suites load it). Its ships are movement-only copies built on the hull scenes.
- `game/tests/reuse_arena.tscn`: the reuse test scene (section 3); not played.
- `game/tests/docking/`: `tri_station.tscn` (the owner's three-bay layout on the
  production station scripts; also used by `reuse_arena`), `station_docking_demo.tscn`
  (`main.tscn` with berth drawing), `tri_dock_demo.tscn`, `tri_dock_test.gd`.
- `game/tests/combat/fixtures/`: the ported combat scenarios on production code.
  `combat_lab.tscn` (F6; keys 1–5 E01–E05, 6–8 P01–P03, F5 reload, C toggles a
  hostile's contact), `encounter_arena.tscn` and its variants, weapon / turret
  ranges, test-only scripts.
- `game/presentation/thrusters/thruster_fx_preview.tscn`: thruster authoring scene.

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
  definitions: `frigate_unit`, `gunship_unit`, `destroyer_unit` (warship),
  `miner_unit` (mining ship), `transporter_unit` (transport ship). Each overrides the
  type's settings (profiles, radii, size class, fuel, scanner kind) and adds `Model`,
  an instance of the hull scene `game/ships/<type>.tscn` (primitive meshes, no
  scripts, bow −Z), last child. Armed variants add hardpoints under `Weapons` and
  `Behavior` before `Model`: Gunship a dorsal cannon turret and two Gatlings;
  Destroyer a bow torpedo tube, a deck missile launcher (4 cells, 4-missile salvos
  every 0.2 s, 12 missiles), a cannon and a stern Gatling. Frigate, Miner and
  Transporter are unarmed and damageable.
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
(pick boxes, ring) and `movement_lab.register_ship()` (notices, destination marker,
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
  A safety net, not traffic resolution.

Profiles (authoritative in `game/ships/<type>_unit.tscn`; the test arena and
`obstruction_test` keep their own movement-only copies; Transporter uses the
Gunship's handling with radius 4.1, Miners the Frigate's):

| | Frigate, Miners | Gunship, Transporter | Destroyer |
|---|---|---|---|
| max speed fwd / rev / lat (u/s) | 5 / 4 / 3 | 4.5 / 2.5 / 2 | 3 / 1.5 / 1 |
| accel fwd / rev / lat (u/s²) | 6 / 3 / 2.5 | 3 / 1.5 / 1.2 | 1.2 / 0.5 / 0.3 |
| turn rate (°/s) / turn accel (°/s²) | 120 / 240 | 60 / 90 | 25 / 20 |
| ship radius / clearance margin (u) | 1.6 / 1 | 3.4 (Transporter 4.1) / 1 | 6.2 / 1 |
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
  the arm end, +Z outward; `slot_size` 14.4 × 13.4 u, Destroyer-sized; markers
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
  (`combat_rules.tres`: 150 for every ship), faction (0 player, 1 hostile), manual /
  automatic target and threats; steps the ship's weapons. Targeting is strict: a
  manual target is the only offensive target; without one, Defensive takes confirmed
  threats (attacks on itself or allies within 30 u, 10 s persistence), Aggressive the
  nearest hostile in contact within its longest usable range, Passive nothing. No
  friendly fire. Destruction: weapons off, references cleared on every ship,
  propulsion off, route / avoidance / fuel / scanner / docking / mining / transport
  stopped, `Docking.abandon()`, deselected; a 2 s hulk, then removal
  (`Avoidance.forget()`, contacts and Selection unregistered) and free.
- `combat_orders.gd` (`CombatOrders`): the one combat command interface (move,
  target, tactic, Attack, Guard, Attack-Move, Waypoint, Cancel, profile) for player
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
  `hardpoint.gd`, configs, `weapon_geometry.gd` (placeholder meshes). Values in
  `cannon.tres`, `gatling.tres`, `torpedo.tres`, `missile.tres` (validated, unchanged).
- Sensors: `sensors.gd` (`Sensors`): faction-shared detection within 100 u with a
  line clear of asteroids, every 0.2 s of simulation time, 8 s last-known memory;
  stations ignored. `contact_board.gd` (`Contacts`): contact = detection. Line of fire
  is separate. Fog of war: `movement_lab.player_sees()` decides what of a hostile is
  drawn, picked, targeted and inspected; `presentation/fog_view.gd` tints uncovered
  space and hides hostile rounds, ordnance, trails and effects outside coverage
  (shader `COVERAGE` shared with Strategic View; up to 128 asteroid occluders and 16
  sensors, beyond that `overflow` and a warning).
- Behavior (`ship_behavior.gd`, `Behavior`, armed Gunship and Destroyer of both
  factions): precedence command (Move, Attack, Guard, Attack-Move, Waypoint, Dock,
  Cancel) > tactic (Aggressive pursues its target in contact; Defensive answers
  attackers from its defended area with local line-of-fire repositioning, 12 u limit,
  no pursuit, area not drawn; Passive nothing, point defense still fires) > weapon
  profile (Siege / Mid-range / Close Quarters from the installed weapons, fallback in
  that order; positioning only, never authorizes or forbids a shot;
  `weapon_profiles.gd`). Guard and explicit movement override autonomous positioning.
- Movement ownership: Locomotion is the only executor. Behavior moves only through
  `movement_lab.autonomous_move()`. Player commands are announced by
  `command_given()` from `_execute()` (a held command is recorded when released);
  Behavior takes a MOVE there as the player's Move. While docking owns the ship,
  Behavior holds the Dock command and requests nothing.
- `hostile_commander.gd` (`HostileCommander`): gives its faction's armed ships a
  tactic, Guard and Attack-Move objectives through CombatOrders once their map is
  ready. No strategic AI.
- Not migrated from the prototype (decision): heading lock, fixed forward cannon,
  v0.2 scenarios.

### 4.7 Camera and views (`camera/`, `presentation/`)

- `camera_rig.gd` / `camera_rig.tscn`: pan W/A/S/D, rotate Q/E or middle drag; pan
  bounds = the sector square, set at start by `movement_lab.gd` (rig default
  300 × 300). Zoom 5–40 by default, `max_zoom` 150 in `main.tscn`, the Showcase and
  `encounter_arena`. The wheel sets `zoom_target` (× / ÷ 1.1 per notch,
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
- Strategic View (`strategic_view.gd`): one more outward notch at the rig's maximum
  hands over (0.45 s) to a fixed top-down camera framing the sector on render layer
  20; an inward notch returns to the exact saved pose. Layer 20: simplified lit
  asteroid spheres (the sun is also put on layer 20), overlay (contours, shadow bands,
  dust; experiment E adds formation density and haze), FogView's material. Screen
  space: selected routes, cluster and per-family resource markers with radial
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
- `command_cursor.gd`: shows what a right-click would do (Move, Mine, Dock,
  Unavailable, arrow) from `resolve_command()` / `command_available()`; cached per
  target / 2 u cell, refreshed every 0.5 s; a group is checked with
  `GroupOrders.can_assign()` after 0.25 s rest. OS cursor shapes are placeholders.
- Thrusters (`presentation/thrusters/`): two reusable GPU-particle scenes in world
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
    0.5, IDLE 0 with glow, NONE 0 without; blended 0.15 s. API: `state_of`,
    `intensity_of`, `plume_of`, `plumes_of`, `jet_of`, `emitters_of`.
  - Ordnance: `WeaponGeometry.build_ordnance()` adds effects to torpedo and missile
    nozzles and missile attitude mounts; `ordnance.gd` drives them; sizes in
    `OrdnanceConfig`. The `OrdnanceTrails` ribbon is kept (owner choice).
- Environment (`sector_environment.gd`, `SectorEnvironment`; profile
  `sector_profile.gd` / `warm_sector.tres`): key light, ambient, background, ground;
  rocks, debris and dust pockets around formations. Sky `environment_experiment`: A
  flat, B the panorama (rotation X 90°, energy 1), C sky-sampled (comparison only).
  `lighting_experiment_d` (with B): designed radiance for ambient and reflections.
  `god_rays.gd` (`god_rays_enabled`): up to 8 shafts and 4 shadow bands from the
  largest formations, fainter at Tactical, not in Strategic. `sector_backdrop.gd`:
  distant silhouettes, never gameplay objects. The Test Arena keeps A with none of
  these.

### 4.9 UI (`ui/`)

- Foundation: `ui/theme/apalit_theme.tres` (HeaderLabel, SectionHeader, MutedLabel,
  WarningLabel, SegmentButton), `resource_icons.gd` (generated placeholders),
  `ui/components/` (`panel_shell`, `section`, `refinery_slot`, `resource_tile`,
  `resource_row`, `segmented_control`): display-only scenes that emit signals;
  gameplay stays in its systems. No UI framework or state manager.
- Inspector: `panel_shell` fixed 340 px, bottom right (16 px margin), fixed header,
  scrolling body up to the screen height − 96 px. Ship panel (`ship_panel`, exactly
  one ship): Header (editable name, class), Status (activity, dock with queue
  position, fuel bar and warnings, hull), Combat (armed ships: tactic and profile
  selectors, command, effective profile, target, weapons and ammunition), Cargo
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
- `asteroid_hover.gd` (layer 2): survey text at the cursor, also the station hover;
  not over a ship or GUI. `combat_hud.gd` (`CombatHUD`): hull bars, speed / pause
  line, target-selection readout, scenario result. Notices share one label.
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
| X / P / Backspace | Cancel command / next weapon profile / clear manual target |
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
- No further movement or docking refinements; docking durations and the Destroyer's
  footprint wait for the owner (radius and collision geometry unchanged by decision).
- Combat: no tuning, new mechanics, Frigate weapons or hostile AI changes.
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
  keeps its following floor. Example (test arena): Miner (90, −5) → (115, −5) crossing
  15 u ahead of a Gunship (115, 40) → (115, −40): contacts and reversals, both arrive.
- Collision: conservative bounding circles (Destroyer stopped up to ~5 u from its hull
  sides); ships starting overlapped stay overlapped; slow creep in sustained contact;
  the ship processed first may gain up to one tick of movement.
- Sphere obstacles use the full radius whatever the plane height; uniform scale assumed
  (only X read); 32-gon outlines give small bends around large asteroids.
- Destroyer mid-route redirect aim line enters the reserve (`navigation_test` known
  failure; no footprint overlap).
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
- Not investigated: in `group_rotation_test` case 4 the Gunship passes the slower
  Destroyer up to 10.5 u off its path and then drifts into the parked Miner2 (2
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

- The Destroyer's circular footprint (6.2 u) keeps it out of bays its hull appears to
  fit (e.g. the 10 u tri-dock bays) and makes exits long. At Station's west berth its
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
  beyond the clearance a Destroyer at Hold3 / Hold4 needs from a deploying
  Transporter, so a ship drifting off those holds can hold a deployment (automatic
  retry). A Destroyer at Hold3 is 3.79 u from the map edge. No long soak with many
  produced ships. Warship production would need its own recipe.
- Survey: the live-cursor hover path is checked only in rendered runs; % / DATA
  UPLOADED labels of close asteroids can overlap at maximum zoom; markers draw under
  the debug panel; analyzed ice hover shows "Asteroid Ice" and reserves only.

### Combat

- Aggressive hostiles acquire civilian player ships like any player ship.
- Stations block fire but take no damage; sensors ignore stations; weapon envelopes
  draw asteroid shadows only. Every hull is 150, civilian ships included.
- A ship destroyed during a controlled entry or exit stays as a 2 s hulk where it was;
  its station records are released at once and the berth is granted again only when
  physically empty.
- Placeholders: Target cursor (OS four-arrow), hostile marker outer outline, weapon
  meshes, hull tint (player blue, hostile red).
- `combat_test.tscn`: with the player's warships Aggressive and no orders the hostile
  fleet won the headless run (observation, no tuning).

### Camera, views and presentation

- Camera: near the bounds the clamp lets the cursor point drift; a large wheel burst
  can tilt up to about 8° per frame; a panel opening under a still cursor may not
  block the first wheel step (inferred); scenes that zoom to 40 show about 48°. In
  headless runs the visible rect is reported as 1152 × 648 (unverified since the
  1920 × 1080 base canvas; section 10). Camera start zoom shows the Destroyer only
  partly in the test arena.
- Tactical: hull bars are hidden at full emphasis; asteroids under about 1 u radius
  can be smaller than their marker at zoom 150 (an edge click misses); diamonds overlap
  below about 1.8 u spacing; the hull-bar and ObjectMarkers icon fades have no
  automated check. Recorded marker-size note "nominal × 0.75 of a 648-line canvas" is
  unverified since the 1080-line base canvas (section 10).
- Showcase: god rays are a restrained stylized stand-in (usually one or two shafts in
  view; shadow bands faint, shade `opacity` 0.4); Local / Tactical fog still tints the
  starfield (only Strategic fog skips sky pixels); the Strategic sun-layer fix also
  lights the Test Arena's Strategic spheres; Strategic framing fits the sector rotated
  by the rig's 45° yaw; environment lighting is subtle (+4–6 %), energies exposed on
  SectorEnvironment.
- Rendering frame spikes (cause unknown, not GroupOrders): once about 2.0–2.5 s after
  Showcase start (34 ms, 39–295 ms with four ships selected) and occasional 40–160 ms
  frames near the sector edge. Not investigated.
- Thrusters: a teleported ship (`place()`) can flash its jets for a tick; particles
  pause with the game but do not follow time dilation.
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
- Editor re-save pitfall: a 2026-10-22 editor re-save dropped the Showcase hostiles'
  `Combat` overrides (they became player ships); restored by hand, cause unknown, may
  repeat. `sector_environment_test` catches it. Check the overrides after any editor
  save of `sector_showcase.tscn`.
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
- Suites: 39 in `game/tests/`, 16 in `game/tests/combat/`, `game/tests/docking/tri_dock_test.gd`
  (56 total). Run: `<godot console> --headless --path . -s res://game/tests/<name>.gd`.
- `--fixed-fps 60` is required for every combat suite and for `shipyard_runtime_test`,
  `reuse_test` (uninterrupted loop as fast as possible), `camera_test`,
  `tactical_view_test`, `strategic_view_test` (fails its boundary-fade check without
  it) and `sector_environment_test`. The 2026-10-23 full run used it for every suite.
- Scene runs: `--headless --path . --fixed-fps 60 --quit-after N [scene]` (600 frames)
  for `main.tscn`, `game/tests/docking/station_docking_demo.tscn`,
  `game/tests/docking/tri_dock_demo.tscn`, `game/tests/combat/fixtures/combat_lab.tscn`,
  `game/scenes/combat_test.tscn`.
- Regression protocol: run the suites and scene runs twice before a change, then
  compare logs line by line, treating as variance only lines that also differ between
  the two baseline runs. Known variance: asteroid seed lines (unseeded fields, e.g.
  `shipyard_runtime_test` B10's asteroid and base), timing values, navigation map-ready
  frame, tri-dock warning order. Expected error lines: `guided_locomotion_test` check
  10 guard, `station_docking_test` deliberate `cancel()`, tri-dock navigation edge
  warnings. Verification scope follows `AGENTS.md` steps C and D. No runner script is
  kept.
- Known failures (current baseline, unchanged output expected): `navigation_test`
  35/36 (Destroyer redirect aim line), `obstruction_test` 10/12 (the two cause B
  overshoot checks), `fleet_test` hostile focus (1 of 47 hostile shots off the
  controller's focus since the 2026-10-24 Destroyer hull redesign).
- Headless input injection: `push_input(event, true)` (local coordinates); in a `-s`
  script add scenes after the first `process_frame`. `mining_test`, `survey_test` and
  `docking_test` step physics manually and switch off `Fuel`.
- Owner rule: never terminate Godot processes by executable name or wildcard; only a
  process the agent launched, by its PID. If another editor or game instance
  interferes, stop and report it (the owner's editor may hold unsaved work).

## 9. Archive and recovery

- `archive/apalit_pre_v3_integration_2026-10-14.zip` (local, ignored by Git; 846,971
  bytes, SHA-256 5C83748EEBD7C13CC019C98079E6D58CF63CF505B9B52F08EDAB15E8646272FC, 112
  files): the original game before Movement V3. Manifest:
  `archive/apalit_pre_v3_integration_2026-10-14.sha256.txt`. Restore: check the
  SHA-256, extract into an empty folder, open in Godot 4.7, compare against the
  manifest.
- Recovery snapshots (outside the project; location unconfirmed, see section 10),
  documented in `C:\Users\Nikos\Documents\apalit_backups\` with a `.manifest.txt`
  each: `apalit_pre_combat_migration_2026-10-19.zip` (892 files, SHA-256
  A2D28390CC75B47BBBD86D3A42AE2B61D7B14B3F535EAF385DFE10C62F8B9D48; runnable combat
  prototype and every experiment) and `apalit_post_combat_migration_2026-10-20.zip`
  (1025 files, SHA-256 46B17C1E0DDB00CB3EF3ED55CBDAADA1FFB291A4AA20244EB7FD8C54484B609D;
  every retired experiment), plus `baseline_logs_2026-10-19/`. Restore: extract into an
  empty folder, run `<godot console> --headless --path <folder> --import`, open in Godot.
- History of everything since 2026-10-20 (code, scenes, earlier HANDOFF versions with
  verification logs and investigation records) is in Git.

## 10. Next task and open items

Next task: none assigned; await the owner's next task. All work follows the
`AGENTS.md` workflow (replace this section after every task).

Open owner decisions:

- Permanent sector size and fuel balance (`local_fuel_scale` 0.1 is a prototype value).
- Renaming the experiment-era exports (`environment_experiment`, `lighting_experiment_d`,
  `strategic_experiment_e`).
- Commit and push conventions.

Open, not investigated: the rendering frame spikes and the Group MOVE avoidance cases
(section 7).

Unresolved documentation questions (from the 2026-10-25 audit; recorded as found,
not decided):

- Recovery snapshots: the documented folder `C:\Users\Nikos\Documents\apalit_backups\`
  was not found from the agent session; whether they still exist, and where, is
  unconfirmed.
- Headless visible rect (1152 × 648) and the Phase B marker-size note (× 0.75 of a
  648-line canvas): possibly obsolete since the 1920 × 1080 base canvas; not verified.
- Design triggers: the combat prototype (facing-control trigger) has happened and
  the heading lock was not migrated by decision; the Showcase (760 u) partly meets the
  larger-maps trigger. Their status is undecided.
- Scanner configuration: Miners' Mining Scanner was recorded as a "temporary testing
  configuration" and the Transporter's Generic Scanner as "owner to confirm".
