# devvm

Bash tool for disposable libvirt/KVM development VMs, see README.md. Tests: `tests/run.sh`
(lint and unit, seconds), `tests/run.sh e2e` (real nested VMs, minutes); details under
"Developing devvm" in the README.

What devvm must do and why it is built as it is: `design/requirements.md` and
`design/spec.md`, each item with its source. Read them before changing behaviour; when a
change adds or alters a requirement or a decision, update them in the same commit, and
record open questions at the end of `spec.md` instead of guessing.

Before pushing a change to `.github/workflows/`, or when CI fails where the tests pass
locally, try the workflow with `act` (README, "Developing devvm": the command and its two
limits: it runs as root, and it cannot run the e2e job). To see what the GitHub runner
sees, run `tests/run.sh unit` as a non-root user outside the libvirt group.

`run_tests` must be the last line of every test file (`tests/lint.sh` checks it).

## Working rules

From the kaizen plugin's standing instructions (uellue/skills README).

- Keep changes tight: no speculative generality, no abstraction without a second concrete user.
- Follow established formats, patterns and tools; before writing a mechanism a library
  implements, search for the library; ask before adding a third-party dependency (N7 in
  `design/requirements.md` lists the current ones).
- Every mechanism, option or output detail names its source, as the items in
  `design/requirements.md` and `design/spec.md` do: a requirement, a decision, or the
  owner's request. A request is a source: record it there in the same commit (see above).
  Without any source, leave it out and suggest it as a next step.
- Earlier notes and brainstorming are options to evaluate, not requirements.
- When a request names a specific case, say whether you read it as the whole ask or as an
  example of a rule, or ask. What stays unanswered goes to the open questions in `spec.md`.
- A request phrased as a question ("should we ...?", "could X be a good place?", "we can
  proceed now?") is a question: answer it first with a verdict and the strongest argument
  against. Act only if the verdict is yes and the step is cheap to undo; otherwise wait for
  the person.
- Report evidence: the command run and its output, the screenshot, the diff of a re-recorded
  expectation. Report "clean" only from the commands CI runs (`tests/run.sh lint unit`;
  `DEVVM_E2E_REQUIRED=1 tests/run.sh unit e2e`, where a missing prerequisite fails instead
  of skipping), with the number of skipped tests. A local run is not CI's: here the user is
  in the libvirt group, the lint-unit runner is not (see above for its view).
- A change beyond a few hundred lines gets a review by an agent that did not write it before
  it is handed over.
- At every hand-over that follows accepted leans, list each one: implemented as agreed, or
  deviated and why.
- Do not build for cases nobody has hit; when an unwanted outcome appears, fix it with its
  concrete example and a test. Security and safety are the exception: think them through
  before building.
- Use absolute paths and self-contained shell commands; edit files with the Edit tool, not
  with inline replacement scripts.
- Never delete through a shell variable that could be empty or unset, in commands you run
  and in code you write (`"${var:?}"`); quote variables, and prefer not creating what you
  would have to delete.
- A vulnerability found while testing is reported first and stops the plan; the fix path is
  the proposed next step.
- Anything that leaves the repository or a session for people and agents at once (issues,
  merge requests, upstream comments, hand-over notes, reports) is split: a short part for
  people first (what is wrong or decided, what to do, one example or the list of actions),
  then the part for agents (context, specifics, commands, what was verified), as a separate
  block, section or file, marked as reviewed by a person or attached unreviewed. Committed
  documentation counts as reviewed by its commit and is not restructured unasked.
