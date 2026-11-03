# devvm

Disposable libvirt/KVM virtual machines for development and tests, one per git branch
or worktree. Like a devcontainer, but a whole machine: for Docker Compose orchestration
(membership in the host's `docker` group is effectively root), privileged containers,
kernel and system settings, system-wide installs, or a coding agent that should be free
to do all of that, where its mistakes do not hit the host system.

The VMs run Debian 13 with Docker. As in a devcontainer, the checkout is shared into
the VM read-write, at `/workspaces/<folder name>`; further host folders and VM-local
volumes can be added. Alternatively, a VM gets commits pushed from the host repository
and shares nothing with the host. No host credentials are passed to the VM.

`devvm` acts on the git repository of the current directory, the *project*. A project
can carry its own settings, provisioning and commands in a `.devvm/` folder, see
[Project configuration](#project-configuration). Nothing in this folder is specific to
one project.

## Prerequisites

- KVM, libvirt, `virt-install` and `qemu-img` on the host, and `virtiofsd` for shared
  folders (Debian: `apt install qemu-system-x86 libvirt-daemon-system virtinst virtiofsd`)
- Membership in the `libvirt` group, so that `devvm` needs no `sudo`:
  `sudo usermod -aG libvirt $USER`, then log in again. `devvm setup` checks
  this and prints the command if it is missing. Running `devvm` with `sudo`
  works as well; files and SSH then still belong to the invoking user.

## Installation

`devvm.sh` finds its own files (`defaults.env`, `cloud-init/`, `guest/`) next to
itself, also through a symlink. To use it for several projects, put it on `PATH`:

```
ln -s /path/to/devvm/devvm.sh ~/.local/bin/devvm
```

The examples below use `devvm`; `./devvm.sh` works the same. Either acts on the
repository of the current directory, not the one `devvm.sh` lives in.

## Configuration

Settings are shell variables, read in this order, later ones win:

1. `defaults.env` next to `devvm.sh`: generic defaults (image, sizing, network,
   packages)
2. `.devvm/config.env` of the project, if present
3. `~/.config/devvm/site.env` of the invoking user, for all projects: `POOL_DIR` for
   images and disks, and `SSH_PUBKEY_FILE`, the key that may log in. Create it once:
   `devvm setup`
4. the environment, per command: `RAM_MB=32768 devvm create`. Under `sudo`, pass
   them after `sudo`: `sudo RAM_MB=32768 devvm create`.

`POOL_DIR` needs about 100 GB of free space per VM, must be writable by you and
traversable by the `libvirt-qemu` user; `setup` creates it or tells you how. The Debian
cloud image is pinned to a release (`IMAGE_RELEASE`) and verified against the release's
`SHA512SUMS`; bump it deliberately, test runs are then reproducible. After a bump,
`devvm prune` deletes downloaded images that no VM uses any more.

To address a VM other than the one of this checkout, give its name with `-n`:
`devvm -n myproject-test status`.

## Usage

```
devvm ls          # VMs of this project, * marks the one of this checkout; -a: all on this host
devvm create      # download and verify the base image, create and boot the VM
devvm wait        # wait for cloud-init and the project's provisioning
devvm snapshot    # snapshot "clean" as a baseline
devvm ssh         # log in
devvm reset       # revert to "clean"
devvm destroy     # remove VM, disk and snapshots; asks first, -y in scripts
```

`devvm` without arguments lists all commands, including those of the project. The VM
sits on libvirt's NAT network. Ports are reachable from the host at the VM's address
(`devvm ip`), or via SSH port forwarding (`devvm ssh -L 8080:localhost:8080`).

`reset` also sets the VM's clock, which otherwise resumes at the time of the snapshot.
It reverts the VM's disk, including volumes, but not shared folders: they are the host's
files.

## Shared folders

By default (`SHARE_WORKSPACE=1`), `create` shares the checkout of the current
directory with the VM, read-write, at `WORKSPACE_ROOT/<folder name>`
(`/workspaces/...`). Login shells start there. The VM user has the uid and gid of the
host user, so files keep their owner on both sides; files that containers create as
root or other users keep those owners on the host, as with Docker on the host. Commits
made in the VM are commits in the host repository, and `push`/`fetch` are not needed.

A linked worktree's `.git` file points to the main repository's git directory by its
absolute host path, so that directory is shared as well, at that path. git in the VM is
set up not to prune the other worktrees of the repository, whose folders it does not
see (`gc.worktreePruneExpire=never`); avoid `git worktree prune` in the VM.

Further mounts are given in `MOUNTS`, in the syntax of devcontainer's `mounts`,
separated by whitespace or newlines:

```
MOUNTS='
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
- A relative target is relative to the workspace in the VM. `${localWorkspaceFolder}`,
  `${localWorkspaceFolderBasename}`, `${containerWorkspaceFolder}` and
  `${localEnv:VAR}` are substituted; use single quotes in `config.env`.

Mounts are set up when the VM is created; to change them, re-create it. The share does
not support POSIX ACLs (`setfacl`) or `chattr`: libvirt starts virtiofsd without
`--posix-acl`, and AppArmor does not allow another binary. Put what needs them on a
volume. The guest memory is shared with virtiofsd, which libvirt sets up
(`memoryBacking` memfd); live snapshots and `reset` work as without shares.

With shared folders, the VM protects the host system, not the shared files: a
`git clean -fdx` or `rm -rf` in the VM acts on the host checkout. Commit before letting
an agent loose, or give it a worktree of its own.

## One VM per branch or worktree

The VM name defaults to `<VM_PREFIX><branch>` of the current checkout (characters other
than letters and digits become `-`, so `feature/x` gives `myproject-feature-x`; on a
detached HEAD pass `-n`). `VM_PREFIX` defaults to the repository name and a `-`.
Everything is keyed on that name: the disk and snapshots, the SSH host key file, the
`<name>/*` refs that `fetch` creates on the host. So to work on two things in parallel,
give each its own worktree and run `devvm` from there; each VM shares its worktree:

```
git worktree add -b feature-a ../myproject-feature-a origin/master
cd ../myproject-feature-a
devvm create && devvm wait && devvm snapshot   # VM myproject-feature-a
```

The VMs have different addresses on the NAT network, so the published ports of their
services do not collide. `devvm -n VM ...` addresses any other VM, and `VM_NAME=VM` in
the environment changes the default, for instance for a long-lived test VM that is not
tied to a branch. `devvm destroy` removes a VM when its branch is done; the base image
is shared and stays.

## Without a shared checkout: push and fetch

A VM created with `SHARE_WORKSPACE=0` shares no folders with the host (unless `MOUNTS`
lists some), for instance a test VM on a fixed commit. The host repository pushes to
and fetches from the checkout `~/<VM_REPO>` in the VM over SSH (`VM_REPO` defaults to
the repository name):

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
key in `POOL_DIR` and hands it to cloud-init, and all connections check against it
(`StrictHostKeyChecking=yes`). The key is kept when a VM is destroyed, so a VM
re-created under the same name has the same identity; delete `POOL_DIR/<vm>.hostkey*`
to rotate it.

Why not SSH agent forwarding (`ssh -A`), in either mode? While a forwarded session is
open, every process of the VM user can use the agent socket, including a Claude Code
session in another terminal, and with it push anywhere your key may push. Pushing
upstream from the host keeps the decision about what reaches upstream with you.

## Development with Claude Code

```
git worktree add -b my-feature ../myproject-my-feature
cd ../myproject-my-feature
devvm create && devvm wait && devvm snapshot
devvm setup-dev                   # git name/email from the host, installs Claude Code
devvm ssh                         # starts in the workspace; then: claude
```

`setup-dev` installs Claude Code with the official installer
(`https://claude.ai/install.sh`) into `~/.local/bin`. Log in on the first start of
`claude` in the VM; that login is stored in the VM only. Claude's commits appear in the
worktree on the host right away; review them there and push upstream from the host.

The VM user may use Docker and `sudo` without a password, so Claude can build and run
things freely inside the VM. Use `devvm reset` to return the VM to the clean snapshot
if something goes wrong; the shared worktree keeps its state, which git can restore.

## Project configuration

A project configures devvm in a `.devvm/` folder at its root, committed with the
project. `devvm init` creates a starting `config.env`. All files are optional:

- **`config.env`**: settings that override `defaults.env`, typically
  ```
  VM_PREFIX=myproject-
  PACKAGES="$PACKAGES build-essential python3-venv"
  RAM_MB=8192
  ```
- **`provision.sh`**: runs once in a new VM, as the VM user (with passwordless `sudo`),
  after the packages are installed, from cloud-init. `devvm wait` reports a failure,
  with the end of the cloud-init log. Install toolchains here, e.g. `uv` or `rustup`.
  It is copied into the VM when the VM is created; changes apply to new VMs.
- **`commands.sh`**: project-specific commands. It is sourced by `devvm.sh`; each
  function `project_cmd_<name>` becomes `devvm <name>` (a `-` in the command is a `_`
  in the function name), and lines appended to `PROJECT_USAGE` show up in the usage
  text. Built-in commands take precedence. The functions can use devvm's helpers and
  variables:

  | Name | |
  |---|---|
  | `vm_run SCRIPT [ARGS...]` | run a local script in the VM (passed as an argument, stdin stays free) |
  | `vm_ssh [ARGS...]` | ssh to the VM |
  | `vm_workspace` | the shared checkout's path in the VM; empty for a VM with `SHARE_WORKSPACE=0` |
  | `vm_git ARGS...` | git in the host repository with SSH set up for the VM |
  | `cmd_push [REF]`, `cmd_fetch` | as the commands |
  | `current_branch` | the branch checked out on the host, fails on a detached HEAD |
  | `as_user CMD...` | run as the invoking user, also under `sudo` |
  | `REPO_ROOT`, `PROJECT_DIR` | the host repository and its `.devvm/` |
  | `VM_NAME`, `VM_USER`, `VM_REPO` | the VM, its user and the checkout in its home |

  Keep scripts that run inside the VM next to it, e.g. in `.devvm/guest/`, and run
  them with `vm_run "$PROJECT_DIR/guest/script.sh" ARGS...`.

`config.env`, `commands.sh` and `provision.sh` are code that runs on the host or in the
VM, like a Makefile: use `devvm` only in repositories you trust.

## Upgrading from the modama-only version

devvm started in the data management system ("modama") repository. Its site settings
moved from `~/.config/modama-devvm/site.env` to `~/.config/devvm/site.env`; the old
file is still read, with a note, until you move it. Existing VMs, their pool and host
keys keep working.

New VMs share the checkout by default. VMs created before that share nothing and keep
working with `push` and `fetch`; set `SHARE_WORKSPACE=0` to create more of that kind.
