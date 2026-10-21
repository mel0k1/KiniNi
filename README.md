<p align="center">
  <img src="assets/kiwi.jpg" width="220" alt="KiniNi mascot — a kiwi bird"/>
</p>

<h1 align="center">KiniNi Linux</h1>

<p align="center">
  A tiny glibc distribution built on Void Linux binary packages,<br>
  with its own runit-like init (<b>niinit</b>) and XBPS-based package manager (<b>kipki</b>).
</p>

<p align="center">
  <a href="https://github.com/mel0k1/KiniNi/actions/workflows/ci.yml"><img src="https://github.com/mel0k1/KiniNi/actions/workflows/ci.yml/badge.svg" alt="ci"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-BSD--2--Clause-blue.svg" alt="license"></a>
  <img src="https://img.shields.io/badge/language-C99-brown.svg" alt="c99">
  <img src="https://img.shields.io/badge/packages-Void%20Linux-478061.svg" alt="void">
</p>

---

## About

KiniNi is a small, opinionated Linux distribution that does not reinvent the
package ecosystem. Instead of maintaining its own repositories, it consumes
the upstream Void Linux binary repositories directly — a glibc system with
access to thousands of ready-to-install packages, no compilation required.
Every tool the user touches, however, is KiniNi's own.

The distribution is assembled by `tools/mkrootfs.sh`: it bootstraps a
`base-system` rootfs from Void mirrors, layers the KiniNi identity on top
(`os-release`, hostname, motd-ready skel), and installs the native components.
The result is a minimal, fully supervised system where the init, the package
manager, and even the terminal greeting bird are first-party code.

The name and the mascot come from the kiwi: small, nocturnal, unassuming —
and surprisingly resilient. The ASCII bird greets you on every console via
`fastfetch` (and works with any fetch tool that accepts a custom file).

## Components

| Component | What it is | Language |
|-----------|------------|----------|
| **niinit** | PID 1: three-stage boot (like runit), orphan reaping, reboot/poweroff/halt signaling | C99 |
| **niinit-sv** | Per-service supervisor: restart on crash, `finish` scripts, `down` files, runit-compatible control FIFO (`u d o t k p c h a i q 1 2 x`), `stat`/`pid` files | C99 |
| **niinit-svdir** | Watches `/etc/niinit/services`, spawns/stops supervisors as dirs appear/vanish | C99 |
| **svctl** | `status` (with uptime) / `up` / `down` / `start` / `stop` / `restart` / `once` / `pause` / `cont` / signals / `check` / `enable` / `disable`; doubles as `reboot`/`poweroff`/`halt` | C99 |
| **kipki** | Package manager on libxbps: transactions, search, orphans, holds, local log | C + libxbps |
| **mkrootfs** | Builds a rootfs from Void repositories | POSIX sh |
| **mkiso** | Builds a bootable live ISO: kernel, initramfs, isolinux, overlayfs root, disk installer on board | POSIX sh |
| **kiwi-install** | Disk installer: partitions, copies the live system, writes fstab and an extlinux bootloader | POSIX sh |

## Quick start

Building requires `gcc`, `make`, `pkg-config`, and `libxbps-devel` (Void) or
`libarchive` + `libxbps` headers elsewhere:

```sh
git clone https://github.com/mel0k1/KiniNi.git
cd KiniNi
make
```

Build a rootfs (run on Void Linux or inside `voidlinux/voidlinux`, as root):

```sh
./tools/mkrootfs.sh /mnt/kinini
# custom mirror:
./tools/mkrootfs.sh /mnt/kinini https://mirror.example.org/voidlinux/current
```

The script produces a complete tree: `base-system` packages, `niinit` as the
init, `kipki` as the package manager, getty services on tty1–tty6, and the
kiwi mascot in place for `fastfetch`.

## Live ISO

`tools/mkiso.sh` turns a rootfs into a bootable hybrid ISO — Linux kernel
6.12, a busybox initramfs that finds the medium and mounts an overlayfs root
(all writes go to a tmpfs layer, the medium stays untouched), isolinux for
BIOS boot and `isohybrid` so the same image also boots from a USB stick:

