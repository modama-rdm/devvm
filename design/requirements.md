# devvm: requirements

Reconstructed on 2026-11-04 from the git history, the code, the README, GitHub issues
and PRs, the hallway test of 2026-11-03 and the Claude Code sessions of this
repository. Only what these sources show is listed. Sources in brackets: commit
hashes, `#n` for GitHub issues and PRs, `README`, `HT` for the hallway test (its
report, `docs/hallway/`, was deliberately not committed), `S` for a statement of the
owner in a Claude Code session, quoted where it gives a reason. How it is built and why: [spec.md](spec.md).

## Demand

devvm started on 2026-10-27 in the data management system repository ("modama") to run
its `deploy/` services and its Docker-based tests isolated from the host [e11fd57].
Within a week it became a generic tool for any git repository [8d96122], moved into a
repository of its own [65f2b6e], and gained a mode for coding agents [be74a09, #1].

The problem it solves: a devcontainer is not enough when the work needs Docker Compose
orchestration (membership in the `docker` group is effectively root), privileged
containers, kernel and system settings, system-wide installs, or a coding agent that is
free to do all of that, while its mistakes must not hit the host [README].

## Users and use scenarios

| Who | Scenario | Source |
|---|---|---|
| Developer | Works on several branches in parallel, each in a git worktree with a VM of its own; edits on the host, runs services and tests in the VM | README, 1b229a0 |
| Developer with a coding agent | Runs Claude Code in the VM with `sudo` and Docker; reviews its commits in the worktree on the host and pushes upstream from there | README, be74a09, #1 |
| Test runner (human, script, CI) | Runs the project's tests from a known VM state and gets their exit status | 5baa2a1 |
| Tester of a fixed commit | Keeps a long-lived VM that shares nothing with the host and receives commits by push | README, c3df199 |
| Host owner | Limits the size of the VMs that projects may create | 00393ca |
| devvm developer | Develops and tests devvm inside a devvm VM, with nested VMs ("self-hosting") | 9671719, #1 |

## Functional requirements

- **F1 One VM per checkout.** The VM of a checkout is named after the project and the
  branch, so that every worktree gets its own VM, disk, snapshots and host refs. Other
  VMs are addressed by name. [1b229a0, README]
- **F2 Shared checkout, like a devcontainer.** The checkout is shared read-write with
  the VM at `/workspaces/<folder>`. Files have the same owner on both sides, and commits
  made in the VM are commits in the host repository. [c3df199]
- **F3 Linked worktrees work in the VM**, including their submodules: `git status` in
  the VM behaves as on the host. [c3df199, #8]
- **F4 Further mounts** in devcontainer `mounts` syntax: host folders (read-write or
  read-only) and folders on the VM's disk ("volumes"). [c3df199]
- **F5 Unshared mode.** A VM can also share nothing and get commits by `push` from the
  host, which in turn `fetch`es the VM's branches. [8d96122, c3df199]
- **F6 Ready to use after `create`**: base image, packages, the project's provisioning,
  and a snapshot "clean" to return to. `create` reports progress and the next steps.
  [b9afb11]
- **F7 Snapshots**: create, update, list, delete, and `reset` to one; after `reset` the
  VM's clock is current. Updating exists because a snapshot can be taken too early
  ("I have now a dev2 since dev was taken too early"); listing shows names, which "would
  be relevant"; `snapshot --help` must not create a snapshot named `--help`.
  [4ba05da, cee2fca, S]
- **F8 Test runs**: `devvm test` resets to a snapshot, runs the project's test command
  with the given arguments in the checkout, and exits with its status. [5baa2a1]
- **F9 Project configuration** committed with the project: settings, a provisioning
  script and project-specific commands. [8d96122]
- **F10 Layered settings**: defaults < site < project < environment, with one exception:
  the site's size limits cannot be raised by a project. The owner: "an important point
  for a site is to set an upper limit for storage, CPU and RAM to not exhaust the host's
  resources. Defaults per site don't really make sense." Rejected: site settings over
  the project's (the earlier order), and clamping silently to the limits. [00393ca, S]
- **F11 Development setup**: `setup-dev` copies the host's git identity, installs Claude
  Code, and optionally passes a Claude Code token so that new VMs need no login. It also
  installs the kaizen plugin, the owner's "personal collection" of skills, by default,
  and the tools for terminal screenshots its hallway test needs. The token exists
  because "logging in to claude over and over again was annoying". [be74a09, fab53b7, #1, S]
- **F12 Installation and update** from a git clone, without root. [c071b47]
- **F13 Lifecycle**: list, status, start, stop (both wait until done), destroy, and
  pruning of unused base images. [4ba05da, 00393ca] Save to disk, so that a VM frees
  its RAM and CPUs and survives a host reboot, and restore; status and ls show the
  state. [user request, 2026-11-04]

## Non-functional requirements

- **N1 The VM protects the host system.** No host credentials go into the VM, except a
  Claude Code token on opt-in, and no SSH agent forwarding. Upstream pushes happen on
  the host. [README, be74a09]
- **N2 Verified SSH**, not trust-on-first-use; a re-created VM keeps its identity.
  [README]
- **N3 Reproducible VMs**: the base image is pinned to a release and checksum-verified.
  [README]
- **N4 No root for daily use**: membership in the `libvirt` group is enough. Under
  `sudo`, files and SSH still belong to the invoking user. [README, code]
- **N5 Predictable CLI** (from the hallway test): one devvm message instead of raw
  libvirt errors; commands refuse arguments they do not take; help on stdout with exit
  0; the error after a long usage text; a confirmation without a terminal fails and says
  how to skip it; devvm's own words instead of virsh's output. [HT, 00393ca, a15003f]
- **N6 Fail early and loudly**: commands on a missing VM fail at once, not after
  timeouts; failed provisioning makes `create` fail, with the end of the log; a waiting
  command says what it waits for. A missing mount source triggers "an actionable error
  message and abort", whose remedy is to "remove the setting or fix the path", at
  `create` and before libvirt starts or reverts the VM. [4ba05da, b9afb11, S]
- **N7 Few dependencies**: bash, git, libvirt, `virt-install`, `qemu-img`, and
  `virtiofsd` for shares. The tests are plain bash; `shellcheck` and `python3-yaml` are
  optional. [README]
- **N8 Tested**: lint, unit tests without VMs, and an end-to-end test with real VMs,
  also in CI on a KVM runner. New behaviour comes with tests. A test that skips in CI
  while CI reports success is a defect. The e2e test includes `setup-dev`, accepting the
  network dependency and the longer CI run. [5baa2a1, e71de32, f1ba365, S]
- **N9 Trust model**: a project's `.devvm/` is code that runs on the host and in the VM,
  like a Makefile; use devvm only in repositories you trust. [README]

## Ways of working

From the owner, in the sessions [S]:

- Ask before adding a third-party dependency ("thank you for asking before pulling
  external stuff"); the ER-C instructions say the same.
- Commit when asked. The owner pushes and merges from the host; the development VM has
  no GitHub credentials.
- Try workflow changes locally with `act` before pushing; put such hints "where users
  and agents can find it" (README, `CLAUDE.md`).

## Operating conditions

- Host: Linux x86_64 (the current state, not a requirement) [owner, 2026-11-04] with KVM and libvirt (`qemu:///system`). Debian 13 and Ubuntu 26.04
  work; live snapshots of a VM with a share fail with Ubuntu 24.04's virtiofsd and QEMU.
  [6837c1e, fd65f74]
- Guest: Debian 13 cloud image (amd64) with Docker. [e11fd57, code]
- About 100 GB of disk per VM in the pool directory. [README]
- Nested VMs work (devvm's own development and its e2e test). [9671719]

## Known limitations, accepted

- With a shared checkout, the VM protects the host system, not the shared files:
  `git clean -fdx` in the VM acts on the host checkout. [README]
- The share supports no POSIX ACLs or `chattr`; volumes cover that. [c3df199]
- Mounts are fixed when the VM is created. [README]
- `devvm ssh CMD` is plain `ssh`: no login shell, home directory, arguments re-parsed.
  [HT, README]
- Branch names that differ only in non-alphanumeric characters (`a/b`, `a-b`) map to
  the same VM name; no detection. [HT; owner, 2026-11-04]

## Open questions

See the end of [spec.md](spec.md).
