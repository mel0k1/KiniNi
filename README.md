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
| **niinit-svdir** | Watches `/etc/niinit/services`, spawns/stops supervisors as dirs appear/vanish; honors `deps` files — a service is spawned only when its dependencies are up (blocked state is visible in `stat`) | C99 |
| **svctl** | `status` (with uptime) / `up` / `down` / `start` / `stop` / `restart` / `once` / `pause` / `cont` / signals / `check` / `enable` / `disable`; doubles as `reboot`/`poweroff`/`halt` | C99 |
| **niinit-parallel** | Runs the independent stage-1 tasks concurrently, honoring `<task>.deps` files (waits, skips on failed deps, reports cycles) | C99 |
| **kipki** | Package manager on libxbps: transactions, search, orphans, holds, local log | C + libxbps |
| **mkrootfs** | Builds a rootfs from Void repositories | POSIX sh |
| **mkiso** | Builds a bootable live ISO: kernel, initramfs, isolinux + grub-efi (BIOS **and** UEFI), overlayfs root, disk installer on board | POSIX sh |
| **kiwi-install** | Disk installer: partitions (msdos/GPT), LUKS2 root encryption, ephemeral encrypted swap, timezone + locale selection, sched_ext scheduler setup, offline extlinux (BIOS) or grub-on-ESP (UEFI) bootloader | POSIX sh |
| **kinini-scx** | sched_ext scheduler selector: `status` / `list` / `use <sched> --now` (live switch) / `on` / `off` / `top` / `log` — CachyOS `scxctl` experience without D-Bus | POSIX sh |
| **kinini-settings** | CachyOS-inspired tuning shipped in the skel: sysctl.d profile, per-device IO-scheduler udev rules, zram swap, watchdog blacklists | conf/sh |
| **kinini kernel** | Vanilla Linux LTS built in CI over `allnoconfig` + a curated fragment: **sched_ext enabled**, BTF, all boot-critical drivers built in (no initramfs modules), zram/bfq/BBR onboard | config + CI |

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
6.12 (live), a busybox initramfs that finds the medium and mounts an overlayfs root
(all writes go to a tmpfs layer, the medium stays untouched), isolinux for
BIOS and a standalone grub `x86_64-efi` on an appended FAT ESP for UEFI
(same `grub-mkrescue`-style image boots CDs and USB sticks on both firmware
types):

```sh
# rootfs with a kernel and fastfetch (linux metapackage is skipped,
# the LTS kernel series is pinned explicitly):
IGNORE_PKGS=linux ./tools/mkrootfs.sh /tmp/rootfs \
        https://repo-default.voidlinux.org/current base-system linux6.12 fastfetch \
        syslinux dhcpcd dosfstools cryptsetup tzdata glibc-locales scx

./tools/mkiso.sh /tmp/rootfs kinini-0.4-x86_64.iso
```

Test it in qemu (BIOS or OVMF/UEFI — the same image):

```sh
qemu-system-x86_64 -m 1024 -cdrom kinini-0.4-x86_64.iso -boot d
qemu-system-x86_64 -m 1024 -cdrom kinini-0.4-x86_64.iso -bios OVMF.fd
```

The live session autologs in on tty1 and ttyS0, brings the network up via
DHCP (`dhcpcd` service, enabled on the live image) and greets you with the
bird:

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
`/etc/niinit/services-available` until you link them in. `sshd`, `dhcpcd`
and `scx` ship there as optional services — disabled by default in installed
systems unless chosen in the installer (the live ISO turns DHCP on for you):

```sh
svctl enable sshd       # symlink from services-available, svdir picks it up in <=5s
svctl start sshd        # waits until it is actually up
svctl enable dhcpcd     # DHCP on wired interfaces (runs dhcpcd -B -M, foreground)
svctl enable scx        # sched_ext BPF CPU scheduler (needs: kipki install scx)
```

`svctl enable/disable` manage those symlinks for you; the supervisor honors
runit conventions: a `down` file in a service dir prevents auto-start at
boot, and a `finish` script runs after each service exit with the exit code
and terminating signal as arguments.

