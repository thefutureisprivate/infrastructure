# Silverblue Workstation

The local workstation profile uses Ansible to reconcile the small part of a
Fedora Silverblue installation that should be host-owned. It follows the Atomic
Desktop split: Flatpak for graphical applications, Toolbx for development
tools, and RPM layering only for software that must integrate with or administer
the host.

## Managed state

The profile owns:

- `/etc/rpm-ostreed.conf` and `rpm-ostreed-automatic.timer`, using staged
  updates by default. Updates become active at the next user-initiated reboot.
- Explicitly present or absent RPM package-layer requests and selected base
  package removals.
- The official OpenTofu RPM repository, with both repository and package
  signature verification rooted in checksum-pinned signing keys.
- The checksum-pinned upstream SOPS binary in `/usr/local/bin`, because Fedora
  and the enabled Trivalent repository do not package SOPS.
- A workstation-specific hardening baseline derived from the
  [PrivSec desktop Linux guide](https://privsec.dev/posts/linux/desktop-linux-hardening/):
  kernel arguments and sysctls, unused-module denial, SELinux enforcement,
  randomized network identities, authenticated time, resolver privacy, login
  throttling, restrictive file defaults, disabled removable-media autorun, and
  a deny-by-default host firewall.
- Per-user Flatpak remotes and applications for the user running Ansible.

It does not automatically reboot, prune undeclared package layers or Flatpaks,
reset undeclared base overrides, or put development toolchains into the
immutable host image.

The committed workstation inventory declares the intended package layers and
explicit removals in `Ansible/inventory/group_vars/silverblue.yml`. Present and
absent package lists must not overlap. Existing applications are system-wide
Flatpaks, so the per-user Flatpak declarations are intentionally empty and the
profile leaves those applications untouched. If per-user entries are added,
existing remotes and applications must match their declared source; otherwise
the play stops instead of silently changing a trust boundary.

The base-removal declaration is tailored to this bare-metal workstation. It
keeps printing and scanning, BlueZ, Wi-Fi firmware, NetworkManager WireGuard and
SMB client support, Podman, the KVM/libvirt host stack, and the `make`,
`ansible-core`, and OpenTofu administration tools. The Fedora `opentofu` layer
is atomically replaced with the current upstream `tofu` package. SOPS is
installed from its exact upstream release with a committed SHA-256 digest. The
profile removes unused VM guest integration, inbound remote-access services,
PPP and non-WireGuard VPN clients, accessibility applications,
non-German/English input data, local GNOME help and stock backgrounds. Fedora's
ModemManager and MBIM/QMI libraries remain because its NetworkManager Bluetooth
plugin hard-depends on the WWAN stack.
German and English glibc locale packages are installed atomically with removal
of the all-language package so the derived deployment is never built without a
glibc locale provider.

Firmware remains intentionally broad because the inventory does not identify
the Wi-Fi/Bluetooth chipset. Base overrides only change the generated
deployment: the underlying OSTree repository and rollback deployment retain
shared objects, so installed RPM sizes are not a promise of equivalent disk
space reclamation.

## Hardening profile

The host firewall drops unsolicited inbound traffic and exposes no SSH server.
It permits DHCPv6 plus mDNS, IPP, and WS-Discovery client traffic so network
printers and scanners can still be discovered. Bluetooth, WireGuard, outbound
SSH and SMB, KVM/libvirt, and rootless Podman remain usable. NetworkManager
randomizes Wi-Fi scan addresses and Wi-Fi/Ethernet addresses on connection; a
network that uses MAC admission or captive-portal identity can override the
managed default in that individual connection profile.

The kernel policy enables IOMMU isolation and the relevant Intel or AMD KVM
mitigations based on gathered CPU facts. It does not disable SMT or 32-bit
execution, because those are compatibility and performance choices rather than
safe unattended defaults. The module denylist deliberately retains Bluetooth,
CIFS, NFS, USB storage, TUN/TAP, bridges, vhost, KVM, and common local/removable
filesystems. Loose reverse-path filtering is used because strict filtering can
break WireGuard, libvirt, and container routing. Unprivileged user namespaces,
`io_uring`, and `binfmt_misc` remain enabled for rootless Podman and VM/container
workflows.

Chrony requires a quorum of three time sources and prefers five NTS-authenticated
servers, with one unauthenticated IP source retained only to bootstrap time when
DNS or certificate validation is not yet usable. `systemd-resolved` disables
LLMNR, opportunistically uses DNS-over-TLS, and validates DNSSEC when the active
network or VPN resolver supports it. GNOME autorun and automount are disabled
and locked; removable media can still be mounted explicitly. New files from
login shells and the systemd user manager use a private `0077` umask.

Some recommendations cannot be made safe from a generic running-system role:

- full-disk encryption and Secure Boot enrollment are audited and reported but
  remain installation/firmware operations;
- Secureblue rebasing, its hardened allocator, custom signing keys, and UKIs
  are not imported into a standard Fedora Silverblue trust boundary;
- blanket Flatpak overrides are not applied because the installed mail, photo,
  scanner, password-manager, and development applications require different
  network, device, audio, and filesystem permissions;
- USBGuard policy generation is not automated because a policy generated
  without every required keyboard, Bluetooth adapter, printer, and scanner can
  lock out those devices;
- `/home` or `/var` `noexec`, global `/proc`/`/sys` hiding, XWayland removal,
  SUID deletion, and disabling user namespaces are omitted because they break
  Flatpak, Toolbx/Podman, libvirt, or currently installed applications.

The `silverblue-check` preview reports staged kernel arguments as well as the
disk-encryption and Secure Boot audit boundaries. Kernel arguments, blocked
modules, systemd user-manager defaults, and layered-package changes take full
effect after a reboot. MAC randomization applies when a connection is next
activated; the playbook does not interrupt the active link.

## Reconcile

On a new workstation, seed the tools needed to run their own declarative
profile, then reboot into that deployment:

```bash
sudo rpm-ostree install --idempotent ansible-core make
systemctl reboot
```

This is a one-time bootstrap. The first reconciliation configures the official
OpenTofu repository and installs its `tofu` package; subsequent reconciliation
owns all three administration layers. Preview the local changes:

```bash
make silverblue-check
```

Apply the reviewed state:

```bash
make silverblue-apply
```

Both targets request the local sudo password because the rpm-ostree policy and
package layers are system state. Flatpaks remain in the invoking user's
installation. If the play reports a pending deployment, reboot when convenient
and run `make silverblue-check` again.