```sh
# rootfs with a kernel and fastfetch (linux metapackage is skipped,
# the LTS kernel series is pinned explicitly):
IGNORE_PKGS=linux ./tools/mkrootfs.sh /tmp/rootfs \
        https://repo-default.voidlinux.org/current base-system linux6.12 fastfetch

./tools/mkiso.sh /tmp/rootfs kinini-0.2-x86_64.iso
```

Test it in qemu:

```sh
qemu-system-x86_64 -m 1024 -cdrom kinini-0.2-x86_64.iso -boot d
```

The live session autologs in on tty1 and greets you with the bird:

<p align="center">
  <img src="assets/screenshot-fastfetch.png" width="720" alt="KiniNi live console with fastfetch and the kiwi mascot"/>
</p>

## Package management with kipki

`kipki` speaks to Void repositories through libxbps and adds a compact,
colored CLI on top — transaction preview, repository sync, orphan handling,
holds and a local transaction log:

```sh
kipki sync                  # refresh repository indexes
kipki install vim git       # resolve + preview + commit (i, add)
kipki upgrade               # update everything (up)
kipki remove vim            # remove (rm, del)
kipki autoremove            # drop orphans (auto)
kipki search terminal       # search name and description (se)
kipki info vim              # full package card
kipki list                  # installed packages (ls)
kipki files vim             # file list of an installed package
kipki owns /usr/bin/vim     # which package owns this file
kipki deps vim -f           # dependencies, -f for the full tree
kipki revdeps glibc         # what depends on it
kipki hold linux            # pin a package (unhold, held)
kipki clean                 # clear the package cache
kipki log                   # local transaction history
```

Operations on a foreign root: `kipki -r /mnt/kinini install vim`.

## Services with niinit

A service is a directory in `/etc/niinit/services` with an executable `run`
script. The supervisor restarts it if it dies, `svctl` talks to it through a
control FIFO:

```sh
# /etc/niinit/services/getty-tty1/run
#!/bin/sh
exec agetty --noclear -L tty1 38400 linux
```

Nothing is enabled behind the user's back: services live in
`/etc/niinit/services-available` until you link them in. `sshd` ships there
as an optional service — disabled by default, no host keys are generated
until you turn it on:

```sh
svctl enable sshd       # symlink from services-available, svdir picks it up in <=5s
svctl start sshd        # waits until it is actually up
```

`svctl enable/disable` manage those symlinks for you; the supervisor honors
runit conventions: a `down` file in a service dir prevents auto-start at
boot, and a `finish` script runs after each service exit with the exit code
and terminating signal as arguments.

```sh
svctl status               # overview with pid and uptime
svctl restart sshd         # up / down / start / stop / restart / once
svctl pause sshd           # SIGSTOP / SIGCONT (cont)
hup, alarm, int, quit, usr1, usr2, term  # raw signals to the service
svctl check sshd           # exit 0 only if up (waits up to -w SEC)
reboot                     # svctl in disguise: signals PID 1
poweroff                   # same story
halt                       # and even that
```

The boot itself is three stages, exactly like runit: `/etc/niinit/1` mounts
pseudo-filesystems and brings up udev and loopback, stage 2 supervises
services until shutdown, and `/etc/niinit/3` unmounts everything back.
PID 1 gives every process a grace period to exit on TERM before the final
KILL, then runs stage 3.

## Installing to disk

The live ISO ships a complete installer. Boot the ISO and run as root:

```sh
kiwi-install -d /dev/sda -y
```

It partitions the disk (one bootable ext4 root), copies the live system,
restores the standard gettys (no autologin on a real install), writes an
`/etc/fstab` and installs an offline extlinux (BIOS) bootloader from the
`syslinux` package that ships inside the ISO — no network needed. The root
password stays `kinini` until you change it (`passwd`).

Without `-y` the installer lists disks, asks for confirmation and offers to
set the root password interactively. After it finishes, remove the medium
and reboot straight into the installed system — the ISO has been verified
to install and boot in qemu end to end (install → boot → login → clean
poweroff).

