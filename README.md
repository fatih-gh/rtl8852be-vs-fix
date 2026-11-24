# RTL8852BE-VS 5 GHz fix for Linux

Installs a patched `rtw89` driver for the Realtek **RTL8852BE-VS** Wi-Fi card (PCI ID `10ec:b85b`, RFE type 41), which can't see 5 GHz networks with the stock Linux driver. Found in HP laptops such as the HP 14-em0xxx.

The fix is the upstream patch "wifi: rtw89: Override antenna number for RTL8852BE-VS", from [morrownr/rtw89](https://github.com/morrownr/rtw89), pinned to commit `8bbbaca`. It's expected to reach mainline in kernel 7.4.

## What it does

- Asks for your distribution (Fedora, Debian/Ubuntu/Mint, or Arch/Manjaro/EndeavourOS), with the detected one as the default
- Installs the build tools and kernel headers with that distribution's package manager
- Builds and installs the driver with DKMS, so it rebuilds after kernel updates
- Installs the firmware and blacklists the conflicting in-kernel driver
- Sets the Wi-Fi country code (detected from your time zone, or one you choose)
- Optionally turns off Wi-Fi power saving for steadier speed
- Adds a boot service that falls back to the in-kernel driver if the patched one is missing or refused
- Enrolls the DKMS signing key when Secure Boot is enabled

## Requirements

- Fedora, Debian/Ubuntu/Linux Mint, or Arch/Manjaro/EndeavourOS, with systemd and kernel 6.6 or newer
- An internet connection (2.4 GHz works with the stock driver)

Tested on Fedora 45 with kernel 7.2. The Debian and Arch paths haven't been tested on hardware yet. Reports are welcome.

## Usage

Update the system and reboot first, so the running kernel matches the headers that get installed:

| Distribution | Update command |
|---|---|
| Fedora | `sudo dnf upgrade --refresh -y && sudo reboot` |
| Debian / Ubuntu / Mint | `sudo apt update && sudo apt full-upgrade -y && sudo reboot` |
| Arch / Manjaro / EndeavourOS | `sudo pacman -Syu && sudo reboot` |

Then run:

```bash
bash rtw89-install.sh
```

To answer the prompts in advance:

```bash
DISTRO=fedora COUNTRY=TR PERF=y bash rtw89-install.sh
```

`DISTRO` can be `fedora`, `debian` or `arch`.

If Secure Boot is enabled, choose **Enroll MOK** on the blue screen after rebooting and enter the password you set. On Arch, this only works if you boot through shim.

## Check

```bash
lsmod | grep rtw89_8852be_git
```

```bash
nmcli dev wifi list --rescan yes
```

## Uninstall

```bash
sudo dkms remove rtw89/6.15 --all
```

```bash
sudo rm -f /etc/modprobe.d/rtw89.conf /etc/modprobe.d/rtw89-perf.conf /etc/modprobe.d/regdom.conf /etc/NetworkManager/conf.d/wifi-powersave-off.conf
```

```bash
sudo systemctl disable --now rtw89-fallback.service && sudo rm -f /etc/systemd/system/rtw89-fallback.service /usr/local/sbin/rtw89-fallback
```

Run `sudo dkms status` first if the version shown isn't `6.15`.

## License

MIT
