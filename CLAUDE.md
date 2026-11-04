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
