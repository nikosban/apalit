# HANDOFF.md

Last updated: 2026-10-20, after the production combat migration (accepted by the
owner after gameplay testing), the M8 repository cleanup, the Git / GitHub
setup, the removal of the defended-area ring and camera Phase A (continuous,
cursor-anchored zoom with pitch following zoom). The movement baseline
is still cause C with the 2026-10-18 direct-move prediction horizon correction.
History: `CHANGELOG.md`. The original game (before Movement V3) and its full
documentation are preserved in the archive (see Archive); the retired experiments
and the pre-cleanup project are preserved in two verified snapshots outside the
project (see Recovery snapshots).

## Current state

The game is Movement V3 (graybox ships on the X/Z plane, mouse selection,
persistent MOVE orders, group MOVE, static navigation, local avoidance and
collision enforcement, camera rig and debug panel) plus Phase 2 Stage 1
(asteroid resource deposits, scanner equipment, a fleet-wide survey with its
scanning presentation, asteroid hover information, a selected-ship panel),
Stage 2 (two Miners, raw cargo, single-asteroid mining assignments), Stage 3
(one station, docking with a shared-slot queue, station storage, manual
Unload / Load), Stage 4 (fuel, warnings, immobilization when empty,
station fuel stock and automatic refueling while docked) and Stage 5
(automated mining cycle with base selection and Resume) and Stage 6 (a
Transporter, a second station and repeating transport assignments), with
Phase 2.5 consistency fixes and station-controlled docking (editor-authored
berths, guided entry and exit, held player commands), and Phase 3 (refining:
six raw minerals plus ice stored per resource, deterministic proportional
extraction, transport requirements in units or percent of the hold, a two-slot
refinery on Station2 producing ingots, station selection and a station panel), and
Phase 4 (ship production: a third station, the Shipyard, builds Mining and
Transport ships from ingots; produced ships join the game at run time). Since the
architecture migration every ship type is defined once, as a variant scene on a
functional archetype, and every station once, as a station scene (see Ship and
station architecture); starting and produced ships use the same variants. The UX and quality-of-life
round (2026-10-18, see that section) added two-stage held commands, mining
orientation, persistent transport docking, a themed right-hand inspector with
editable display names, a draft transport editor, hover / selection outlines,
object markers, context cursors and propulsion effects with thruster parts. The
production combat migration (2026-10-19 / 20, see Production combat) added combat
to every ship (hull, faction, the validated Gunship and Destroyer weapon loadouts),
Commands, Tactics and Weapon Profiles on the armed ships, faction-shared sensors and
the fog of war, global pause and time dilation for the whole simulation, the
tactical camera and UI, and a minimal hostile commander. No component
manufacturing, station construction or strategic AI.

- `project.godot`: main scene `res://main.tscn`. Template defaults (not owner
  decisions): Forward Plus, Jolt Physics (3D, unused by movement), D3D12 on
  Windows, stretch `canvas_items` / `expand`. Window maximized.
- `main.tscn`: the playable scene (see Scenes).
- `game/`: all production code and scenes (see Code).
- `icon.svg`, `icon.svg.import`: project icon.
- `archive/`: the pre-integration ZIP and its manifest (see Archive); ignored by
  Git, local only.
- `experiments/planned_rejoin/ship_avoidance_rejoin.gd`: the only remaining
  experiment: the paused cause B planned-rejoin prototype (unaccepted; a full
  replacement of `game/avoidance/ship_avoidance.gd` as it was on 2026-10-15,
  SHA-256 4A7E9EFA…592655A). Not used by the game; its probes and logs were not
  kept. It predates the 2026-10-18 direct-move prediction horizon correction and the
  combat migration's `Avoidance.forget()` (called when a destroyed ship is removed),
  so it must be reviewed against current production avoidance before it is resumed;
  it is not production-ready.
- Retired 2026-10-20 (M8 cleanup, owner-approved; all in the post-migration
  snapshot): `experiments/combat_prototype/` (replaced by production combat),
  `experiments/movement_v3/` (the Movement V3 experiment, its README and the owner's
  original PRD; production `game/` is its successor), `experiments/parked_navigation/`
  (findings below), `experiments/station_docking/` (its active regression files moved
  to `game/tests/docking/`; the superseded prototype scripts and logs removed) and
  `_migration_tmp/` (residue of the 2026-10-17 architecture migration).
- `AGENTS.md`, `CHANGELOG.md`, `HANDOFF.md`, `.editorconfig`, `.gitattributes`,
  `.gitignore`; `.godot/` is the editor cache (ignored by Git).
- Git repository (owner decision 2026-10-20, replacing the 2026-10-14 no-Git
  decision): branch `main`, remote `origin` =
  `git@github.com:nikosban/apalit.git` (private), initial commit `d2eb056`.
  `.gitignore` excludes `.godot/`, `/android/` and `/archive/`; `.gitattributes`
  stores text files with LF line endings.

Terminology (owner-agreed): shared, self-contained pieces such as the camera
rig are "reusable scenes" (own `.tscn`, instanced into other scenes).

### Scenes

- `main.tscn` (root `Main`, script `game/scenes/movement_lab.gd` with
  `scenario_keys = false`): environment, directional light, camera rig (yaw
  45°, start zoom 20), plain 300 × 300 ground at Y 0, `Asteroids`,
  `Stations` (`Station` = `station.tscn` at (−36, 1.5, −20); `Station2` =
  `refinery_station.tscn` at (−108, 1.5, 6); `Shipyard` = `shipyard_station.tscn`
  at (−31, 1.5, −113), rotated +31° about Y, its `Deployment` marker at world
  ≈ (−39.24, 1.5, −126.71), bow = its −Z, heading 31°), `StaticNavigation` and
  `PlanarCollision` (both `obstacles_path` = `../Asteroids`, plus the
  `static_obstacle` group), `Ships` (in this order: Frigate (−12, 0), Gunship
  (0, 0), Destroyer (14, 0), Miner1 (−8, 14), Miner2 (8, 14), Transporter
  (−80, 30), Y 1.5; instances of `frigate_unit`, `gunship_unit`, `destroyer_unit`,
  `miner_unit` (both Miners) and `transporter_unit`), `Survey`, `Selection`,
  `GroupOrders`, destination marker / lines, notice label, `SurveyView`,
  `MiningView`, `AsteroidHover`, `ShipPanel`, `StationPanel` (Phase 3), debug panel
  (top left) and drawings, then (UX round) `WorldHighlight`, `ObjectMarkers`,
  `CommandCursor` and `ThrusterView` at the end. Every ship and station instance overrides only its transform
  (`shipyard_test` checks it); ships produced during the game are added under
  `Ships`. Scanners: Frigate, Gunship, Destroyer and Transporter Generic; Miners
  Mining (temporary testing configuration). Combat migration: `SimClock` (first
  child), `Contacts`, `Projectiles`, `Effects`, `OrdnanceTrails`, `CombatOrders`,
  `Sensors` (100 u, every 0.2 s, 8 s contact memory), `CombatOverlay` and `CombatHUD`;
  `movement_lab.gd` adds `TimeControl`, `WeaponEnvelopes`, `TacticalMarkers`,
  `TacticalGrid`, `FogView` and `BehaviorView` at start; the camera rig's
  `max_zoom` is 150 (strategic zoom). All starting ships are player faction; there
  are no hostiles.
- `game/scenes/combat_test.tscn` (inherits `main.tscn`): the integrated combat scene
  for play and `combat_scene_test`: a second player Gunship (`Gunship2`, (2, −12)) and
  a hostile fleet in the east, beyond the player's sensor range (`HostileDestroyer`
  (126, 2), `HostileGunship` (117, −6), `HostileGunship2` (117, 11), faction 1,
  Aggressive) under a `HostileCommander` (the Gunships Guard the Destroyer, which
  Attack-Moves to (20, 0), then (−30, 8)). Run with F6.
- `Asteroids`: 36 `SphereMesh` spheres (one shared mesh of radius 0.5, uniform
  scale 2.1–11.2, so radius 1.05–5.6 u: 16 below 2 u, 14 of 2–4 u, 6 of 4 u or
  more), centres at ship height Y 1.5 (the large ones extend below the ground),
  surface gaps ≥ 14.44 u, ≥ 37.75 u clear around the origin (recomputed
  2026-10-14 with the true radius; earlier figures used the scale as radius);
  generated once offline with a fixed seed (20261014) and saved in the scene.
  Each carries a stable `metadata/asteroid_id` (1–36); the node has the
  `AsteroidField` script.
- `game/scenes/movement_test.tscn` (root `MovementLab`, scenario keys on): the
  test arena, identical to the accepted Movement V3 lab: grid ground, round,
  wall, rotated-block, gap, pocket, closed-box and slalom obstacles under
  `Obstacles`, the same ships and systems. The `game/tests` suites load it.
  Run with F6.
- `game/tests/reuse_arena.tscn`: the reuse test scene (see Ship and station
  architecture); not played.
- `game/tests/docking/` (moved from the station-docking experiment in the M8
  cleanup): `tri_station.tscn` (the owner's three-bay tri-dock station layout on the
  production `station.gd` / `berth.gd`; also the second dock layout of
  `reuse_arena.tscn`), `station_docking_demo.tscn` (`main.tscn` with the berth
  drawing on), `tri_dock_demo.tscn` (that demo with the tri-dock station at (70, 60),
  asteroids hidden and not obstacles) and the `tri_dock_test.gd` stress test.
- `game/tests/combat/fixtures/`: the ported combat prototype scenarios on the
  production code: `combat_lab.tscn` (keys 1–5 E01–E05, E05 with the Behavior layer;
  6–8 P01–P03; F5 reload; C toggles a hostile's contact), `encounter_arena.tscn` and
  its E01–E05 / P01–P03 variants, the weapon and turret ranges; test-only scripts
  (`combat_arena.gd`, `encounters.gd`, `behavior_scenarios.gd`, `enemy_controller.gd`,
  `hostile_fleet.gd` (the E05 scripted fleet), `fleet_battle.gd`, `combat_hud.gd`,
  `combat_lab.gd`, `target_dummy.gd`).

### Ship and station architecture (accepted 2026-10-17)

Three levels: archetype (functional components) → predefined variant (one per ship
type) → instance (a ship in a scene). The component scripts are unchanged; there is
no shared ship base scene, entity framework or equipment system.

- Archetypes, `game/ships/archetypes/` (root Node3D, component nodes with scripts
  attached and script defaults only, no hull, no per-type values):
  - `warship.tscn`: Locomotion, RouteFollower, Avoidance, Scanner, Docking, Fuel,
	Weapons, Combat.
  - `mining_ship.tscn`: Locomotion, RouteFollower, Avoidance, Cargo, Extractor,
	Mining, Scanner, Docking, Fuel, Weapons, Combat.
  - `transport_ship.tscn`: Locomotion, RouteFollower, Avoidance, Cargo, Transport,
	Scanner, Docking, Fuel, Weapons, Combat.
  - Combat migration: every archetype ends with `Weapons` (an empty Node3D; a
	variant adds its hardpoints under it) and `Combat` (`combat/combat_ship.gd`: hull,
	faction, targeting; physics priority 2). `Weapons` comes first so the installed
	weapons are ready when Combat collects them.
- Component order is part of the archetype and must be kept: nodes of equal physics
  priority run in tree order. RouteFollower and Avoidance (−1) run in that order
  (Avoidance reads its RouteFollower); Locomotion (0) before Scanner (0); Mining or
  Transport, then Docking, then Fuel (all 1). There is deliberately no common base
  scene: an inherited scene appends its own nodes after the inherited ones, which
  would put the role components after Fuel. Inherited nodes cannot be removed, so
  an archetype holds only what every variant of it has; a component a variant adds
  goes last and is allowed only where that order does not matter, otherwise it is a
  new archetype. Role components are found by node name (`Mining`, `Transport`,
  `Cargo`), as before.
- Variants, `game/ships/<type>_unit.tscn` (the authoritative definition of a ship
  type): inherit their archetype, override the type's settings (Locomotion profile,
  RouteFollower `ship_radius` / `clearance_margin`, Avoidance `size_class` /
  `separation_margin`, Fuel capacity / consumption, Scanner `kind`; Cargo and
  Extractor use the script defaults) and add `Model`, an instance of the existing
  hull scene (`game/ships/<type>.tscn`, unchanged, at identity, last child).
  `frigate_unit`, `gunship_unit`, `destroyer_unit` (warship), `miner_unit` (mining
  ship), `transporter_unit` (transport ship). Values in the Profiles table below. A
  change to an archetype reaches every variant that does not override that value.
  Combat migration: `gunship_unit` adds under `Weapons` a dorsal cannon turret and
  two Gatlings (left / right hardpoints); `destroyer_unit` a bow torpedo tube, a deck
  missile launcher (4 cells in 2 columns, 4-missile salvos every 0.2 s, 12 missiles:
  the E05 configuration), a tower cannon and a stern Gatling. Both add `Behavior`
  (`behavior/ship_behavior.gd`) before `Model`. The Frigate, Miner and Transporter
  variants have no weapons and no Behavior (unarmed; damageable).
- Hull under `Model`: Selection pick boxes and ring (`ShipSelection.register_ship()`)
  and station picking search meshes recursively (`find_children(..., owned = false)`),
  so the nested hull gives the same boxes, ring radii and bounds (preflight in
  Godot; `shipyard_test`); the collision footprint is still
  `RouteFollower.ship_radius`. Code that addresses a hull part by path uses
  `Model/<part>`. Since the UX round each hull scene also has `Thrusters` (black
  `MainEngine` cylinder + eight jet boxes); they are hull parts by owner decision
  (pick boxes, outline, ring radius) and stay inside `ship_radius`.
- Instances: `main.tscn` ships are instances of their variants with only a
  transform; produced ships are instances of the same variants (`Shipyard.RECIPES`:
  `miner_unit.tscn`, `transporter_unit.tscn`). Runtime state (orders, routes,
  cargo inventory, fuel, assignments, docking state) is per instance: script
  variables and an `Inventory.new()` per Cargo and per station.
- Stations: the shared behaviour is `stations/station.gd` and `stations/berth.gd`,
  which read their geometry from the scene (Berth children in scene order, any
  number; `Hold*` markers, any number; meshes in `static_obstacle` for navigation and
  collision; all meshes for picking). A layout scene supplies the editor-authored
  geometry with `station.gd` on its root, in the `station` group:
  `game/stations/station.tscn` (two-berth exposed-arm layout, unchanged); the
  three-berth `game/tests/docking/tri_station.tscn` uses the same scripts
  and docking unchanged. Specialized stations inherit a layout and add a capability
  node: `refinery_station.tscn` = `station.tscn` + `Refinery`;
  `shipyard_station.tscn` = `station.tscn` + `Shipyard` + `Deployment` (Marker3D,
  local (0, 0, −16)). The panel and `movement_lab.gd` find capabilities by those node
  names. Storage, fuel stock, refinery slots, production and berth reservations are
  per station instance.
- Gameplay-scene layout contract (the assets work only in a scene laid out like
  this, not under arbitrary hierarchies): root children `Ships`, `Stations`,
  `StaticNavigation`, `PlanarCollision`, `Survey`, `Asteroids` (with `AsteroidField`),
  plus `Selection` for selection; ships direct children of `Ships`, stations direct
  children of `Stations`. The exported NodePath defaults depend on it: ship
  components `../../../StaticNavigation`, `../../../PlanarCollision`,
  `../../../Survey`, `../../../Asteroids`, `../..` (Ships); stations
  `../../Ships`, `../../StaticNavigation`; Shipyard `../../../Ships`, `../Deployment`.
  Most lookups fail with an error when missing, but Locomotion's collision path and
  the station's ships and navigation paths are optional and fail silently (no
  collision; empty occupancy and every exit side clear). Order under `Ships` still
  decides the avoidance tie rule and collision order. Combat migration: root children
  `SimClock`, `Contacts`, `Projectiles`, `Effects` and `OrdnanceTrails` (Combat's
  paths `../../../Contacts`, `../../../Projectiles`, `../../../Effects`); a scene with
  ships needs `SimClock` (Combat reads the clock; a missing clock is an error);
  `CombatOrders` turns on the combat layer of `movement_lab.gd`; `Sensors` (optional)
  turns on the fog of war.
- Runtime registration and deployment: the Shipyard instantiates the
  variant, sets its transform before it enters the tree (Locomotion reads it in
  `_ready()`), adds it under `Ships` and emits `ship_deployed`; in `main.tscn`
  `movement_lab.gd` registers it in Selection and its command layer in that call
  (`register_ship()`, which since the combat migration also registers it in
  Selection and connects its Combat `destroyed` / `removing`: one call registers any
  ship added at run time). The Shipyard builds only the Mining Ship and the Transport
  Ship (no warships); produced ships are the same variants as the starting ones
  (verified through the real production path in `combat_scene_test` S6).
  A scene without `movement_lab.gd` has to register produced ships itself (the
  reuse test registers them in Selection); notices and destination markers need
  `movement_lab.gd`.
- Reuse is verified in `game/tests/reuse_arena.tscn` (`reuse_test`): the layout
  contract with six asteroids, two `refinery_station`s, a `shipyard_station`, the
  tri-dock layout and seven ship instances (each warship variant, two Miners, two
  Transporters), nothing rebuilt by hand.