> BIOS/extlinux only for now; UEFI and swap setup are on the roadmap.

## Booting

For a manual install, point any Linux kernel and bootloader (GRUB, syslinux,
EFISTUB) at the rootfs — `/sbin/init` is a symlink to `niinit`, so pass
`root=UUID=... rw` and optionally `init=/sbin/niinit` if you prefer to be
explicit. Or skip the manual assembly entirely and use `kiwi-install` from
the live ISO above.

## CI

Every push runs three Void Linux container jobs: one builds both components
and runs the supervisor test suite (up/down/restart/once, `down` files,
`finish` scripts, crash restart, start/stop/check, enable/disable, signals,
supervisor exit, plus the `svdir` spawn/stop cycle), the second builds a full
rootfs from live Void repositories and verifies the resulting tree byte by
byte, and the third builds the complete live ISO (including a static busybox
compiled from source) and uploads it as a workflow artifact.

## Mascot

The kiwi. It lives in `fetch/kiwi.txt`, is installed to
`/usr/share/kinini/kiwi.txt`, and greets every console through the default
`fastfetch` config shipped in the skel.

## License

BSD-2-Clause. See [LICENSE](LICENSE). KiniNi consumes Void Linux binary
packages but contains no Void Linux source code.

---

## Русская версия

**KiniNi** — небольшой дистрибутив Linux на glibc, который не строит
собственную экосистему пакетов, а напрямую использует бинарные репозитории
Void Linux: тысячи готовых пакетов без сборки. При этом всё, с чем работает
пользователь, — собственный код проекта.

**Состав:**

- `niinit` — свой init в стиле runit (три стадии, супервизия сервисов,
  сироты-процессы не остаются); runit-совместимый control-FIFO
  (`u d o t k p c h a i q 1 2 x`), `finish`-скрипты, `down`-файлы;
- `niinit-sv` / `niinit-svdir` / `svctl` — супервизоры и управление:
  рестарт при падении, `svctl status|up|down|start|stop|restart|once|pause|
  cont|hup|usr1|usr2|term|check|enable|disable`, `status` показывает pid и
  uptime, а также `reboot`/`poweroff`/`halt`; PID 1 даёт процессам grace-период
  на корректный выход перед KILL;
- `kipki` — пакетный менеджер на libxbps: транзакции с предпросмотром,
  поиск, сироты, hold, локальный журнал операций;
- `tools/mkrootfs.sh` — сборка корня из репозиториев Void;
- `tools/mkiso.sh` — загрузочный live-ISO: ядро 6.12, initramfs на busybox,
  isolinux + isohybrid, корень на overlayfs; sshd лежит в
  `services-available` и по умолчанию выключен;
- `tools/kiwi-install` — установщик на диск: разметка, копирование live-
  системы, fstab и extlinux (BIOS) без сети, прямо из ISO;
- маскот — птичка киви, ASCII-арт устанавливается в
  `/usr/share/kinini/kiwi.txt` и показывается `fastfetch`.

**Сборка:** `make` (нужны gcc, make, pkg-config, libxbps-devel).

**Rootfs:** `./tools/mkrootfs.sh /mnt/kinini` (на Void или в контейнере
`voidlinux/voidlinux`, от root).

**Live-ISO:** `IGNORE_PKGS=linux ./tools/mkrootfs.sh /tmp/rootfs \
https://repo-default.voidlinux.org/current base-system linux6.12 fastfetch syslinux`,
затем `./tools/mkiso.sh /tmp/rootfs kinini.iso`.

**Установка на диск:** загрузите ISO и выполните `kiwi-install -d /dev/sda -y`
— разметка, копирование системы, fstab и extlinux без сети; проверено
end-to-end в QEMU (установка → загрузка с диска → вход → чистый poweroff).

**Загрузка:** `/sbin/init` — симлинк на `niinit`, так что достаточно любого
ядра и загрузчика; либо просто установите систему через `kiwi-install`.

**Лицензия:** BSD-2-Clause.