Services can also declare dependencies: a `deps` file inside the service
dir lists service names (whitespace-separated, `#` comments). `niinit-svdir`
spawns a service only once every dependency is enabled **and** up; until
then the service shows `blocked (waiting for dep 'x')` in `svctl status`.
Dependencies resolve transitively, a dependency cycle is visible in the
stat files instead of hanging silently, and — runit semantics — a running
service is not stopped when its dependency goes down.

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
pseudo-filesystems and brings up udev, stage 2 supervises services until
shutdown, and `/etc/niinit/3` unmounts everything back. PID 1 gives every
process a grace period to exit on TERM before the final KILL, then runs
stage 3.

Stage 1 is parallel where it can be: after the critical path (base mounts +
udevd) the independent work — udev event replay, sysctl tuning, module
loading, hugepage policy, bpffs/debugfs, loopback, encrypted swap from
crypttab, zram — runs concurrently from `/etc/niinit/1.d/`, ordered by
`<task>.deps` files. `niinit-parallel` waits for dependencies, skips the
dependents of a failed task and reports cycles; a failed task never stops
the boot.

## Installing to disk

The live ISO ships a complete installer. Boot the ISO (BIOS or UEFI — the
installer autodetects the firmware via `/sys/firmware/efi/efivars`) and run
as root:

```sh
kiwi-install -d /dev/sda -y              # BIOS: msdos + extlinux
kiwi-install -d /dev/nvme0n1 -y          # UEFI (autodetected): GPT + ESP + grub
kiwi-install -d /dev/sda -b uefi -y      # force UEFI layout on a BIOS boot
kiwi-install -d /dev/sda -s 0 -N -y      # no swap partition, no DHCP
```

It partitions the disk, creates a swap partition (default `min(2×RAM, 4 GiB)`,
`-s` to change) and an ext4 root, copies the live system, restores the
standard gettys (no autologin on a real install), enables the `dhcpcd`
service (unless `-N`), writes an `/etc/fstab` and installs a bootloader —
all offline, from binaries shipped inside the ISO:

- **BIOS**: msdos label, extlinux + syslinux MBR;
- **UEFI**: GPT with a 512 MiB ESP, and the standalone grub `x86_64-efi`
  binary copied to `\EFI\BOOT\BOOTX64.EFI` — the removable-drive fallback
  path that boots on any UEFI machine without touching NVRAM. The loader
  locates the root filesystem by the `/.kinini-live` marker and reads
  `/boot/grub/grub.cfg` from it.

zram swap is configured in addition to the swap partition (see below). The
root password stays `kinini` until you change it (`passwd`). Without `-y`
the installer lists disks, offers **LUKS2 encryption**, **timezone** and
**locale** pickers, asks whether to enable a **sched_ext scheduler**, asks
for confirmation and offers to set the root password interactively. After
it finishes, remove the medium and reboot straight into the installed
system.

### Full-disk encryption (LUKS2)

Answer `y` to the encryption question (or pass the flags directly):

```sh
kiwi-install -d /dev/sda -e                          # asks for a passphrase twice
kiwi-install -d /dev/sda -e -p /root/lukskey         # scripted installs
kiwi-install -d /dev/sda -e -p /root/lukskey -z Europe/Moscow -l ru_RU.UTF-8 -S scx_lavd
```

The root partition becomes a LUKS2 container (default argon2id KDF) opened
as `/dev/mapper/kinini`; the passphrase is asked in the initramfs at every
boot (three attempts, then a rescue shell). The swap partition, when it
exists, is **not** protected by your passphrase — instead it is re-encrypted
with a fresh random key on every boot via `/etc/crypttab` (plain dm-crypt,
`/dev/urandom` key), so no passphrase prompt and nothing sensitive leaks to
disk across reboots. `rd.luks.uuid=` on the kernel command line ties the
initramfs to the right container.

### Timezone and locale

`-z Region/City` writes `/etc/localtime` (interactive continent/city picker
without the flag), `-l xx_XX.UTF-8` writes `/etc/locale.conf`, enables the
locale in `/etc/default/libc-locales` and regenerates it through
`xbps-reconfigure -f glibc-locales`. `/etc/profile.d/10-locale.sh` exports
`LANG` for login shells. Defaults in `-y` mode: `UTC` and `en_US.UTF-8`.

