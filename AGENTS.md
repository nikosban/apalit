# AGENTS.md

Shared instructions for all coding agents (Claude Code, Codex) in this
repository. Do not create CLAUDE.md or run /init.

## Session start

1. Read this file.
2. Read `CHANGELOG.md` for project history.
3. Read `HANDOFF.md` for current state and the next task.

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
- Units: spaceships. A cube is the initial prototype.
- Input: mouse. Left-click selects, right-click issues a move command.
- No systems, code, documentation, configuration, or dependencies from
  previous projects.

Anything not listed here is undecided. Do not infer mechanics, architecture,
genre, gameplay loops, or requirements.

## Workflow (every task)

- **A. Inspection:** Read the task and relevant files. Modify nothing.
  Report unexpected files.
- **B. Findings and questions:** Report findings, risks, open questions,
  and recommendations. Separate verified facts from assumptions. Ask only
  questions that block the current task. Wait for answers; repeat until
  resolved.
- **C. Plan:** Present scope, files to create/modify, approach, exclusions,
  verification, acceptance criteria, and limitations in the conversation.
  STOP for explicit approval.
- **D. Implementation:** Implement only the approved plan and files. If an
  unforeseen decision arises, stop and ask. Run available verification.
  Report changes, results, and remaining problems.
- **E. User validation:** Stop. The task is not complete until the owner
  explicitly accepts it. Requested changes return to A, B, or C.
- **F. Handoff:** After acceptance, add a one-to-two-sentence `CHANGELOG.md`
  entry and update `HANDOFF.md` to reflect current state only (replace
  outdated content; do not append history). Update `AGENTS.md` only for
  approved project-wide changes. Remove temporary task documents
  only with approval. Report final state and stop.

## Rules

- A recommendation is not an approved decision.
- Never choose between alternatives without owner approval.
- Missing requirements are not permission to invent behavior.
- Never expand scope silently or implement future tasks early.
- Prefer simple implementations; no unrequested features or abstractions.
- Never claim tests passed unless they were executed.
- Without approval: do not initialize Git, generate projects, install
  dependencies, or create configuration files or extra documents.
- Never modify files outside this project directory.
- Keep documentation concise and factual. Distinguish unknown facts from
  undecided choices.