### Code (`game/`)

The movement code started as production copies of the accepted Movement V3
experiment (retired 2026-10-20) and is now the only implementation. Combat:
see Production combat below.

- `locomotion/ship_locomotion.gd` (`Locomotion`, one per ship, physics
  priority 0): the only writer of a ship's movement state and transform
  (planar position, velocity, heading, turn rate; Y kept). Bounded kinematics:
  forward / reverse / lateral acceleration ellipse, turn rate and turn
  acceleration limits, turn-aware braking with braking priority, FACE / HOLD
  heading modes; input from `move_to()`, `steer()` (route) and `avoid()`
  (avoidance); `_apply_motion()` asks `PlanarCollision` before committing.
  Stage 4: `propulsion` (set by `Fuel`); false = no translation or rotation
  (velocity and turn rate zeroed every step, position and heading held, order
  kept) and `avoidance_cap` reported as 0, so other ships' avoidance treats
  the ship as waiting (stationary). True (always with fuel) = unchanged.
  Phase 2.5 station docking stage 1: guided mode, not used by the game yet.
  `guide(legs, speed, accel, turn rate, turn accel)` flies legs from rest (turn
  in place to a heading, or a straight move forward / in reverse with the heading
  held) within those limits capped by the ship's own, with a stopping profile
  (`STOP_SHARE` 0.8) that ends each leg at rest; while guided: no destination
  (RouteFollower does not steer, own avoidance neutral, other ships treat it as
  idle), `steer()` / `avoid()` input ignored, `move_to()` refused and counted
  (`guided_order_errors`, error logged), target heading = actual heading (no swing
  back when guidance ends); motion still through `_apply_motion()` (collision,
  committed motion for Fuel); without propulsion it holds still. `place()` cancels
  guidance; `remaining_points()` lists the move legs still to fly. Not guided, the
  step is the unchanged code.
- `navigation/static_navigation.gd` (`StaticNavigation`): one
  NavigationServer2D map per planning radius (ship radius + 1 u), baked once
  from the obstacle meshes (cylinders and spheres as circles, boxes as rotated
  rectangles; 300 × 300 map): the direct mesh children of `obstacles_path`
  plus, since Stage 3, every mesh in the `static_obstacle` group
  (`OBSTACLE_GROUP`; `PlanarCollision` collects the same set; only the
  collection changed); routes, closest reachable point, clearance tests.
- `navigation/route_follower.gd` (`RouteFollower`, one per ship, priority −1):
  one route per order, continuous lookahead, route speed profile planned per
  order (slowing for corners); holds `ship_radius` (read by the other systems).
  End-of-route correction (retained by the owner, `route_end_test`): the
  destination is braked for at least the ship's straight distance to it (shifted
  by avoidance's offset) while that line is clear, so a ship pushed off its route
  near the end is not capped to 0 short of it (routed orders only).
  Phase 2.5: `order()` returns whether the order was taken (planned, or queued
  while the map is not ready); without a route it is refused ("No route found")
  and nothing changes (status, route, request, Locomotion: the current order goes
  on); a queued order that finds no route restores the status and request from
  before it was queued. `NO_ROUTE` is no longer set. Station docking: `order()`
  is refused while the ship is guided (notice "Order refused during station
  control", route and command state unchanged, counted in `guided_refusals`; held
  commands keep legitimate orders away, so it stays 0); `clear()` drops route,
  queued order and status when the station takes over.
- `avoidance/ship_avoidance.gd` (`Avoidance`, one per ship, priority −1, after
  its RouteFollower): closed-form prediction per pair; give-way roles (idle and
  waiting ships stand on, overtaking ship gives way, else smaller `size_class`,
  equal: later in the scene); pass (starboard head-on, astern crossing, away
  when converging) or yield; only offsets steering and caps speed.
  Obstruction correction (2026-10-15), only when the passed ship is
  `is_stationary()` (no order, or out of fuel; below 0.1 u/s; ships held by
  avoidance with an order do not count): if the line to the shifted steering
  point would enter the reserve (footprints + half the margin), the point is
  pulled back along the route toward the ship's route position (`_keep_reserve`,
  at most a sideways step; unchanged if that line would cut an obstacle); the
  pass speed cap limits only travel (velocity, or at rest the direction to the
  steering point) toward the reserve, √(2 · a_brake · distance), 0 inside it.
  Cause C (2026-10-15): a stationary ship's yield is decided after the one
  applied pass; if the applied shift already clears it (`_shift_clears()`, the
  per-ship test of `_pass_feasible`) it gets only the stationary pass cap and is
  committed to the pass's side (`_follow_pass()`), otherwise it yields as before;
  moving-ship encounters unchanged.
  Direct-move prediction horizon (2026-10-18): the own-ship prediction runs from the
  route position along the leg; on a direct move it now stops after the leg left
  from there (`from` → destination), no longer after the straight distance from the
  ship's actual position (which, for a ship a pass had displaced, ran past the
  destination and kept a pass against an idle ship parked beyond it: the group MOVE
  shuttling / spinning stall). Only the prediction's stop time changed; preferred
  speed, `remaining` (caps, corridors, feasibility) and routed moves are unchanged.
- `collision/planar_collision.gd` (`PlanarCollision`): read-only service;
  bounding circles and obstacle shapes, continuous sweeps, removes only the
  velocity into a contact (no bounce, push or separation), at most 3 contacts
  per step, sequential in scene order.
- `selection/ship_selection.gd` (`Selection`): click (hull boxes + 0.3 u),
  Shift-click, box drag (centres), green rings; never touches movement. Phase 4:
  `register_ship(ship)` reads a ship's hull boxes and creates its ring (idempotent);
  `_ready()` calls it for every starting ship, and a produced ship is registered in
  the call that adds it (`pick()` needs every child of `Ships` registered).
- `orders/group_orders.gd` (`GroupOrders`): one destination per selected ship
  once per command (largest first, rings around the click, footprint + 1 u +
  0.5 u apart, reachable, approach-aware, departure preference for groups up
  to 4), all or none. `resolve_occupied()` (2026-10-15): for a single-ship
  MOVE whose point lies inside a stationary ship's clearance (both footprints
  + 1 u + 0.5 u), the same rings and checks for that ship alone, at most
  `resolve_margin` (5 u, provisional) beyond that clearance.
