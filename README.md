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
| **niinit** | PID 1: three-stage boot (like runit), orphan reaping, reboot/poweroff signaling | C99 |
| **niinit-sv** | Per-service supervisor: restart on crash, control FIFO, `stat`/`pid` files | C99 |
| **niinit-svdir** | Watches `/etc/niinit/services`, spawns/stops supervisors as dirs appear/vanish | C99 |
| **svctl** | `status` / `up` / `down` / `restart` / `kill`; doubles as `reboot`/`poweroff` | C99 |
| **kipki** | Package manager on libxbps: transactions, search, orphans, holds, local log | C + libxbps |
| **mkrootfs** | Builds a bootable rootfs from Void repositories | POSIX sh |

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

```sh
svctl status               # overview of all services
svctl restart sshd         # up / down / restart / kill
reboot                     # svctl in disguise: signals PID 1
poweroff                   # same story
```

The boot itself is three stages, exactly like runit: `/etc/niinit/1` mounts
pseudo-filesystems and brings up udev and loopback, stage 2 supervises
services until shutdown, and `/etc/niinit/3` unmounts everything back.

## Booting

KiniNi ships no kernel or bootloader of its own — point any Linux kernel and
bootloader (GRUB, syslinux, EFISTUB) at the rootfs:

```
root=UUID=... rw init=/sbin/niinit
```

## CI

Every push runs two Void Linux container jobs: one builds both components and
smoke-tests the supervisor lifecycle (up → down → up through the control
FIFO), the other builds a full rootfs from live Void repositories and verifies
the resulting tree byte by byte.

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
  сироты-процессы не остаются);
- `niinit-sv` / `niinit-svdir` / `svctl` — супервизоры и управление:
  рестарт при падении, control-FIFO, `svctl status|up|down|restart`,
  а также `reboot`/`poweroff`;
- `kipki` — пакетный менеджер на libxbps: транзакции с предпросмотром,
  поиск, сироты, hold, локальный журнал операций;
- `tools/mkrootfs.sh` — сборка корня из репозиториев Void;
- маскот — птичка киви, ASCII-арт устанавливается в
  `/usr/share/kinini/kiwi.txt` и показывается `fastfetch`.

**Сборка:** `make` (нужны gcc, make, pkg-config, libxbps-devel).

**Rootfs:** `./tools/mkrootfs.sh /mnt/kinini` (на Void или в контейнере
`voidlinux/voidlinux`, от root).

**Загрузка:** ядро и загрузчик любые, системе нужен только
`init=/sbin/niinit`.

**Лицензия:** BSD-2-Clause.
