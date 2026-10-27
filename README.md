# Development VM

A libvirt/KVM virtual machine for working on the services in `deploy/`, and for tests
that run Docker containers, without giving them (or a coding agent) access to the
host. Membership in the host's `docker` group is effectively root, and `smbdrop` runs
privileged, so the test deployment is better run inside a VM than on a workstation.

The VM runs Debian 13 with Docker. The repository is cloned inside the VM; no host
folders or credentials are shared with it.

## Prerequisites

- KVM, libvirt, `virt-install` and `qemu-img` on the host
  (Debian: `apt install qemu-system-x86 libvirt-daemon-system virtinst`)
- Membership in the `libvirt` group (`sudo usermod -aG libvirt $USER`, then log in
  again), or run `devvm.sh` with `sudo`

## Configuration

Generic settings (image, sizing, network) are in `defaults.env`. Site-specific
settings go in `site.env`, which is not committed:

```
cp site.env.example site.env
$EDITOR site.env
```

`POOL_DIR` holds the base image and the VM disk, so it needs about 100 GB of free
space. Variables set in the environment take precedence over both files, for example
`RAM_MB=32768 ./devvm.sh create`.

## Usage

```
./devvm.sh create      # download and verify the base image, create and boot the VM
./devvm.sh wait        # wait for cloud-init, check Docker
./devvm.sh snapshot    # snapshot "clean" as a baseline
./devvm.sh ssh         # log in
./devvm.sh reset       # revert to "clean"
./devvm.sh destroy     # remove VM, disk and snapshots
```

Inside the VM, clone the repository with submodules (see the top-level `README.md`)
and log in to the image registry with `docker login` if you want to pull images rather
than build them with `deploy/build.sh`. Prepare `deploy/testfolder/` and the secrets in
`/var/local/data-mgmt/` as described in the top-level `README.md`.

The VM sits on libvirt's NAT network. Ports of the test deployment are reachable from
the host at the VM's address (`./devvm.sh ip`), or via SSH port forwarding.
