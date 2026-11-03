# devvm

Disposable libvirt/KVM virtual machines for development and tests, one per git branch
or worktree. For work that should not touch the host: services that need Docker
(membership in the host's `docker` group is effectively root), privileged containers,
system-wide installs, or a coding agent that should be free to do all of that.

The VMs run Debian 13 with Docker. The repository is pushed into the VM from the host
repository; no host folders or credentials are shared with it.

`devvm` acts on the git repository of the current directory, the *project*. A project
can carry its own settings, provisioning and commands in a `.devvm/` folder, see
[Project configuration](#project-configuration). Nothing in this folder is specific to
one project.

## Prerequisites

- KVM, libvirt, `virt-install` and `qemu-img` on the host
  (Debian: `apt install qemu-system-x86 libvirt-daemon-system virtinst`)
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

## One VM per branch or worktree

The VM name defaults to `<VM_PREFIX><branch>` of the current checkout (characters other
than letters and digits become `-`, so `feature/x` gives `myproject-feature-x`; on a
detached HEAD pass `-n`). `VM_PREFIX` defaults to the repository name and a `-`.
Everything is keyed on that name: the disk and snapshots, the SSH host key file, the
`<name>/*` refs that `fetch` creates on the host. So to work on two things in parallel,
give each its own worktree and run `devvm` from there:

```
git worktree add -b feature-a ../myproject-feature-a origin/master
cd ../myproject-feature-a
devvm create && devvm wait && devvm snapshot   # VM myproject-feature-a
devvm push
```

The VMs have different addresses on the NAT network, so the published ports of their
services do not collide. `devvm -n VM ...` addresses any other VM, and `VM_NAME=VM` in
the environment changes the default, for instance for a long-lived test VM that is not
tied to a branch. `devvm destroy` removes a VM when its branch is done; the base image
is shared and stays.

## Getting the code into the VM, and changes back out

The VM has no credentials for the upstream repository. Instead, the host repository
pushes to and fetches from the checkout `~/<VM_REPO>` in the VM over SSH (`VM_REPO`
defaults to the repository name):

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

Why not SSH agent forwarding (`ssh -A`)? While a forwarded session is open, every
process of the VM user can use the agent socket, including a Claude Code session in
another terminal, and with it push anywhere your key may push. Routing commits through
the host keeps the decision about what reaches upstream with you.

## Development with Claude Code

```
devvm create && devvm wait && devvm snapshot
devvm push                        # the branch of this worktree
devvm setup-dev                   # git name/email from the host, installs Claude Code
devvm ssh                         # then: cd <repo> && claude
```

`setup-dev` installs Claude Code with the official installer
(`https://claude.ai/install.sh`) into `~/.local/bin`. Log in on the first start of
`claude` in the VM; that login is stored in the VM only. Create a branch in the VM,
let Claude work and commit there, then use `fetch` and push from the host as above.

The VM user may use Docker and `sudo` without a password, so Claude can build and run
things freely inside the VM. Use `devvm reset` to return to the clean snapshot if
something goes wrong; this also discards the checkout, so fetch anything worth keeping
first.

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
