# omamobile-usb

The phone's USB data follows the lock, as on Android:

| The phone | At a computer | At a charger |
| --- | --- | --- |
| Locked | No USB data: the gadget is unbound, the computer sees no device, the phone only charges. USB host ports authorize no new device. | Charges |
| Unlocked, nothing chosen yet | Charging only, and a notification asks what the computer may use: **SSH & network**, **File transfer** or **Both** | Charges, nothing asked |
| Unlocked, chosen | What was chosen, until the cable comes out. A lock turns it off; the unlock brings it back without asking again | |
| Before the first session of a boot | USB as the initramfs set it up (the USB network), so a phone whose session never starts can still be reached | |

- **SSH & network** is the gadget the initramfs sets up: CDC NCM (the USB network, `172.16.42.1`, SSH) and the ACM serial port.
- **File transfer** is MTP: `umtprd` (package `umtp-responder`) on the gadget's FunctionFS, run as the session's user, sharing that user's Documents, Downloads, Music, Pictures and Videos (the XDG user folders that exist inside the home). Never the whole home: its dotfiles hold keys and configuration. A computer's file manager sees the phone as a media device.

## How it works

`omamobile-usbd` (system unit `omamobile-usb.service`, root) owns the gadget (`/sys/kernel/config/usb_gadget/g1`).

- **Locked** is logind's `LockedHint` on seat0's active session. Omarchy's lock sets it from omamobile-omarchy 0.1.54 (patch 0038); with an older lock the hint never changes, and the phone counts as unlocked.
- **A computer** is the USB power supply's BC1.2 detection, `usb_type` `SDP` or `CDP` (a charger reads `DCP`). The charger detects it by itself, so it works with the gadget unbound. A choice ends when VBUS goes away, not when the detection reads something else for a moment.
- It reacts to logind's signals and the kernel's uevents (power supply, UDC, USB), and looks again every 30 s.
- The session's side, `omamobile-usb-prompt` (user unit), asks in a critical notification (it stays until answered) and withdraws it when the question no longer stands (locked, unplugged, chosen elsewhere). A dismissed question leaves the phone charging; `omamobile-usb ask` asks again.
- Stopping the unit (`systemctl stop omamobile-usb`, or removing the package) puts the USB network back. `systemctl mask omamobile-usb` keeps it off at boot (`disable` doesn't remove the package's wants link).

## Commands

```sh
omamobile-usb                 # the lock, what is at the port, the USB mode
omamobile-usb mode network    # charge | network | files | both, for this connection
omamobile-usb ask             # ask again in a notification
```

Only the session's user and root may ask, and only while unlocked with a computer at the port.

## Settings: `/etc/omamobile/usb.conf`

| Key | Values | Default |
| --- | --- | --- |
| `LOCKED` | `off`, or `keep` to leave USB as it is while locked (bring-up: SSH over USB on a locked phone) | `off` |
| `UNLOCKED` | What a computer gets before anyone chooses: `ask`, `charge`, `network`, `files`, `both` | `ask` |
| `SUPPLY` | The power supply's name, when the first USB one in `/sys/class/power_supply` isn't the port's | the first |

The file is read, never run, at every change and every 30 s.

## Before installing it on a phone you work on over USB

Once it runs, a locked phone has no SSH over USB. Install and start it with a way back armed: a dead-man timer that stops the unit (`systemd-run --on-active=120 systemctl stop omamobile-usb`), checked over a fresh SSH login after the phone is unlocked and SSH & network chosen. `LOCKED=keep` is the setting for bring-up phones.

## Files

| Path | What |
| --- | --- |
| `lib/omamobile-usbd` | The daemon (`/usr/lib/omamobile/`) |
| `lib/omamobile-usb-prompt` | The session's notification |
| `bin/omamobile-usb` | The command |
| `systemd/system/omamobile-usb.service`, `omamobile-usb-mtp@.service` | The daemon; umtprd for one user (started by the daemon only) |
| `systemd/user/omamobile-usb-prompt.service` | The prompt, in every graphical session |
| `etc/omamobile/usb.conf` | Settings |
| `test/all` | The policy against a fake gadget, supply, session and systemctl; the prompt against a fake notify-send; the CLI |
