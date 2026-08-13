# NVIDIA Driver Installer

A single bash script that installs an NVIDIA `.run` driver on Debian-based
systems, with a console UI that tells you what it is doing.

```bash
./install-nvidia-driver.sh
```

## What it does

1. **Asks where the driver should come from:**

   ```
   Where should the driver come from?

   › 1) Install from a local .run file
        3 packages found – newest: 595.58.03
     2) Search online at NVIDIA and download
        drivers for NVIDIA RTX A500 Laptop GPU
     3) Quit
   ```

   **Option 1 – local file.** Every `NVIDIA*.run` next to the script, sorted by
   driver version. One file → it is used right away; several → a menu with the
   newest preselected, wrong-architecture packages flagged.

   **Option 2 – online search.** Reads the driver index on
   `download.nvidia.com`, then checks each release's supported-GPU table
   against your PCI device ID, so the list only contains drivers that really
   support your card. The newest **stable** release (from `latest.txt`) comes
   first and is the default; newer releases are marked `beta branch`. After the
   selection the package is downloaded into this folder — size is shown first.

   Errors are explicit: no `curl`/`wget`, no connection to
   `download.nvidia.com`, an unreadable index, or no driver supporting your GPU
   (with a pointer to the legacy branch) each stop with their own message. If
   the search fails you land back in the menu.

2. **Prepares the system.** Blacklists `nouveau`, rebuilds the initramfs,
   adds `nouveau.modeset=0 modprobe.blacklist=nouveau` to the GRUB command line
   (a timestamped backup of `/etc/default/grub` is kept) and installs the
   kernel headers plus the build tools.
3. **Stops the graphical session** and runs the NVIDIA installer, in expert
   mode when the kernel enforces module signatures.
4. **Verifies** with `nvidia-smi` and offers a reboot.

It asks for root only once the driver is chosen and you confirmed the plan —
then it re-execs itself through `sudo`.

## Options

| Option | Effect |
| --- | --- |
| `-f, --file PATH` | Install this `.run` file, skip search and menu |
| `-l, --local` | Straight to the local `.run` files, no source menu |
| `-o, --online` | Straight to the online search at NVIDIA |
| `-y, --yes` | Non-interactive, accept every prompt (picks the newest driver) |
| `-s, --silent` | Run the NVIDIA installer unattended (`--silent --dkms`) |
| `-k, --keep-x` | Do not stop the display manager |
| `-n, --dry-run` | Print every command, change nothing |
| `--no-verify` | Skip the archive integrity check (`--check`) |
| `--no-reboot` | Never offer to reboot |
| `--no-color` | Plain output (also honours `NO_COLOR`) |
| `-h, --help` | Usage |

## Run it from a text console

Installing the driver means stopping the display manager, which kills every
graphical terminal — including the one running this script. The script detects
that situation and warns you. Do it properly:

```
Ctrl+Alt+F3          # switch to a text console
sudo /path/to/install-nvidia-driver.sh
```

## Notes

* Requires `bash`, `systemd` and `apt-get`; the driver package itself is not
  included in this repository (`*.run` is in `.gitignore`).
* Progress goes to `/var/log/nvidia-driver-installer.log`; the NVIDIA installer
  writes its own log to `/var/log/nvidia-installer.log`.
* Network access happens only in the online search (option 2): the version
  index, `latest.txt`, one supported-GPU table per candidate release, and the
  driver download itself. Everything comes from `download.nvidia.com`.
* `--dry-run` never downloads anything — it prints the URL it would use and
  stops there.
* With Secure Boot enabled you must let the installer generate a key pair and
  enroll it via MOK, otherwise the module will not load.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Installer stops right after the license | Kernel headers do not match the running kernel | `sudo apt-get install linux-headers-$(uname -r)`, reboot, run again |
| Tainted kernel / unsigned module | Kernel enforces module signatures | Expert mode (the script does this automatically), choose "Generate a new key pair" |
| `Failed to initialize NVML: GPU access blocked` | Leftovers from an older driver | `dpkg -l \| grep -E "nvidia\|cuda"`, then `sudo apt-get purge` the old packages |
| Black screen after reboot | X config was overwritten | Answer **No** to "Update your X configuration" — or delete `/etc/X11/xorg.conf` |

`install-driver.md` holds the original German step-by-step notes this script
grew out of.