- `scenes/movement_lab.gd`: scene input above the systems (right-click MOVE /
  group MOVE, scenario keys when `scenario_keys`), destination rings and
  lines, notices, debug wiring; Stage 2: right-click on an asteroid with
  exactly one miner selected assigns mining, and every MOVE given (single, or
  a group MOVE that was dispatched) cancels the ships' mining assignments;
  Stage 3: right-click on a station with exactly one ship selected docks it
  (cancels mining); mining cancels docking; every MOVE cancels both;
  2026-10-15: `_move_single()` sends a MOVE onto a stationary ship to the
  resolved point ("Destination occupied by X - moved beside it"), or refuses it
  ("No free position near X - no order given"; current order and assignments
  kept); the replacement counts only once RouteFollower reports the order taken
  (or queued) at that point. Phase 2.5: every right-click command is checked
  before anything is cancelled: a MOVE RouteFollower refuses, Dock where
  `Docking.can_dock()` is false ("X: unable to dock - no reachable docking
  position") and Mine where `MiningOperation.can_mine()` is false ("X: no
  reachable working position at the asteroid") only show the notice; order,
  mining, docking and transport stay as they were (checks skipped while the map
  is not ready: deferred as before). Dock on the station the ship is already
  docking at (`Docking.is_docking_at()`) changes nothing. Station docking: a click
  is resolved once into a command (Dock at a station, Mine an asteroid, Move to a
  point) and given per ship through `_order()`: under station control it is held
  (`Docking.hold_command()`, newest wins) and given again when control ends,
  checked then; for a docked ship (anything but its own station) the same checks
  run first (refused: notice, nothing changes; accepted: automation paused as by
  Undock, the command held, the controlled exit started); otherwise it executes
  as before. A group MOVE with no ship under control or docked is the unchanged
  `GroupOrders.command()`; otherwise one `GroupOrders.assign()` (atomic) and each
  ship gets exactly its own destination, held ships after their maneuver.
  Phase 4: `register_ship(ship)` (idempotent) connects the ship's RouteFollower,
  Mining, Docking, Fuel and Transport notices and gives it a destination marker and
  request line (the scene's own pair for the first ship, copies for the others);
  `_ready()` calls it for every starting ship and connects each
  `Stations/*/Shipyard`'s `notice` and `ship_deployed`; `_on_ship_deployed()`
  registers the new ship in Selection and here, in the same call that added it.
  `scenes/avoidance_scenarios.gd` (scenario layouts), `scenes/lab_grid.gdshader`
  (test arena ground).
- `debug/`: Movement, Navigation and Avoidance Debug panel and drawings
  (collision contacts shown under Avoidance Debug).
- `camera/`: camera rig (pan W/A/S/D, rotate Q/E or middle drag, pivot clamped
  to 300 × 300; zoom 5–40 by default, 150 in `main.tscn` and `encounter_arena`).
  Camera Phase A (accepted 2026-10-20): the wheel sets `zoom_target` (× / ÷ 1.1 per
  notch, `InputEventMouseButton.factor` honoured, at most 10 notches per event);
  the rendered `zoom_distance` follows in log space (95% in `zoom_smoothing_time`
  0.25 s, real time); the ground point under the cursor at the last wheel event
  stays under it (pivot shifted each frame; bounds win; W/A/S/D, Q/E, middle drag
  or an outside move drop the anchor); pitch is `pitch_for(rendered distance)`:
  45° up to 20 u, smoothstep in log distance to 80° at 100 u (all exported); the
  wheel is ignored while a UI control is hovered (`gui_get_hovered_control()`).
  Snap: write `zoom_distance` and call `_apply_zoom()` (a write alone snaps on the
  next frame). `zoom_level()`: 0–1, log on the fixed 5–150 reference range; not
  yet read by any presentation system (Phase B).
- `ships/`: `frigate.tscn` (3 u), `gunship.tscn` (6 u), `destroyer.tscn`
  (12 u), `miner.tscn` (2.4 × 1.6 u: dark hull, wider mid-grey rear cargo
  section, light-grey flat-fronted mining block; farthest corner 1.44 u),
  `transporter.tscn` (Stage 6: forward 2.1 × 0.8 × 1.4 at z −2.9, cargo
  section 2.6 × 0.9 × 4.6 at z 0.25, propulsion 2.2 × 1.0 × 1.1 at z 3.1, three
  greys; 7.25 u long, farthest corner 3.81 u, radius 4.1): the hull (model)
  scenes, primitive meshes, no scripts, bow −Z; also used directly by the test
  arena and `obstruction_test`. `archetypes/` and the `*_unit.tscn` variants: see
  Ship and station architecture.
- `tests/`: `locomotion_test`, `navigation_test`, `avoidance_test`,
  `selection_test`, `group_test`, `collision_test`, `obstruction_test` (adds a
  Miner and a Transporter at run time), `guided_locomotion_test` (Locomotion's
  guided mode: limits capped by the ship, legs end at rest without overshoot, no
  effective route or avoidance input, a stale order does not resume, collision and
  propulsion still apply, `place()`, the `move_to()` guard, which logs one expected
  error line) (headless, on the test arena);
  `survey_test`, `mining_test`, `docking_test`, `route_end_test`,
  `group_rotation_test` (direct-move prediction horizon: placed ships, one avoidance
  step: an idle ship beyond the destination but clear of the leg left is no
  encounter, one within separation of the leg left (mid-leg, or at its end) still
  is; group MOVE of the five starting ships to (18.2, 7.0): no pass kept against an
  idle ship the leg left clears, all arrive, no footprint overlap; to (23.5, 4.0):
  the same for Miner1, arrival not required; prints cumulative turning, distance
  travelled and progress), `berth_test`
  (berth authoring, parking points = the Stage 3 docking positions, rectangles,
  poses, exits incl. blocked sides, path separation, occupancy at the boundary,
  debug drawing off), `station_docking_test` (station-controlled docking: entry
  alignment and hold, exits and release at rectangle clearance, hand-overs incl.
  the former Hold1 / Hold4 deadlocks and the Destroyer's ExitB, both berths, cancel
  semantics, held single and group commands, docked validation, panel, transport
  pause during entry, mining / transport / blocked transfer; one expected error line
  from a deliberate `cancel()` during control),
  `order_consistency_test` (Phase 2.5: refused MOVE / Mine / Dock / Resume and a
  queued order without a route change nothing; same-station Dock; accepted
  commands unchanged; real right-clicks; refusals forced as in the other suites,
  MOVE through a StaticNavigation subclass with no route to a zone around
  (20, −20)), `transport_config_test` (Phase 2.5: station and requirement edits
  during an active transport assignment; Phase 3: percent requirements, capacity
  rejection, the requirement row incl. an amount committed after deselection),
  `resources_test` (Phase 3: inventory, full extraction of every deposit of three
  seeds, proportions, determinism, two miners, cargo limit, partial transfers),
  `refinery_test` (Phase 3: refinery slots, station selection and panel),
  `silicon_shortage_test` (Phase 3: the whole production loop), `shipyard_test`
  (Phase 4: authoring and placement geometry; variant = starting ship in components,
  order, scripts, settings, hull parts at any depth and reach; every variant inherits
  its archetype with its hull under `Model`; every ship and station in `main.tscn` an
  instance of its scene with only the transform overridden; starting and produced
  ships of a series on the same variant; the production cycle stepped
  deterministically) (headless, on `main.tscn`);
  `shipyard_runtime_test` (Phase 4: the uninterrupted game loop, run with
  `--fixed-fps 60`; part A through the gameplay API, part B through real clicks on
  the panels, ships and stations); `reuse_test` (architecture migration, on
  `reuse_arena.tscn`, run with `--fixed-fps 60`: the layout contract resolves;
  variants and instances; an archetype edit in memory reaches the variants except
  their overrides; independent ships (mining cycle, transport delivery, a move, a
  dock at the three-berth layout and its exit) and stations (storage, fuel, refinery
  slots and rates, reservations every tick); Shipyard production into that scene
  from the starting Miners' variant; click selection; 0 contacts and refusals; logs
  the tri-dock layout's known navigation edge warnings).

Phase 2 Stage 1 (resources and scanning; gameplay data separate from
presentation; Movement V3 untouched):

- `resources/asteroid_field.gd` (`AsteroidField`, on `Asteroids`): one deposit
  per asteroid keyed by `asteroid_id`: family (MINERALS / ICE), composition
  (whole percents, read-only; minerals: iron, nickel, silicon, cobalt, gold,
  titanium, each ≥ 1 %, sum 100; ice: ice 100), reserves (abstract units).
  Generated at start from `session_seed` (0 = new seed each session, printed as
  `Asteroid field seed: N`; set it to reproduce); each deposit depends only on
  the seed and its id. Provisional: 65 % minerals, reserves 500–5000
  (independent of size). Ray picking for hover. Phase 3: each deposit records the
  units it has given per resource (`extracted`); see Phase 3.
- `survey/survey.gd` (`Survey`): the one owner of fleet knowledge per asteroid
  (UNKNOWN, IDENTIFIED, ANALYZED; never downgraded; session only) and of scans
  in progress. A scan is fixed at its activation point; asteroids with any part
  inside the radius are detected when the pulse front reaches them; an
  analysis runs only if it raises what is known (2.5 s), then DATA UPLOADED
  (1.2 s), then the level is committed. A higher scan during an analysis raises
  it in place; during the upload it follows as a new analysis. Pulse 30 u/s
  (all provisional).
- `survey/scanner.gd` (`Scanner`, per-ship equipment): `kind` GENERIC (family)
  or MINING (also composition and live reserves), radius 50 u, cooldown 3 s per
  ship from activation (provisional); reads the ship position only.
- `survey/survey_view.gd` + `scan_grid.gdshader` (`SurveyView`): pulse ring on
  the ground, grid overlay (`material_overlay`) sweeping top to bottom, transient
  progress ring / percentage and DATA UPLOADED; canvas layer 0 (under the panels).
  Since the UX round there are no persistent asteroid markers (ObjectMarkers shows
  the asteroid diamond on hover, tinted with SurveyView's colours: grey unknown,
  amber minerals, blue ice).
- `ui/asteroid_hover.gd` (`AsteroidHover`, layer 2): one panel at the cursor
  with the survey-level text; not over a ship or a GUI control.
- `ui/ship_panel.tscn/.gd` (`ShipPanel`): exactly one ship selected; layout and
  sections since the UX round (see that section).

Phase 2 Stage 2 (mining and cargo; Movement V3 untouched, the mining operation
only gives RouteFollower orders):

- `cargo/inventory.gd` (`Inventory`, data): capacity and a quantity per resource
  (since Phase 3; the Stage 2 lots of Metal / Ice Chunks with compositions are
  retired); never beyond capacity. See Phase 3.
- `cargo/cargo.gd` (`Cargo`, per ship): owns the ship's Inventory; capacity
  1000 (provisional).
- `mining/extractor.gd` (`Extractor`, per ship): rate 20 units/s, working range
  4.5 u from the ship's centre to the asteroid's outline (provisional); time-
  integrated with fractions carried (same totals at any physics rate); never
  more than the reserves or the free cargo (`AsteroidField.extract()`, the only
  writer of reserves); Phase 3: the units arrive as the asteroid's raw resources.
- `mining/mining_operation.gd` (`Mining`, per miner, physics priority 1):
  saved `target` kept apart from `status` (No assignment, Traveling, Mining,
  Cargo Full, Depleted, Unreachable, Canceled). On assignment it picks one
  working point (16 candidates on the asteroid's outline + 3.75 u, the ship's
  side first; accepted when the planning radius fits on the navigation map, no
  other ship is parked at or heading for it, and a route ends there) and gives
  one RouteFollower order; none possible: Unreachable with a notice, no order.
  Extracts while within range and below 0.2 u/s; stops at full cargo or
  depletion (cargo stays aboard; notices). Mining never changes the survey.
- `mining/mining_view.gd` (`MiningView`): temporary flickering beam from each
  extracting miner's bow to the asteroid's outline, drawn only while
  `Mining.extracting` (the miner faces the asteroid; UX round).

Phase 2 Stage 3 (stations and docking; since Phase 2.5 the station-controlled
docking below):

- `stations/station.tscn/.gd` (`Station`, static, physics priority 2): body
  box 8 × 3 × 6 and two arms 4 × 0.8 × 1.2 along ±X (all three in
  `static_obstacle`; footprint 16 × 6 u), visual-only docking heads at the
  arm ends, markers `Hold1`–`Hold4` (±7.5, ±27; any `Hold*` marker is a holding
  position). Berths (Phase 2.5): Berth children are the only source of docking
  positions, headings and maneuver points, in scene order (`BerthEast` = slot 0,
  `BerthWest` = slot 1; `stations/berth.gd`, `@tool`): origin at the arm end, +Z
  the outward axis, `slot_size` 14.4 × 13.4 u (the parking rectangle,
  Destroyer-sized), `handover_margin` / `exit_margin` 1 u, markers `ParkStop`
  (1.5 u: the parked collision circle's stop line; its −Z is the final heading),
  `Handover` (14.4 u, the rectangle end; handover point = + radius + margin),
  `ExitBack` (3.5 u; the back-out ends at + radius + margin), `ExitA` / `ExitB`
  (±14 u lateral, 18 u out; fixed, sized for the Destroyer); queries: axis,
  rectangle gap / overlap / corners, parking point and heading, handover point,
  entry and exit legs; the editor draws the rectangle (preview child, never saved
  or created in the game). Three separate states per berth: the reservation
  (`slots[i].ship` / `leaving`), physical occupancy (`berth_occupants(i)`:
  collision circles overlapping the rectangle, on demand) and corridor clearance
  (`corridor_clear()`: the waiting ship's planned route to the handover point and
  on to the parking point keeps two footprints + `corridor_margin` 1 u from the
  remaining exit path of every ship leaving under station control). FIFO queue (one
  entry per ship, with the berths it can use): a berth is granted only to the first
  queued ship allowed there, only while unreserved, physically empty and with a
  clear corridor; nobody skips ahead. A requesting ship at the front gets the
  available berth whose handover point is nearest. A leaving ship keeps its
  reservation until its whole circle is outside the rectangle. Exit sides
  (`exit_sides()`): only sides whose back-out and departure legs are clear of
  static obstacles for that hull; `choose_exit_side()` takes the one farthest from
  the first waiting ship's route and other ships (at Station's west berth the
  Destroyer has only ExitB). Guided-maneuver limits `guide_speed` 1.5 u/s,
  `guide_accel` 1.0 u/s², `guide_turn_rate_deg` / `guide_turn_accel_deg` 30
  (capped by each ship's own). `show_berths` (debug, off; yellow free, orange
  reserved, red occupied, exit paths; `pick()` ignores it). Storage `Inventory`,
  transfer rate. Hover text: storage per resource, docks in use, waiting ships.
  Never orders or moves ships.
- `stations/docking.gd` (`Docking`, per ship, physics priority 1): states
  Not docked, Requesting Dock, Waiting for Dock, Approaching Station, Docked,
  Undocking, Waiting to Continue Transfer, Unable to Dock. Dock: the berths the
  ship can use (a route reaches the handover point, the straight entry is clear
  for the hull, at least one exit side) are requested (none: Unable to Dock with a
  notice, no order); granted: an ordinary order to the handover point. Station
  handover once arrived there at rest (velocity 0, within 0.25 u) with the berth
  reserved: `RouteFollower.clear()`, `Locomotion.guide()` (ENTRY phase, still
  Approaching Station): turn to the berth's final heading, straight in; Docked once
  that ends on the pose (≤ 0.25 u, ≤ 0.5°); stopped short by a contact: a notice,
  then Unable to Dock (nothing recovers). Queued: order to the nearest free,
  unoccupied, reachable holding position; the request is kept until a berth is
  granted. Undock: the controlled exit (EXIT phase, Undocking): straight back, turn
  toward the chosen exit side, forward to the exit point; Undocking ends (and
  control returns) when the exit has finished; no clear side: notice, stays docked.
  `under_control()`, `control_ended`; one held command (`hold_command()`, newest
  wins) runs when control ends. During station control `cancel()` / `dock()` are
  refused and counted (`refused_during_control`, push_error). `cancel()` otherwise
  releases the request, queue entry, holding position and transfer request and
  never moves the ship (also while Docked: the reservation is released once the
  ship has left the rectangle; no production path does this); departure is always
  `undock()`. Unload Cargo / Load (resource, amount): timed at the station's rate
  with fractions carried; a blocked transfer (storage full, no stock) keeps its
  request, leaves through the controlled exit, waits at a holding position
  (Waiting to Continue Transfer) and docks again once it can go on; a full hold ends
  a Load; units already moved stay moved. Ships without `Cargo` dock without cargo
  actions.
- `cargo/inventory.gd`: `transfer_to(other, amount, resource)` moves whole units
  (one resource, or every resource in the fixed order), never beyond the source
  or the destination's free space.
- `ui/ship_panel`: docking status (with queue position), Undock, station
  storage, Unload Cargo, Load (any resource, amount 1–1000) and transfer progress.
  `ui/asteroid_hover.gd` also shows the station's hover text. Phase 2.5: Start /
  Resume Transport and Resume Mining are disabled only while the station moves the
  ship; from a docked state a valid Resume Mining (`can_resume`, `can_mine`) or
  Start Transport docked away from its loading station is held, the controlled
  exit runs, then it starts (checked again); Start Transport at its loading
  station loads in place.

Provisional (Stage 3 / Phase 2.5): storage 5000 units, transfer 50 units/s,
dock tolerance 0.25 u, berth geometry and guided limits above. Docking positions
on Station's east / west arm (x; unchanged from Stage 3): Frigate and Miners
−24.9 / −47.1, Gunship −23.1 / −48.9, Destroyer −20.3 / −51.7. Docking durations
(baseline, owner 2026-10-16: acceptable; final tuning deferred until more
representative ship models, station geometry, animations and UI feedback):
handover to Docked 11–17.5 s, whole dock 18.6–38 s, exit 21.9–23.7 s; three
automated mining cycles 348 s (260 s before), three transport deliveries 342 s
(196 s before).

Phase 2 Stage 4 (fuel and resupply; the only movement change is
Locomotion's `propulsion` above):

- `fuel/fuel.gd` (`Fuel`, per ship, physics priority 1, after Locomotion):
  `capacity`, `consumption` (per u), `start_level` (share filled at start).
  Uses `consumption` × the length of Locomotion's `committed_motion` each tick
  (after collision), so every kind of movement follows one rule; standing,
  blocked and rotating ships use none; never below 0. At 0 it switches
  `propulsion` off (notice "out of fuel - stopped"); any fuel switches it back
  on. Warnings Low Fuel / Fuel Warning / Critical Fuel once each as the fuel
  falls below 15 / 10 / 5 % (notices); a threshold re-arms when the fuel rises
  above it. Docked (Docking state Docked): takes `min(rate × delta, free tank,
  station stock)` per tick from the station; the station loses exactly what
  the tank gains; stops on undocking. Scanning uses no fuel.
- `stations/station.gd`: `fuel_capacity`, `fuel_stock` (start), `refuel_rate`
  (per docked ship); hover line "Fuel: n / capacity". No production.
- `ui/ship_panel`: fuel quantity / capacity / percentage, bar, warning (or Out
  of Fuel) and, while docked, Refueling / Tank full / Station out of fuel.
- `scenes/movement_lab.gd`: fuel notices use the existing notice label.

Provisional (Stage 4): Frigate and Miners tank 100, 0.25 per u; Gunship 200,
0.5 per u; Destroyer 400, 1.0 per u (400 u range each); station 2000
capacity, 1000 at start, 20 units/s per docked ship.

Phase 2 Stage 5 (automated mining; Movement V3 untouched):

- `mining/mining_operation.gd` now runs the whole cycle. Saved configuration:
  `target` (asteroid) and `base` (a station, or null = nearest); the active
  operation is `status` (adds RETURNING; CARGO_FULL now means "Cargo Full - No
  Eligible Base", DEPLETED "Asteroid Depleted - select a new target"). Full
  cargo or depletion → base = the chosen base if `Docking.can_dock()` it (never
  silently changed; else it waits), else the nearest station it can dock at
  (stations found through the `station` group, `Station.GROUP`); then
  `Docking.dock()`; once Docked it asks `Docking.unload()`, waits for Fuel to
  fill the tank (or the station's fuel to run out), `Docking.undock()`, and
  once the controlled exit has ended gives one order back to a new working point
  at the same asteroid (a pending working-point order waits while the station
  moves the ship). Depletion (also a load that empties it): one final
  return, then DEPLETED, undocked. Mining and Docking never order the ship in
  the same leg; docking state is read from Docking (`activity()` builds the
  panel text: Traveling to / Returning to Asteroid, Mining, Returning to Base,
  Waiting for Dock, Unloading, Resupplying, Leaving Base, Waiting for Storage,
  Assignment Paused, Unreachable, " - Out of Fuel"). 2 route orders per cycle
  since station docking (working point, handover point; 4 before). `assign()` releases any dock request; `cancel()` pauses (settings
  kept); `resume()` / `can_resume()` (not for a depleted asteroid; Phase 2.5:
  `resume()` returns whether it restarted, refused with a notice when
  `can_mine(target)`, the read-only working-point check, is false);
  `set_base()` never cancels. Full station storage: the existing blocked
  transfer (unloads what fits, waits at a holding position, docks again).
- `stations/docking.gd`: `can_dock(station)` (at least one usable berth; see
  Docking). `station.tscn`: root in the `station` group.
- `ui/ship_panel`: miners: Base selector ("Nearest station", then stations it
  can dock at, nearest first; rebuilt on selection and when opened), status
  (`activity()`), Start / Resume Mining; manual Undock / Unload / Load pause the
  operation; the panel now shrinks to its contents every frame (it used to keep
  the height of the tallest ship shown, covering clickable ground).
- `scenes/movement_lab.gd`: unchanged commands (comment only).

Phase 2 Stage 6 (transport logistics; Movement V3 untouched):

- Transporter: the Gunship's locomotion profile, clearance margin 1 u (planning
  radius 5.1), size class 2 and fuel (200, 0.5 per u); Cargo 1000 (default);
  a Generic Scanner (owner to confirm). Crosses the asteroid field and docks
  bow-in at all four berths (0° since station docking).
- `Station2`: a station on the unchanged `station.tscn` layout (since Phase 3 with
  a refinery; now a `refinery_station.tscn` instance) at (−108, 6), about 77 u west of
  `Station`; every docking / approach / holding / exit point ≥ 15 u from
  asteroids. Station roles come only from assignments; miners can use either.
- `transport/transport_operation.gd` (`Transport`, per Transporter, physics
  priority 1, before Docking): saved `load_station`, `unload_station`,
  `required` (per resource; Phase 3: units or percent, see Phase 3); active
  `status` (LOADING, DELIVERING, PAUSED, UNREACHABLE). `start()` (needs two
  different stations and a requirement) → `Docking.dock(load)`; docked: one timed
  `load_cargo()` for a missing resource (one in stock first), resized or stopped
  (`Docking.stop_transfer()`) when the requirements change; since the UX round a
  resource out of stock keeps the ship waiting docked in its berth (see UX round,
  persistent transport docking); every requirement met and refuelled → undock,
  then (once clear of the slot) dock at the destination, `unload()` everything
  aboard (full station: waits in the berth until empty), refuel, undock, back to
  the loading station.
  Cargo not required is carried and delivered, never discarded. `cancel()`
  pauses (settings kept). Phase 2.5 configuration edits: a setter given the
  existing value does nothing; changing or clearing a station, or every
  requirement reaching zero, pauses an active operation once with a notice
  ("transport paused - station changed" / "- no cargo required"), never
  redirecting a trip under way (`_pause()`: docked or in the controlled entry →
  stays (or ends) docked, `stop_transfer()`; undocking → the departure finishes; otherwise
  `Docking.cancel()` releases request, slot, queue entry, hold and transfer
  request; cargo, fuel and configuration kept; Resume applies the edit); other
  requirement edits stay live. Each tick an active operation with an invalid
  configuration (written without the setters) pauses ("- choose two different
  stations and a cargo requirement") before any dock request, so
  `Docking.dock()` never receives one; `activity()` builds the panel text (Traveling to
  Loading Base, Waiting for Dock, Loading Cargo, Waiting for Resources,
  Resupplying, Leaving Loading Base, Traveling to Destination, Unloading Cargo,
  Waiting for Storage, Returning to Base, Assignment Paused, Unable to Reach
  Station, Requirements Exceed Capacity, " - Out of Fuel"). 7 route orders for
  three deliveries since station docking (19 before).
- `stations/docking.gd`: `stop_transfer()`. `scenes/movement_lab.gd`: MOVE and
  Dock also pause a transport assignment; its notices use the notice label.
- `ui/ship_panel`: Transporter: Load at / Unload at (stations nearest first),
  requirements (since the UX round through the transport editor), status, Start /
  Resume Transport, cargo; manual Undock / Unload / Load pause transport too.

Phase 3 (refining; accepted 2026-10-16 after the owner's gameplay test; Movement
V3, avoidance, Locomotion, navigation, collision, docking maneuvers, ship handling
and fuel untouched):

- Resources (`cargo/inventory.gd`): `RAW` = iron, nickel, silicon, cobalt, gold,
  titanium (AsteroidField's names) and ice; `INGOTS` = one per mineral
  (`silicon_ingot`, …); `RESOURCES` = all 13 in a fixed order (lists, displays,
  transfers of everything). `Inventory`: `amounts` (resource → units, only those
  held), one capacity; `add()`, `remove()`, `quantity_of()`, `free_space()`,
  `transfer_to()` (one resource, or all in the fixed order), `describe()`;
  `display_name()` ("Silicon", "Silicon Ingots"), `ingot_of()`. Metal Chunks and
  composition lots are gone; there is no save data, so nothing was migrated.
- Extraction: `AsteroidField.extract(id, n)` returns {resource: units}; each unit
  is the deposit's `next_resource()`, the one furthest below its share of all units
  it has given so far (integer arithmetic, ties in MINERALS order; ice deposits
  give ice only). The split depends only on how much the asteroid has given (not
  the tick rate, chunk size or which miner); total mass = reserves removed; every
  mineral stays within one unit of its share (largest deviation measured 0.93
  over all deposits of three seeds). Reserves, compositions, generation, the
  65 % / 35 % distribution and asteroid types are unchanged; `Extractor` adds the
  units per resource; cargo capacity is counted in units as before.
- Docking: `load_cargo(resource, amount)`, `load_resource`; Station hover lists
  storage per resource.
- Transport requirements: every resource (raw, ice, ingots); per resource
  `required` and `percent` (false: units; true: percent 0–100 of the hold's total
  capacity, `required_units()` = capacity × percent / 100 rounded down, never of
  free space or stock); units and percent mix freely; unallocated capacity stays
  empty; cargo aboard counts; `missing()`, `requirements_met()`, `is_configured()`
  use the units, so shortage waiting, live edits (a running load is resized; a
  lower requirement never unloads), station-change pauses, all-zero pause and
  Resume are unchanged. `set_requirement(resource, amount, as_percent)` returns
  false and changes nothing, with a notice ("requirements would exceed the cargo
  capacity (n / capacity) - not changed"), when all requirements together would
  exceed the hold's capacity. `describe_requirements()`: "Iron 100, Silicon 30%
  (300)".
- The Phase 3 ship-panel requirement row was replaced in the UX round by the
  transport editor (draft, one atomic Apply); the Load list shows every resource,
  and cargo is shown as resource tiles.
- `refining/refinery.gd` (`Refinery`, child of its station in `refinery_station.tscn`, i.e. `Station2` in `main.tscn`, physics
  priority 3: after Docking and the stations): two slots, each with a mineral
  (none by default) and Enabled (off by default); both may take the same mineral.
  An enabled slot adds rate × delta to its progress while its mineral is in stock
  and completes a unit by removing one raw unit and adding one ingot (no losses or
  byproducts; consumed only on completion, so nothing is held in process). No
  input: waits, consumes nothing. Disabling or changing the mineral resets the
  partial unit, no raw material lost. Slots run in order (slot 1 first), so two
  slots on one mineral draw from one stock without duplication; stock delivered in
  a tick is used from that tick. Raw and ingots share the station's storage
  capacity (no separate output); with 1-for-1 conversion a full storage still
  refines. No reservations: refining and transport loading take stock in
  simulation order. Rates (units/s per slot, provisional test parameters): Iron 4,
  Nickel 3, Silicon 2.5, Cobalt 2, Titanium 1.5, Gold 1. Status: No mineral
  selected, Disabled, Waiting for <mineral>, Processing; `processed` counts units;
  `assignment_processed` (UX round) counts units since the slot's current mineral
  was assigned (reset only when the mineral changes; shown as "N refined").
- `ui/station_panel.tscn/.gd` (`StationPanel`, in the same right-hand panel shell as
  the ship panel since the UX round, never shown together): left-click a station
  (not over a ship or GUI, no Shift,
  no drag; found with `AsteroidHover.station_at()`) selects it; a click elsewhere
  or selecting ships clears it (ShipSelection unchanged: the click clears ships as
  any click off a ship). Shows name, storage n / capacity, Raw and Ingots lines,
  and for a station with a Refinery each slot's mineral choice, Enabled switch,
  status with rate and units refined, and a progress bar of the current unit.
  Since the UX round the selected station gets the selection outline; layout
  under the UX round.

Phase 4 (ship production; accepted 2026-10-17 after the owner's gameplay test;
movement, avoidance, navigation, collision, docking, mining, refining, transport,
inventory and fuel untouched):

- Shipyard station: `Stations/Shipyard`, a `shipyard_station.tscn` instance (the
  unchanged `station.tscn` layout with the `Shipyard` and `Deployment` children; its
  storage, fuel stock, berths, holds, docking and transfers as at the other
  stations) at (−31, 1.5, −113), yaw +31° (owner-approved "option C";
  `Transform3D(0.857167, 0, 0.515038, 0, 1, 0, -0.515038, 0, 0.857167, -31, 1.5, -113)`).
  Measured in Godot on the authored scene: every docking, holding, exit and
  deployment point ≥ 15.0 u from asteroid surfaces (worst 15.289672 u, Hold4;
  +30° failed at 14.999303 u); every class has a clear entry and both exit sides
  at both berths and `can_dock()` from its spawn and from Station2; routes from
  both berths of Station and Station2 reach both Shipyard handovers for every class
  (78–219 u); every hold fits every planning radius; navigation and collision read
  45 obstacles, no navigation edge errors. Station lists sorted by distance now
  include it (from near Station: Station, Shipyard, Station2).
- `shipyard/shipyard.gd` (`Shipyard`, child of the Shipyard station, physics
  priority 3 as the Refinery): one production slot, no queue. Recipes (provisional
  prototype values, `RECIPES`): Mining Ship = iron ingots 200, nickel ingots 100,
  silicon ingots 50, 60 s, `miner_unit.tscn`, series "Miner"; Transport Ship = iron
  ingots 300, titanium ingots 100, cobalt ingots 50, 90 s, `transporter_unit.tscn`,
  series "Transporter". States IDLE → WAITING → CONSTRUCTING → (AWAITING_DEPLOYMENT)
  → IDLE. `order(id)` only while idle (otherwise refused, nothing changes); it
  starts at once when every ingredient is in the station's own storage, otherwise
  waits indefinitely. Waiting consumes and reserves nothing (other users of the
  storage take stock as before; shortages follow the storage); when the whole
  recipe is present it is removed in one tick (full check first, then removal) and
  construction starts. `cancel()` only while waiting (nothing to refund); no
  cancellation, refund or new order during construction; ingots delivered then are
  only stored. Construction time is summed physics delta. Fuel, currency and other
  resources are not used.
- Deployment: at the station's `Deployment` marker (position and yaw only, bow =
  its −Z). Blocked while any child of `Ships` (moving, docked or idle) is closer to
  the marker than the new ship's radius + its radius + `DEPLOY_MARGIN` 1.0 u
  (`deployment_clear()`, from Locomotion positions and RouteFollower radii). Clear
  at completion: the ship deploys in that tick (no Awaiting Deployment). Blocked:
  the finished ship is held outside the tree (AWAITING_DEPLOYMENT, slot occupied,
  nothing consumed again) and deploys in the first tick the point is clear; no
  other spawn point, no pushing or moving of ships, no use of a berth or
  reservation. The ship is instantiated from its variant scene (`*_unit.tscn`), named on in its series
  (`_next_name()`: 1 + the highest number in use, a ship named exactly like the
  series counting as 1: Miner3, Miner4, Transporter2, ...), given its transform
  before it enters the tree (Locomotion reads it in `_ready()`), added under
  `Ships` with `add_child()`, then `ship_deployed(ship)` (runtime registration, see
  Selection and `movement_lab.gd`) and `notice("Shipyard: Miner3 completed")`;
  `last_completed` keeps the name. A held ship is freed if the scene closes.
  Verified in the game loop (probe, then `shipyard_runtime_test`): a ship added
  during the Shipyard's tick has every `_ready()` run at once and its first
  physics callbacks in the next frame, in normal priority order.
- Produced ships: player-owned (under `Ships`), idle (no order, route, mining,
  transport, dock request or transfer), full tank by the existing `Fuel._ready()`
  (no station fuel used), Mining Scanner on Miners and Generic on Transporters,
  the starting ships' settings; selectable and commandable at once, and every
  system that finds ships under `Ships` (avoidance, collision, GroupOrders, berth
  occupancy and exits, MiningView, debug) includes them. Being later in the scene,
  they follow the existing "later in the scene" tie rules.
- `ui/station_panel`: Ship Production section, only for a station with a
  Shipyard: idle, each recipe with its time and per ingot "required n, available
  n" with "missing n" (red) or "available" (green), Order Mining Ship / Order
  Transport Ship and a note that an order starts construction as soon as every
  ingot is in the station and construction cannot be cancelled; waiting, the ship,
  the same lines for its recipe, Cancel Order, no progress bar; constructing, a
  progress bar and seconds remaining, no actions; awaiting deployment, the
  obstruction explained; "Last completed: <name>". Completion also shows in the
  notice label. No camera movement or fleet interface.

UX and quality-of-life round (accepted 2026-10-18 after per-package owner review;
Movement V3 / cause C, avoidance, navigation, collision, berth geometry,
extraction quantities, refining conversion, transport quota semantics and the
Shipyard untouched). Owner decisions that stay in force:

- Held commands during station control (two-stage validation): at issue only the
  intent is checked (target exists, command permitted for the ship), with no route
  planned from the guided position. A rejected command never replaces the held one
  ("… - held order kept"); the latest valid one wins. A held MOVE / group MOVE shows
  its destination ring and line at once (Dock / Mine show none). At release it runs
  through the unchanged `_order()` / `_execute()` checks from the actual release
  position; refused there: the usual notice, held command and marker cleared. Dock at
  the station being entered changes nothing. `movement_lab.gd`: `_hold()`,
  `_release()`, `_intent_valid()`, `_held_move()`; `Docking.held_command()`.
- Mining orientation: a Miner must face its asteroid before and while extracting.
  `Locomotion.face(heading)` is the one narrow idle-heading request (refused while
  guided or with a destination; cleared by movement, guidance or `place()`; normal
  turn limits). `Mining` requests the bearing at its working point and extracts only
  within `ALIGN_TOLERANCE` 1° of the bearing to the asteroid's centre (`extracting`);
  misaligned, extraction pauses until realigned. The status stays "Mining" during the
  turn (owner choice). Output per aligned second is unchanged.
- Persistent transport docking (automated Transport only; Miners and manual Load /
  Unload keep the leave-and-wait blocked transfer): `Docking.load_cargo(…, wait)` /
  `unload(wait)` keep one transfer request in a waiting sub-state (`waiting`) with the
  ship Docked and its reservation held, one notice per wait ("… - waiting in the
  berth"). Loading waits until the whole quota is aboard (a load waiting on an
  out-of-stock resource switches to another missing resource that is in stock);
  unloading waits until everything aboard is delivered; then the route continues
  automatically. Status texts "Waiting for Resources" / "Waiting for Storage". Berth
  congestion is intended: no eviction or auto-resolution. A valid manual departure
  (Undock, MOVE, Dock elsewhere) pauses the assignment; only Resume restarts it,
  without repeating completed transfers. Fuel refuels throughout the wait.
- UI foundation: `game/ui/theme/apalit_theme.tres` (type variations HeaderLabel,
  SectionHeader, MutedLabel, WarningLabel, SegmentButton), `ui_palette.gd`,
  `resource_icons.gd` (generated placeholder icons), components in
  `game/ui/components/` (`panel_shell`, `section`, `refinery_slot`, `resource_tile`,
  `resource_row`, `segmented_control`): display-only scenes that emit signals;
  gameplay stays in its systems. No UI framework or state manager.
- Inspector: `panel_shell` is a fixed 340 px PanelContainer anchored bottom right
  (16 px margin), fixed header, vertical scroll body, height up to the screen minus
  96 px (notices), so content never changes its width. Ship panel: Header (editable
  name, class), Status (activity, dock, fuel bar, hull "Hull: n / 150" since the
  combat migration), Combat (armed ships only, see Production combat), Cargo
  (summary and resource tiles from the actual inventory),
  Actions (scanner, Scan Area, mining, transport, docking and transfers). Station
  panel: Header (name, type), Status (fuel stock bar, health placeholder), Storage
  (tiles), Refinery (slot components), Production (Shipyard). The debug panel is top
  left. No keyboard shortcuts are shown (none exist).
- Display names (`game/ui/display_name.gd`): `DisplayName.of()`, `rename()`,
  `class_of()` read and write metadata `display_name` / `display_class` (the class on
  each variant and station scene); renaming in a panel header changes only what
  panels, hover text and notices show. Node names, selection registration and the
  Shipyard's series numbering are unchanged.
- Transport configuration: the Transport section shows Route (load → unload),
  Required, an informational Unloading line (everything aboard; no unload quotas)
  and Configure. `transport_editor.tscn/.gd` edits a draft (loading only): tabs Ore
  (six minerals + Ice), Ingots (six ingots + the same Ice: one draft entry, one
  requirement) and Components (disabled, "not implemented"); rows show the
  resource, the amount aboard, the requested amount, Units / % and Clear. Nothing is
  live until Apply, which calls `Transport.apply_requirements(amounts, as_percent)`:
  validates the whole candidate, then commits all or nothing (rejected: notice, live
  configuration and draft kept). Cancel discards the draft; tab or focus changes
  keep it.
- World feedback (`game/presentation/`):
  - `world_highlight.gd` + `highlight_fill` / `highlight_outline.gdshader`
	(stencil): one `material_overlay` pair per object mesh; selected ships and the
	selected station cyan (fill 0.08, outline 2 px), hover pale (fill 0.04,
	1.5 px), width constant on screen at any zoom; the green selection rings stay.
	Asteroids: a copied surface material with the highlight as next pass, so the
	survey grid and the shared material are untouched.
  - `object_markers.gd`: 7 px screen-space markers only on hover or selection:
	triangle combat ships, octagon ships with Cargo (logistics, miners), square
	stations, diamond asteroids (survey colours). Transient scan feedback (pulse,
	grid, progress, DATA UPLOADED) stays in SurveyView.
  - `command_cursor.gd`: the cursor shows what a right-click would do, from
	`movement_lab.gd`'s read-only `resolve_command()` and `command_available()` (the
	same resolution and checks as the click, notices muted): Move (cross), Mine
	(pointing hand), Dock (can-drop), Unavailable (forbidden), arrow otherwise. OS
	cursor shapes are placeholders. Cached per target / 2 u cell, refreshed every
	0.5 s; a group's assignment is checked after 0.25 s rest.
- Propulsion effects: `thruster_view.gd` (one node, reads every child of `Ships`
  each physics tick after the ships, never writes) and `thruster_plume.gdshader`.
  Emitters are the hull's `Thrusters` parts; jet intensity = the ship-frame
  acceleration (from the change of velocity / turn rate) as a share of its limit,
  smoothed 0.08 s, zero without propulsion; main and directional effects combine
  (e.g. main plume and turning jets while accelerating through a turn). Main plume
  (bright core, soft orange glow, slight flow) states: BOOST while accelerating
  forward, THRUST while cruising (forward speed > 0.2 u/s, not braking), IDLE (a flat
  glow on the nozzle: stopped, braking, turning, sideways), NONE without propulsion;
  sizes scale with the engine (Miner reference). Pale-blue directional jets. No
  trail, smoke or combustion. Per type: engine radius / jet box 0.2 / 0.14 (Miner),
  0.15 / 0.12 (Frigate, engine inset, 0.09 u protruding), 0.35 / 0.22 (Gunship),
  0.45 / 0.25 (Transporter), 0.45 / 0.30 (Destroyer, inset, 0.18 u protruding).
- Tests added: `ui_qol_test`, `held_command_test`, `mining_facing_test`,
  `transport_persistent_test`, `transport_editor_test`, `world_highlight_test`,
  `object_markers_test`, `command_cursor_test`, `thruster_view_test`. Assertions
  migrated with owner approval (transport, transport_config, silicon_shortage,
  shipyard_runtime, panel paths in ten suites, refinery tiles, mining / transport
  hull geometry with the thrusters checked separately).

Profiles (set once per type in its variant scene, `game/ships/<type>_unit.tscn`;
the Transporter uses the Gunship's with radius 4.1; the test arena
`movement_test.tscn` and `obstruction_test` keep their own movement-only copies of
these values; Movement V3 profiles unchanged from the accepted experiment; the
Miners use the Frigate's):

| | Frigate, Miners | Gunship | Destroyer |
|---|---|---|---|
| max speed forward / reverse / lateral (u/s) | 5 / 4 / 3 | 4.5 / 2.5 / 2 | 3 / 1.5 / 1 |
| accel forward / reverse / lateral (u/s²) | 6 / 3 / 2.5 | 3 / 1.5 / 1.2 | 1.2 / 0.5 / 0.3 |
| turn rate (°/s) / turn accel (°/s²) | 120 / 240 | 60 / 90 | 25 / 20 |
| ship radius (u) / clearance margin (u) | 1.6 / 1 | 3.4 / 1 | 6.2 / 1 |
| size class | 1 | 2 | 3 |

Origin: the movement code was copied from the Movement V3 experiment in Stage 7
(paths to `res://game/`, the lab split into `main.tscn` and the test arena,
`SphereMesh` obstacles read by `StaticNavigation` / `PlanarCollision`,
`movement_lab.gd`'s `scenario_keys`); the experiment was retired on 2026-10-20.

### Production combat (migrated 2026-10-19 / 20, accepted after the owner's gameplay test)

Migrated from the combat prototype v0.5 and the behavior prototype v0.1 (accepted in
P01–P03 and E05); the prototype was retired in the M8 cleanup. One implementation of
each system:

- Simulation time (`game/time/`): `sim_clock.gd` (node `SimClock`, first child of
  every gameplay scene, physics priority −100) adds up the physics delta: the one
  simulation clock (`SimClock.now()`). `time_control.gd` (node `TimeControl`, added
  by `movement_lab.gd`) is the one owner of `SceneTree.paused` and
  `Engine.time_scale`: pause (Space), speed 0.25x / 1x / 2x (- / =), 0.25x while
  attack-target selection is open (a speed chosen meanwhile is restored after).
  Every simulation system (ships, combat, sensors, mining, refining, the Shipyard,
  fuel, transport, docking, the survey) runs on physics time, so pause and speed
  apply to all of them; `movement_lab.gd` sets the scene's simulation children
  PAUSABLE and its input, camera, selection, panels and presentation (`ALWAYS_NODES`)
  always processing; the camera, notices and command cursor divide the time scale out
  (real time). Orders and panel actions given while paused take effect at once and
  nothing advances until resumed.
- Combat (`game/combat/`): `combat_ship.gd` (node `Combat`, every ship, physics
  priority 2) is the one owner of hull health (`combat_rules.tres`: 150 for every
  ship), faction (0 player, 1 hostile), manual / automatic target and threats, and
  steps the ship's weapons. Targeting is strict: a manual target is the only
  offensive target; without one, Defensive takes confirmed threats (attacks on itself
  or allies within 30 u, 10 s persistence), Aggressive the nearest hostile in contact
  within its longest usable weapon range, Passive (Hold Fire) nothing. Friendly ships
  never damage each other. Destruction: weapons off, references cleared on every ship,
  propulsion off, route / avoidance / fuel / scanner / docking / mining / extraction /
  transport stopped, `Docking.abandon()` releases the station records, the ship
  leaves the selection; a 2 s hulk, then removal (`Avoidance.forget()`, Selection
  unregistered) and free. `combat_orders.gd` (node `CombatOrders`) is the one combat
  command interface (move, target, tactic, Attack, Guard, Attack-Move, Waypoint,
  Cancel, profile) for player input, the commander and tests.
  `projectile_system.gd` (node `Projectiles`) moves rounds and guided ordnance and
  resolves hits against ship hull boxes, asteroids, stations and hostile ordnance
  (point-defense interception); `ordnance.gd` (torpedo, missile flight and guidance),
  `combat_effects.gd`, `ordnance_trails.gd`. `combat_obstacles.gd`: station parts
  (the `static_obstacle` group) for projectile obstruction, weapon line of fire,
  missile avoidance and Behavior's firing positions; a station without a hull
  component (all production stations) stops shots without damage; one with a
  `take_hit()` component of another faction takes the damage. Sensors ignore stations.
- Weapons (`game/weapons/`): `weapon.gd` (shared firing authorization: owner,
  ammunition, target, contact, tactic, range, coverage, alignment, reload, cooldown,
  solution, clear path), `turret.gd` (cannon), `gatling.gd` (point defense under every
  tactic, then offense), `launcher.gd` (torpedo tube, missile cells, salvos),
  `hardpoint.gd`, `weapon_config.gd`, `ordnance_config.gd`, `weapon_geometry.gd`
  (placeholder meshes); `cannon.tres`, `gatling.tres`, `torpedo.tres`, `missile.tres`
  (unchanged validated values).
- Sensors (`game/sensors/`): `sensors.gd` (node `Sensors`): faction-shared detection
  within 100 u with a line clear of asteroids, every 0.2 s of simulation time; a lost
  contact keeps a last-known position for 8 s. `contact_board.gd` (node `Contacts`):
  contact = detection (and not removed by hand). Weapon line of fire is separate.
  Fog of war: `movement_lab.player_sees()` decides what of a hostile ship is drawn,
  picked, targeted and inspected; `presentation/fog_view.gd` shades the uncovered
  ground and hides hostile rounds, ordnance, trails and effects outside coverage.
- Commands, Tactics, Weapon Profiles (`game/behavior/`): `ship_behavior.gd` (node
  `Behavior`, on the armed Gunship and Destroyer variants, friendly and hostile
  alike; physics priority −3). Precedence: a command (Move, Attack, Guard,
  Attack-Move, Waypoint Move, Dock, Cancel) over the tactic (Aggressive pursues its
  target in contact; Defensive answers attackers from its defended area with local
  line-of-fire repositioning, no pursuit; Passive does nothing, point defense still
  fires) over the weapon profile (Siege / Mid-range / Close Quarters, available from
  the installed weapons, fallback in that order; it chooses positioning only, never
  authorizes or forbids a shot). Guard and explicit movement override autonomous
  positioning. `weapon_profiles.gd`.
- Movement ownership: Locomotion is the only executor of ship movement. Behavior's
  own positioning goes through `movement_lab.autonomous_move()` (one RouteFollower
  order; moved beside an occupying ship, checked for a route; no assignment
  cancelled, no notice, not a command; refused while docking has the ship). Player
  commands are announced by `movement_lab.command_given(ship, kind)` from
  `_execute()` (so a command held during station control is recorded when it is
  released); Behavior takes a MOVE there as the player's Move. Docking owns the ship's
  movement from the dock request until control ends (Behavior holds the Dock command
  and requests nothing).
- Hostile commander (`behavior/hostile_commander.gd`, node `HostileCommander`, in
  `combat_test.tscn`): gives its faction's armed ships a tactic, Guard of an escorted
  ship and Attack-Move objectives through CombatOrders once their navigation map is
  ready; the ships carry them out with their own Behavior. No strategic AI.
- Tactical UI and presentation: `ui/combat_hud.gd` (node `CombatHUD`: hull bars over
  visible ships, speed / pause line, target-selection readout, scenario result);
  ship panel Combat section (armed ships only): Tactic and Weapon Profile selectors
  (the loadout's profiles), command and effective profile, target, weapons with
  ammunition; `presentation/tactical_markers.gd` (strategic zoom above 65, back
  below 55: models hidden, ships drawn in the ObjectMarkers category shapes, triangle
  combat / octagon logistics, in the faction tint, hostile with a second outer
  outline; picking through the markers), `tactical_grid.gd` (G), `weapon_envelopes.gd`
  (Alt, target selection), `combat_overlay.gd` (target lines; F10 debug arcs),
  `behavior_view.gd` (guard positions, waypoint and Attack-Move lines; the Defensive
  defended area is not drawn).
  Hull tint: player blue, hostile red. Selection: only live ships of the player's
  faction are selectable; `pick_any()` finds hostiles for targeting.
- Not migrated (by decision): the prototype's heading lock and fixed forward cannon,
  and its v0.2 scenarios.

### Controls

- Left-click a ship: select it; Shift-click: add / remove; left-click ground:
  clear (Shift keeps). Left-drag > 5 px: box selection (Shift adds).
- Right-click: MOVE for the selected ship (over a stationary ship: to the
  nearest valid point beside it, with a notice; over a moving ship: the point
  itself); several selected: group MOVE (notice if there is not enough space). Orders belong to
  the ships and continue after deselection; a new MOVE replaces the old one,
  keeping momentum.
- Miner (exactly one selected): right-click an asteroid to mine it (scanned or
  not); right-click elsewhere is a MOVE and cancels mining (target kept);
  right-click another asteroid replaces the target. Several ships selected:
  the usual group MOVE, also over asteroids.
- Any ship (exactly one selected): right-click the station to dock (normal
  approach to the berth's handover point, then the station guides it in); a
  right-click elsewhere during the normal approach or while waiting cancels
  docking (and any transfer request). While the station guides a ship in or out,
  right-clicks for it are held (the newest wins) and carried out once control
  returns; for a docked ship a command is checked first and, accepted, follows the
  controlled exit. A group MOVE gives every ship its own destination; guided or
  docked ships take theirs after their maneuver.
- A command that cannot be carried out (no route, no reachable working or
  docking position, Resume without a working position) shows a notice and
  changes nothing (also for a docked ship); Dock on the station the ship is
  already docking at changes nothing.
- Ship panel (one ship selected): Scan Area (every ship); miner status and
  cargo; docking status, Undock, and while docked with a cargo hold Unload
  Cargo and Load (resource, amount). Hover an asteroid for its survey
  information, the station for its fuel, storage and docks. A ship without
  fuel still takes orders (it moves once refuelled). Transporter: a requirement
  per resource in units or % of the hold (an edit exceeding the hold is rejected
  with a notice); changing a station or setting every requirement to zero while
  the assignment runs pauses it (Start / Resume Transport applies the edit).
- Station (Phase 3): left-click a station to select it and open its panel
  (storage; Station2 also its refinery: per slot a mineral, Enabled, status,
  progress); a click elsewhere or selecting ships closes it. Phase 4: the
  Shipyard's panel adds Ship Production (Order Mining Ship / Order Transport Ship
  while idle, Cancel Order while waiting for materials); produced ships are
  selected and commanded like the others.
- Camera: W/A/S/D pan, Q/E or middle-drag rotate, wheel zoom toward the cursor
  (smooth; tilts toward top-down when zoomed out; not over UI panels).
- Debug panel (top left, off at launch): Movement, Navigation, Avoidance Debug.
- UX round: hovering a ship, station or asteroid outlines it (pale) and shows its
  marker; selected ships and the selected station are outlined cyan. The cursor
  shows the right-click result (Move, Mine, Dock, Unavailable). Click the name in a
  panel header to rename the ship or station. Transporter: Configure opens the
  transport editor (Apply / Cancel).
- Combat: right-click a visible hostile: target it (selected ships); T attack-target
  selection (0.25x; left-click a hostile; Esc or right-click elsewhere cancels);
  Ctrl + right-click a hostile: Attack, a friendly ship: Guard it, the ground:
  Attack-Move; Shift + right-click the ground: add a waypoint; X cancel the command;
  P next weapon profile; F1 / F2 / F3 Passive / Defensive / Aggressive; Backspace
  clear the manual target; hold Alt weapon ranges; G tactical grid; F10 combat debug
  overlay; Space pause; - / = speed 0.25x / 1x / 2x; wheel out for strategic zoom.
- Test arena only: keys 4–9, 0, − set up the avoidance scenarios.

### Archive

- `archive/apalit_pre_v3_integration_2026-10-14.zip` (846,971 bytes, SHA-256
  5C83748EEBD7C13CC019C98079E6D58CF63CF505B9B52F08EDAB15E8646272FC, 112
  files): the original game before integration, without `archive/`,
  `experiments/`, `.godot/` and the empty `.claude/`; `main.gd` as it was
  (SHA-256 BB7D3627…71EB5, including unrecorded S4-I4 group slot code, not the
  older documented baseline). Manifest:
  `archive/apalit_pre_v3_integration_2026-10-14.sha256.txt`.
- Verified 2026-10-14: extracted outside the project, all 112 files match the
  manifest; the extracted project imported and ran its `main.tscn` headless
  (600 frames) without errors.
- Restore: check the ZIP's SHA-256, extract into an empty folder, open in
  Godot 4.7 (rebuilds `.godot/`), compare against the manifest.
- Removed from the project (all in the ZIP with matching hashes; sent to the
  Windows Recycle Bin): in Stage 7 `main.gd`, `ship.gd`, `ship.tscn`,
  `ship_movement.gd`, `ship_movement.tscn`, root `camera_rig.gd` /
  `camera_rig.tscn`, their `.uid` files, `Refine/tests/`, `Refine/playtest/`,
  `Refine/experimental/` (the old `main.tscn` was replaced); in the final
  cleanup (owner, 2026-10-14) `Refine/` (`PLAN.md`, `TASKS.md`, `Ship systems
  fantasy alignment pass.md`, `baseline/movement-baseline-2026-10-13.zip`),
  `tech_docs/` (`README.md`, `movement.md`, `collision.md`, `navigation.md`)
  and `asteroid.tscn`. Nothing in the project depended on them; decisions that
  still apply were moved to Design decisions carried forward.

### Recovery snapshots (outside the project)

In `C:\Users\Nikos\Documents\apalit_backups\`, each with a `.manifest.txt` beside it
(contents, exclusions: only `.godot/` and the empty `.claude/`, verification, restore):

- `apalit_pre_combat_migration_2026-10-19.zip` (892 files, SHA-256
  A2D28390CC75B47BBBD86D3A42AE2B61D7B14B3F535EAF385DFE10C62F8B9D48): the project
  before the combat migration, with the runnable combat prototype and every
  experiment.
- `apalit_post_combat_migration_2026-10-20.zip` (1025 files, SHA-256
  46B17C1E0DDB00CB3EF3ED55CBDAADA1FFB291A4AA20244EB7FD8C54484B609D): the accepted
  production combat migration before the M8 cleanup (every retired experiment and
  `_migration_tmp/` included).
- Both verified by extraction, a SHA-256 comparison of every file and a headless
  import and run of the restored copy. Restore: extract into an empty folder, run
  `<godot console> --headless --path <folder> --import`, open in Godot 4.7.2.
- `baseline_logs_2026-10-19/` there: the Gate 0 regression logs of the migration.

## Design decisions carried forward

Owner decisions from 2026-10-11 (the original game's fantasy alignment pass,
document removed 2026-10-14) that still apply; decisions about the original
movement model were not carried over.

- Fantasy: the player is an admiral commanding WWII-style warships in space;
  heavy capital and cargo ships, no fighters.
- The player gives intentions (where), the autopilot owns speed, braking,
  turning and waiting; no player speed orders.
- Collision is a safety net the player should almost never see; a contact
  keeps the order.
- No drag (momentum stays something to plan around); flip-and-burn only for
  transit between sectors.
- No reversing out of deadlocks (decided for the original traffic system;
  relevant to the V3 stall limitation, not re-confirmed since).
- The developer's own play is the validation (solo hobby project).
- Later work, each started only when its trigger arrives, with what was
  already decided:
  - Facing control (heading separate from travel): trigger combat
	prototype; needed for fixed firing arcs.
  - Nearby-ship spatial grid: at about 20 ships; replaces all-pairs ship
	checks.
  - Formations: after groups; keep shape, shared internal speed cap, blocked
	slots resolve, break and rejoin.
  - Transit between sectors: sector layer; physical, interceptable,
	flip-and-burn, ships arrive slowed to local speed.
  - Larger maps: with weapon ranges and sectors; missile range must leave room
	for an approach phase.

## Parked-ship navigation investigation (2026-10-15, accepted, not integrated)

Hypothesis: parked ships as StaticNavigation obstacles, ShipAvoidance only for
moving ships. Owner decision: not integrated; no further navigation experiments
for now.

Prototype (formerly `experiments/parked_navigation/`, retired 2026-10-20; its
scripts, harness, logs and pictures are in the recovery snapshots; its harness had
stopped compiling once `RouteFollower.order()` returned a value in Phase 2.5;
scripts swapped in at run time, production untouched): `parked_navigation.gd` extends StaticNavigation; a ship
with no order and no queued order (operational state, not velocity) adds its
bounding circle to the obstacle list shared by the maps and `segment_clear()`;
one update at a time rebakes every planning-radius map synchronously, and
`is_ready()` stays false until every map has synchronised, so orders queue.
`parked_route_follower.gd` releases the ship's own obstacle in `order()`.
`parked_avoidance_ignore.gd` = variant B (cause C ignoring parked obstacles);
variant A = cause C unchanged; control = no parked obstacles. Active routes are
never replanned (owner choice for the experiment). Harness:
`parked_navigation_test.gd` (real game loop, test arena; `-- A|B|control`, or
`main` for the main.tscn bake benchmark; a png folder argument draws pictures in
a rendered run). `results/`: the final raw logs (`run_A`, `run_B`,
`run_control`, `run_main` headless; `run_A_render`, `run_B_render` rendered) and
the variant A pictures plus variant B's two 2b pictures (copied unchanged, not
regenerated; the Godot editor will import the PNGs). Earlier debug runs and the
remaining variant B pictures were not kept.

Measured:

- Works: routes bend around already-parked ships (route kept 6.0 u from a
  Miner's centre = avoidance's separation); Gunship behind an idle Miner 3/3,
  Miners 4 u apart (cause C layout, route around the outside), the 16 u spawn
  pair, and the arena gap held by two Miners (not traversed; routed around the
  walls; cause C holds short there): all arrive, 0 contacts, 0 reversals.
  A MOVE between the 4 u Miners resolves to a point 7 u away and arrives.
  Departure: route starts at the ship's position, old footprint removed from
  every map, re-registered on arrival.
- Cost: synchronous rebake per park or departure ≈ 119 ms on main.tscn (four
  maps, 27.7–30.4 ms each, 42 static obstacles + 6 ships); 8.2–8.9 ms in the
  test arena (three maps). Synchronisation 8–17 physics ticks on main.tscn
  (3–9 in the arena); every order to a parked ship waits for it and shows the
  "Navigation map not ready - order queued" notice.
- Routes planned before a ship parks are not invalidated: a Miner parking on a
  Gunship's planned (multi-segment) route stalls the Gunship permanently beside
  it (variant A, 0 contacts; the shared clearance checks block the route and the
  pass); variant B collides (1–3 contacts) and stalls. On a direct move variant A
  passes as cause C does. A route bent around a ship that then left is flown
  unchanged (+3 % length in the test).
- Local avoidance still needed: variant A still enters passing for parked ships
  (shift ≤ 0.01 u in open space); ignoring them (B) is unsafe for stale routes.
  Routes pass closer than cause C (0.5 u footprint gap: the lookahead cuts
  corners to its reserve) and 0.6–2.0 s slower in the single-Miner case.
- A parked ship's own obstacle also affects map queries made before its order
  (e.g. `GroupOrders.resolve_occupied` rejected every candidate near the mover).
- A footprint overlapping a static outline (0.6 u, artificial) gives Godot's
  "Navigation region synchronization had 1 edge error(s)" once per map; touching
  (0.1 u) does not.

Not evaluated (unknown, not shown unsuitable): asynchronous or threaded baking,
incremental or local (chunked) map updates, route invalidation and replanning,
avoidance changes, moving ships as obstacles, out-of-fuel ships, docking,
mining and group orders. Timings from one machine.

## Station-controlled docking (prototype 2026-10-15, integrated and accepted 2026-10-16)

Integrated in three stages (all accepted): 1 guided Locomotion, 2a editor-authored
berth geometry (passive), 2b station-controlled docking; current behaviour under
Code. Owner (2026-10-16): Berth geometry and guided entry / exit accepted;
occupancy, reservations and corridor clearance function; queue hand-overs and
held player commands passed gameplay testing; Mining and Transport work with
the new docking; durations are an acceptable baseline (tuning deferred); the
Destroyer's circular footprint remains a known limitation; no further movement or
docking refinements are authorized. The prototype record below is history.

Preceded by a read-only docking audit (owner, 2026-10-15): production ships enter
the berth at full speed and dock up to 16° off the arm axis; idle ships on a lane
or berth leave a docking ship in "Approaching Station" forever; the first-choice
exit (+50°) crosses the Hold1 → east approach route (and Hold4 → west), so
hand-overs deadlock (reproduced: 3 of 6 cases on `main.tscn`).

Prototype (formerly `experiments/station_docking/`, subclasses of the production
scripts swapped in by scene; owner playtest accepted 2026-10-15). Retired
2026-10-20: the scenes and the tri-dock test, which run on production code, moved to
`game/tests/docking/`; the superseded prototype scripts and the logs listed below
were removed (they are in the recovery snapshots):

- `guided_locomotion.gd`: built the guided mode now in production Locomotion
  (stage 1; station limits used 1.5 u/s, 1.0 u/s², 30 °/s, 30 °/s²); since stage 1
  an empty subclass kept for the scenes and casts. The target-heading hold fixed a
  prototype defect (ships swung back 105–109° to their last order's bearing after
  docking).
- `slot_station.gd` (extends Station, exposed arms): per-port parking rectangle
  (14.4 × 13.4 u, Destroyer-sized), handover point on the axis outside it, parking
  pose, exit legs (back 3 u, turn 60° away from the first waiting ship's route and
  other ships, forward until clear). Reservation, physical occupancy (circle vs
  rectangle, each tick) and corridor clearance (waiting ship's route vs remaining
  exit paths) are separate; a leaving ship's reservation ends when its circle leaves
  the rectangle; a grant also needs an empty rectangle and a clear corridor.
- `tri_station.gd` / `.tscn`: owner's tri-dock reference (three recessed bays, 120°
  apart, 10 u wide, rectangle 18.4 × 7.5 u); every berth authored with markers
  (ParkStop = stop line and final heading, Handover, ExitBack, ExitA / ExitB).
- `station_docking.gd` (extends Docking): entry and exit as a phase inside
  APPROACHING / UNDOCKING (Mining and Transport unchanged); DOCKED only after the
  entry; blocked transfers leave through the exit; `cancel()` / `dock()` refused
  while under control (never reached in the tests).
- `deferring_lab.gd`, `deferring_panel.gd`: right-clicks for a ship under station
  control kept as one pending command (newest wins), replayed through the unchanged
  command path when control ends; a right-click on a docked ship starts the
  controlled exit first; panel actions that would cancel docking disabled.
- Scenes `station_docking_demo.tscn`, `tri_dock_demo.tscn` (asteroids hidden and not
  obstacles, tri station at (70, 60)); harnesses `station_docking_test.gd`
  (20/20; `-- baseline` reproduces the production deadlocks), `tri_dock_test.gd`
  (14/14); logs in `results/`.

Measured: alignment 0.00° at Docked and after 10 s for every class, 0 contacts, no
movement discontinuities, release exactly when the circle leaves the rectangle,
all hand-over cases (Hold1, Hold4 mirror) dock. Exposed arm: entry 11–17.5 s after
the handover, exit 17.7–19.7 s (production 5.5–7.2 s). Tri-dock: entry 15.8–20.3 s,
exit 26.6–27.8 s.

Prototype open items, as resolved in the integration: the Destroyer's circular
footprint (still open, see Known limitations); tri-dock navigation edge warnings
(still logged, experiment only); docked commands are now validated before the exit;
group commands now keep every ship's GroupOrders destination.

Owner decisions applied in the integration: fixed editor-authored exit points
sized for the largest supported ship; a manual command while docked is validated
first (rejected: nothing changes; accepted: controlled exit, then the command,
re-validated); a transport configuration pause during the controlled entry lets it
finish and stay docked; Resume Mining / Start Transport usable from a docked state
(disabled only while the station moves the ship); group commands keep every ship's
GroupOrders destination (no new group framework); `cancel()` never moves a ship
(departure only through Undock); `RouteFollower.order()` refused while guided;
Berth nodes the only source of docking geometry (legacy calculations and
`DockEast` / `DockWest` removed). Requirements met: no RouteFollower order reaches
a guided ship (counters 0 in every suite); handover only with the ship at rest.

## Latest verification (2026-10-20, camera Phase A)

- Baseline once before the change (52 suites: 50 pass, known failures navigation
  35/36 and obstruction 9/12), then the full set after it, twice (the second after
  the UI-panel wheel block): 51 of 53 pass; the two known failures have identical
  output; no suite's error or warning lines changed. `main.tscn`, `combat_test.tscn`
  (and once `movement_test.tscn`) ran 600 frames headless without errors. Not the
  full protocol under Environment notes (one baseline run; three scene runs).
- New `camera_test` 34/34: smoothing (95% in 15 frames at 60 fps, no overshoot,
  reversal, limits, inverse steps), wheel factor, pitch, anchoring (0.000 px drift
  at centre, off-centre, edges, yaws 0 / 45 / 200 / 300, during the pitch change),
  bounds and missed-ray cases, pan / Q / middle drag cancelling the anchor, snaps,
  `zoom_level()`, UI panel blocking, equal settle time at 1x / 0.25x / 2x / paused.
- Changed checks: `strategic_test` S1 (all E05 corners on screen at 150 replaced by
  target and convergence, 80° pitch, pivot in bounds, finite ground under the screen,
  a wider region than at 40, marker pick and MOVE at the maximum) 17/17;
  `time_test` C3 / C6 (target at once, settling while paused, equal settle frames)
  39/39; `selection_test` line 151 reads `zoom_target` 41/41.
- Owner acceptance 2026-10-20. No rendered or visual check was run by the agent.

## Earlier verification (2026-10-20, production combat migration and M8 cleanup)

- Recovery: both snapshots above verified before any change (Gate 0 of the migration,
  M8 Gate 0).
- Migration (M1–M7): the 13 prototype combat suites ported to `game/tests/combat/`
  (353 checks) gave logs identical to the prototype's apart from removed v0.2
  sections and renamed check texts; P01–P03 and E05 measurements unchanged. The v0.2
  `combat_test` (heading lock, fixed forward cannon) was not ported; its required
  behaviour is covered by the ported suites (Gate 2 mapping). New suites:
  `production_world_test` 13/13, `combat_docking_test` 11/11 (real station: Guard to
  Dock, held Move recorded after the controlled exit, destruction in entry / docked /
  exit), `combat_scene_test` 25/25 (commander, fog, full battle with salvos,
  point defense and kills, pause and dilation of the economy, controls, inspector,
  both Shipyard recipes through the real production path).
- Owner gameplay acceptance (Gate 1): 2026-10-20.
- M8 cleanup: 671 files and 34 directories deleted (11.25 MB); 5 docking regression
  files moved to `game/tests/docking/`; 3 unused code paths removed. After it: a clean
  import of a fresh copy without errors; every `.gd` / `.tscn` / `.tres` loads (0
  failures; before the cleanup 3 failed, all in retired experiments); no missing
  `res://` path or unresolved UID.
- Regression: 57 runs (35 production suites, `tri_dock_test`, 16 combat suites, 5
  scene runs; 1,121 counted checks), before the cleanup and twice after it: the same
  results; only the known failures navigation 35/36 and obstruction 9/12. Variance
  seen across runs (each check passing): asteroid seeds, timing lines, map-ready
  frame, tri-dock edge-warning counts, and twice a one-tick difference (P03 guard
  offset 8.3 / 8.5 u, one powered-missile tick).

## Earlier verification (2026-10-18, direct-move prediction horizon)

Investigation (owner report: during a five-ship group MOVE a Miner stuck among
larger ships rotated in place; orange marker = that ship's own GroupOrders
destination, the only ship still ordered). The exact screenshot layout was not
reproduced; the same failure was, from the spawn in `main.tscn` (scratch probes, not
kept: group MOVE of Frigate, Gunship, Destroyer, Miner1, Miner2 to 336 click points
on rings 12.5–40 u around the group, real game loop, 90 s each).

- Cause: on a direct move the own prediction stopped after the straight distance
  from the ship to its destination while starting at the route position. A ship a
  pass had displaced sideways near its leg's end got a predicted path running past
  the destination; an idle ship parked beyond it (e.g. the Destroyer at its group
  destination 10.0 u away, separation 8.8 u) stayed in conflict only on that
  extension (traced: 0.6–6.4 u from the predicted path, 10.00 u from the leg left),
  so the pass never ended, and Locomotion's direct-move braking toward the unshifted
  destination (cause B) made the ship overshoot the shifted steering point and turn
  around, indefinitely. Production before the fix: 19 rotating stalled ships (10
  Miner1, 5 Frigate, 4 Gunship); 18 had this phantom pass against an idle ship, the
  other a real conflict; none of the 25 stalled routed ships had it.
- `group_rotation_test` 7/7 (before the fix 3/7: the phantom case and both group
  checks failed). (18.2, 7.0): Frigate before 4839° turned and 232 u travelled in
  90 s, 5.9 u from its destination, still passing the idle Destroyer; after: arrives
  in 10.0 s, 252° in total, every ship arrives. (23.5, 4.0): Miner1 before 4694° and
  225 u in 90 s (last 30 s: 1622°, 73 u, 9.4 → 5.7 u); after 362° and 28.7 u in
  total, last 30 s 0°, 0 u: it waits 4.45 u from its destination yielding to the
  Frigate (both ordered, nose to nose, gap 0.01 u), the known mutual give-way stall.
- Sweep, production before / after: every ship arrives in 238 / 254 clicks; stalled
  ships 189 / 141; rotating stalled ships 19 / 1 (the real-conflict case: the
  Destroyer, itself stalled with an order, 1.41 u from Miner1's destination; Miner1
  shuttles as before, cause B); footprint overlaps 0 / 0; mean time until all
  arrive 17.06 / 16.84 s; 18 clicks no longer stall, 2 newly do (a Frigate wedged by
  two idle ships, a Destroyer and Miner1 holding each other; outcomes change with
  click shifts of a fraction of a unit). Collision contacts (Locomotion contact
  starts) 5387 / 12994 in total: clicks arriving in both 567 / 695 (one click
  4 → 156), clicks that stall in both 3309 / 11531 (ships that held a phantom pass now
  press into the ship blocking them, the contact restarting repeatedly), the 18
  fixed clicks 1493 / 310.
- Regression: the 34 earlier `game/tests` suites, `tri_dock_test` and the three scene runs, twice
  before the change and once after, compared line by line: identical apart from
  baseline variance (asteroid seeds; `shipyard_runtime_test` B10 gave asteroid 17 /
  Shipyard once, asteroid 24 / Shipyard and 25 / Station (the baseline line) in two
  repeats); error output identical; known failures navigation 35/36, obstruction
  9/12 unchanged.
- Owner acceptance: 2026-10-18, with the deviations above.

## Earlier verification (2026-10-18, UX and quality-of-life round)

- P0 baseline: all 26 suites and the three scene runs captured twice before any
  change.
- Per package (P1–P9): focused suites, then the full regression compared line by
  line against the previous accepted run and both P0 runs. Variance was counted only
  where the P0 runs differed (asteroid seeds, cost timings, `shipyard_runtime_test`
  B10, navigation map-ready frames 5 / 6, warning order). Known failures were
  unchanged: navigation 35/36 and obstruction 9/12.
- Every assertion change was owner-approved before it was applied.
- Final run (`thruster_view_test` added): all 35 suites and 3 scenes. New suites:
  - `ui_qol_test` 13/13, `held_command_test` 10/10, `mining_facing_test` 10/10;
  - `transport_persistent_test` 11/11, `transport_editor_test` 13/13;
  - `world_highlight_test` 15/15, `object_markers_test` 12/12,
	`command_cursor_test` 12/12, `thruster_view_test` 17/17.
- Migrated suites in the final run: `mining_test` 40/40, `transport_test` 40/40,
  `transport_config_test` 48/48.
- Error output was identical to the previous run in every suite.
- Owner manual acceptance of every package, then the whole round, on 2026-10-18.

## Earlier verification (2026-10-17, reusable ships and stations architecture)

- Preflight in Godot before any change (18/18): every hull nested under a `Model`
  node gives the same meshes, transforms and bounds in the ship frame, pick boxes and
  ring radius (Frigate 2.0977, Gunship 3.6623, Destroyer 6.6188, Miner 1.9422,
  Transporter 4.3122) as the ship built on it; an archetype-based Transporter had the
  starting Transporter's components, order, priorities, settings and resolved paths;
  clicks picked the intended ship; station picking unchanged; no script errors.
- Baseline: all 25 suites (24 in `game/tests` plus `tri_dock_test`) and headless runs
  of `main.tscn`, `station_docking_demo.tscn` and `tri_dock_demo.tscn`, captured twice
  before any change. Logs compared unmasked; a line counted as run-to-run variance
  only where the two baseline runs differed (asteroid seed lines, `group_test`
  microsecond timings). An authored-configuration dump (668 entries: per ship child
  order, scripts, priorities, every exported value, resolved node paths, hull parts,
  pick boxes, ring, initial pose, fuel, cargo, planning radius; per station every
  node's transform, berth and hold geometry with entry and exit legs per ship radius,
  storage and fuel, the obstacle set; the produced Miner and Transporter) was
  compared after each step.
- After each step (Transport, Mining, Warship archetypes; station scenes) and
  finally: the dump identical apart from the planned scene paths (6 ships, 2
  stations); identical to the baseline: automining, avoidance, berth, collision,
  docking, fuel, group, guided_locomotion, locomotion, mining, navigation (35/36,
  the known Destroyer redirect), obstruction (9/12, the known three), order_consistency,
  resources, route_end, selection, shipyard_runtime, silicon_shortage,
  station_docking, survey, transport_config, tri_dock and the three scene runs; error
  output identical (the expected lines in guided_locomotion and station_docking, three
  navigation warnings each in tri_dock and its demo). Planned differences only:
  `shipyard_test` 44/44 (was 37: archetype inheritance, plain instances, one variant
  per series), `refinery_test` 31/31 and `transport_test` 39/39 (one station-scene
  check reworded each). `shipyard_runtime_test` B10's asteroid and base varied in
  repeated runs (asteroids 12, 24, 25, 26; Station or Shipyard) as recorded for its
  unseeded field; every other line identical. `station_docking_demo.tscn` still
  applies `show_berths` to the migrated Station2.
- New: `reuse_test` 27/27, identical across three runs (148 s simulated); see Code.
- Owner gameplay test: accepted 2026-10-17, no issues found.

## Earlier verification (2026-10-17, Phase 4: ship production)

All 23 existing suites plus the two new ones run headless against a baseline
captured just before Phase 4 (check lines compared with numbers masked); repeated
for the closeout after acceptance with the same results:

- New: `shipyard_test` 37/37 (authoring and the approved transform; placement
  geometry as listed under Phase 4; unit scenes = Miner1, Miner2 and the
  Transporter in components, order, scripts, compared settings incl. node paths,
  hull parts and extent, collision radius, base hull scene; waiting without
  consumption or reservation, shortages after removal, cancel, atomic start with
  extra stock kept, refusals during construction, deliveries during construction;
  contention with a Transporter loading 150 iron at the Shipyard while a Transport
  Ship order waits: iron conserved every tick, never negative, consumed exactly
  once; 60 s to the tick, immediate deployment when clear, Miner4 at the marker,
  idle, full tank, station fuel untouched, Mining Scanner, one notice; registration
  and idempotent re-registration; Awaiting Deployment for 30 s with nothing consumed
  again, the clearance boundary ±0.01 u, exactly one Transporter3; two successive
  orders, unique names). `shipyard_runtime_test` 25/25 (uninterrupted loop, no
  physics switched off: part A, the existing Transporter supplies a waiting order,
  Miner3 built in 59.98 s and deployed in the same tick, initial state and resolved
  node paths = Miner1 / Transporter captured before their first tick, registration,
  normal first ticks, Transporter2 held behind Miner3 then deployed once after a
  right-click moved it, both arrive with 0 contacts; part B by real clicks: station
  selection, Order / Cancel Order and every panel state, the ship-panel transport
  set-up, selection, the blocked then released deployment, Miner3 docking at the
  Shipyard (0.00°), Undock, mining by right-click with the full hold unloaded at its
  base, Transporter2's Station → Shipyard assignment delivering 100 iron ingots,
  0 contacts, 0 refusals). Its asteroid field is not seeded, so the asteroid and
  base in check B10 vary between runs.
- Planned differences only: `transport_test` (three station instances, nine station
  boxes; station list from near Station: Station, Shipyard, Station2; the panel
  check expects four entries and picks Station2 at its new position),
  `automining_test` (four eligible bases; base selector with four entries),
  `docking_test` and `survey_test` (45 obstacles; nine station boxes), `berth_test`
  (wording, one more info line for the Shipyard; no new blocked exit sides).
- Identical to the baseline: avoidance, collision, group, locomotion, navigation
  (35/36 known), obstruction (9/12 known), guided_locomotion, selection, route_end,
  mining, fuel, order_consistency, transport_config, station_docking, resources,
  refinery, silicon_shortage, tri_dock (its three
  navigation edge warnings unchanged, order varies). Error output identical to the
  baseline (the known expected lines only); `main.tscn` 600 frames headless without
  errors; the panel's five states checked in rendered screenshots.
- Owner gameplay test of ship production: accepted 2026-10-17.

## Earlier verification (2026-10-16, Phase 3: refining)

All 23 suites run headless against a baseline captured just before Phase 3 (check
lines compared with numbers masked):

- New: `resources_test` 13/13 (108 deposits of seeds 20261014, 7, 424242 fully
  extracted: mass = reserves, every mineral within one unit of its share at every
  unit (largest 0.93), ice only from ice; same split for chunk sizes 1 / 7 / mixed
  / 999, for the Extractor at 30 / 60 / 144 Hz and for two miners sharing an
  asteroid; cargo limit 7; partial transfers conserve every resource).
  `refinery_test` 31/31 (rates, 25 ingots in 10 s at 2.5 / s, waiting without
  input, both slots on one mineral (20 in 4 s; 3 units in stock → exactly 3), reset
  on disable / mineral change with storage unchanged, independent slots, new stock,
  full storage, the real game loop; station selection by real clicks, ground click,
  Shift-click, drag, ship selection, panel rows and labels, Station without a
  refinery). `silicon_shortage_test` 10/10 (seed 20261014: Mining Scanner survey,
  asteroid 29 (Silicon 22 %, 4734 reserves) chosen; both slots wait; the
  Transporter (Silicon 30 % = 300) waits for resources; the first 1000 units mined
  hold exactly the predicted Silicon; departure only with all 300 aboard (285 s
  after mining started); delivered, refined into 300 Silicon Ingots; 100 ingots
  transported back to Station; every tick of 539 s all inventories (ingots as their
  mineral) equal what the asteroids gave; 0 contacts, 0 control refusals).
- `transport_config_test` 48/48: the 26 Phase 2.5 checks identical, plus 22 Phase 3
  checks (percent units and rounding, mixed units, capacity rejection incl. during
  loading, mixed loading with unallocated capacity, shortage waiting with cargo
  aboard, live percent edits, all at 0 %, Resume, panel row, an amount committed
  after deselection: reproduced the owner's `ship_panel.gd` null-ship error before
  the fix).
- Identical to the baseline: avoidance, berth, collision, fuel, group,
  guided_locomotion, locomotion, navigation (35/36 known), obstruction (9/12
  known), order_consistency, route_end, selection, station_docking, survey,
  tri_dock. Replaced only where the retired representation was tested: automining
  2 checks (lot composition → resources unchanged / only the asteroid's resources),
  docking 4 (oldest lots → fixed resource order; compositions → resources), mining
  6 (lots and Metal / Ice Chunks → per-resource counts and proportions, panel
  "Collected"), transport 1 (composition clause → only the delivered resources);
  test inputs moved from Metal Chunks to Iron. Error output identical to the
  baseline (the known expected lines only); `main.tscn` 600 frames headless without
  errors; panels checked once in a rendered screenshot.
- Owner gameplay test of the full production loop: accepted 2026-10-16.

## Earlier verification (2026-10-16, Phase 2.5 station docking stage 2b: station-controlled docking)

- `station_docking_test` 22/22: every class docks on both berths (3 approach
  directions; Destroyer from the front) at 0.00° and 0.000 u, still 0.000° after
  10 s (visible bow), 1.50 u from the hull and 0.30 u from the docking heads, 0
  contacts, no snaps or shared control (acceleration ≤ 1.00 u/s², turn ≤ 30 °/s²);
  exits from valid sides with the reservation released exactly at rectangle
  clearance (gap −0.004…−0.014 the tick before, +0.006…+0.015 at release); all 7
  hand-overs dock with 0 contacts, granted only with the rectangle empty and the
  corridor clear (the Destroyer's ExitB with a ship at Hold4: granted 3.1 s after
  the release, once its exit ended; closest 1.02 u); both berths independent;
  `cancel()` refused during the entry (deliberate), no movement while docked; held
  Move during exit / entry / while docked, newest wins; group MOVE: every ship at
  exactly its GroupOrders destination; panel from docked and under-control states;
  transport pause during the entry; mining cycle, transport delivery, blocked
  transfer; RouteFollower refusals + Locomotion guard 0.
- `tri_dock_test` 14/14 on the production code (its three navigation edge
  warnings unchanged); `station_docking_demo.tscn`, `tri_dock_demo.tscn` and
  `main.tscn` run headless without errors.
- Every other suite against the stage 2a logs (timings removed): identical for
  locomotion, navigation (35/36 known), avoidance, collision, obstruction (9/12
  known), group, selection, route_end, mining, survey, order_consistency,
  transport_config; planned differences only in docking (alignment 0° instead of
  8–16°, smallest station gap 1.50 u instead of 0.86, blocked-transfer and
  empty-source checks now name the controlled exit, longer times), automining /
  transport (fewer route orders, longer cycles), fuel (fuel used during the exit)
  and guided_locomotion (check 10 now expects the RouteFollower refusal). Existing
  suites migrated: Berth APIs, 0.5° bow-in tolerance, unreachable docking forced by
  moving the handover markers, reset helpers clearing the station-control phase,
  `transport_test` check 17 back to the east berth. Owner gameplay test accepted
  2026-10-16.

## Earlier verification (2026-10-15, Phase 2.5 station docking stage 2a: passive berth geometry)

- `berth_test` 12/12: berths at the arm ends with the slots' axes; authored parking
  point = production docking position (all classes, four berths, 0.000000 u);
  rectangles apart, edges outside the hull (touching the arm end, 0.00 u by
  design); parked circles 0.30 u from the visible heads; handover points 1.00 u and
  exit points ≥ 1.94 u outside the rectangle; east / west paths ≥ 19 u apart; exit
  paths ≥ 14.4 u from holds beyond two Transporter footprints; occupancy exact at the
  boundary (inside / outside the far end, side, corner); occupancy independent of
  reservations; passive (no drawing, extra meshes or run-time children). Blocked
  exit side: Station west ExitA, Destroyer only.
- `show_berths` on (scratch check): drawing works, occupancy colour, `pick()`
  ignores the drawing.
- Every other suite against the stage 1 logs: identical apart from timing values,
  console echo lines and the navigation map-ready frame count (5 or 6 between runs,
  NavigationServer timing; that arena has no stations); `station_docking_test`
  20/20, `tri_dock_test` 14/14, `main.tscn` 600 frames without errors. Owner
  accepted 2026-10-15.

## Earlier verification (2026-10-15, Phase 2.5 station docking stage 1: guided Locomotion)

- `guided_locomotion_test` 10/10 (one expected stderr error line, check 10's guard).
  Turn 150°: exact, at rest, no overshoot, rate / acceleration at the capped limits
  (Frigate and Gunship 30 °/s, 30 °/s²; Destroyer 25 °/s, 20 °/s²); moves 12 u
  forward / 3 u reverse: within 0.001 u, top 1.5 u/s (Destroyer reverse 1.36);
  same-tick order, a ship passing within 1.0 u and direct avoid() input: guided
  trajectory identical tick by tick (750 ticks); stale order not resumed for 10 s;
  contact stop at 5.005 u (contact 5.0); propulsion off holds, committed motion =
  guided travel; `place()` cancels; `move_to()` refused and counted.
- Every other suite against a baseline captured just before the change: identical
  apart from timing values (0 differing lines with timings removed; navigation
  35/36 and obstruction 9/12 known); `station_docking_test` 20/20, `tri_dock_test`
  14/14 (its three navigation edge-merge warnings unchanged); `main.tscn` 600 frames
  headless without errors. The guard error appears only in check 10. Owner accepted
  without a playtest (nothing in the game calls guided mode). Open for stage 2: a
  RouteFollower order given during guidance is taken by RouteFollower while
  Locomotion refuses it (state left behind, nothing moves); `guide()` assumes rest.

## Earlier verification (2026-10-15, Phase 2.5 transport configuration consistency)

- `transport_config_test` 26/26; against the pre-change code 17 of 26 fail (every
  defect check; the no-op, live-edit and Resume checks pass on both), with about
  10,000 stderr lines of script errors. Reproduced before the change on
  main.tscn: Unload / Load at cleared → `Docking.dock(null)`, two script errors
  per tick (`docking.gd:180`, `:190`), stuck "Requesting Dock" with cargo kept;
  Load at = Unload at → loaded and unloaded at Station2 every cycle; stations
  swapped mid-trip → 300 loaded at Station delivered back to Station; all
  requirements zero → endless empty round trips (3 trips: 21 orders, 291 station
  fuel).
- `transport_test` 39/39, `order_consistency_test` 19/19, `docking_test` 53/53:
  check lines identical to the runs just before the change; no stderr output.
  Other suites not re-run (no other file changed). Owner playtest: accepted
  2026-10-15.

## Earlier verification (2026-10-15, Phase 2.5 rejected-order consistency)

- `order_consistency_test` 19/19; against the pre-change project 14 of 19 fail
  (every refusal and the direct-move following check; the accepted-command
  checks and the direct arrival pass on both). Reproduced before the change on
  main.tscn: mining refused while traveling replaced the target (Unreachable) as
  the ship flew on to the old working point; refused while docked released
  docking with the ship left in its held slot; a refused Dock paused mining
  (Unable to Dock), or while docked elsewhere left the slot held; a MOVE without
  a route left the old order running without avoidance (routed: circling a
  frozen aim point 1.9 u away at 3.5 u/s after 30 s).
- The other 14 suites: check lines identical to the cause C logs
  (`obstruction_test` all 183 rows; known failures navigation 35/36,
  obstruction 9/12). Owner playtest: accepted 2026-10-15.

## Earlier verification (2026-10-15, cause C baseline restored)

- `game/avoidance/ship_avoidance.gd` restored to the accepted cause C version
  (SHA-256 1B7A5787…18D3A792, the copy saved by the cause B session before the
  rejoin prototype replaced it in production). It was the only file that
  differed from that session's cause C snapshot of the project.
  `obstruction_test` afterwards: identical to the cause C log (all 183 result
  rows; 9 of 12 checks pass; the 3 failures are the known open items: the two
  cause B overshoot checks and the staggered Destroyer swing).

## Earlier verification (2026-10-15, multiple stationary ships, cause C)

- `obstruction_test` 8/10: two stationary ships 14/14 passable layouts arrive
  (before 5/14: 16 u apart incl. the Destroyer going around, 4 u apart with
  opposite committed sides, staggered), 0 contacts, 0 passing-side flips, no
  limit violations; two ships across the arena gap: the Gunship holds short,
  then arrives. FAIL (cause B): MOVE just beyond a stationary ship (1 reversal
  each); staggered Destroyer swings 2 u past its destination line after the pass
  (2 along-route reversals, no reverse thrust). Scenarios 1–4 and 6 identical.
- Every other suite identical to the accepted obstruction correction apart from
  timings (navigation 35/36 known). Avoidance cost mean 11.6 µs per ship per
  tick. Owner playtest: accepted 2026-10-15.

## Earlier verification (2026-10-15, ship obstruction correction)

- `obstruction_test` 7/9: MOVE onto / in front of a stationary ship 8/8 arrive
  (5.9–11.1 s, 0 reversals, 0 contacts; before 0/8 completed, 19–34 reversals);
  close approaches past an idle Miner 75/75 (before 43/75; 0 contacts, 0
  reversals); click on a moving ship not resolved; no valid destination refused
  with the order kept; moving-ship encounters unchanged; Miner holding the arena
  gap: hold short, then arrive. FAIL (open issues below): MOVE just beyond a
  stationary ship (1 reversal each), two stationary ships 5/12.
- `route_end_test` 8/8 (no row worse: smallest gap 0.50 u, no added contacts),
  `selection_test` 41/41 (right-click over a stationary ship now checks the MOVE
  beside it). Other suites identical apart from timings: locomotion, avoidance,
  group, collision, survey, mining, docking, fuel, automining, transport;
  navigation 35/36 (known). Avoidance cost mean 10.9 → 11.9 µs per ship per
  tick. Owner playtest: accepted 2026-10-15.

## Earlier verification (2026-10-14, Phase 2 Stages 3–6)

- `transport_test` 39/39 (Stage 6: graybox and radius, Gunship profile, two
  stations, field crossing and bow-in docking at all four slots, station order,
  configuration validation, two families, departure only when met, refuel,
  timed transfers, composition, return, three unattended deliveries (1200, 19
  orders, 0 contacts), empty source waiting and resuming, edited requirements
  (removed, lowered, raised, unrequired cargo kept), destination capacity and
  waiting, manual Move / Dock pause and Resume, shared slots and queue, empty
  fuel, conservation through interruptions, miners at Station2, panel).
  Check 17 releases the west slot: with the east one the Transporter stalls
  against the undocking Frigate (reproduced with plain MOVEs). `survey_test`
  and `docking_test` now count 42 obstacles (6 station boxes);
  `automining_test` lists both stations.
- Scratch soaks (not kept): Transporter alone 30 min, 26 deliveries, 0
  contacts; with both Miners: see Known limitations.

- `automining_test` 35/35 (Stage 5: one assignment starts the cycle, extraction
  at the working point, full cargo returns, chosen base respected over a nearer
  one, nearest base otherwise, unreachable chosen base waits, slot and queue
  shared with a docked Frigate, timed unload, storage gain = cargo removed,
  composition kept, refuel before leaving, slot released, resumes at the same
  asteroid (≤ 6 orders per cycle), three full cycles from one assignment (3000
  delivered, 12 orders, 0 contacts), depletion with partial cargo then waiting
  (no orders, Resume unavailable), full station storage (waits at a hold, no
  orders, resumes), two miners conserve every unit, manual Move / Dock pause
  and keep settings, Resume, base change does not cancel, pausing while
  waiting / unloading / returning, low fuel warns only, empty fuel holds the
  assignment, panel). `mining_test`: three checks now expect the return to base
  instead of stopping at Cargo Full / Depleted (same amounts).
- Scratch probes (not kept, real game loop): three unattended cycles on
  asteroids 19, 5, 30 and 12 (12 orders, 0 contacts each); two Miners for 30
  minutes on different asteroids 19–20 cycles each, 0 contacts.

- `fuel_test` 45/45 (Stage 4: consumption = rate × committed travel for all
  five ships, identical route tick by tick with and without fuel processing,
  standing / blocked / rotating ships use none, warnings at the crossings and
  not repeated, re-armed after refueling, immobilized at zero (position,
  heading, no linear or angular velocity), order kept, right-click order
  accepted while empty without turning toward it, scanning usable, restored
  movement and turning, stranded ship counted as waiting and passed in eight
  encounters with 0 contacts (two of them stalled before the correction),
  every hull stops and resumes, refuels at 20 units/s up to capacity, station
  loses exactly what is delivered, undocking stops refueling, shared /
  insufficient / empty stock, unload / load / queue with fuel active, panel,
  hover). `mining_test`, `survey_test` and `docking_test` also switch off
  `Fuel` (they step physics manually); `docking_test` frames its right-click
  test between station and asteroid (the taller panel covered the asteroid).
- `docking_test` 53/53 (station as obstacle, docking positions outside the
  clearance and apart, the four-step prototype (two docked, third waiting at a
  hold, undock hands the slot over), bow-in docking of every class on both
  arms, FIFO order and holds, cancellation by MOVE and mining, right-click
  input, Unable to Dock, transfer_to, timed unload / load, blocked and partial
  transfers, empty source, interruption, panel, no penetration of the station
  (smallest gap 0.86 u)).
- `survey_test` 50/50 (obstacle count now 39: 36 asteroids + 3 station boxes),
  `mining_test` 39/39.
- Movement suites identical to before Stage 3 (and after Stage 4) apart from
  timings: locomotion 33/33, navigation 35/36 (known Destroyer redirect),
  avoidance PASS, selection 41/41, group 9/9, collision PASS.
- `main.tscn` and `game/scenes/movement_test.tscn`: headless runs without
  errors. Scratch checks (not kept): a working position still exists at all 36
  asteroids; rendered panel during an unload.
- Scratch soak (not kept): five ships docking and undocking continuously for
  10 simulated minutes, seeds 1–6: every run eventually deadlocked (two ships
  approaching on crossing routes, or one approaching against one leaving;
  Movement V3 mutual give-way), 1–9 docks per ship before it, 2–27 contacts.
- Owner playtests: Stages 1–6 accepted 2026-10-14.

## Known limitations

Open movement issues (owner, 2026-10-15: unresolved, not accepted):

- Direct-move overshoot past a stationary ship (cause B): on a single-leg move
  Locomotion brakes for the straight distance to the unshifted destination, which
  stays about the passing shift while beside it, so a ship ending just past a
  stationary ship overshoots about 4.4 u and backs up once. Paused (owner,
  2026-10-15); the unaccepted planned-rejoin prototype is kept in
  `experiments/planned_rejoin/`.
- Multiple stationary ships: only one shift is applied; if it does not clear a
  second stationary ship the ship yields, also where a larger shift would clear
  both (not separated in the tests). Moving or avoidance-held ships are outside
  the cause C correction. Station traffic past docked ships not soaked since.
- Order acceptance (after Phase 2.5): refusals are rare in play (a ready map
  always resolves a MOVE to the closest reachable point; Mine / Dock refusals
  need blocked geometry), so they are verified only with forced conditions. An
  order queued while the map is not ready (start-up) leaves a ship's previous
  order running unsteered until it is planned; a refused order given while
  another is still queued drops the queued one. Undock with no clear exit side
  keeps the ship docked with a notice (every berth has a clear side for every
  class in the current layouts).
  `GroupOrders.command()` ignores `order()`'s result (destinations validated by
  the same query just before). Automated callers (`Docking.dock()`,
  `MiningOperation.assign()`) unchanged: their UNABLE / UNREACHABLE states remain.
- Stationary-ship passing: if the pulled-back steering line would cut an
  obstacle, the old steering is kept and the ship may wait at the reserve.
- Own-ship prediction (accepted with the 2026-10-18 correction): it starts at the
  route position, so a ship far off its leg (pushed by a large pass) does not see
  ships beside its actual position, and once its route position has reached the end
  of a direct leg no stationary ship is an encounter any more; such a ship drives
  for its destination and can be held by collision against parked ships (stalled,
  no overlap; the main source of the higher collision contact count in stalling
  group MOVE layouts). Some ships that spun before now end in the mutual give-way
  stall instead (e.g. `group_rotation_test` (23.5, 4.0)). A ship held at a pass
  shift near its destination by a real conflict still shuttles (cause B). Routed
  moves keep the straight-distance horizon (`RouteFollower.remaining`); no phantom
  pass was seen on them (25 routed stalls in the sweep).

- Traffic stalls: ships can wait permanently with their orders (avoidance
  has no time limit or recovery). Measured in the Stage 7 investigation with
  6–12 lab ships: 2–4 stalled orders in three of five runs (mutual give-way,
  passes capped to 0 u/s among parked ships); identical with collision off.
  Collision prevents penetration but resolves no deadlock.
- Group assignment cost: 2–11 ms for three ships; groups of four 20–198 ms
  (all 24 placement orders tried whenever any departure conflict exists);
  about 52 ms in the closed-box test case.
- Movement cost (lab, all ships per tick): mean 0.21 ms with 6 ships, 0.70 ms
  with 12, p99 up to 2.05 ms; avoidance grows with the ship count (21–40 µs per
  ship per tick).
- Destroyer mid-route redirect aim line (`navigation_test` FAIL, no footprint
  overlap).
- Avoidance: late detection of ships accelerating from rest on crossing paths;
  unsafe passes possible (pass feasibility, move across not swept against the
  passed ship); pass speed cap keeps its following floor. Seen in the parked
  navigation investigation (identical with plain cause C): a Miner crossing
  15 u ahead of a Gunship toward a point on its line (test arena, Gunship
  (115, 40) → (115, −40), Miner (90, −5) → (115, −5)) passes with its steering
  point about 29.5 u off and has 3 contacts and 3 reversals (Gunship 2 contacts);
  both arrive. Not investigated.
- Collision: conservative bounding circles (Destroyer stopped up to ~5 u from
  its hull sides); ships starting overlapped stay overlapped; slow creep along
  a surface in sustained contact; the ship processed first may gain up to one
  tick of movement.
- Sphere obstacles: the full sphere radius is used whatever the ship plane's
  height; uniform scale assumed (only the X scale is read). Navigation outlines
  circles as 32-gons, so Gunship and Destroyer routes around large asteroids
  have several small bends.
- Ships added during the game are supported only through registration
  (Phase 4: `ShipSelection.register_ship()` and `movement_lab.register_ship()`, done
  by the Shipyard's `ship_deployed`); a ship added under `Ships` without it makes
  `ShipSelection.pick()` (called every frame by AsteroidHover) log a script error
  (reproduced in the Phase 4 probe). No code removes ships.
- Camera Phase A: near the bounds the clamp lets the cursor point drift (the pivot
  stays inside); a large wheel burst can tilt up to about 8° per frame (one notch
  at most 0.6°); hover updates on mouse motion, so a panel opening under a still
  cursor may not block the first wheel step (inferred, not observed); models still
  switch to markers at zoom 65 / 55 mid-zoom and the grid ramps on raw distance
  until Phase B; scenes that zoom to 40 now show about 59° instead of 45°; in
  headless runs the visible rect is 1152 × 648 (project stretch), whatever
  `root.size` is set to.
- Not available: camera focus / follow trigger (the rig's `follow()` exists);
  stall or "stuck" notices for the player; camera start zoom shows the Destroyer
  only partly in the test arena.
- The yield fallback is not a permanent test scenario (verified once).
- The playable scene still uses the lab's script name (`movement_lab.gd`).
- Stage 1: the live-cursor hover path is checked only in rendered runs
  (headless runs have no cursor); % / DATA UPLOADED labels of asteroids close on screen can
  overlap at maximum zoom; markers draw under the debug panel. Analyzed ice
  hover shows "Asteroid Ice" and reserves only (no "Ice 100%" line).
- Station-controlled docking (accepted 2026-10-16; no further movement or
  docking refinements authorized): the Destroyer's conservative circular
  collision footprint (6.2 u) keeps it out of bays its hull appears to fit (e.g.
  the 10 u tri-dock bays) and makes its exits long (radius and collision geometry
  unchanged by owner decision); at Station's west berth its ExitA is blocked by an
  asteroid, so it always leaves by ExitB (a waiting ship on that side waits until
  the exit ends). Durations are a baseline (tuning deferred). No recovery: an entry
  or exit stopped by a contact, or a ship running out of fuel mid-maneuver, stays
  where it is (an entry stopped short ends as Unable to Dock with a notice; the
  ship stays inside the rectangle, which keeps the berth physically occupied); an
  idle ship parked inside a rectangle blocks that berth with no notice (waiting
  ships stay at their holds). A command accepted for a docked ship is checked again
  after the exit and can be refused then (the ship is left at its exit point). A
  group MOVE including docked ships undocks each of them. `cancel()` on a docked
  ship (no production path) releases the request without moving it. Ships leaving
  under control are seen by other ships as idle (they give way; predicted along
  current velocity). Tri-dock experiment: its overlapping hub / back-block outlines
  log navigation edge warnings.
- Stage 3 station traffic (owner decision 2026-10-14, Option A: no serialized
  docking traffic, no Movement V3 deadlock recovery): the hand-over deadlocks are
  resolved by the controlled exit and corridor gate, but ships moving around a
  station on crossing routes under ordinary movement can still deadlock
  permanently; the player clears it with a new order. Several ships ordered off
  together from the clustered spawn can stall before reaching the station (also
  with plain MOVE). Notices share one label; docking heads are not obstacles;
  docking is bow-in only; typing in the Load amount box may also pan the camera
  (W/A/S/D read directly; not checked).
- Stage 4 fuel: a ship stops dead (one tick) when its tank empties; the tick
  that empties the tank still completes (≤ 0.08 u); a stranded ship can only
  be refuelled by docking (no rescue), so one that empties on the way stays
  there (on a docking approach: "Approaching Station"); undocking an empty
  ship from an empty station leaves it inside the rectangle (Undocking, berth
  physically occupied); warnings re-arm as
  soon as the fuel rises above a threshold (refueling happens only docked);
  refuel rate is per docked ship.
- Stage 6 transport (30-minute soaks with both Miners; every stall a
  Movement V3 one, each ship holding a single order): (1) a ship pushed
  sideways by avoidance near the end of its route stopped 3–8 u short forever
  (addressed by the RouteFollower end-of-route correction, `route_end_test`;
  not re-soaked); (2) asteroid 19 lies beside the Station ↔ Station2 route: a
  Miner working there deadlocked with the Transporter in 2 of 5 runs; (3) a
  Transporter leaving a hold for a just-freed slot could stall against the
  undocking ship (resolved by station-controlled docking; not re-soaked); (4) converging on Station's west approach, Transporter and
  Miner graze repeatedly (69 contacts in one run, no stall). Requirements can no
  longer exceed the hold through the setters (Phase 3); a hold filled by cargo
  that is not required still waits docked holding the slot ("Requirements Exceed
  Capacity"), as do over-capacity values written directly; Start always goes to the
  loading station first (also with cargo aboard, owner 2026-10-15: unchanged);
  a transport paused by a configuration edit while travelling finishes its
  current order and parks at that handover, holding or exit point, and one
  paused while docked (or during the controlled entry) stays docked until Undock;
  clearing the only requirement before setting another pauses the assignment
  (all zero at that moment); a station
  removed at run time is not handled (no code removes stations); station names
  default to "Station" / "Station2" (renamable in the panel since the UX round).
- Stage 5 automated mining: two Miners on the same asteroid stall permanently
  after about 12 cycles (one leaving full for the base meets the other
  returning near the asteroid; both wait, 2–5 contacts; Movement V3 mutual
  give-way, reproduced in two soaks). Ships left on the spawn cluster can stop
  a Miner leaving it (identical with a plain MOVE). The station's 1000 fuel
  lasts about 30 round trips to the farthest asteroids; then Miners leave
  without a full tank and strand (no production, no automatic return).
  Storage 5000 fills after about five loads (Miners then wait). A waiting Miner
  docks again for each bit of storage freed (each time through the controlled
  entry and exit).
- Stage 2: the known
  traffic-stall limitation applies near busy asteroids (separate working
  points avoid it in the tests); one Miner (1000) can deplete only asteroids
  with ≤ 1000 units (reserves 500–5000).
- Phase 3 refining (accepted 2026-10-16): mineral distribution, refining rates,
  logistics balance, models and UI polish remain subject to future iteration
  (asteroid generation, the 65 % mineral share, reserves and the rates Iron 4,
  Nickel 3, Silicon 2.5, Cobalt 2, Titanium 1.5, Gold 1 are provisional test
  parameters). Raw and ingots share station capacity and conversion is 1 for 1,
  so a refinery slot never waits for output space. No stock reservations: a
  transporter loading at the refinery station competes with the slots (since the
  UX round it waits docked, so a quota the slots keep consuming can hold the berth
  indefinitely). Unloading
  everything moves resources in the fixed order (no longer oldest first). Only
  Station2 refines; refinery settings, station selection and all stock are
  session only (no save system). Since
  Phase 4 ingots are used by the Shipyard (ship production only).
- Phase 4 ship production (accepted 2026-10-17): recipes and construction times
  are provisional prototype values. One order at a time, no queue, repeat or batch;
  only the Shipyard produces; production state, like all game state, is session
  only (no save system). Miners on "Nearest station" can unload raw minerals at the
  Shipyard (stored, never a production input; it shares the 5000 storage, so it can
  fill and block ingot deliveries with the existing Waiting for Storage). The
  deployment point is 2.01 u beyond the clearance a Destroyer at Hold3 / Hold4
  needs from a Transporter being deployed, so a ship drifting off those holds can
  hold a deployment until it moves (automatic retry). A Destroyer at Hold3 is 3.79 u
  from the map edge (the hold fits its planning radius). Produced ships add to the finite station fuel use (no fuel production) and
  to the known traffic-stall limitations; no long soak with many produced ships
  was run. The station panel's production section has no queue, camera move or
  fleet view; no presentation of construction beyond the panel.
- Ship and station architecture (accepted 2026-10-17): reuse depends on the
  gameplay-scene layout contract (see Ship and station architecture); under another
  hierarchy most lookups fail with errors, but Locomotion's collision and the
  station's ships and navigation paths fail silently. Produced ships are registered
  only by `movement_lab.gd` (another scene must do it itself). Inherited scenes
  cannot remove an archetype's components, and a variant's added components run
  last. The test arena (`movement_test.tscn`) and `obstruction_test` keep their own
  movement-only ship copies built on the hull scenes. `reuse_test` depends on
  `game/tests/docking/tri_station.tscn` (moved there from the experiment). Its
  station-fuel check asserts only that each station's stock fell where ships docked,
  not exact amounts.
- UX and quality-of-life round (accepted 2026-10-18):
  - Held commands: real right-clicks cannot produce an invalid intent, so the
    intent refusal is tested through `_order()`. A group MOVE with held ships takes
    its destinations from the unchanged `GroupOrders.assign()`, planned from every
	ship's current position (each re-checked at release). A command given while
	docked is still fully validated from the berth.
  - Mining: an out-of-fuel Miner cannot turn, so a misaligned one does not extract
	until refuelled. The tolerance is to the asteroid's centre.
  - Transport: a quota that cannot complete (e.g. a refinery consuming the same
    mineral) waits docked indefinitely, holding the berth. Congestion is not shown.
  - Inspector: at 1280×720 long names such as "Titanium Ingots" clip in editor
    rows, and the Ingots list scrolls. A wide notice can overlap the top-left debug
    toggles. Icons are generated placeholders.
  - Outlines: two highlighted objects overlapping on screen share the stencil (no
    outline between them). The asteroid hover fill is barely visible.
  - Markers: the 7 px octagon reads almost as a circle.
  - Cursors: a cached result can be up to 0.5 s old, and a group shows Move for its
    first 0.25 s on a cell. Not investigated: with an artificial 40 u no-route zone
	a group click gave RouteFollower's "No route found" instead of the group
	notice.
  - Propulsion: a teleported ship (`place()`) can flash its jets for a tick.
- Production combat (accepted 2026-10-20):
  - The Shipyard builds only the Mining Ship and the Transport Ship; warship
	production would need its own recipe (deployment and registration would apply).
  - Aggressive hostile ships acquire civilian player ships like any other player
	ship (the same hostile-faction rule); friendly fire does not exist.
  - Stations have no hull component, so they block fire but take no damage; sensors
	ignore stations (asteroids only); weapon envelopes draw asteroid shadows only.
  - Every ship's hull is 150 (the validated value; civilian ships use the same).
  - A ship destroyed during the controlled docking entry or exit stays as an inert
    hulk where it was for 2 s; its station records are released at once and the
    berth is granted again only when physically empty.
  - Placeholders: the Target cursor (OS four-arrow shape), the hostile marker's outer
	outline, the weapon placeholder meshes, the hull tint.
  - `combat_test.tscn` battle: with the player's warships Aggressive and no orders the
    hostile fleet won the headless run (an observation, no tuning).
  - The owner's editor state (`.godot/editor/editor_layout.cfg` and fold / script
	caches) still names files of the retired experiments; the editor may report once
	that it cannot reopen them (headless `--import` logs "Cannot load shader:
	res://experiments/movement_v3/…"); project files are unaffected.

## Unresolved

Undecided (owner choices): Task 01 not recorded in `CHANGELOG.md`; the
RouteFollower end-of-route correction has no `CHANGELOG.md` entry of its own. The legacy
cleanup decisions are resolved (removed 2026-10-14, see Archive).

Constraints (verified 2026-10-14): obstacles are read once at start (no
stations added later); stations cannot be under `Ships` (GroupOrders requires
`Locomotion`); docked ships count as parked for avoidance.

## Environment notes

- Git 2.55.0 (`C:\Program Files\Git\cmd\git.exe`) and GitHub CLI 2.102.0 are
  installed; `gh` is logged in as `nikosban` and pushes use SSH
  (`~\.ssh\id_ed25519`). Sessions started before an install may not see the new
  PATH.
- `godot` is not on PATH. Console executable:
  `C:\Users\Nikos\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe`
  (4.7.2.stable).
- Tests: `<godot console> --headless --path . -s res://game/tests/<name>.gd`;
  `shipyard_runtime_test`, `reuse_test` and `camera_test` with `--fixed-fps 60`
  (the first two: uninterrupted loop as fast as possible). Combat suites, every one with `--fixed-fps 60`:
  `res://game/tests/combat/<name>.gd` (`acquisition_test`, `behavior_test` (P01–P03),
  `command_test`, `e05_behavior_test`, `fleet_test` (E05), `fog_test`, `hull_test`,
  `salvo_test`, `strategic_test`, `time_test`, `turret_pitch_test`, `weapons_test`,
  `weapon_info_test`, `production_world_test`, `combat_docking_test` (real station),
  `combat_scene_test` (integrated scene)). Docking stress test:
  `res://game/tests/docking/tri_dock_test.gd`.
- Regression baseline: run every `game/tests/*_test.gd`, every
  `game/tests/combat/*_test.gd`, `game/tests/docking/tri_dock_test.gd` and the
  headless scene runs (600 frames, `--fixed-fps 60`) of `main.tscn`,
  `game/tests/docking/station_docking_demo.tscn`, `game/tests/docking/tri_dock_demo.tscn`,
  `game/tests/combat/fixtures/combat_lab.tscn` and `game/scenes/combat_test.tscn`,
  twice before a change, then compare logs line by line, treating as variance only
  lines that also differ between the two baseline runs; known failures navigation
  35/36, obstruction 9/12. No runner script is kept in the project (the commands are
  run directly).
- Playable: `main.tscn` (F5: economy, production, docking, pause, strategic zoom; no
  hostiles), `game/scenes/combat_test.tscn` (F6: integrated fleet combat),
  `game/tests/combat/fixtures/combat_lab.tscn` (F6: E01–E05, P01–P03 on the
  production code).
- Headless input injection: `push_input(event, true)` (local coordinates). In
  a `-s` script, add scenes after the first `process_frame`.
- Run a scene headless: `--headless --path . --fixed-fps 60 --quit-after N
  [scene path]`.
- Owner rule (2026-10-15): never terminate Godot processes by executable name or
  wildcard; only a process the agent launched, by its process ID. If another
  editor or game instance interferes, stop and report it (the owner's editor may
  hold unsaved work).

## Next task

None assigned: await the owner's next task. The project is under Git and pushed
to GitHub (2026-10-20); no commit or push conventions are decided beyond the
initial setup. The production combat migration and the M8 repository cleanup
(2026-10-20) are the latest accepted game work and the baseline; combat behaviour is frozen as accepted (no tuning, new mechanics, Frigate
weapons or hostile AI changes without the owner). Components, upgrades and equipment
swapping remain placeholders; the transport editor's Components tab is disabled.
Recipes, construction times, mineral distribution, refining rates, logistics
balance, models and UI polish wait for iteration by the owner. No additional
movement or docking refinements are authorized (durations and the Destroyer's
footprint wait for the owner). The movement baseline is fixed at cause C with the
direct-move prediction horizon correction; cause B, planned rejoin
(`experiments/planned_rejoin/`, paused) and parked navigation are not to be reopened
without the owner. Camera Phase A is accepted; Phase B (semantic presentation:
models, tactical markers and grid driven by `zoom_level()`) and a Global view are
anticipated but not authorized or planned. All work follows the AGENTS.md workflow
(replace this section after every task).
