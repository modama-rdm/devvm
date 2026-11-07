# devvm

libvirt/KVM virtual machines for development and tests, quick to create, reset and
destroy, and as long-lived as you like. By default there is one per git branch or
worktree, set up for working in the checkout from inside the VM, also with Claude Code.
Like a devcontainer, but a whole machine: for Docker Compose orchestration
(membership in the host's `docker` group is effectively root), privileged containers,
kernel and system settings, system-wide installs, or a coding agent that should be free
to do all of that, where its mistakes do not hit the host system.

The VMs run Debian 13 with Docker. As in a devcontainer, the checkout is shared into
the VM read-write, at `/workspaces/<folder name>`; further host folders and VM-local
volumes can be added. Alternatively, a VM gets commits pushed from the host repository
and shares nothing with the host. No host credentials are passed to the VM, except a
Claude Code token if you opt in (see [Development with Claude Code](#development-with-claude-code)).

`devvm` acts on the git repository of the current directory, the *project*. A project
can carry its own settings, provisioning and commands in a `.devvm/` folder, see
[Project configuration](#project-configuration).

## Prerequisites

- KVM, libvirt, `virt-install` and `qemu-img` on the host, and `virtiofsd` for shared
  folders (Debian: `apt install qemu-system-x86 libvirt-daemon-system virtinst virtiofsd`)
- Membership in the `libvirt` group, so that `devvm` needs no `sudo`:
  `sudo usermod -aG libvirt $USER`, then log in again. `devvm setup` checks
  this and prints the command if it is missing. Running `devvm` with `sudo`
  works as well; files and SSH then still belong to the invoking user.

## Installation

devvm runs from a git clone; `install.sh` links the `devvm` command into
`~/.local/bin`:

```
git clone https://github.com/modama-rdm/devvm ~/.local/share/devvm
~/.local/share/devvm/install.sh
devvm setup
```

`devvm update` pulls the latest version into the clone (`git pull --ff-only`), and
`devvm version` shows the installed one. For a fixed version, check out a tag in the
clone. `devvm` finds its own files (`defaults.env`, `cloud-init/`, `guest/`) next to
itself, also through the symlink; it acts on the repository of the current directory,
not on its own clone.

## Configuration

Settings are shell variables named `DEVVM_*`, the same in the files and in the
environment. They are read in this order, later ones win:

1. `defaults.env` next to `devvm`: generic defaults (image, sizing, network,
   packages)
2. `~/.config/devvm/site.env` of the invoking user, for all projects:
   `DEVVM_POOL_DIR` for images and disks, `DEVVM_SSH_PUBKEY_FILE`, the key that may
   log in, and the site's limits (below). Create it once: `devvm setup`
3. `.devvm/config.env` of the project, if present
4. the environment, per command: `DEVVM_RAM_MB=32768 devvm create`. Under `sudo`, pass
   them after `sudo`: `sudo DEVVM_RAM_MB=32768 devvm create`.

A project can thus override the site's settings, and a command the project's. The
exception are the site's limits: `DEVVM_MAX_VCPUS`, `DEVVM_MAX_RAM_MB` and
`DEVVM_MAX_DISK_GB` in `site.env` (or the environment) cap the size of a VM, to keep
the host from running out of resources. `create` refuses a larger VM and says which
limit it exceeds; a project's `config.env` cannot raise them. By default there is no
limit. `create` prints the size of the VM it creates.

`DEVVM_POOL_DIR` needs about 100 GB of free space per VM, must be writable by you and
traversable by the `libvirt-qemu` user; `setup` creates it or tells you how. The Debian
cloud image is pinned to a release (`DEVVM_IMAGE_RELEASE`) and verified against the
release's `SHA512SUMS`; bump it deliberately, test runs are then reproducible. After a
bump, `devvm prune` deletes downloaded images that no VM uses any more.

To address a VM other than the one of this checkout, give its name with `-n`:
`devvm -n myproject-test status`.

## Usage

```
devvm ls          # VMs of this project, * marks the one of this checkout; -a: all on this host
devvm create      # download and verify the base image, create and boot the VM, wait for
                  # cloud-init and the project's provisioning, snapshot "clean"
devvm ssh         # log in
devvm reset       # revert to "clean"
devvm destroy     # remove VM, disk and snapshots; asks first, -y in scripts
```

`create` reports what it waits for and prints the next steps, for interactive work and
for test runs. `create --no-wait` returns once the VM is booting; then `devvm wait` and
`devvm snapshot` complete it. If your SSH key has a passphrase and is not loaded in
ssh-agent, `wait` asks for it once; `ssh-add` avoids the prompts of later commands.

`devvm` without arguments lists all commands, including those of the project. The VM
sits on libvirt's NAT network. Ports are reachable from the host at the VM's address
(`devvm ip`), or via SSH port forwarding (`devvm ssh -L 8080:localhost:8080`).

Snapshots: `devvm snapshot NAME` creates one (default name "clean"; an existing name is
refused), `snapshot -u NAME` brings an existing one up to the VM's current state,
`snapshot -l` lists them with their creation time, `snapshot -d NAME...` deletes
them. `devvm ls` shows the snapshot names per VM.

`start` boots a stopped VM and waits until SSH answers; `stop` shuts it down and waits
until it is off. `save` writes the VM's state (memory and devices) to disk and stops it,
which frees its RAM and CPUs and survives a host reboot; `start` restores it, with
running processes, and sets the guest clock. The saved state takes up to the VM's RAM
size in libvirt's directory on the host (`/var/lib/libvirt/qemu/save`); `reset`
discards it. `start` also continues a paused VM (`virsh suspend`, or libvirt pausing
it, for instance on a full disk). The words are libvirt's: its `suspend` pauses in RAM.
`status` shows state, IP, size, workspace and snapshots (`-v` adds libvirt's details).
`devvm --help` prints the commands. Commands that take no arguments refuse them, and
commands on a VM that does not exist say so.

`reset` also sets the VM's clock, which otherwise resumes at the time of the snapshot.
It reverts the VM's disk, including volumes, but not shared folders: they are the host's
files.

## Shared folders

By default (`DEVVM_SHARE_WORKSPACE=1`), `create` shares the checkout of the current
directory with the VM, read-write, at `DEVVM_WORKSPACE_ROOT/<folder name>`
(`/workspaces/...`). `devvm ssh` starts there, and so does `devvm ssh CMD`, unless the
arguments begin with an ssh option (`devvm ssh -L ...`). `devvm ssh CMD` is no login
shell, so it runs without `~/.local/bin` on the `PATH`. The VM user has the uid and gid of the
host user, so files keep their owner on both sides; files that containers create as
root or other users keep those owners on the host, as with Docker on the host. Commits
made in the VM are commits in the host repository, and `push`/`fetch` are not needed.

A linked worktree's `.git` file points to the main repository's git directory by its
absolute host path, so that directory is shared as well, at that path. Its submodules
point to it by a relative path, so the VM also gets a symlink to it where that path leads
from the checkout in the VM (`/workspaces/<main checkout>/.git` for a worktree next to the
main checkout); nothing is created where something exists already. git in the VM is
set up not to prune the other worktrees of the repository, whose folders it does not
see (`gc.worktreePruneExpire=never`); avoid `git worktree prune` in the VM.

Further mounts are given in `DEVVM_MOUNTS`, in the syntax of devcontainer's `mounts`,
separated by whitespace or newlines:

```
DEVVM_MOUNTS='
source=${localEnv:HOME}/datasets,target=/data,readonly
source=build,target=build,type=volume
'
```

- `type=bind` (default): a host folder, shared with virtiofs; `readonly` is enforced
  by the host. A relative source is relative to the checkout.
- `type=volume`: a folder on the VM's disk, named by `source`, mounted at the target.
  Over subfolders of the workspace, volumes keep build output, caches and container
  data in the VM: faster, not mixed with the host's builds, and with full file system
  semantics.
- A volume over a subfolder of the workspace needs its mount point in the workspace:
  with a shared checkout, `create` leaves an empty folder of that name in the checkout
  on the host.
- A relative target is relative to the workspace in the VM. `${localWorkspaceFolder}`,
  `${localWorkspaceFolderBasename}`, `${containerWorkspaceFolder}` and
  `${localEnv:VAR}` are substituted; use single quotes in `config.env`.

Mounts are set up when the VM is created; to change them, re-create it. `create` refuses
a mount whose source folder does not exist and says where `DEVVM_MOUNTS` is set. A shared
folder removed on the host later (a mount source, or the checkout itself) stays mounted
in a running VM, but empty and not writable; `status` flags it, and `start`, `reset` and
`test` refuse until the folder is back or the VM is re-created without it. libvirt
could not start the VM's virtiofsd without the folder, and a failed `reset` could leave
the VM off with an orphaned virtiofsd that blocks every later start. The share does
not support POSIX ACLs (`setfacl`) or `chattr`: libvirt starts virtiofsd without
`--posix-acl`, and AppArmor does not allow another binary. Put what needs them on a
volume. The guest memory is shared with virtiofsd, which libvirt sets up
(`memoryBacking` memfd); live snapshots and `reset` work as without shares, given a
recent virtiofsd and QEMU: with older ones (Ubuntu 24.04's) QEMU refuses a live snapshot
of a VM with a share ("vhost-user backend lacks VHOST_USER_PROTOCOL_F_LOG_SHMFD").
Debian 13 and Ubuntu 26.04 work.

With shared folders, the VM protects the host system, not the shared files: a
`git clean -fdx` or `rm -rf` in the VM acts on the host checkout. Commit before letting
an agent loose, or give it a worktree of its own.

## VM names: one per branch or worktree by default

A VM lives until you destroy it: for an afternoon, or for months across many branches.
What devvm makes easy is creating, resetting and removing them, so that a separate VM
for an experiment or a parallel branch costs little. Only the default name follows the
branch; how long a VM lives is up to you.

The VM name defaults to `<DEVVM_VM_PREFIX><branch>` of the current checkout (characters
other than letters and digits become `-`, so `feature/x` gives `myproject-feature-x`; on
a detached HEAD pass `-n`). `DEVVM_VM_PREFIX` defaults to the repository name and a `-`.
Everything is keyed on that name: the disk and snapshots, the SSH host key file, the
`<name>/*` refs that `fetch` creates on the host. So to work on two things in parallel,
give each its own worktree and run `devvm` from there; each VM shares its worktree:

```
git worktree add -b feature-a ../myproject-feature-a origin/master
cd ../myproject-feature-a
devvm create                                   # VM myproject-feature-a
```

The VMs have different addresses on the NAT network, so the published ports of their
services do not collide. `devvm -n VM ...` addresses any other VM; `devvm use VM` sets
the VM of a checkout (next section), and `DEVVM_VM_NAME=VM` in the environment that of
a shell or script. `devvm destroy` removes a VM when you are done with it; the base
image is shared and stays.

### Long-lived VMs

A VM with a shared checkout is tied to the checkout's folder, not to a branch: after a
`git switch` in that folder, the VM sees the files of the new branch, and its
installed tools, containers, volumes and Claude Code login stay. What changes is the
default name: on the new branch, `devvm` looks for a VM named after it, says that there
is none, and offers to create one or to keep the existing one with `devvm use`:

```
git switch -c feature-b             # in the checkout whose VM is myproject-feature-a
devvm use myproject-feature-a       # this checkout keeps that VM, on any branch
devvm status                        # VM: myproject-feature-a (set with devvm use)
```

For a VM meant to live long from the start, give it a name that is not a branch:
`devvm use myproject-dev`, then `devvm create`. `devvm use` without a name shows the
checkout's VM, `devvm use --clear` returns to the one named after the branch. The name
is kept in the checkout's git directory (`.git/devvm-vm`, in a linked worktree
`.git/worktrees/<name>/devvm-vm`): per worktree, never committed, and removed with the
worktree. `-n` and `DEVVM_VM_NAME` in the environment take precedence over it. Not in
`.devvm/config.env`: that file belongs to the project, and every checkout would share
the VM.

For a VM that lives long:

- `devvm snapshot -u clean` (or another name) records a state worth returning to, for
  instance after installing tools; `reset` returns to it.
- `devvm save` frees its RAM and CPUs between sessions, with its running processes
  kept for the next `start`; `stop` shuts it down.
- What `create` sets up stays as it was then: packages, `provision.sh`, mounts and
  size. Later changes to those in `.devvm/` reach the VM by hand or through a new VM;
  the project's commands and `DEVVM_TEST_COMMAND` apply on every call.

## Without a shared checkout: push and fetch

A VM created with `DEVVM_SHARE_WORKSPACE=0` shares no folders with the host (unless
`DEVVM_MOUNTS` lists some), for instance a test VM on a fixed commit. The host
repository pushes to and fetches from the checkout `~/<DEVVM_VM_REPO>` in the VM over
SSH (`DEVVM_VM_REPO` defaults to the repository name):

```
devvm push                        # the branch checked out here -> same branch in the VM
devvm push origin/master          # after git fetch: upstream master -> branch master
devvm fetch                       # VM branches -> <vm-name>/* on the host
git push origin myproject-feature-a/my-feature:my-feature   # on the host, then open the MR
```

The first push creates the checkout on that branch and initialises the submodules from
their URLs. Later pushes of other branches only create them; check them out in the VM
as usual. Pushing to the branch that is checked out in the VM updates its working tree
if that is clean, and is refused otherwise; a push that is not a fast-forward is refused
as well.

SSH to the VM is verified, not trust-on-first-use: `create` generates an ed25519 host
key in `DEVVM_POOL_DIR` and hands it to cloud-init, and all connections check against it
(`StrictHostKeyChecking=yes`). The key is kept when a VM is destroyed, so a VM
re-created under the same name has the same identity; delete
`DEVVM_POOL_DIR/<vm>.hostkey*` to rotate it.

Why not SSH agent forwarding (`ssh -A`), in either mode? While a forwarded session is
open, every process of the VM user can use the agent socket, including a Claude Code
session in another terminal, and with it push anywhere your key may push. Pushing
upstream from the host keeps the decision about what reaches upstream with you.

## Development with Claude Code

```
git worktree add -b my-feature ../myproject-my-feature
cd ../myproject-my-feature
devvm create
devvm setup-dev                   # git name/email from the host, installs Claude Code
devvm snapshot dev                # optional: a baseline with Claude Code
devvm ssh                         # starts in the workspace; then: claude
```

`setup-dev` installs the Debian packages `xvfb`, `xterm`, `xdotool` and `imagemagick`,
which let an agent drive a terminal and judge it by screenshots (the `hallway-test`
skill of the kaizen plugin), and Claude Code with the official installer
(`https://claude.ai/install.sh`) into `~/.local/bin`, then the `kaizen` plugin (skills for
requirements, walk-throughs, hallway tests and debriefs) from the `uellue/skills`
marketplace, at user scope. It also installs the two companions kaizen recommends:
[Matt Pocock's skills](https://github.com/mattpocock/skills) (`mattpocock-skills`, at
user scope; its `code-review` skill shares the name of Claude Code's built-in
`/code-review`, call it as `/mattpocock-skills:code-review`) and
[OpenSpec](https://github.com/Fission-AI/OpenSpec) (`openspec`, from npm), with
Node.js 22 LTS from nodejs.org (checksum verified) in `~/.local`, since Debian's is too
old. OpenSpec's telemetry is turned off with `OPENSPEC_TELEMETRY=0` in `~/.bashrc`.
`setup-dev` does not run `openspec init` in your project. Log in on the first start of
`claude` in the VM; that login is stored in the VM only. Claude's commits appear in the
worktree on the host right away; review them there and push upstream from the host.

To skip the login in every new VM, let `setup-dev` pass a token. Create one on the host
with `claude setup-token` (it needs a Claude subscription and is valid for a long time),
save it in a file only you can read, and name that file in `~/.config/devvm/site.env`:

```
claude setup-token                        # prints the token
(umask 077; cat > ~/.config/devvm/claude-token)   # paste it, then Ctrl-D
echo "DEVVM_CLAUDE_TOKEN_FILE=$HOME/.config/devvm/claude-token" >> ~/.config/devvm/site.env
```

`setup-dev` sends the token over SSH's stdin, stores it in the VM as
`~/.config/devvm/claude-oauth-token` and exports it as `CLAUDE_CODE_OAUTH_TOKEN` from
`~/.bashrc`. Everything that runs as the VM user, including Claude itself and what it
starts, can read the token and use your Claude account with it, also while the VM
holds it in snapshots; it cannot use your host's SSH keys or upstream repositories. Use
a token of its own for devvm, so that you can revoke it separately. Your own login on
the host is not copied: host and VM would then share one session.

The VM user may use Docker and `sudo` without a password, so Claude can build and run
things freely inside the VM. Use `devvm reset dev` (or `devvm reset` for the clean
snapshot, without Claude Code) to return the VM to a known state if something goes
wrong; the shared worktree keeps its state, which git can restore.

## Test runs

`devvm test` runs the project's tests in its VM, from the clean snapshot. Configure the
command once, in `.devvm/config.env`:

```
DEVVM_TEST_COMMAND="uv run pytest"
```

```
devvm test                        # reset to "clean", run the tests in the checkout
devvm test -k slow tests/unit     # arguments are passed on, quoted as given
devvm test --no-reset ...         # without the reset, for quick iterations
devvm test --snapshot dev ...     # from another snapshot
devvm test --no-reset -- --x      # after --, devvm's own options go to the tests
```

For a VM without a shared checkout, `test` always pushes the branch first, also with
`--no-reset`, so that the tests run the code as it is on the host; a rejected push stops
the run.

`DEVVM_TEST_COMMAND` is a shell command; it runs in the checkout in the VM, in a login
shell, so the `PATH` is that of an interactive `devvm ssh` (e.g. with `~/.local/bin`
from provisioning), unlike `devvm ssh CMD`. `devvm test` exits with the command's status, for use in scripts and CI.

With a shared checkout, the tests see the working tree of the host, uncommitted changes
included. In a VM created with `DEVVM_SHARE_WORKSPACE=0`, `devvm test` first pushes the
branch checked out on the host (as `devvm push`) and runs the tests in
`~/<DEVVM_VM_REPO>`.

A project that defines its own `project_cmd_test` in `.devvm/commands.sh` keeps it:
`devvm test` then calls that function with all arguments instead.

## Project configuration

A project configures devvm in a `.devvm/` folder at its root, committed with the
project. `devvm init` creates a starting `config.env`. All files are optional:

- **`config.env`**: settings that override `defaults.env`, typically
  ```
  DEVVM_VM_PREFIX=myproject-
  DEVVM_PACKAGES="$DEVVM_PACKAGES build-essential python3-venv"
  DEVVM_RAM_MB=8192
  DEVVM_TEST_COMMAND="uv run pytest"
  ```
- **`provision.sh`**: runs once in a new VM, as the VM user (with passwordless `sudo`),
  after the packages are installed, from cloud-init. `devvm create` reports a failure,
  with the end of the cloud-init log. Install toolchains here, e.g. `uv` or `rustup`.
  It is copied into the VM when the VM is created; changes apply to new VMs.
- **`commands.sh`**: project-specific commands, for what `devvm test` (see
  [Test runs](#test-runs)) does not cover. It is sourced by `devvm`; each
  function `project_cmd_<name>` becomes `devvm <name>` (a `-` in the command is a `_`
  in the function name), and lines appended to `PROJECT_USAGE` show up in the usage
  text. Built-in commands take precedence, except over `project_cmd_test`. The functions can use devvm's helpers and
  variables:

  | Name | |
  |---|---|
  | `vm_run SCRIPT [ARGS...]` | run a local script in the VM (passed as an argument, stdin stays free) |
  | `vm_ssh [ARGS...]` | ssh to the VM |
  | `vm_workspace` | the shared checkout's path in the VM; empty for a VM with `DEVVM_SHARE_WORKSPACE=0` |
  | `vm_git ARGS...` | git in the host repository with SSH set up for the VM |
  | `cmd_push [REF]`, `cmd_fetch` | as the commands |
  | `current_branch` | the branch checked out on the host, fails on a detached HEAD |
  | `as_user CMD...` | run as the invoking user, also under `sudo` |
  | `REPO_ROOT`, `PROJECT_DIR` | the host repository and its `.devvm/` |
  | `DEVVM_VM_NAME`, `DEVVM_VM_USER`, `DEVVM_VM_REPO` | the VM, its user and the checkout in its home |

  Keep scripts that run inside the VM next to it, e.g. in `.devvm/guest/`, and run
  them with `vm_run "$PROJECT_DIR/guest/script.sh" ARGS...`.

`config.env`, `commands.sh` and `provision.sh` are code that runs on the host or in the
VM, like a Makefile: use `devvm` only in repositories you trust.

## Upgrading from the version in the data management system repository

devvm started in the data management system ("modama") repository. Since then:

- All settings are named `DEVVM_<old name>`, e.g. `DEVVM_RAM_MB`, in the files as in
  the environment, and so are the variables available to project commands
  (`DEVVM_VM_NAME`, `DEVVM_VM_REPO`, ...). Rename them in `.devvm/config.env` and
  `.devvm/commands.sh`.
- The site settings are in `~/.config/devvm/site.env` (formerly
  `~/.config/modama-devvm/site.env`); run `devvm setup` to create it, with the same
  pool directory and key as before. Existing VMs, their pool and host keys keep working.

New VMs share the checkout by default. VMs created before that share nothing and keep
working with `push` and `fetch`; set `DEVVM_SHARE_WORKSPACE=0` to create more of that
kind.

The command is `devvm` from this repository (installed with `install.sh`) instead of
`devvm/devvm.sh` in the project.

## Developing devvm

devvm's own tests are in `tests/`, plain bash without further dependencies;
`shellcheck` for linting and `python3-yaml` for some unit tests are optional (tests
that need them are skipped):

```
tests/run.sh                  # lint and unit tests, seconds, no VM needed
tests/run.sh e2e              # real VMs: create, ssh, test, reset, destroy; minutes
tests/run.sh all
tests/run.sh tests/unit/mounts.sh
```

The unit tests source `devvm`, which then defines its functions and settings without
running a command, in a throw-away HOME and repository, and replace libvirt and SSH by
stubs. The end-to-end tests need KVM and libvirt; they create a small VM of a throw-away
project, with a fresh key, in your `DEVVM_POOL_DIR` (or `DEVVM_E2E_POOL_DIR`), and
remove it afterwards.

CI (`.github/workflows/tests.yml`) runs lint and unit tests, and the e2e test on a
runner with KVM. To try the workflow before pushing, use
[act](https://github.com/nektos/act) (needs Docker; install a release binary and check
its checksum):

```
act -j lint-unit -P ubuntu-24.04=catthehacker/ubuntu:act-24.04
```

Two limits. `act` runs as root, and devvm skips its libvirt-group check for root, but the
GitHub runner is an ordinary user outside that group: to see what it sees, run the unit
tests as such a user, e.g. `sudo -u nobody -H bash -c 'unset SUDO_USER SUDO_UID SUDO_GID;
cd REPO && tests/run.sh unit'`. And the `e2e` job needs KVM and libvirt, so run it with
`tests/run.sh e2e` in a devvm host (below), not in `act`.

devvm is developed in its own VM: `.devvm/` makes the VM a devvm host with nested KVM.
`devvm create` in this repository, then `devvm test [all|e2e|...]` runs the tests there.