Both firmware paths — plus a full LUKS2 + Europe/Moscow + `ru_RU.UTF-8` +
`scx_lavd` install — are verified in CI on every push: qemu boots the ISO,
installs it to a virtio disk, reboots from disk and checks login, DHCP
lease, zram, the tuning, the passphrase unlock, the timezone, the locale,
the encrypted swap and the attached scheduler — over the serial console,
for BIOS and OVMF UEFI alike.

## System tuning (CachyOS-inspired)

KiniNi is not a bare-bones base: the skel ships a tuned profile ported from
[CachyOS-Settings](https://github.com/CachyOS/CachyOS-Settings), applied at
boot by `/etc/niinit/1`:

- **sysctl** (`/usr/lib/sysctl.d/70-kinini-settings.conf`): zram-friendly
  `vm.swappiness=100` (150 while zram is active), `vfs_cache_pressure=50`,
  absolute dirty-page limits, `page-cluster=0`, big `max_map_count`, quiet
  console (`printk 3 3 3 3`), NMI watchdog off, larger socket/backlog
  buffers and **BBR congestion control with fq pacing**;
- **zram swap** (`/usr/bin/zram-swap` + `/etc/kinini/zram.conf`):
  `min(RAM, 32 GiB)` of zstd-compressed swap at priority 100 by default,
  zswap disabled while zram runs — same reasoning as CachyOS;
- **IO schedulers** (`66-kinini-iosched.rules`): `bfq` for HDDs,
  `mq-deadline` for SATA/USB SSDs and eMMC, `kyber` for NVMe;
- **watchdog blacklists** (`kinini-watchdog.conf`): iTCO/sp5100/wdat off —
  less power, one less module at boot;
- **amdgpu si/cik** support (`kinini-amdgpu.conf`) for GCN 1/2 Radeons;
- **transparent hugepage defrag** set to `defer+madvise` at boot.

Everything is a plain config file under `/etc` or `/usr/lib` — edit
`/etc/sysctl.d/*.conf` or `/etc/kinini/zram.conf` to override, no tools
required.

## sched_ext CPU schedulers (CachyOS-style)

CachyOS's defining feature is the kernel, and KiniNi follows suit: every
installed system boots the **KiniNi kernel** — a pure vanilla stable (6.18.x,
no patches) built in CI from `kernel/kinini-x86_64.config` over `allnoconfig`
with `CONFIG_SCHED_CLASS_EXT=y` and BTF on. Void's own kernels ship with
sched_ext disabled, so the distro builds its own — everything the installed
system needs (ext4, virtio, AHCI/NVMe, dm-crypt, zram, BFQ/deadline/kyber,
BBR+fq, e1000/virtio-net, USB) is built in, so the boot initramfs carries
**no kernel modules at all** (only cryptsetup for LUKS unlocking).

The Void `scx` package (the same upstream
[sched-ext/scx](https://github.com/sched-ext/scx) tree CachyOS ships)
provides the BPF schedulers themselves. KiniNi integrates them the runit
way, without D-Bus: the `scx` service runs the configured scheduler in the
foreground under the niinit supervisor, so a crashed scheduler is restarted
automatically and stopping the service falls back to the kernel cleanly.

```sh
kipki install scx                # scx_lavd, scx_bpfland, scx_flash, ...
kinini-scx on                    # enable + start the scx service
kinini-scx status                # kernel support / configured / running
kinini-scx list                  # what the scx package ships
kinini-scx use scx_bpfland --now # switch scheduler live, no reboot
kinini-scx top                   # scxtop, live scheduler/CPU telemetry
kinini-scx log 100               # scheduler log tail
dmesg | grep sched_ext           # "BPF scheduler \"scx_bpfland\" enabled"
zcat /proc/config.gz | grep SCHED_CLASS_EXT   # the kernel tells its config
```

`kinini-scx use` validates the scheduler binary, rewrites
`SCX_SCHEDULER=` in `/etc/kinini/scx.conf` and — with `--now` — performs a
supervised restart of the `scx` service, which is exactly what switching
under CachyOS' `scx_loader` does, minus D-Bus. Without `--now` the choice
applies at the next boot or service start.

Scheduler cheat-sheet (same picks as the CachyOS wiki):

| Scheduler | Sweet spot |
|-----------|-----------|
| `scx_lavd` | latency-criticality aware dynamic priority — CachyOS default, desktops and gaming |
| `scx_bpfland` | interactive-first vruntime scheduler, general desktop |
| `scx_flash` | lightweight EDF, very low overhead — servers and VMs |
| `scx_p2dq` | pick-two dispatch queues, simple and modern |
| `scx_rusty` | load-balancing hierarchical buckets |
| `scx_layered` | policy-driven hierarchical layers for advanced setups |

The installer offers to enable a scheduler (`-S scx_lavd` to script it,
`-S none` to skip; `scx_lavd` is the default in `-y` mode) and mounts
`bpffs` + loads `sched_ext` at boot in stage 1 regardless, so enabling the
service later takes exactly one `svctl` command.

## Booting

For a manual install, point any Linux kernel and bootloader (GRUB, syslinux,
EFISTUB) at the rootfs — `/sbin/init` is a symlink to `niinit`, so pass
`root=UUID=... rw` and optionally `init=/sbin/niinit` if you prefer to be
explicit. Or skip the manual assembly entirely and use `kiwi-install` from
the live ISO above. The installed system boots the **KiniNi kernel** (see
sched_ext above); the live session keeps running the stock Void kernel.

## CI

Every push runs three Void Linux container jobs: one builds both components
and runs the supervisor test suite (up/down/restart/once, `down` files,
`finish` scripts, crash restart, start/stop/check, enable/disable, signals,
supervisor exit, plus the `svdir` spawn/stop cycle), the second builds a full
rootfs from live Void repositories and verifies the resulting tree byte by
byte, and the third builds the complete live ISO — static busybox from
source, the KiniNi kernel (vanilla LTS compiled with sched_ext + BTF) and a
cryptsetup-enabled disk initramfs — then **boots it in qemu — BIOS and OVMF
UEFI — installs to a virtual disk (twice: a plain install and a LUKS2 +
Europe/Moscow + ru_RU.UTF-8 + scx_lavd install), reboots from the installed
systems and checks everything** — login, DHCP, zram, the tuning, the
passphrase unlock, the timezone, the locale, the encrypted swap and the
attached sched_ext scheduler — over the serial console before uploading the
ISO as a workflow artifact.

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
  на корректный выход перед KILL; сервисы могут объявлять зависимости
  (`deps`-файл: сервис стартует, только когда все зависимости включены и
  подняты; `svctl status` показывает `blocked (...)`, циклы видны в stat);
- `niinit-parallel` — параллельный запуск независимых задач stage-1
  (`/etc/niinit/1.d/`): ожидание зависимостей из `<task>.deps`, пропуск
  зависимых при падении, обнаружение циклов; падение задачи не останавливает
  загрузку;
- `kipki` — пакетный менеджер на libxbps: транзакции с предпросмотром,
  поиск, сироты, hold, локальный журнал операций;
- `tools/mkrootfs.sh` — сборка корня из репозиториев Void;
- `tools/mkiso.sh` — загрузочный live-ISO: live-ядро Void 6.12, initramfs на busybox,
  isolinux (BIOS) и grub x86_64-efi на ESP (UEFI) в одном гибридном образе,
  корень на overlayfs; sshd и dhcpcd лежат в `services-available`, на live
  DHCP включён сразу;
- `tools/kiwi-install` — установщик на диск: разметка (msdos/GPT),
  **LUKS2-шифрование корня** (пароль запрашивается в initramfs при каждой
  загрузке) с эфемерно шифруемым swap-разделом через `/etc/crypttab`,
  **выбор часового пояса и локали**, настройка scx-планировщика, копирование
  live-системы, fstab и загрузчик без сети — extlinux (BIOS) или grub на ESP
  (UEFI, `\EFI\BOOT\BOOTX64.EFI`);
- **tuning** — системные настройки в духе CachyOS: sysctl-профиль
  (swappiness, vfs_cache_pressure, BBR+fq и т.д.), zram-подкачка
  (`zram-swap`, zstd, приоритет 100), udev-правила выбора IO-планировщика
  (bfq/mq-deadline/kyber), блэклисты watchdog'ов, THP `defer+madvise`;
- **sched_ext** — BPF-планировщики CPU как в CachyOS: пакет `scx`
  (scx_lavd, scx_bpfland, scx_flash, scx_p2dq, scx_rusty, scx_layered,...),
  сервис `scx` гоняет выбранный планировщик под супервизией niinit
  (без D-Bus, конфиг `/etc/kinini/scx.conf`), stage-1 монтирует bpffs
  и грузит модуль sched_ext; `kinini-scx` — выбор планировщика на лету:
  `status` / `list` / `use <имя> --now` (живое переключение без перезагрузки)
  / `on` / `off` / `top` / `log`;
- **kinini-kernel** — своё ядро как у CachyOS: чистый vanilla 6.18.x
  без патчей, собирается в CI из `kernel/kinini-x86_64.config` поверх
  allnoconfig — `CONFIG_SCHED_CLASS_EXT=y` + BTF, все нужные драйверы
  встроены в ядро (ext4, virtio, AHCI/NVMe, dm-crypt, zram, bfq/kyber,
  BBR+fq, USB) — initramfs дисковой загрузки не несёт модулей ядра вовсе;
  live-сессия при этом продолжает грузить стандартное ядро Void;
- маскот — птичка киви, ASCII-арт устанавливается в
  `/usr/share/kinini/kiwi.txt` и показывается `fastfetch`.

**Сборка:** `make` (нужны gcc, make, pkg-config, libxbps-devel).

**Rootfs:** `./tools/mkrootfs.sh /mnt/kinini` (на Void или в контейнере
`voidlinux/voidlinux`, от root).

**Live-ISO:** `IGNORE_PKGS=linux ./tools/mkrootfs.sh /tmp/rootfs \
https://repo-default.voidlinux.org/current base-system linux6.12 fastfetch syslinux dhcpcd dosfstools cryptsetup tzdata glibc-locales scx`,
затем `./tools/mkiso.sh /tmp/rootfs kinini.iso`.

**Загрузка:** три стадии, как в runit; stage-1 после критического пути
(базовые монтирования + udevd) гоняет независимые задачи параллельно из
`/etc/niinit/1.d/` (replay uevent, sysctl, модули, THP, bpffs/debugfs,
loopback, шифрованный swap из crypttab, zram) с упорядочиванием через
`<task>.deps`.

**Установка на диск:** загрузите ISO (BIOS или UEFI — установщик
определяет прошивку сам) и выполните:

```sh
kiwi-install -d /dev/nvme0n1 -y    # UEFI: GPT + ESP + grub
kiwi-install -d /dev/sda -y        # BIOS: msdos + extlinux
kiwi-install -d /dev/sda -e        # с LUKS2: пароль спросит дважды
kiwi-install -d /dev/sda -e -p /root/lukskey -z Europe/Moscow -l ru_RU.UTF-8 -S scx_lavd
```

— разметка, swap-раздел (по умолчанию min(2×RAM, 4 ГиБ), при LUKS —
эфемерно шифруемый свежим ключом при каждой загрузке), копирование
системы, fstab, DHCP-сервис, часовой пояс и локаль (`/etc/locale.conf` +
генерация через glibc-locales), загрузчик — всё без сети. Без `-y`
установщик показывает диски, предлагает шифрование, часовой пояс,
локаль и sched_ext-планировщик интерактивными меню. Оба пути (BIOS и
OVMF/UEFI), а также полный сценарий LUKS2 + Europe/Moscow + ru_RU.UTF-8 +
scx_lavd проверяются в CI на каждый пуш: QEMU грузит ISO, ставит систему
на виртуальный диск и перезагружается с неё, проверяя вход, DHCP, zram,
настройки, разблокировку LUKS, часовой пояс, локаль, шифрованный swap
и подключённый планировщик по serial-консоли.

**sched_ext (CachyOS-style):** `kipki install scx`, затем
`svctl enable scx && svctl start scx`; планировщик выбирается в
`/etc/kinini/scx.conf` (по умолчанию scx_lavd — дефолт CachyOS), сервис
держит его под супервизией: упал — перезапущен, остановили — ядро
возвращается к EEVDF. Список планировщиков и их профили — как в вики
CachyOS: scx_lavd (десктоп/игры), scx_bpfland (интерактивность),
scx_flash (серверы/ВМ), scx_p2dq, scx_rusty, scx_layered.

**Загрузка:** `/sbin/init` — симлинк на `niinit`, так что достаточно любого
ядра и загрузчика; либо просто установите систему через `kiwi-install`.

**Лицензия:** BSD-2-Clause.
