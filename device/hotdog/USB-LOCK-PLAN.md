<!-- SPDX-License-Identifier: MIT -->
# USB lock plan (hotdog): no USB data while locked, a prompt at a computer

**Status (2026-11-28): U1-U5 pass on the phone with the owner's taps (lock,
unlock, prompt, SSH & network, file transfer, both, unplug); the service
runs. Open: a suspend while locked, a wall charger (U5's second half) and a
boot (U6).** New packages `packages/umtp-responder` 1.8.1-2 and
`packages/omamobile-usb` 0.1.3, and
`packages/omamobile-omarchy` 0.1.54 (patch 0038). No kernel or
device-package change.

**Goal.** As on Android: a locked phone gives a computer no USB data at all,
only the charge. Plugged into a computer while unlocked, the phone charges
and asks in a notification what the computer may use: **SSH & network**
(the USB network SSH runs on), **File transfer** (MTP) or **Both**. The
design and settings are in [packages/omamobile-usb/README.md](../../packages/omamobile-usb/README.md).

**What changes for work on this phone.** Once `omamobile-usb` runs, SSH over
USB works only while the phone is unlocked and SSH & network was chosen
for the connection. After every plug-in someone at the phone taps the
prompt. `LOCKED=keep` in `/etc/omamobile/usb.conf` keeps the USB network up
while locked (bring-up), `UNLOCKED=network` skips the question, and
`systemctl stop omamobile-usb` (or `mask` for the next boot) puts things back
as before.

## 1. Facts

| What | Source |
| --- | --- |
| The initramfs builds gadget `g1` (CDC NCM `ncm.usb0` + ACM `acm.GS0`) and binds it to `a600000.usb`; in Arch, systemd-networkd gives `usb0` 172.16.42.1 (`20-usb-gadget.network`), ufw allows 22/tcp on `usb0` only | `initramfs/init`, phone, 2026-11-28 |
| The charger tells a computer from a charger by itself (BC1.2): `pm8150b-charger/usb_type` reads `Unknown [SDP] DCP CDP` on the laptop's port | phone, 2026-11-28, `7.3.0-rc6-omamobile-crypt1-gf3a11a5f5062` |
| `CONFIG_USB_CONFIGFS_F_FS=y`, `CONFIG_USB_F_FS=y`: FunctionFS (for MTP) is built in. The UDC runs at high speed here (`current_speed`), maximum super-speed-plus | `/proc/config.gz`, `/sys/class/udc/a600000.usb` |
| No USB host bus (`/sys/bus/usb/devices` is empty): the port is peripheral only, so the host-port part of the lock does nothing on this phone | phone |
| Nothing in Omarchy 4.5 sets logind's `LockedHint` (no `SetLockedHint` or `LockedHint` under `/usr/share/omarchy`; it read `no`); the lock's state is only on its IPC, `omarchy-shell lock isLocked`, reachable from the user's session | phone, 2026-11-28, `grep -r`, `loginctl show-session 1` |
| The shell (quickshell) runs in `user@1000.service`, not in logind's session 1, but `SetLockedHint` on `/org/freedesktop/login1/session/auto` from there reaches the user's display session without polkit (`b false`, exit 0) | phone, 2026-11-28, through `systemd-run --machine=<user>@.host --user` |
| Omarchy's notification server shows actions (up to 16) and keeps a critical notification until it is answered; a normal one expires after 8 s, which ends `notify-send -A`'s wait without an answer | `plugins/notifications/Service.qml` (`durationFor`) |
| `umtp-responder` isn't in Arch Linux ARM or the AUR; upstream 1.8.1 (GPL-3.0-or-later) builds with systemd's readiness notice, writes full-, high- and super-speed descriptors, and hides dotfiles with `show_hidden_files 0` | upstream source |

## 2. Design

- `omamobile-omarchy` 0.1.54, patch 0038: the lock sets `LockedHint` when a
  lock is requested and clears it at unlock (from `currentlyLocked()`, the
  lock's own state), and sends it once when the shell starts.
- `omamobile-usbd` (root, `omamobile-usb.service`): reads `LockedHint` of
  seat0's active session and the supply's `usb_type`, and owns the gadget:
  unbound while locked or until a choice; NCM + ACM for SSH & network;
  `ffs.mtp` (FunctionFS mounted for the session's user, `umtprd` as that
  user, sharing only the XDG media folders) for file transfer. Before the
  first session of a boot it leaves the gadget as the initramfs set it up.
  A choice ends when VBUS goes; a lock keeps it, and the unlock brings it
  back. Its stop puts the USB network back.
- `omamobile-usb-prompt` (user unit): the critical notification with the
  three actions; `omamobile-usb` the CLI (`status`, `mode`, `ask`).

## 3. Runbook

Every step is the owner's go. The owner holds the phone; announce each
step, since USB data dropping looks like a broken phone. A step that cuts
SSH has a dead-man timer that stops `omamobile-usb`, which puts the USB
network back. Gotcha: when the phone's USB network comes back, the laptop's
NetworkManager may drop 172.16.42.2 from the link; re-add it with
`sudo ip addr add 172.16.42.2/24 dev <the phone's interface>` (IPv6
link-local, `root@fe80::…%<iface>` in `OMAMOBILE_SSH_HOST`, works meanwhile).

### U0. Read-only: the detection follows the cable (risk: none)

```sh
tools/phone-ssh 'timeout 60 udevadm monitor --udev -s power_supply'   # owner: unplug, wait 5 s, plug back
tools/phone-ssh 'cat /sys/class/power_supply/pm8150b-charger/{online,usb_type}'
```

Expect: change events on `pm8150b-charger` at the unplug and the plug;
`online` 1 and `[SDP]` afterwards (SSH needs the gadget, so the first
command's output arrives after the replug). **Stop** if no event arrives: the
daemon would then see a plug only at its 30 s look.

### U1. Install the packages (risk: low; the shell restarts)

```sh
# the three built packages: umtp-responder and omamobile-usb (aarch64), omamobile-omarchy (any)
for f in umtp-responder-1.8.1-1-aarch64 omamobile-usb-0.1.0-1-aarch64 omamobile-omarchy-0.1.54-1-any; do
  tools/phone-ssh "cat > /var/tmp/$f.pkg.tar.zst" < "<build dir>/$f.pkg.tar.zst"
done
tools/phone-ssh 'pacman -U --noconfirm /var/tmp/{umtp-responder-1.8.1-1-aarch64,omamobile-usb-0.1.0-1-aarch64,omamobile-omarchy-0.1.54-1-any}.pkg.tar.zst'
tools/phone-ssh 'omamobile-omarchy-patches status | tail -3'
# announce: the shell restarts
tools/phone-ssh 'systemd-run --machine=<user>@.host --user -q omarchy-restart-shell'
# the prompt's wants link starts it only at the next login: start it now
tools/phone-ssh 'systemctl --user -M <user>@.host start omamobile-usb-prompt'
```

Expect: 0038 applied; `omamobile-usb` not running (its wants link starts it
at the next boot). Then the owner locks and unlocks the phone, and
`loginctl show-session 1 -p LockedHint` reads `yes` while locked (over SSH,
which still works) and `no` after. **Stop** if it stays `no` while locked.
Rollback: `pacman -U` the cached `omamobile-omarchy-0.1.50`, remove
`omamobile-usb` and `umtp-responder`.

### U2. First start, unlocked, under a dead-man timer (risk: medium, cuts SSH)

```sh
tools/phone-ssh 'systemd-run --unit=x-usb-deadman --on-active=180 systemctl stop omamobile-usb.service'
tools/phone-ssh 'systemctl start omamobile-usb.service'   # SSH drops here
```

Expect, with the phone unlocked: USB data stops (the laptop loses the
interface), the notification "Connected to a computer" appears with three
buttons; the owner taps **SSH & network**, the link comes back, a short
"USB: SSH & network on" notice shows. Then over a fresh login:

```sh
tools/phone-ssh --fresh 'systemctl stop x-usb-deadman.timer; omamobile-usb; journalctl -u omamobile-usb -b --no-pager | tail'
```

**Stop** if the notification doesn't appear or SSH isn't back in 3 minutes:
the timer stops the unit and the USB network returns. Rollback:
`systemctl stop omamobile-usb`.

### U3. Lock and unlock (risk: medium)

Re-arm the dead-man timer as in U2. The owner locks the phone (power key):
the laptop loses the link. The owner unlocks: the link comes back without a
question. Check over `--fresh`, stop the timer. **Stop** if the link stays
up while locked (patch 0038 or the daemon), or doesn't come back at unlock.

### U4. File transfer (risk: low)

```sh
tools/phone-ssh 'systemd-run --unit=x-usb-deadman --on-active=180 systemctl stop omamobile-usb.service; omamobile-usb ask'
```

The owner taps **Both**. Expect SSH back, and the phone in the laptop's file
manager (or `gio mount -li | grep -i mtp`) with Documents, Downloads, Music,
Pictures and Videos as storages; copy a file both ways. Then `--fresh`, stop
the timer. **Stop** if the gadget doesn't bind (`journalctl -u
omamobile-usb -u 'omamobile-usb-mtp@*'`).

### U5. Unplug and charger (risk: low)

The owner unplugs and plugs back: the question comes again (the choice
ended with the cable). At a wall charger: no question, `omamobile-usb`
reads "a charger" afterwards.

### U6. A boot (risk: medium; a reboot)

`systemctl reboot` (owner's yes). Expect SSH over USB before the session
starts, then charging only after login until the owner chooses (or nothing
while the lock is up). **Stop** if SSH never comes back after a choice: the
owner runs `sudo systemctl mask --now omamobile-usb` in a terminal on the
phone, which puts the USB network back and keeps the unit off.

## 4. Results

**2026-11-28, `7.3.0-rc6-omamobile-crypt1-gf3a11a5f5062`, omamobile-shell
0.2.143.** A tap on the prompt was stood in for by Omarchy's notification
IPC, run on the phone from a transient unit so it outlives the SSH drop:
`omarchy-shell notifications invokeAction N` (1 SSH & network, 2 File
transfer, 3 Both) presses the newest toast's button.

- **U1 pass.** umtp-responder 1.8.1-1, omamobile-usb 0.1.0,
  omamobile-omarchy installed (the fork's build, where the same patch was
  0035 in 0.1.53; renumbered 0038 in 0.1.54 here, after upstream's 0.1.53
  and the 0035 of the open #1092); 33 Omarchy patches applied, it among
  them; after `omarchy-restart-shell` the hint read `no` (unlocked).
- **U2, three findings, then pass on 0.1.2.**
  1. The prompt's user unit wasn't running: its wants link acts at the next
     login only (now in U1). The daemon had gone to charging only and asked;
     the dead-man timer brought the network back at 180 s.
  2. The question counter restarted at 1 with the daemon, and the prompt,
     still running, had shown question 1: nothing appeared (`invokeAction`
     answered `none`). 0.1.1: a question's id is the clock in ns, and the
     prompt forgets what it showed when the state file goes.
  3. After the choice the daemon rebound the gadget about twice a second
     (35 s of CPU in 3 minutes, `usb0` flapping, no link): it compared the
     wanted functions (`ncm.usb0 acm.GS0`) with the linked ones in their
     listing order (`acm.GS0 ncm.usb0`), so every look rebound, and each
     rebind's uevents brought the next look. 0.1.2 compares sets; a test
     checks that a second look leaves a bound gadget alone.
  
  On 0.1.2: charging only and the prompt at start, SSH & network pressed
  8 s later, SSH back 11 s after the start; 0.9 s of CPU.
- **U4, two findings, then pass on umtp-responder 1.8.1-2 and omamobile-usb
  0.1.3.** umtprd as the user exited at once, `mq_open error 22`: its command
  queue asked for 20 messages, over `fs.mqueue.msg_max` (10) for a process
  without CAP_SYS_RESOURCE; the package now asks for 10. And the daemon tried
  the failing MTP start at every look, rebinding each time; from 0.1.3 a
  failed start isn't tried again until the next choice or plug. Then: Both
  pressed, SSH back at 11 s, the laptop saw the CDC interfaces and an Imaging
  (class 6) one; `mtp-detect` read model "OnePlus 7T Pro" and the storages
  Documents, Downloads, Music, Pictures, Videos; `mtp-sendfile` wrote a file
  into Documents, owned by the session's user, mode 644 (removed afterwards).
- **U3, lock half pass.** `omarchy-shell lock lock`: `LockedHint=yes`, the
  daemon logged "locked … USB: charge (chosen: both)" at once, the laptop
  lost the link within 2 s, umtprd stopped. The dead-man timer then stopped
  the unit and the network came back with the phone still locked. **Open:**
  the unlock (the hint back to `no`, the choice back without a question)
  needs the owner's PIN.

**2026-11-28 18:28-18:31, the owner's hands (omamobile-usb 0.1.3,
umtp-responder 1.8.1-2).** Daemon journal against a laptop-side recorder
(`lsusb` interface classes and a ping, once a second):

| Time | The owner | Daemon | Laptop |
| --- | --- | --- | --- |
| 18:28:47 | (phone locked from the earlier test; unit started) | locked, USB: charge | no USB device |
| 18:29:09-13 | unlocks, taps Both | unlocked, asking; then both (chosen: both) | CDC + Imaging (6), ping ok |
| 18:29:18 | locks | locked, charge (chosen: both) | no USB device |
| 18:29:49 | unlocks | both (chosen: both), no question | CDC + MTP, ping ok |
| 18:30:17-34 | locks, unplugs, plugs back while locked | locked; port none (choice ends); SDP, still charge | no USB device |
| 18:30:57-31:00 | unlocks, taps Both | asking; both | CDC + MTP, ping ok |

U3's second half passes (the unlock brings the choice back without a
question); U5's first half passes (unplugging ends the choice, a plug-in
while locked gives no data, the unlock asks again). No suspend fell in this
window (no `PM: suspend` line), so locked-and-suspended is not covered yet.
The service was left running, the dead-man timer stopped.
