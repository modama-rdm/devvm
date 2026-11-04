# devvm: specification

What devvm does and why it does it that way, as of 2026-11-04. Reconstructed from the same sources as [requirements.md](requirements.md),
with the same brackets. User-facing details (all options, examples) are in the
[README](../README.md); this file is the contract and the reasons.

## Components

| File | Role |
|---|---|
| `devvm` | The whole tool: one bash script, `set -euo pipefail`. Sourced instead of run, it defines its functions and settings without running a command (for the unit tests). |
| `defaults.env` | Generic defaults of all `DEVVM_*` settings, commented. |
| `cloud-init/*.tmpl` | user-data and meta-data with `@PLACEHOLDERS@`; devvm appends the parts that come from settings. |
| `guest/setup-dev.sh` | Runs in the VM for `setup-dev`. |
| `install.sh` | Links `devvm` into `~/.local/bin` from a clone. |
| `.devvm/` | devvm's own project configuration: its VM is a devvm host (nested KVM). |
| `tests/` | `run.sh`, `lint.sh`, `lib.sh`, `unit/*.sh`, `e2e/lifecycle.sh`. |

devvm finds its own files next to the resolved script (also through a symlink on
`PATH`), and acts on the git repository of the current directory, the *project*.
[8d96122, c071b47]

## Settings

Shell variables `DEVVM_*`, with the same names in the files and in the environment
[c735692]: a generic name like `PACKAGES` in the caller's environment overrode
settings by accident.

Order, later wins: `defaults.env` < `~/.config/devvm/site.env` (per user, all projects,
written by `devvm setup`) < `<project>/.devvm/config.env` < environment. The site's
`DEVVM_MAX_VCPUS/RAM_MB/DISK_GB` are restored after the project file is read, so a
project cannot raise them; `create` refuses a larger VM. [00393ca]

Implementation: the exported environment is saved (`export -p`), the files are sourced,
then the saved environment is re-applied.

Main settings: `VM_PREFIX` (default `<main repository name>-`), `VM_NAME`, `VCPUS`,
`RAM_MB`, `DISK_GB`, `POOL_DIR`, `SSH_PUBKEY_FILE`, `LIBVIRT_URI`, `NETWORK`,
`IMAGE_*`, `PACKAGES`, `VM_USER` (`dev`), `SHARE_WORKSPACE` (1), `WORKSPACE_ROOT`
(`/workspaces`), `VM_REPO`, `MOUNTS`, `CLAUDE_TOKEN_FILE`, `TEST_COMMAND`. See
`defaults.env`.

## VM identity and naming

- Name: `-n VM`, else `DEVVM_VM_NAME`, else `<prefix><branch>` with every character
  other than `[A-Za-z0-9]` replaced by `-`. A detached HEAD or no repository gives no
  default; only usage and `ls` work then [4ba05da]: a fixed fallback such as
  `modama-HEAD` would be shared by every detached checkout.
- The prefix comes from the *main* repository's name, also in a linked worktree, so
  that all worktrees of a project list together.
- The name must match `^[A-Za-z0-9][A-Za-z0-9_.-]*$`: it is a libvirt domain, a file
  stem, a hostname and an SSH host alias.
- Everything is keyed on the name: `<pool>/<name>.qcow2`, `<name>.hostkey`,
  `<name>.known_hosts`, the libvirt snapshots, and the host refs `<name>/*` of `fetch`.

## create

1. Refuse if the VM or its disk exists, the public key is unreadable, or a size limit
   is exceeded. Print the size.
2. Plan the mounts (below); shares need `virtiofsd` on the host.
3. Download the Debian cloud image of `DEVVM_IMAGE_RELEASE` into `<pool>/base/` once,
   verified against the release's `SHA512SUMS`. A bump is deliberate; `prune` deletes
   images that no disk and no setting uses.
4. Generate the VM's ed25519 host key in the pool, unless it exists (kept across
   re-creates), and write `known_hosts` from it.
