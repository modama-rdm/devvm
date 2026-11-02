# Development VM

A libvirt/KVM virtual machine for working on the services in `deploy/`, and for tests
that run Docker containers, without giving them (or a coding agent) access to the
host. Membership in the host's `docker` group is effectively root, and `smbdrop` runs
privileged, so the test deployment is better run inside a VM than on a workstation.

The VM runs Debian 13 with Docker. The repository is pushed into the VM from the host
repository; no host folders or credentials are shared with it.

There are two typical uses, ideally in separate VMs: developing with Claude Code
inside the VM, and testing the whole deployment. Each git worktree gets its own VM, see
[One VM per branch](#one-vm-per-branch-or-worktree).

## Prerequisites

- KVM, libvirt, `virt-install` and `qemu-img` on the host
  (Debian: `apt install qemu-system-x86 libvirt-daemon-system virtinst`)
- Membership in the `libvirt` group, so that `devvm.sh` needs no `sudo`:
  `sudo usermod -aG libvirt $USER`, then log in again. `./devvm.sh setup` checks
  this and prints the command if it is missing. Running `devvm.sh` with `sudo`
  works as well; files and SSH then still belong to the invoking user.

## Configuration

Generic settings (image, sizing, network) are in `defaults.env`. The two
site-specific ones, `POOL_DIR` for images and disks and `SSH_PUBKEY_FILE` for the key
that may log in, live in `~/.config/modama-devvm/site.env` of the invoking user, so
one file serves every worktree. Create it once:

```
./devvm.sh setup
```

Any variable from either file can be overridden per command in the environment, for
example `RAM_MB=32768 ./devvm.sh create`. Under `sudo`, pass them after `sudo`:
`sudo RAM_MB=32768 ./devvm.sh create`. To address a VM other than the one of this
checkout, give its name with `-n`: `./devvm.sh -n modama-test status`.

`POOL_DIR` needs about 100 GB of free space per VM, must be writable by you and
traversable by the `libvirt-qemu` user; `setup` creates it or tells you how. The Debian cloud image is pinned to a release (`IMAGE_RELEASE`)
and verified against the release's `SHA512SUMS`; bump it deliberately, test runs are
then reproducible. After a bump, `./devvm.sh prune` deletes downloaded images that no
VM uses any more.

## Usage

```
./devvm.sh ls          # VMs of this project, * marks the one of this checkout; -a: all on this host
./devvm.sh create      # download and verify the base image, create and boot the VM
./devvm.sh wait        # wait for cloud-init, check Docker
./devvm.sh snapshot    # snapshot "clean" as a baseline
./devvm.sh ssh         # log in
./devvm.sh reset       # revert to "clean"
./devvm.sh destroy     # remove VM, disk and snapshots
```

`./devvm.sh` without arguments lists all commands. The VM sits on libvirt's NAT
network. Ports of the test deployment are reachable from the host at the VM's address
(`./devvm.sh ip`), or via SSH port forwarding (`./devvm.sh ssh -L 1890:localhost:1890`).

## One VM per branch or worktree

The VM name defaults to `modama-<branch>` of the checkout that `devvm.sh` runs from
(characters other than letters and digits become `-`, so `feature/x` gives
`modama-feature-x`; on a detached HEAD pass `-n`), and everything is keyed on that
name: the disk and snapshots, the SSH host key file,
the checkout inside the VM and the `<name>/*` refs that `fetch` creates on the host.
So to work on two things in parallel, give each its own worktree and run `devvm.sh`
from there:

```
git worktree add -b feature-a ../dms-feature-a origin/master
cd ../dms-feature-a/devvm
./devvm.sh create && ./devvm.sh wait && ./devvm.sh snapshot   # VM modama-feature-a
./devvm.sh push feature-a
```

The two VMs have different addresses on the NAT network, so the published ports of
their test deployments do not collide. `./devvm.sh -n VM ...` addresses any other
VM, and `VM_NAME=VM` in the environment changes the default, for instance for a long-lived test VM that is not tied to a branch.
`./devvm.sh destroy` removes a VM when its branch is done; the base image is shared
and stays.

## Getting the code into the VM, and changes back out

The VM has no credentials for the upstream repository. Instead, the host repository
(the one containing this `devvm/` folder) pushes to and fetches from the checkout
`~/data-management-system` in the VM over SSH:

```
./devvm.sh push                        # the branch checked out here -> same branch in the VM
./devvm.sh push origin/master          # after git fetch: upstream master -> branch master
./devvm.sh push origin/some-branch     # -> branch some-branch in the VM
./devvm.sh fetch                       # VM branches -> <vm-name>/* on the host
git push origin modama-feature-a/my-feature:my-feature   # on the host, then open the MR
```

The first push creates the checkout on that branch and initialises the submodules from
their public URLs. Later pushes of other branches only create them; check them out in
the VM as usual. Pushing to the branch that is checked out in the VM updates its working tree if
that is clean, and is refused otherwise; a push that is not a fast-forward is refused
as well.

SSH to the VM is verified, not trust-on-first-use: `create` generates an ed25519 host
key in `POOL_DIR` and hands it to cloud-init, and all connections check against it
(`StrictHostKeyChecking=yes`). The key is kept when a VM is destroyed, so a VM
re-created under the same name has the same identity; delete `POOL_DIR/<vm>.hostkey*`
to rotate it.

VMs created before host keys were introduced have no `<vm>.hostkey` in `POOL_DIR` and
cannot be reached by the current script; destroy and re-create them.

Why not SSH agent forwarding (`ssh -A`)? While a forwarded session is open, every
process of the VM user can use the agent socket, including a Claude Code session in
another terminal, and with it push anywhere your key may push. Routing commits through
the host keeps the decision about what reaches upstream with you.

## Development with Claude Code

```
./devvm.sh create && ./devvm.sh wait && ./devvm.sh snapshot
./devvm.sh push                        # the branch of this worktree
./devvm.sh setup-dev                   # git name/email from the host, installs Claude Code
./devvm.sh ssh                         # then: cd data-management-system && claude
```

`setup-dev` installs Claude Code with the official installer
(`https://claude.ai/install.sh`) into `~/.local/bin`. Log in on the first start of
`claude` in the VM; that login is stored in the VM only. Create a branch in the VM,
let Claude work and commit there, then use `fetch` and push from the host as above.

The VM user may use Docker and `sudo` without a password, so Claude can build and run
the deployment freely inside the VM. Use `./devvm.sh reset` to return to the clean
snapshot if something goes wrong; this also discards the checkout, so fetch anything
worth keeping first.

## Testing the deployment

```
./devvm.sh -n modama-test create && ./devvm.sh -n modama-test wait
./devvm.sh -n modama-test test-deploy                     # the branch checked out here
./devvm.sh -n modama-test test-deploy origin/master       # after git fetch: upstream master
./devvm.sh -n modama-test test-deploy my-branch --clean   # another local branch, from scratch
```

`test-deploy` pushes the given ref, checks out that commit in the VM and runs
`guest/test-deployment.sh` there, which

1. creates throwaway secrets in `/var/local/data-mgmt/` if they are missing
   (`mgmt_secret.py`, `modama_session_secret`, `externalstorage_pw`,
   `nextcloud-config-secret.json`, a minimal LDAP-free `sssd.conf`) and a test CA with
   the `smbdrop` server certificate,
2. prepares `deploy/testfolder/`,
3. builds all images with `docker compose build` and starts the test deployment with
   `docker compose up --wait`, which returns once all containers run,
4. waits until Nextcloud answers on `http://127.0.0.1:1890/nextcloud/status.php` and
   exits non-zero if the containers or Nextcloud do not come up within the timeouts.

The deployment keeps running afterwards for inspection. `--clean` removes containers,
volumes, test folders and secrets before starting. The first run builds everything and
takes a while. There is no LDAP in the VM, so logins (Nextcloud, WebDAV) are not
covered; the test checks that every service starts and answers.

The guest scripts always come from the host's `devvm/` folder, the deployment from the
commit under test.
