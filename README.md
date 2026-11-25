# RTL8852BE-VS 5 GHz fix for Linux

Installs a patched `rtw89` driver for the Realtek **RTL8852BE-VS** Wi-Fi card (PCI ID `10ec:b85b`, RFE type 41), which can't see 5 GHz networks with the stock Linux driver. Found in HP laptops such as the HP 14-em0xxx.

The fix is the upstream patch "wifi: rtw89: Override antenna number for RTL8852BE-VS", from [morrownr/rtw89](https://github.com/morrownr/rtw89), pinned to commit `8bbbaca`. It's expected to reach mainline in kernel 7.4.

The script also applies a fix for bogus signal readings (see [RSSI fix](#rssi-fix)) and five fixes backported from the upstream rtw89 tree (see [Upstream patches](#upstream-patches)).

On an HP 14-em0xxx, 5 GHz went from invisible to about 190 Mbit/s steady (230–250 Mbit/s peaks on fast.com), the same as the Windows driver at the same spot.

## What it does

- Asks for your distribution (Fedora, Debian/Ubuntu/Mint, or Arch/Manjaro/EndeavourOS), with the detected one as the default
- Installs the build tools and kernel headers with that distribution's package manager
- Builds and installs the driver with DKMS, so it rebuilds after kernel updates
- Installs the firmware and blacklists the conflicting in-kernel driver
- Sets the Wi-Fi country code (detected from your time zone, or one you choose)
- Applies the RSSI fix and the upstream patches, and builds without them if the patched build fails
- Sets Wi-Fi power saving: **auto** (default), always off, or always on
- Adds a boot service that falls back to the in-kernel driver if the patched one is missing or refused
- Enrolls the DKMS signing key when Secure Boot is enabled

## Requirements

- Fedora, Debian/Ubuntu/Linux Mint, or Arch/Manjaro/EndeavourOS, with systemd and kernel 6.6 or newer
- An internet connection (2.4 GHz works with the stock driver)

Tested on Fedora 45 (kernel 7.2) and Arch (kernel 7.3). The Debian path hasn't been tested on hardware yet. Reports are welcome.

## Usage

Update the system and reboot first, so the running kernel matches the headers that get installed:

| Distribution | Update command |
|---|---|
| Fedora | `sudo dnf upgrade --refresh -y && sudo reboot` |
| Debian / Ubuntu / Mint | `sudo apt update && sudo apt full-upgrade -y && sudo reboot` |
| Arch / Manjaro / EndeavourOS | `sudo pacman -Syu && sudo reboot` |

Then install with one command:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fatih-gh/rtl8852be-vs-fix/main/rtw89-install.sh)
```

Or clone the repository and run the script:

```bash
git clone https://github.com/fatih-gh/rtl8852be-vs-fix && cd rtl8852be-vs-fix && bash rtw89-install.sh
```

To answer the prompts in advance:

```bash
DISTRO=arch COUNTRY=TR PERF=auto bash rtw89-install.sh
```

| Variable | Values |
|---|---|
| `DISTRO` | `fedora`, `debian`, `arch` |
| `COUNTRY` | two-letter code such as `TR`, `DE`, `US`, or `00` for world |
| `PERF` | `auto` (default), `off`, `on` |
| `RSSI_FIX` | `y` (default), `n` (also skips the upstream patches) |
| `UPSTREAM` | `y` (default), `n` |

If Secure Boot is enabled, choose **Enroll MOK** on the blue screen after rebooting and enter the password you set. On Arch, this only works if you boot through shim.

## Wi-Fi power saving

On this card, power saving roughly halves 5 GHz throughput. The `auto` mode follows your power settings:

| State | Power saving |
|---|---|
| Power profile **Power Saver** | on |
| Power profile **Performance** | off |
| **Balanced** on charger | off |
| **Balanced** on battery | on |

It reacts to plugging in or unplugging, power profile changes (needs `power-profiles-daemon`), and every reconnect. Check what it did with `journalctl -t wifi-power-policy -n 5`.

## RSSI fix

On the RTL8852B family, the driver adds a signed correction to each path's RSSI using unsigned 8-bit math. On an unused path (path A on the RTL8852BE-VS), the value underflows and shows up as an impossible +12…+17 dBm. Since the reported signal is the maximum of both paths, the signal indicator jumps between the real value and "full".

`patches/0001-rtw89-8852bx-clamp-rssi-on-rpl-conversion.patch` does the math in `int` and clamps it to 0…255. The script applies the same change with `sed`, so it also works with the one-line install. If the patched build fails, it builds without it. Set `RSSI_FIX=n` to skip it.

## Upstream patches

These commits from the rtw89 maintainer tree ([pkshih/rtw](https://github.com/pkshih/rtw), `rtw-next`) aren't in morrownr/rtw89 at `8bbbaca` yet. They are expected in kernel 7.5:

| Patch | Upstream commit | What it does |
|---|---|---|
| `0001` | [`e25702b`](https://github.com/pkshih/rtw/commit/e25702b576595c49bcbe7b9b99df7ef114399203) | Avoid premature power save entry when the AP has buffered traffic |
| `0002` | [`e1744a3`](https://github.com/pkshih/rtw/commit/e1744a3a4e210986a78c308488b1503f103160bd) | Low-latency power save for RTL8852B/RTL8852BT |
| `0003` | [`154d366`](https://github.com/pkshih/rtw/commit/154d3668b645ad196fe922f371eb9c26f1f61c5b) | Set the rate adaptation start level once the RSSI is known |
| `0004` | [`f3207ae`](https://github.com/pkshih/rtw/commit/f3207ae572742077b42bb398316197ffb423c054) | Wi-Fi/Bluetooth antenna map on shared-antenna chips |
| `0006` | [`0bd0557`](https://github.com/pkshih/rtw/commit/0bd0557aefe635e5ffaeca86631362818aa86098) | New default value for the RTL8852B analog switching regulator |

The script downloads them from `patches/upstream/`, checks their SHA-256, and applies them on top of the RSSI fix. If one doesn't apply or the build fails, it builds without them.

Firmware stays at the linux-firmware version that the backport supports (0.29.29.18). Version 0.29.29.19 doesn't work with `8bbbaca`: the card associates, but the WPA handshake never completes.

## Check

```bash
lsmod | grep rtw89_8852be_git
```

```bash
nmcli dev wifi list --rescan yes
```

## Uninstall

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fatih-gh/rtl8852be-vs-fix/main/rtw89-install.sh) --uninstall
```

Or from a clone: `bash rtw89-install.sh --uninstall`

This removes the DKMS driver and config files, disables the fallback service and the power policy, reinstalls your distribution's firmware package, and switches back to the in-kernel driver. Reboot afterwards.

## License

MIT
