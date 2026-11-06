# kenzo (Redmi Note 3 Pro, MSM8956): Ubuntu + Docker on mainline Linux

Adapted from [GinkgoMainlineAndroid](https://github.com/rafitadev/GinkgoMainlineAndroid).

This project turns a Xiaomi Redmi Note 3 Pro (kenzo, Snapdragon 650 / MSM8956) into a headless Ubuntu Server
box running a mainline Linux kernel, booted through lk2nd. First boot lands on fbcon with **auto-login** of the
build-time default user, USB RNDIS networking to your PC, a running Docker daemon, a power key that toggles the
panel backlight, and SSH over USB ready out of the box.

## What you get

- **Mainline kernel** (`7.0.0-msm8956+`) with Docker, Tailscale (`CONFIG_TUN=y`), Wi-Fi and Bluetooth support.
- **Ubuntu 24.04 (noble) arm64 rootfs** built with debootstrap, flashed to the userdata partition.
- **Userland installed at build time** (zsh + Oh My Zsh, eza, fastfetch, delta, Node 22, bun, uv, GitHub CLI,
  docker compose v2, fail2ban/ufw packages, helper scripts in `~/bin`, ...) inside the chroot via
  `setup_rootfs.sh`. The phone does **not** need Wi-Fi on first boot.
- **USB RNDIS networking**: phone = `192.168.7.2`, host = `192.168.7.1`.
- **Wi-Fi (wcn36xx / WCN3660B Pronto) and Bluetooth (btqcomsmd, e.g. wireless keyboards)** enabled in the DTS.
  They work once the signed per-device firmware is copied from the phone's own modem partition; the
  `kenzo-wifi` helper does this.
- **Power-key daemon** that toggles panel backlight and console blanking.
- **24/7 server battery management**: charging is cut at a threshold and the phone runs from USB pass-through.
- **Health check tool** (`kenzo-health`) for units, remoteprocs, firmware, modules, radios, storage, time and battery.
- **Device-side interactive setup** (`~/setup_kenzo.sh`) for passwords, SSH keys, Tailscale, firewall and tunnels.
  It runs whenever you later have a USB ICS or Wi-Fi uplink.

---

## 1. Prerequisites (host)

- Any x86_64 Linux, or WSL2 with `binfmt-support` and `qemu-user-static` (so the arm64 chroot works).
- Install host tooling once:
  ```
  ./scripts/setup-deps.sh
  ```
  This installs build-essential, the aarch64 cross toolchain, cpio, bison/flex, u-boot-tools, docker,
  qemu-user-static/binfmt and `zstd`. Both host-side `modules_install` and the on-device rootfs need `zstd`
  because the kernel ships `*.ko.zst` (`CONFIG_MODULE_COMPRESS_ZSTD=y`).
- Clone the msm8956 kernel source next to this repo (or set the `KERNEL_SRC` env var):
  ```
  git clone --depth 1 --branch wip https://github.com/zennnez/msm8956-mainline-linux ~/msm8956-mainline-linux
  ```
- Optionally drop firmware files into `firmware/` (layout = linux-firmware, so `firmware/wcnss.*` etc.).
  `build-rootfs.sh` copies the whole folder into `/usr/lib/firmware` on the image. This is useful if you have
  already extracted the wcnss firmware from a Kenzo `NON-HLOS.bin`, so you don't have to run
  `kenzo-wifi firmware` on-device. See `firmware/README.txt`.
- Back up your current boot partition before flashing: `fastboot fetch:boot`, or `dd` it from your existing
  Android install, or simply keep the old `boot.img`.

---

## 2. Build (strict order: kernel → bootimg → rootfs → flash)

```
export KERNEL_SRC=~/msm8956-mainline-linux

./scripts/build-kernel.sh
   # defconfig + kenzo.fragment + kenzo-docker.fragment + kenzo-wireless.fragment
   # Outputs:  out/kernel/Image.gz, out/dtbs/, out/modroot/ (modules_install, with *.ko.zst)

./scripts/build-bootimg.sh
   # Combines lk2nd (assets/lk2nd.img) + Image.gz + dtbs into an Android boot v2 image.
   # Output:  out/boot.img  (fastboot-flashable, same layout as a Lineage boot.img)
   # Override lk2nd binary:    LK2ND=assets/lk2nd-from-lineage-boot.img ./scripts/build-bootimg.sh
   # Verbose kernel cmdline:   KENZO_VERBOSE=1 ./scripts/build-bootimg.sh

export KENZO_USER='kenzo'              # optional, default: kenzo
export KENZO_USER_PASSWORD='....'      # optional; blank leaves it locked until the first interactive run
export KENZO_ROOT_PASSWORD='....'      # optional; blank leaves root locked (recommended)
export KENZO_SSH_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI.... user@host"

./scripts/build-rootfs.sh
   # Output: out/rootfs.img   (ext4; gets written to the userdata partition)
```

### What `build-rootfs.sh` does, in order

1. debootstrap noble base + apt install of core packages (ssh, docker.io, network-manager, zstd, kmod,
   bluez, bluez-tools, crda, iw, wpasupplicant, rfkill, wireless-regdb, ...).
2. Creates `$KENZO_USER` (UID 1000, `sudo` + `docker` groups) and sets passwords if the env vars are provided.
   `KENZO_SSH_PUBKEY` is authorized for the user and root.
3. Writes the autologin drop-in for `getty@tty1` (substituting `$KENZO_USER`) so boot lands at a shell.
4. Applies `rootfs-overlay/`: USB RNDIS gadget, power-key daemon, battery daemon, modules-load.d, logind.conf.d,
   systemd units, `/usr/local/sbin` helpers, the firmware folder, fastfetch config.
5. Runs `/setup_rootfs.sh` inside the chroot, which installs **all** userland packages at build time (see
   [§8](#8-script-reference)). Installation is best-effort: if a download fails (for example a transient GitHub
   outage) the build continues with a warning, and on-device `apt` can repair it later.
6. Copies `scripts/setup_kenzo.sh` to `~/setup_kenzo.sh` and `/usr/local/sbin/setup_kenzo.sh` for later
   interactive runs on the device.
7. Enables these systemd units: `getty@tty1`, `kenzo-powerkey`, `kenzo-batteryd`, `usb-gadget-rndis`, `ssh`,
   `NetworkManager`, `bluetooth`, `systemd-modules-load`.
8. Writes the hostname and generates the ext4 `out/rootfs.img`.

### Why the build order matters

`build-rootfs.sh` copies `out/modroot/lib/modules/$(uname -r)` into the image and runs `depmod -a`. If you flash
a `boot.img` whose kernel version string (including the trailing `+` from `setlocalversion`) doesn't match the
directory name under `/lib/modules`, the kernel won't find any modules. The symptom is `modprobe wcn36xx`
failing with "not found" even though the module exists under a different suffix.

- The script **fails fast** if `out/modroot/lib/modules` is missing, with a pointer to `build-kernel.sh`.
- After `depmod -a`, it runs `modprobe -n` on the wireless modules as a sanity check and warns for each one
  that cannot be resolved.
- Always reflash **both** `boot` and `rootfs` from a single
  `build-kernel.sh && build-bootimg.sh && build-rootfs.sh` pass to keep them in sync.

---

## 3. Flash (device in lk2nd fastboot mode)

```
./scripts/flash.sh test      # fastboot boot: RAM only, no writes. RUN THIS FIRST. Confirm the panel lights up
                             # and the host sees a USB RNDIS adapter. If this works, the rest will too.
./scripts/flash.sh boot      # fastboot flash boot_a out/boot.img
./scripts/flash.sh rootfs    # fastboot flash userdata_a out/rootfs.img   -> WIPES the userdata partition
```

`flash.sh` keeps the slot choice explicit so you don't accidentally overwrite slot B.

---

## 4. First boot

Reboot the phone. It should:

1. Light up the panel with fbcon.
2. Not stop at `kenzo login:`. `getty@tty1` auto-logs in as `$KENZO_USER` through the drop-in written by
   `build-rootfs.sh`. If it still asks for a login, check `systemctl cat getty@tty1.service` to see whether the
   `ExecStart=-/sbin/agetty -a <user> ...` override took effect.
3. Start USB RNDIS. On the host, assign the new Ethernet interface `192.168.7.1/24`, then:
   ```
   ssh $KENZO_USER@192.168.7.2     # authorized_keys already contains $KENZO_SSH_PUBKEY
   ```
4. Toggle the backlight and fbcon blanking on power-key presses. The daemon is `systemctl status kenzo-powerkey`.
   It reads `/dev/input/event*` for `KEY_POWER` and drives the display through `/usr/local/sbin/kenzo-screen`.

The whole build-time stack is already usable without any network:

```
ls          # eza --icons
btop        # system monitor
fastfetch   # banner
docker --version ; docker compose version
zsh         # zsh is already the login shell; Oh My Zsh + plugins loaded
```

### Giving the phone internet over USB

To provide internet for Tailscale or Docker pulls, enable Windows Internet Connection Sharing on your host's
Wi-Fi/Ethernet and share it to the RNDIS adapter. Windows will set that adapter to `192.168.137.1/24`.
`setup_kenzo.sh` on the phone tries both the `192.168.7.1` path **and** a Windows-ICS fallback
(`192.168.137.2` with default route via `192.168.137.1`).

### Notes on boot behavior

- The kernel cmdline keeps `lk2nd.pass-ramoops=zap` and uses `console=tty0 quiet loglevel=3`.
  `KENZO_VERBOSE=1` on `build-bootimg.sh` keeps the debug-level cmdline.
- The RNDIS messages `unknown RNDIS 0x0000000 len 16` / `RNDIS command error -524` are a harmless gadget-side
  warning (the host sent an empty control message; the link works). They are kept off the console: the gadget
  script lowers the console loglevel and the default cmdline uses `loglevel=3`. They remain visible in `dmesg`.
- DRM, panel and USB are built in (`=y`), so the screen and USB come up without udev. If the display
  misbehaves, fall back to `=m` and let udev load them.
- Debugging: fbcon on screen, and `/sys/fs/pstore` after a crash (ramoops at `0xdfc00000`).

---

## 5. On-device interactive setup (optional, no network required for most steps)

Run `~/setup_kenzo.sh` only if and when you want to finish the interactive choices. It does **not** install
packages (those were installed at build time), so you don't need Wi-Fi just to bring up the dev tools.

```
sudo ~/setup_kenzo.sh
   # user password + (optionally) root password, sudoers
   # USB network routing (asks whether to set default via 192.168.7.1; tries the Windows ICS 137.* fallback)
   # clock sync from an HTTP Date header
   # SSH authorized keys from your PC, or generate a keypair on the device; optionally disable root SSH
   #   and switch to key-only authentication (if any authorized key is present)
   # Tailscale install + up via a Headscale URL and pre-auth key (reads ~/docker/.env if present)
   # UFW enable (allows usb0 + tailscale0, plus a LAN subnet you can type in) + fail2ban sshd jail.local
   # Cloudflare tunnel (reads CLOUDFLARE_TUNNEL_TOKEN from ~/.env or ~/docker/.env)
   # Oracle SSH reverse tunnel via autossh (/etc/systemd/system/oracle-tunnel.service)
   # chsh to zsh, Git global config with core.pager=delta, version summary
```

- The password, sudo and UFW parts work with no internet at all. Tailscale, Cloudflare and Oracle emit a clear
  skip message when offline and can be re-run later.
- The script is idempotent for the choices you confirm: run it again over Wi-Fi or ICS to finish the rest.
- A flag-only mode exists for non-interactive reuse. See `--help` and the script header of
  [setup_kenzo.sh](scripts/setup_kenzo.sh).

---

## 6. Wi-Fi + Bluetooth (WCNSS Pronto: wcn36xx + btqcomsmd)

The DTS ships `status = "okay"` for `wcnss@a21b000` (smd_edge / wlan) and the Bluetooth companion, with
`firmware-name = "wcn3660"` and `iris = <2>` (WCN3660B, matching Kenzo hardware). No DTS edit is required.
The remoteproc is driven by `qcom_wcnss_pil`, which loads signed, per-device, non-redistributable firmware from
`/usr/lib/firmware/wcnss.{mdt,b00..b12}`. You extract it from the phone's own modem partition (FAT32);
`kenzo-wifi firmware` does this on-device with no PC required.

Kernel side (`config/kenzo-wireless.fragment`, merged into every build): the Wi-Fi stack, BT stack and
HIDP/UHID are `=m`, because the wcnss remoteproc needs signed firmware that only exists in the mounted rootfs.
VFAT, CP437 and ISO8859-1 are `=y` so the phone can read its own modem partition at runtime.

> **Module name gotcha:** `CONFIG_QCOM_WCNSS_CTRL` produces `wcnss_ctrl.ko`, **not** `qcom_wcnss_ctrl.ko`
> (that name does not exist). All helpers use the correct name.

### The module chain

`kenzo-wifi start` and `/etc/modules-load.d/kenzo-wireless.conf` use the same 14 modules, in this order:

```
rfkill libarc4 cfg80211 mac80211 qcom_common qcom_pil_info qcom_wcnss_pil wcnss_ctrl wcn36xx
bluetooth btqca btqcomsmd hidp uhid
```

`systemd-modules-load.service` is enabled by the build, so on every boot the chain autoloads before
`network.target`. If you add modules, keep the conf file and `kenzo-wifi start` in sync. You only need to run
`kenzo-wifi start` manually after flashing a rootfs that has never had the firmware copied in, or after a
DTS/kernel rebuild that changed remoteproc binding order.

### `kenzo-wifi` subcommands (run on the phone, with sudo)

#### `sudo kenzo-wifi diag`

One-shot full report:

- `uname -a` and whether `/lib/modules/$(uname -r)` exists (empty modules dirs stand out immediately).
- Kernel `CONFIG_*` grep for WCN36XX / QCOM_WCNSS_{PIL,CTRL} / BT_QCA / BT_HIDP / UHID / VFAT / LIBARC4 /
  QCOM_COMMON / QCOM_PIL_INFO, so you can tell if a fragment got lost in a custom rebuild.
- A module table: basename, resolvable via depmod, and loaded in lsmod, with a legend that calls out the
  `wcnss_ctrl` naming gotcha above.
- Device-tree wcnss nodes, found with four heuristics (compatible string, `firmware-name` property, node basename
  match, plus a dmesg fallback) so DTBs with different compatibles or paths still show a row.
- A **DTS sanity** section that greps dmesg for `overlaps.*wcnss`, `error -22 setting up firmware` and
  `Failed to load program segments`. An overlap means the wcnss and qseecom reserved-memory carveouts collide,
  which is a kernel/DTS-side `-EINVAL` regardless of firmware quality.
- Every `/sys/class/remoteproc` device with name, state and firmware.
- Firmware sizes: mdt size, `.bNN` count and total `.bNN` bytes. It warns when the mdt is about 7 KB and the
  `.bNN` total is under about 500 KB. That is the number-one cause of `error -22`: only the header file was
  copied, without the split program segments.
- A recursive listing of every `*wcnss*` / `*pronto*` file under `/usr/lib/firmware`.
- `ip -br link`, `rfkill list`, `/sys/class/bluetooth`, `bluetoothctl list`, and the last 60 filtered dmesg lines.
- A **How to read this** legend mapping common outputs to fixes.

#### `sudo kenzo-wifi firmware [--modem /path/to/dir] [--nv /path/to/WCNSS_qcom_wlan_nv.bin]`

Copies `wcnss.mdt` + `wcnss.bNN` and `WCNSS_qcom_wlan_nv.bin` into `/usr/lib/firmware` (or `$FWDIR`).
With **no arguments** it:

- auto-mounts `/dev/disk/by-partlabel/modem` read-only (temporary mount under `/run/kenzo-wifi.*/`) and finds
  `wcnss.mdt` inside it;
- searches the `system`, `vendor`, `persist` and `cache` partlabels for `WCNSS_qcom_wlan_nv.bin`;
- installs idempotently (files are overwritten in place), including any `pronto*`, `mba*` and `WCNSS*` files
  next to the split MDT;
- prints mdt size, `.bNN` count and total size, and warns if the `.bNN` total is tiny (under 500 KB), which
  means you probably have the wrong files (modem instead of pronto).

`--modem` points at a folder that already contains the right files (for example extracted from the `image/`
folder of `NON-HLOS.bin` and `scp`'d over); `--nv` does the same for the calibration NV file. The script exits
non-zero with a copy-pasteable error if a source can't be located.

#### `sudo kenzo-wifi start`

1. `modprobe` of the 14-module chain above.
2. For every wcnss remoteproc in sysfs: writes `stop`, sleeps 2 s, writes `start` (write errors are ignored
   because the kernel logs the real failure to dmesg).
3. Sleeps 5 s for SMD/edge enumeration, then `rfkill unblock all` and `systemctl enable --now bluetooth`.
4. Prints `ip -br link` and a 40-line filtered dmesg tail.
5. If any remoteproc failed, runs a targeted post-mortem:
   - reserved-memory overlap → kernel/DTS issue; stop here before trying firmware variants;
   - `error -22` / `Failed to load program segments` → check the diag firmware sizes (header-only MDT, wrong
     chip version, wrong signature);
   - `request_firmware failed: -2` → run `kenzo-wifi firmware`.
6. Prints the connect commands:
   - Wi-Fi: `nmcli device wifi list ; sudo nmcli device wifi connect 'SSID' password 'PASS'`
     (plus `iw reg set XY` if the scan is empty)
   - Bluetooth: `bluetoothctl` → `power on / agent on / scan on / pair XX / trust XX / connect XX`

#### Expected healthy output

```
== result
lo               UNKNOWN        127.0.0.1/8 ::1/128
usb0             UP             192.168.7.2/24 fe80::ff:fe00:702/64
wlan0            DOWN           <->                 <-- WCN36XX interface appeared; bring up via nmcli / wpa
docker0          NO-CARRIER     172.17.0.1/16 br 172.17.255.255
...
[   61.445831] remoteproc remoteproc1: powering up 6000000.remoteproc:wcnss
[   61.447700] remoteproc remoteproc1: Booting fw image wcnss.mdt, size 1825092     <-- big size = segments seen
[   61.488698] wcn36xx a21b000.wcnss_smd_edge:1: wcn36xx driver probed successfully
[   62.289155] wcn36xx a21b000.wcnss_smd_edge:1 wlan0: renamed from wlan0
...
Wi-Fi interface is up (wlan0). Connect with:
   nmcli device wifi list ; sudo nmcli device wifi connect 'SSID' password 'PASS'
Bluetooth HCI up (hci0). Pair a wireless keyboard with:
   bluetoothctl  ->  power on / agent on / scan on / pair XX:XX / trust XX:XX / connect XX:XX
```

### `kenzo-bt`

A Bluetooth CLI helper in the same style as `kenzo-wifi`: `status`, `on`, `off`, `scan`, `devices`, `pair`,
`connect`, `disconnect`, `remove`, `start` and `diag`.

### Host-side firmware drop-in

To skip `kenzo-wifi firmware` on-device, populate `firmware/wcnss.*` (and `firmware/ath10k/...`, matching the
linux-firmware layout) before running `build-rootfs.sh`. The script copies the whole tree into
`/usr/lib/firmware`. See `firmware/README.txt`.

### Wi-Fi / BT troubleshooting

| Symptom | Fix |
|---|---|
| `iw: command not found` | The rootfs was built without the `.kenzo-wireless-pkgs-done` marker. Re-run `build-rootfs.sh` (it installs iw/bluez on the second pass when the marker is absent), or on the phone: `apt install -y iw wpasupplicant bluez rfkill wireless-regdb bluez-tools crda`. |
| `modprobe wcn36xx` → `Module wcn36xx not found in directory /lib/modules/7.0.0-msm8956+` | `/lib/modules/$(uname -r)` is empty: `build-rootfs.sh` ran before `build-kernel.sh`, or before a rebuild that changed `CONFIG_LOCALVERSION`. Build order is `build-kernel.sh` → `build-bootimg.sh` → `build-rootfs.sh` → flash. |
| `uname -r` shows `7.0.0-msm8956` but modules live under `7.0.0-msm8956+` | A kernel rebuild left the trailing `+` from `scripts/setlocalversion` on the modules_install side. Reflash **both** `boot` and `rootfs` from a single `build-kernel.sh && build-bootimg.sh && build-rootfs.sh` pass. |
| `kenzo-wifi start` → `no wcnss remoteproc registered` | Either (a) the DT has no wcnss node (`kenzo-wifi diag` says "NONE FOUND"; only a DTS/kernel rebuild fixes it), or (b) `qcom_wcnss_pil` and/or `wcnss_ctrl` aren't loaded. For (b): `lsmod \| grep wcnss`; `sudo depmod -a && sudo modprobe qcom_wcnss_pil wcnss_ctrl`. |
| remoteproc boots OK, but `ip link` has no wlan0 | Check `rfkill list`; Wi-Fi/BT are often soft-blocked on a new image: `sudo rfkill unblock all && sudo systemctl restart NetworkManager`. If still nothing, `ls -la /sys/class/net/` and check dmesg for `wcn36xx` / `MAC address` lines. |
| nmcli shows scan results but association fails | Regulatory domain: `crda` is installed by `build-rootfs.sh`; set it on first boot with `iw reg set IN` (or your country). The Pronto MAC is read from `WCNSS_qcom_wlan_nv.bin`; re-run `kenzo-wifi firmware` in case the NV file ended up zero-length. |
| Bluetooth keyboard pairs but HID events don't arrive | `lsmod \| grep -E '^hidp\|^uhid'` (both must be loaded; both are in `modules-load.d/kenzo-wireless.conf`). `bluetoothctl show \| grep Powered` should say yes, and `hcitool dev` (or `btmgmt info`) should show `hci0` with a valid MAC. |
| `modprobe` fails with `invalid compressed format` | `kmod` needs zstd support. On the phone: `apt install zstd` (and `update-initramfs -u` if you use initramfs-tools). `build-rootfs.sh` installs `zstd` in the image. |
| `Booting fw image wcnss.mdt, size 7324` then `error -22 setting up firmware wcnss.mdt` | The driver read only the 7 KB MDT header and failed to map the split segments (`wcnss.b00..b08`). Re-run `sudo kenzo-wifi firmware` and check the diag firmware section. If the `.bNN` total is under 500 KB the files probably came from the wrong partition; the correct source is the `image/` directory inside Kenzo's `NON-HLOS.bin` (Kenzo = WCN3660B, iris=2). Also see the next two rows. |
| dmesg: `reserved-memory: wcnss@... overlaps with qseecom@...` | The reserved-memory carveouts for wcnss and qseecom overlap, so the PIL driver's `ioremap_wc` of the program segments returns `-EINVAL` whatever firmware you use. This is a kernel/DTS issue, not a userspace one. The kernel tree this project targets already has working carveouts; if you use a different tree, move one of the two regions so they don't overlap and rebuild. |
| dmesg: `mbox_request_channel: can't parse "mboxes" property` | The wcnss smd-edge nodes reference the APCS mailbox through `mboxes`, but the mailbox provider is missing `#mbox-cells = <1>;` or the smd-edge node lacks the property. Without it SMD messages can't be delivered and `wlan0`/`hci0` never appear. Fix in the DTS of your kernel tree. |
| The device-tree section prints "NONE FOUND" while remoteproc0 says `firmware=wcnss.mdt` | Older diag scripts matched only `compatible = qcom,wcnss*` and missed nodes without a compatible. The current script uses the four-heuristic sweep and prints a note when DT nodes were only found via the dmesg fallback but sysfs shows the driver bound. |

---

## 7. Battery management and 24/7 server pass-through

Running a phone as a 24/7 server with the battery held at 100% accelerates capacity loss and causes heat and
swelling. Kenzo's Qualcomm PM8950 / SMBCHG hardware supports power-path switching: with charging disabled, the
PMIC cuts current to the battery completely while still powering `VSYS` directly from USB VBUS. The battery sits
cool at 0 mA and still acts as a UPS during a power cut.

**Kernel side** (`patches/kernel/0003`): adds a `charging_enabled` sysfs attribute to `qcom-smbchg-usb` and ties
`current_ua == 0` in `smbchg_charging_set_ilim()` to the PMIC register `SMBCHG_BAT_IF_CMD_CHG` (`CHG_EN_BIT`),
so userland can stop battery charging while keeping USB power active.

**Userland side**: `kenzo-batteryd` is an autonomous daemon (`kenzo-batteryd.service`, enabled by default)
that follows `/etc/kenzo-battery.conf`:

```ini
# Battery charge thresholds for 24/7 server operation
STOP_THRESHOLD=60
START_THRESHOLD=58
CHECK_INTERVAL_SEC=30
```

- When the battery reaches `STOP_THRESHOLD` (default 60%), charging is cut and power flows directly from USB.
- When it drops to `START_THRESHOLD` (default 58%), through self-discharge or a transient power outage, charging
  resumes automatically.

```bash
sudo kenzo-batteryd status       # capacity, voltage, current and threshold state
sudo kenzo-batteryd disable      # cut off charging immediately (force USB pass-through)
sudo kenzo-batteryd enable       # re-enable charging
```

---

## 8. Script reference

### Host side (`scripts/`)

| Script | What it does |
|---|---|
| [setup-deps.sh](scripts/setup-deps.sh) | One-shot, re-runnable host dependency install (build-essential, gcc-aarch64, cpio, bison/flex, u-boot-tools, zstd, docker, qemu-user-static/binfmt). |
| [build-kernel.sh](scripts/build-kernel.sh) | Builds the msm8956 defconfig + three fragments (`config/kenzo*.fragment`). Outputs `out/kernel/Image.gz`, `out/dtbs/*.dtb`, `out/modroot/`. Respects `KERNEL_SRC`, `CROSS_COMPILE`, `THREADS`. |
| `apply-kernel-patches.sh` | Run by `build-kernel.sh`. Applies `patches/kernel/*.patch` to `$KERNEL_SRC`, idempotently. A patch that no longer applies only warns unless `KENZO_STRICT_PATCHES=1`; `KENZO_SKIP_PATCHES=1` skips patching. |
| [build-bootimg.sh](scripts/build-bootimg.sh) | Builds `out/boot.img` from `assets/lk2nd.img` (or `LK2ND=...`) + Image.gz + dtbs as Android boot v2. Adds `console=tty0 quiet loglevel=3`; `KENZO_VERBOSE=1` keeps debug-level. |
| `fix-dtb.sh` | Run by `build-bootimg.sh`. Applies the DTS fixes in [§9](#9-hardware-fixes-applied-in-the-dtb) directly to the compiled DTB (node lookup, idempotent, kenzo-only), so a `boot.img` rebuild is enough even if your kernel source differs from the patches. `KENZO_NO_DTB_FIX=1` skips it. |
| [build-rootfs.sh](scripts/build-rootfs.sh) | **Main entry for the image.** See [§2](#2-build-strict-order-kernel--bootimg--rootfs--flash). |
| [setup_rootfs.sh](scripts/setup_rootfs.sh) | Runs **inside** the arm64 chroot. Installs packages (see `apt_install_best_effort`), DEB releases (fastfetch, delta), NodeSource 22, GitHub CLI, uv, bun, docker compose v2 + buildx, and the ufw and fail2ban **packages** (enablement stays on-device). Writes the Docker `daemon.json`, sets iptables-nft alternatives, installs Oh My Zsh + plugins as the target user, writes a marker-guarded `~/.zshrc` (rebuilds don't clobber user edits) with aliases for eza/bat/fd/rg/btop/uv/fzf/tmux/docker/Git/delta, zoxide, a fastfetch greeting and Tailscale defaults, installs a minimal `~/.tmux.conf`, drops helper scripts in `~/bin` (`eveupdate`, `everebuild`, `evedeploy`, `evelogs`, `dockerstart`, `ddeploy`), and copies the dotfiles to `/etc/skel` so future users get them too. |
| [flash.sh](scripts/flash.sh) | Thin `fastboot` wrapper: `test` = `fastboot boot`, `boot` = flash `boot_a`, `rootfs` = flash `userdata_a`. |

### Device side, interactive

| Script | What it does |
|---|---|
| [setup_kenzo.sh](scripts/setup_kenzo.sh) | Runs on the phone. Passwords, sudoers, USB routing, clock sync, SSH hardening, Tailscale, UFW/fail2ban, Cloudflare tunnel, Oracle SSH reverse tunnel, zsh default shell, Git config, version summary. Has a flag-only mode (`--help`). Does not install packages. If run as root, it asks for or creates the default user first. |

### On the phone (`rootfs-overlay/`)

| Binary / unit | What it does |
|---|---|
| [usb-gadget-rndis.sh](rootfs-overlay/usr/local/sbin/usb-gadget-rndis.sh) + `usb-gadget-rndis.service` | Brings up the USB configfs gadget with the RNDIS function (phone = `192.168.7.2/24` on `usb0`) early on every boot. |
| [kenzo-batteryd](rootfs-overlay/usr/local/sbin/kenzo-batteryd) + `kenzo-batteryd.service` | Battery threshold manager; see [§7](#7-battery-management-and-247-server-pass-through). |
| [kenzo-health](rootfs-overlay/usr/local/sbin/kenzo-health) | Read-only sanity check (`sudo kenzo-health`): systemd units, remoteprocs (wcnss/adsp), firmware/driver dmesg errors, kernel modules, Wi-Fi/BT radios, ZRAM, storage, NTP time, battery/CPU health, and a warning whenever online CPUs differ from possible CPUs. |
| [kenzo-wifi](rootfs-overlay/usr/local/sbin/kenzo-wifi) | Wi-Fi/BT bring-up and diagnostics (`diag`, `firmware`, `start`, `connect`); see [§6](#6-wi-fi--bluetooth-wcnss-pronto-wcn36xx--btqcomsmd). No internet needed. |
| [kenzo-bt](rootfs-overlay/usr/local/sbin/kenzo-bt) | Bluetooth CLI helper in the style of `kenzo-wifi`. |
| [kenzo-keysd](rootfs-overlay/usr/local/sbin/kenzo-keysd) + [kenzo-powerkeyd](rootfs-overlay/usr/local/sbin/kenzo-powerkeyd) + `kenzo-powerkey.service` | Opens `/dev/input/event*` devices (via the `input` group), reads `KEY_POWER` release events to toggle the display through `kenzo-screen`, and monitors volume keys. The service orders after `systemd-udevd`, requires `/dev/input` to exist, settles briefly before starting, and has `video`/`render` supplementary groups. |
| [kenzo-screen](rootfs-overlay/usr/local/sbin/kenzo-screen) | Full display on/off: powers down the panel via DRM KMS (`FB_BLANK_POWERDOWN`), cuts the WLED backlight, inhibits the touchscreen to avoid phantom wakeups, and re-initializes the display cleanly on wake. |
| [kenzo-screen-banner](rootfs-overlay/usr/local/sbin/kenzo-screen-banner) | Clears tty1, shows the `fastfetch` banner and the `kenzo-ssh` connection instructions on the phone screen without terminal clobbering or prompt clipping. |
| `/etc/kenzo-battery.conf` | Battery thresholds (`STOP_THRESHOLD`, `START_THRESHOLD`, `CHECK_INTERVAL_SEC`). |
| `/etc/fastfetch/config.jsonc` | Fastfetch branding: CPU shown as "Qualcomm Snapdragon 650 (MSM8956)", GPU as "Qualcomm Adreno 510". |
| `/etc/systemd/logind.conf.d/10-kenzo-powerkey.conf` | Sets `HandlePowerKey=ignore` so `systemd-logind` doesn't suspend or shut down the phone on `KEY_POWER` and `kenzo-powerkeyd` handles it instead. It lives in `logind.conf.d` (not `systemd-logind.service.d`) because `[Login]` is `logind.conf` syntax. |
| `/etc/systemd/system/getty@tty1.service.d/autologin.conf` | Overrides the getty command line to `agetty -a <user> --noclear ...`. The username placeholder (`REPLACE_WITH_KENZO_USER`) is substituted by `build-rootfs.sh` at build time. |
| `/etc/modules-load.d/kenzo-wireless.conf` | Autoloads the 14-module Wi-Fi/BT chain on boot. |
| `usb-gadget-rndis.service`, `kenzo-powerkey.service`, `kenzo-batteryd.service` | Phone-critical services, all `WantedBy=multi-user.target` and enabled by default. |

---

## 9. Hardware fixes applied in the DTB

`build-bootimg.sh` runs `fix-dtb.sh`, and `build-kernel.sh` applies the matching `patches/kernel/*.patch` to
your source tree. Either path works and both are idempotent, so a rebuilt kernel DTB has the fixes natively.

### ADSP crash loop (`crash detected in adsp: type watchdog`)

**Cause.** In `msm8976.dtsi` the `adsp` node's `wdog` interrupt is `GIC_SPI 289`, which is also the interrupt of
its own `smd-edge`. The moment the ADSP sends its first SMD message (opening the IPCRTR channel) the kernel reads
it as a watchdog bite and "recovers" the ADSP, which boots, sends a message, and so on, hundreds of times. The
`qcom_smd_qrtr ... error -12`, `qcom,apr ... error -12` and `can't stop rproc: -22` lines are fallout. msm8953
(same LPASS block) uses SPI **293** for `wdog` and 289 only for the SMD edge. The firmware itself is fine:
`adsp.mdt` is relocatable and needs exactly 16 MiB, well inside the 23 MiB `lpass_mem` the DTS reserves.

**Fix.** `fix-dtb.sh` moves `wdog` to SPI 293 and prints
`dtb-fix: adsp wdog IRQ SPI 289 ... -> SPI 293`. Rebuild and test:

```
./scripts/build-bootimg.sh
./scripts/flash.sh test      # RAM-only boot first
./scripts/flash.sh boot
```

After the fix, `sudo kenzo-health` should show `remoteproc1 adsp running`. That only means the DSP is up; audio
output still needs the `qcom,q6*` / WCD9335 stack, ALSA UCM profiles and speaker/mic routing, which are not
done here. If you want the DSP off until you work on audio (it costs power), set
`&adsp { status = "disabled"; };` in `msm8956-xiaomi-kenzo.dts` (or use `fdtput` on the DTB) and rebuild.

If the ADSP is looping on a running system and you can't reflash yet, stop auto-recovery:
```
echo disabled | sudo tee /sys/class/remoteproc/remoteproc1/recovery
```
Confirm the number with `cat /sys/class/remoteproc/remoteproc*/name`. If crashes continue after the fix, the
interrupt was not the only problem: collect
`sudo dmesg | grep -iE 'adsp|remoteproc1|smp2p|qrtr' | head -60` from a fresh boot and look at the **first**
crash, not the 548th.

### CPUs: 4x A53 + 2x A72, not 4+4

`msm8976.dtsi` describes `cpu@100..103` (four A72), but MSM8956 has only two. Two of the nodes never come up,
which costs boot time and prints `failed to come online` on every boot. `fix-dtb.sh` disables the two extra
nodes (`cpu@101` and `cpu@102` by default; `patches/kernel/0002-*.patch` does the same in `msm8956.dtsi`),
so the kernel then reports 6 possible CPUs, all online.

- The default choice (`101 102`) is inferred from observed `online` lists. Confirm with
  `dmesg | grep -i 'failed to come online'`. If it names other CPUs, pass their `reg` values:
  `KENZO_DISABLE_CPUS="102 103" ./scripts/build-bootimg.sh`. `KENZO_DISABLE_CPUS=none` keeps all eight.
- The A72 cluster still has no cpufreq/CPR in the DTS, so those cores run at the bootloader's frequency.
- The `cpu*-thermal` zones for the absent cores remain in the DT and are harmless unless a sensor on an absent
  core reads high.

---

## 10. Kernel and boot notes

- **Kernel patches:** none are required to boot or to use Wi-Fi/BT. The patches in `patches/kernel/` cover the
  ADSP wdog IRQ, the CPU node cleanup and the battery pass-through attribute. The same kernel tree builds a
  Lineage 23.2 kernel (`7.0.0-msm8956+`, same panel drivers, same DTS apart from a touchscreen supply tweak).
- **Panel:** lk2nd patches the panel compatible at boot (`xiaomi,kenzo-panel` → boe-nt35532 / sharp-r63315 /
  tianma-nt35596), so the DTS needs no edit.
- **Wireless nodes:** `wcnss@a21b000` / `pronto@a21b000` are `status = "okay"` with
  `firmware-name = "wcn3660"` and `iris = <2>`.
- **Cmdline:** keeps `lk2nd.pass-ramoops=zap`; `maxcpus=4` is not used.
- **lk2nd binaries:** `assets/lk2nd.img` is the default (postmarketOS build). `assets/lk2nd-from-lineage-boot.img`
  is the lk2nd extracted from a Lineage `boot.img`; use it with
  `LK2ND=assets/lk2nd-from-lineage-boot.img ./scripts/build-bootimg.sh` if the default misbehaves.
- **Kernel fragments:**
  - `config/kenzo-docker.fragment` sets `CONFIG_TUN=y`, so Tailscale works with no `modprobe tun`, even if
    `/lib/modules` is ever empty.
  - `config/kenzo-wireless.fragment` is merged into every build (see [§6](#6-wi-fi--bluetooth-wcnss-pronto-wcn36xx--btqcomsmd)).