5. Disk: a qcow2 overlay on the base image.
6. `virt-install --import` with `--cpu host-passthrough`, virtio disk and network on
   libvirt's NAT network, `--cloud-init` with the rendered user-data, `--graphics none`
   but `--video virtio` (without a display device the Debian kernel resets after GRUB),
   and for shares `memoryBacking` memfd/shared plus one virtiofs filesystem per share.
7. Record the shared workspace (`host`, `guest`) in libvirt metadata
   (`https://devvm.invalid/1`); commands later read it to tell shared from unshared VMs.
8. `wait`, then snapshot `clean`, then print the next steps for interactive work and
   for test runs. `--no-wait` stops after booting. [b9afb11]

### cloud-init

- The user `DEVVM_VM_USER` gets the host user's uid and gid (raised to 1000 if lower,
  since system ids exist in the image), groups `sudo`, `docker`, `adm`, passwordless
  `sudo`, and the public key. `adm` lets it read the cloud-init log. [c3df199, df5847c]
- The primary group is created in `bootcmd` with the host gid, or any gid if taken.
- `packages` from `DEVVM_PACKAGES` (default: git, curl, Docker, Compose, buildx).
- `ssh_keys`: the pre-generated host key. No other secrets. [README]
- `runcmd`: a generated `setup.sh` (as root), Docker enabled, then the project's
  `provision.sh` as the VM user. A failing `provision.sh` fails cloud-init. [8d96122]

### setup.sh (generated, runs as root in the VM)

- Mounts each virtiofs share and each volume (a bind mount of
  `/var/lib/devvm/volumes/<name>`), recorded in `/etc/fstab` with `nofail`. Mount
  points are created as the VM user where possible, so that those inside a share belong
  to the host user. A volume inside the workspace thus leaves an empty folder in the
  host checkout. [c3df199, HT]
