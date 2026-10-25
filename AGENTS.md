# AGENTS.md

Shared instructions for all coding agents (Claude Code, Codex) in this
repository. Do not create CLAUDE.md or run /init.

## Session start

1. Read this file for operating rules.
2. Read `HANDOFF.md` for current project state, accepted decisions, known
   limitations, and the next task.
3. Consult `CHANGELOG.md` and Git history only when historical context is
   relevant to the task; do not read the whole changelog every session.

## Roles

The project owner makes all design, technical, and implementation decisions.
The agent inspects, reports, asks, recommends, and implements only after
explicit approval.

## Confirmed requirements

- Engine: Godot 4.7 (declared in `project.godot`; installed version verified
  by owner).
- Language: GDScript.
- Platform: Windows desktop (initially).
- Rendering: 3D.
- Camera: perspective projection; pitch follows zoom (45° close in,
  steepening gradually toward top-down as the camera zooms out; no manual
  tilt); yaw rotation, pan, and zoom allowed.
- Navigation: strictly 2D on a fixed horizontal plane. No vertical movement
  or altitude changes.
- Units: spaceships.
- Input: mouse. Left-click selects, right-click issues a move command.
- No systems, code, documentation, configuration, or dependencies from
  previous projects.

Decisions recorded as accepted in `HANDOFF.md` are also confirmed; anything
else is undecided. Do not infer mechanics, architecture, genre, gameplay
loops, or requirements.

## Workflow (every task)

- **A. Inspection:** Read the task and the code it touches. Where relevant,
  check what interacts with it: callers, scenes and variants that instance or
  override it, signals, NodePaths, processing order, shared resources, and
  covering tests. Modify nothing. Report unexpected files and any existing
  defects or conflicting behavior found.
- **B. Findings and questions:** Report findings, risks, open questions,
  and recommendations. Separate verified facts from assumptions. Ask only
  questions that block the current task. Wait for answers; repeat until
  resolved. If nothing blocks, present the plan (C) in the same response.
  - **Editability:** If the result includes values judged by look or feel
	rather than correctness, ask: expose them in the Godot editor, give a
	manual refinement guide, or neither? If unsure, ask.
- **C. Plan:** Present scope, files to create/modify, approach, exclusions,
  affected existing behavior and regression risks, verification scope (what
  and why), acceptance criteria, and limitations in the conversation.
  STOP for explicit approval.
- **D. Implementation:** Implement only the approved plan and files. If an
  unforeseen decision arises, stop and ask. Run verification suited to the
  type of change (the relevant `game/tests` suites for gameplay code), plus
  broader regression proportional to the affected systems and risk, as
  planned. Report changes, which verification ran, results, what was not
  verified, any files Godot modified as a side effect, and remaining
  problems, plus where agreed editable values live (scene, node, property)
  or the agreed refinement guide.
- **E. User validation:** Stop. The task is not complete until the owner
  explicitly accepts it. Requested changes return to A, B, or C.
- **F. Handoff:** After acceptance, add a one-to-two-sentence `CHANGELOG.md`
  entry and update `HANDOFF.md` to reflect current state only (replace
  outdated content; do not append history). Update `AGENTS.md` only for
  approved project-wide changes. Remove temporary task documents
  only with approval. Report final state and stop.

## Rules

- A recommendation is not an approved decision.
- Behavior, visual design, architecture, scope, and substantive
  implementation choices need owner approval; routine coding details within
  an approved plan are the agent's judgment. If unsure which, ask.
- Missing requirements are not permission to invent behavior.
- Never expand scope silently or implement future tasks early.
- Prefer simple implementations; no unrequested features or abstractions.
- Never claim tests passed unless they were executed.
- Without approval: do not initialize Git, generate projects, install
  dependencies, or create configuration files or extra documents.
- Never modify files outside this project directory.
- Keep documentation concise and factual. Distinguish unknown facts from
  undecided choices.

## Strict reusability policy

All objects and systems sharing the same function and visual appearance must
use centralized reusable scenes, scripts, and resources.

- Shared implementations must have a single authoritative source.
- Differences between instances must be expressed through configuration
  rather than duplicated implementations.
- Changes to shared definitions must propagate predictably throughout the
  game.
- Per-instance adjustments must not unintentionally modify shared resources.
- Avoid unique implementations unless justified by genuine functional
  differences.
- Favor reusable production assets over one-off implementations.
- Do not introduce unnecessary abstraction layers merely to achieve reuse.

Apply this policy to all future development; do not retroactively refactor
unrelated systems.
