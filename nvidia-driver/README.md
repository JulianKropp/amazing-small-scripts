# NVIDIA Driver Installer

Installs an NVIDIA `.run` driver on Debian in two phases: everything that needs
you, and everything that needs your desktop closed.

```bash
./install-nvidia-driver.sh
```

Run it from your normal desktop terminal. No text console needed.

---

## The idea

Installing a `.run` driver means killing the desktop — which also kills the
terminal the installer runs in. So the work is split:

| | Phase 1 – **prepare** | Phase 2 – **install** | Phase 3 – **verify** |
|---|---|---|---|
| runs | in your desktop session | detached in `screen`, started by systemd | after the reboot, as a systemd unit |
| needs you | yes, a few questions | no | no |
| changes the system | **nothing** | everything | undoes everything if the driver is broken |

After phase 1 answers your last question, you are done. The desktop closes, the
driver installs, the machine reboots, and the driver is checked. If the check
fails, the installation is rolled back and the machine reboots again — into the
state it was in before.

---

## Phase 1 — prepare

Checks and collects everything, and touches nothing:

1. **Hardware and session** — GPU and PCI ID, kernel, loaded driver, display
   manager, running desktop, X11/Wayland, default target, Secure Boot.
2. **Driver source** — a menu:
   * **local `.run` file** — everything next to the script, sorted by version,
     newest preselected
   * **online search** — reads NVIDIA's driver index, matches each release's
     supported-GPU table against your PCI ID, lists only drivers that really fit
     your card, newest **stable** first, then downloads it here
3. **Root rights** — asks for the sudo password once, up front, and keeps it
   alive for the rest of the phase.
4. **Packages** — installs everything the build needs (kernel headers,
   build-essential, dkms, screen, pciutils, acpid, libglvnd-dev, pkg-config)
   and re-checks afterwards. **This is why phase 2 needs no internet.**
5. **Distribution driver** — finds Debian's own `nvidia-*` packages (the display
   driver only; container toolkit and CUDA are left alone) and asks whether to
   remove them in phase 2.
6. **Driver package** — verifies the archive with `--check`.
7. **The check list** — one box, one line per condition:

   ```
   ╭──────────────────────────────────────────────────────╮
   │ Everything that has to be right                      │
   ├──────────────────────────────────────────────────────┤
   │ ✔ NVIDIA GPU detected                                │
   │ ✔ Root rights available                              │
   │ ✔ Driver package present                             │
   │ ✔ Archive integrity verified                         │
   │ ✔ All packages installed (offline-ready)             │
   │ ✔ Kernel headers for 6.12.101+deb13-amd64            │
   │ ✔ screen available (background installation)         │
   │ ✔ Secure Boot off – module needs no signature        │
   │ ✔ Display manager: gdm.service                       │
   │ ! Downgrade: 595.91.07 is loaded, 580.126.09 chosen  │
   ├──────────────────────────────────────────────────────┤
   │ Ready, with 1 warning(s)                             │
   ╰──────────────────────────────────────────────────────╯
   ```

   A single ✖ and phase 2 does not start.
8. **Backups and state** — backs up `/etc/default/grub` and any existing nouveau
   blacklist, writes the state file, copies itself to `/usr/local/sbin/` and
   registers the post-reboot check.

Then it shows what phase 2 will do and asks once.

## Phase 2 — install

Starts as `systemd-run … screen -DmS nvidia-install` so it belongs to systemd,
not to your dying desktop session. Runs with no questions at all:

1. stop the display manager, switch to `multi-user.target`
2. remove Debian's driver packages (if you agreed — works offline)
3. blacklist nouveau, unload it, rebuild the initramfs
4. add `nouveau.modeset=0 modprobe.blacklist=nouveau` to GRUB
5. unload old `nvidia*` modules
6. `nvidia-installer --silent --dkms --no-questions --ui=none`
7. arm the post-reboot check and reboot

Any failure triggers the rollback immediately, brings the desktop back and
leaves the system usable.

Watch it while it runs:

```bash
sudo screen -r nvidia-install     # leave again with Ctrl+A then D
tail -f logs/install-*.log
./install-nvidia-driver.sh status
```

## Phase 3 — verify (after the reboot)

A systemd unit waits for the session to come up and then checks:

* is the `nvidia` kernel module loaded?
* does `nvidia-smi` answer?
* is the version the one that was installed?
* is the display manager running, did the system reach its normal target?

All good → the check unit removes itself, `logs/REPORT.txt` says `OK`.

Anything wrong → **automatic rollback**: uninstall the driver, restore
`/etc/default/grub`, remove the nouveau blacklist (only if we created it),
reinstall the distribution packages, re-enable the display manager, then reboot
into the old state. `logs/REPORT.txt` says what failed.

---

## Commands

| Command | What it does |
| --- | --- |
| *(none)* | phase 1, then phase 2 |
| `prepare` | only phase 1 — check and download, change nothing |
| `install` | only phase 2 (normally started for you) |
| `verify` | the post-reboot check (normally started by systemd) |
| `rollback` | undo everything by hand |
| `status` | which phase are we in? |
| `attach` | `screen -r` into the running installation |

## Options

| Option | Effect |
| --- | --- |
| `-f, --file PATH` | use this `.run` file, skip search and menu |
| `-l, --local` | straight to the local files |
| `-o, --online` | straight to the online search |
| `-y, --yes` | no questions, take every default |
| `-n, --dry-run` | print every command, change nothing, download nothing |
| `--no-reboot` | install but do not reboot |
| `--keep-desktop` | do not stop the display manager (testing only) |
| `--no-color` | plain output (also honours `NO_COLOR`) |

## Logs

Everything lands in `logs/` next to this script:

| File | Content |
| --- | --- |
| `prepare-<ts>.log` | what you saw on screen |
| `prepare-<ts>-detail.log` | every command with its full output |
| `install-<ts>.log` / `-detail.log` | same for phase 2 |
| `verify-<ts>.log` / `-detail.log` | same for phase 3 |
| `REPORT.txt` | the short answer: worked, failed, rolled back |

The NVIDIA installer keeps its own log in `/var/log/nvidia-installer.log`.
State and backups live in `/var/lib/nvidia-driver-installer/`.

## Requirements and limits

* Debian-based, systemd, `apt-get`, bash 4+.
* **Secure Boot must be off.** An unattended install cannot enroll a MOK key.
  Phase 1 stops with a clear message and tells you how to install by hand.
* The `.run` file is not in this repository (`*.run` is gitignored), and neither
  are the logs.
* Only phase 1 uses the network — for the online driver search and the download.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `status` says `installing` but nothing happens | `sudo screen -r nvidia-install`, or read `logs/install-*.log` |
| Machine came back without a driver | that is the rollback doing its job — read `logs/REPORT.txt` |
| Want to undo it yourself | `sudo ./install-nvidia-driver.sh rollback` |
| Installer stops right after the license | kernel headers do not match the running kernel — reboot, run again |
| Black screen after the reboot | the post-reboot check rolls back on its own; if not, boot the previous kernel from the GRUB menu and run `rollback` |

`install-driver.md` holds the original German step-by-step notes this script
grew out of.