- For a shared linked worktree (git links, `guest_git_links`; only where nothing exists
  yet):
  - a symlink from the checkout's host path to `/workspaces/<folder>`, since the
    repository records the worktree by its host path; without it git considers the
    worktree prunable;
  - a symlink to the main repository's git directory where its relative path from the
    checkout leads (e.g. `/workspaces/<main>/.git`), since submodules of a worktree
    link to their module directories by relative paths [#8, PR #9].
- `gc.worktreePruneExpire=never` for the VM user: the VM does not see the host's other
  worktrees, and `git gc` would prune them from the shared repository.
- The host's git `user.name` and `user.email`; login shells `cd` into the workspace.

## Shared folders and mounts

- `DEVVM_SHARE_WORKSPACE=1` (default): the checkout at `DEVVM_WORKSPACE_ROOT/<folder
  name>`. A linked worktree also gets the main repository's git directory shared at its
  host path, because the worktree's `.git` file names it by absolute path. [c3df199]
- `DEVVM_MOUNTS`: devcontainer `mounts` syntax (`source`, `target`, `type=bind|volume`,
  `readonly`; `consistency` ignored), separated by whitespace. Relative sources are
  relative to the checkout, relative targets to the workspace in the VM;
  `${localWorkspaceFolder}`, `${localWorkspaceFolderBasename}`,
  `${containerWorkspaceFolder}`, `${localEnv:VAR}` are substituted.
- Paths must be absolute and free of whitespace, `,`, quotes, `\`, `&`, `<`, `>`:
  they end up in fstab, libvirt XML and option strings.
- Why devcontainer conventions: users know them, and the README promises "like a
  devcontainer". [c3df199]
- A missing source folder is an error with a way out. At `create`: the normalised path,
  where `DEVVM_MOUNTS` is set (environment, `config.env`, `site.env` or defaults) and
  "create the folder, or fix or remove the mount", before anything is created. Later
  (the folder or the checkout removed on the host): `start` and `reset` (so also `test`)
  check the sources in the VM's libvirt definition first and refuse, naming the folder
  and the remedies (restore it, or re-create the VM without it, since shares are fixed
  at create); `status` shows a `Missing:` line. Why: with a missing source libvirt
  cannot start the share's virtiofsd; a failed live revert left the VM off and an
  orphaned root virtiofsd holding its log file, so every later start failed until root
  killed it (libvirt 11.3.0, virtiofsd 1.13.2). A running VM keeps the mount, empty and
  not writable; nothing can prevent that. [S, 2026-11-04]

## SSH and remote execution

- All connections use `UserKnownHostsFile=<pool>/<name>.known_hosts`,
  `HostKeyAlias=<name>`, `StrictHostKeyChecking=yes`: verified from the first
  connection and independent of the DHCP address. [README]
- The address comes from libvirt's DHCP lease.
- `vm_run SCRIPT ARGS` sends a local script as an argument of `bash -c`, not on stdin:
  a command in it that reads stdin (`docker compose exec` without `-T`) would swallow
  the rest of the script. [39a94bc]
- No agent forwarding: while a forwarded session is open, every process of the VM user,
  including an agent in another terminal, could push anywhere the key may push. [README]

## wait

Probes SSH with `BatchMode` and a short timeout. "Permission denied" means sshd is up
but the key needs interaction (passphrase); the probe then stops and the rest runs in
one ordinary session that asks once. A host key mismatch fails at once. Then
`cloud-init status --wait`; on error, the last 30 lines of the log and failure. Reports
elapsed times. Finally ejects the cloud-init CD-ROM: virt-install deletes the ISO, and
a snapshot that references it cannot be reverted. [b9afb11, 4ba05da]

`start` uses the same probe, with fewer tries, and counts "Permission denied" as up,
with a hint to `ssh-add`; it used to retry until its timeout and fail, though the VM was
up. A shut-off VM or a host key mismatch also fails at once there. [user report, 2026-11-04]

## Snapshots and reset

- libvirt internal snapshots, `--atomic`, of the running VM (live), including volumes,
  not shares. Names starting with `-` are refused.
- `snapshot NAME` refuses an existing name; `-u` replaces one (delete, then create;
  libvirt cannot overwrite), `-l` lists, `-d NAME...` deletes, all-or-nothing on missing
  names. [cee2fca]
- `snapshot -l` and `status` list name and creation time, not virsh's table as it is:
  its State column is the VM's state when the snapshot was taken, "running" for every
  live snapshot, which read as if several VMs were running. [user report, 2026-11-04]
- `reset [NAME]` reverts to `clean` or NAME, running, then sets the guest clock from the
  host, since it resumes at snapshot time. [4ba05da]

## test

`devvm test [--no-reset] [--snapshot S] [--] [ARGS...]` [5baa2a1]:
reset (unless `--no-reset`); for an unshared VM push the host's branch (also with
`--no-reset`, so that the tests run the code as on the host; see open question 1); then
`bash -lc 'cd <checkout> && $DEVVM_TEST_COMMAND <ARGS quoted>'`, so the `PATH` is that
of an interactive login. Exit status is the tests'. A project's own `project_cmd_test`
takes precedence, since it predates the built-in command.

## push and fetch (unshared VMs only)

- `push [REF]`: default the host's current branch; `origin/X` becomes `X`. The ref is
  checked on the host first, so a typo leaves no empty repository in the VM. The VM
  checkout `~/<VM_REPO>` is created with `receive.denyCurrentBranch=updateInstead`;
  until it has a commit it counts as new, and the push that gives it one also
  initialises the submodules from their URLs, so an interrupted first push is
  completed by the next. [4ba05da]
- `fetch`: the VM's branches into `refs/remotes/<vm>/*` on the host.
- Commits travel through the host repository, so the VM never holds upstream
  credentials. Both refuse on a shared VM.

## Project configuration (`.devvm/`)

- `config.env`: settings. `devvm init` writes a starting one.
- `provision.sh`: copied into the VM at create, runs once as the VM user from
  cloud-init.
- `commands.sh`: sourced; `project_cmd_<name>` becomes `devvm <name>` (`-` in the
  command is `_` in the function); lines appended to `PROJECT_USAGE` appear in the
  usage. Built-in commands win, except over `project_cmd_test`. Helpers available:
  `vm_run`, `vm_ssh`, `vm_workspace`, `vm_git`, `cmd_push`, `cmd_fetch`,
  `current_branch`, `as_user`, `REPO_ROOT`, `PROJECT_DIR`, `DEVVM_VM_*`. [8d96122, 39a94bc]

## setup-dev and the Claude Code token

- Copies the host's git name and email, installs `xvfb xterm xdotool imagemagick` if
  missing, Claude Code with the official installer into `~/.local/bin`, and the
  `kaizen` plugin from the `uellue/skills` marketplace at user scope; each step is
  skipped when done. [fab53b7]
- With `DEVVM_CLAUDE_TOKEN_FILE` (from `claude setup-token` on the host; a warning if
  the file is readable by others), the token goes over SSH's stdin, not as an argument,
  which process listings show. In the VM: `~/.config/devvm/claude-oauth-token`, mode
  600, exported as `CLAUDE_CODE_OAUTH_TOKEN` from the *top* of `.bashrc`, before its
  early return, so non-interactive shells get it too. Why: logging in in every new VM
  was annoying [#1]. The host's own login is not copied: host and VM would share one
  session; a separate token can be revoked separately. [be74a09]

## Privileges

- Without root, the user must be in the `libvirt` group; otherwise devvm prints how to
  join it (or to log in again if the group was added after login). Usage text needs no
  group.
- Under `sudo`, only libvirt runs as root; files, downloads, git and SSH run as
  `SUDO_USER` (`as_user`).
- `PATH` is reset to the system directories: `virt-install` needs the system Python
  (conda environments on `PATH` broke it).

## CLI conventions

From the hallway test [HT, 00393ca]: commands without arguments refuse any;
`-h/--help/help` print the usage on stdout with exit 0; an unknown command prints the
usage, then the error, exit 1; one message for a missing VM (`require_vm`); `stop` and
`start` wait (until off, until SSH answers); `status` is a short summary, `-v` adds
`virsh dominfo`; confirmations (`destroy`, `setup` overwrite) fail without a terminal
and say how to skip them (`-y`). [a15003f]

## Install and update

`install.sh` links `devvm` into `~/.local/bin`, from the clone it runs in or from a
fresh clone in `~/.local/share/devvm`; it never replaces a non-symlink. `devvm update`
is `git pull --ff-only` in the clone, `devvm version` is `git describe`. The command is
named for what it does, not for its language (`devvm`, not `devvm.sh`). [c071b47]

## Tests and CI

- `tests/run.sh [lint|unit|e2e|all|FILE]`; default lint and unit. Each test function
  runs in a subshell with a fresh `HOME`, site settings, key and repository; exit 77
  skips. `run_tests` must be the last line of a test file (`lint.sh` checks it): once
  it sat in the middle and the tests after it never ran. [00393ca]
- Unit tests source `devvm` and stub libvirt and SSH. The e2e test creates a small real
  VM of a throw-away project and goes through the lifecycle, including `setup-dev`.
- CI (GitHub Actions): lint and unit on ubuntu-24.04; e2e on ubuntu-26.04 with KVM
  (24.04's virtiofsd and QEMU cannot snapshot a VM with a share), where
  `DEVVM_E2E_REQUIRED=1` turns skips into failures [6837c1e, f1ba365]. Actions are
  pinned to major tags (`actions/checkout@v7`), not commit SHAs. Try the workflow
  locally with `act`; it runs as root, so also run the unit tests as a non-root user
  outside the `libvirt` group, as on the GitHub runner. [1fa963e, de906d8]
- devvm is developed in its own VM: `.devvm/provision.sh` adds libvirt, moves the
  nested default network to a free `192.168.N.0/24`, creates a key and a small-VM
  `site.env`, and links `devvm` from the shared checkout. [9671719]

## Open questions

Things the sources do not settle; the answers belong here once decided.

1. `test --no-reset` on an unshared VM: the owner accepted the hallway lean "skip the
   push unless asked", but the code and README still push, because the VM would
   otherwise run stale code. Which holds? [HT, S]
2. `reset` to a snapshot taken while the VM was off ends with a running VM, and a
   failure to set the clock is only a warning. Intended? [HT]
3. Should `create` check that `git status` works in the VM, as #8 suggests?
4. Help per command (`devvm snapshot --help` prints the whole usage) was deferred
   ("scoped help later"). [S]
5. Should the kaizen plugin in `setup-dev` have an opt-out? Offered, not decided. [S]
