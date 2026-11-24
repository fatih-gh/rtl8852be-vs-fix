#!/bin/bash
COMMIT=8bbbacadf6fa73c3a3195aefbd4b2ec2422ae356
SRC=~/rtw89
LOG=~/rtw89-install.log
exec > >(tee "$LOG") 2>&1
say() { echo; echo "===== $* ====="; }
die() { echo; echo "!!!!! FAILED: $* !!!!!"; echo "Log: $LOG"; exit 1; }
[ "$EUID" -eq 0 ] && die "run as your normal user, not with sudo"
KVER=$(uname -r)
MODE=install
case "$1" in
  ""|--install) MODE=install ;;
  --uninstall|-u|uninstall) MODE=uninstall ;;
  -h|--help)
    echo "Usage: bash rtw89-install.sh [--install | --uninstall]"
    echo "Env: DISTRO=fedora|debian|arch  COUNTRY=XX  PERF=y|n"
    exit 0 ;;
  *) die "unknown option '$1' (use --install or --uninstall)" ;;
esac

say "Distribution"
if [ -z "$DISTRO" ]; then
  . /etc/os-release 2>/dev/null
  case " $ID $ID_LIKE " in
    *" fedora "*) GUESS=1 ;;
    *" debian "*|*" ubuntu "*) GUESS=2 ;;
    *" arch "*) GUESS=3 ;;
    *) GUESS="" ;;
  esac
  echo "Detected: ${PRETTY_NAME:-unknown}"
  echo "  1) Fedora"
  echo "  2) Debian / Ubuntu / Linux Mint"
  echo "  3) Arch Linux / Manjaro / EndeavourOS"
  if [ -t 0 ]; then
    read -r -p "Select your distribution [${GUESS:-none}]: " ANS
    ANS=${ANS:-$GUESS}
  else
    ANS=$GUESS
  fi
  case "$ANS" in
    1) DISTRO=fedora ;;
    2) DISTRO=debian ;;
    3) DISTRO=arch ;;
    *) die "no distribution selected" ;;
  esac
fi
case "$DISTRO" in
  fedora|debian|arch) echo "Using: $DISTRO" ;;
  *) die "DISTRO must be fedora, debian or arch" ;;
esac

if [ "$MODE" = uninstall ]; then
  say "Uninstall 1/5: removing DKMS driver"
  if command -v dkms >/dev/null && sudo dkms status rtw89 2>/dev/null | grep -q rtw89; then
    for v in $(sudo dkms status rtw89 | sed -n 's#^rtw89/\([^,: ]*\).*#\1#p' | sort -u); do
      sudo dkms remove "rtw89/$v" --all || true
      sudo rm -rf "/usr/src/rtw89-$v"
    done
  else
    echo "No DKMS rtw89 found."
  fi
  sudo rm -rf /lib/modules/*/extra/rtw89 /lib/modules/*/updates/dkms/rtw89_*_git.ko*
  sudo depmod -a

  say "Uninstall 2/5: removing config files"
  sudo rm -fv /etc/modprobe.d/rtw89.conf /etc/modprobe.d/rtw89-perf.conf /etc/modprobe.d/regdom.conf \
    /etc/NetworkManager/conf.d/wifi-powersave-off.conf

  say "Uninstall 3/5: removing fallback service"
  sudo systemctl disable rtw89-fallback.service 2>/dev/null || true
  sudo rm -fv /etc/systemd/system/rtw89-fallback.service /usr/local/sbin/rtw89-fallback
  sudo systemctl daemon-reload

  say "Uninstall 4/5: restoring distribution firmware"
  FWPKGS=""
  for f in /lib/firmware/rtw89/*; do
    [ -e "$f" ] || continue
    case "$DISTRO" in
      fedora) p=$(rpm -qf --qf '%{NAME}\n' "$f" 2>/dev/null | grep -v 'not owned') ;;
      debian) p=$(dpkg -S "$f" 2>/dev/null | cut -d: -f1) ;;
      arch)   p=$(pacman -Qoq "$f" 2>/dev/null) ;;
    esac
    [ -n "$p" ] && FWPKGS="$FWPKGS $p"
  done
  FWPKGS=$(echo $FWPKGS | tr ' ' '\n' | sort -u | tr '\n' ' ')
  if [ -n "${FWPKGS// }" ]; then
    echo "Reinstalling: $FWPKGS"
    case "$DISTRO" in
      fedora) sudo dnf reinstall -y $FWPKGS ;;
      debian) sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall $FWPKGS ;;
      arch)   sudo pacman -S --noconfirm $FWPKGS ;;
    esac || echo "WARNING: firmware reinstall failed - reinstall your linux-firmware package manually"
  else
    echo "No packaged rtw89 firmware found - nothing to restore."
  fi

  say "Uninstall 5/5: switching back to the in-kernel driver"
  for m in rtw89_8852be_git rtw89_8852b_git rtw89_8852b_common_git rtw89_pci_git rtw89_core_git; do
    sudo modprobe -r "$m" 2>/dev/null
  done
  sudo modprobe rtw89_8852be 2>/dev/null && echo "In-kernel rtw89_8852be loaded." || echo "Reboot to load the in-kernel driver."
  rm -rf "$SRC"

  say "Uninstalled"
  if mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    echo "The DKMS signing key stays enrolled (harmless). To remove it: sudo mokutil --delete /var/lib/dkms/mok.pub"
  fi
  echo "Reboot recommended:  sudo reboot"
  echo "Log: $LOG"
  exit 0
fi

say "1/7 System check (kernel $KVER)"
lspci -nn 2>/dev/null | grep -i b85b || echo "WARNING: 10ec:b85b not found - continuing anyway"
[ -d "/lib/modules/$KVER/kernel" ] || die "modules for running kernel $KVER are missing - reboot after your last kernel update and rerun"

say "2/7 Installing build tools + headers ($DISTRO)"
case "$DISTRO" in
  fedora)
    sudo dnf install -y git make gcc dkms mokutil elfutils-libelf-devel kernel-devel iw wireless-regdb || die "dnf failed"
    if [ ! -e "/lib/modules/$KVER/build/Makefile" ]; then
      sudo dnf install -y "kernel-devel-$KVER" || {
        V=${KVER%%-*}; R=${KVER#*-}; R=${R%.x86_64}
        sudo dnf install -y "https://kojipkgs.fedoraproject.org/packages/kernel/$V/$R/x86_64/kernel-devel-$KVER.rpm" \
          || die "no kernel-devel for $KVER - run 'sudo dnf upgrade --refresh', reboot, and rerun"
      }
    fi
    ;;
  debian)
    sudo apt-get update || die "apt-get update failed"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git build-essential dkms mokutil libelf-dev iw wireless-regdb \
      || die "apt-get install failed"
    if [ ! -e "/lib/modules/$KVER/build/Makefile" ]; then
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "linux-headers-$KVER" \
        || die "no linux-headers-$KVER - run 'sudo apt full-upgrade', reboot, and rerun"
    fi
    ;;
  arch)
    PKGBASE=$(cat "/usr/lib/modules/$KVER/pkgbase" 2>/dev/null || echo linux)
    sudo pacman -S --needed --noconfirm git base-devel dkms iw wireless-regdb mokutil "${PKGBASE}-headers" \
      || die "pacman failed - run 'sudo pacman -Syu', reboot, and rerun"
    ;;
esac
[ -e "/lib/modules/$KVER/build/Makefile" ] || die "kernel headers for $KVER not found"

say "3/7 Getting driver source (commit ${COMMIT:0:7})"
if [ ! -f "$SRC/Makefile" ]; then
  rm -rf "$SRC"
  git clone https://github.com/morrownr/rtw89 "$SRC" || die "git clone failed"
fi
cd "$SRC" || die "cannot enter $SRC"
git fetch origin >/dev/null 2>&1
git checkout -f -q "$COMMIT" || die "commit $COMMIT not found"
git log -1 --oneline
PKGVER=$(sed -n 's/^PACKAGE_VERSION="\?\([^"]*\)"\?/\1/p' dkms.conf | head -1)
[ -z "$PKGVER" ] && die "could not read PACKAGE_VERSION from dkms.conf"
echo "DKMS package: rtw89/$PKGVER"

say "4/7 Removing old/conflicting installs"
sudo make cleanup_target_system || true
if sudo dkms status rtw89 2>/dev/null | grep -q rtw89; then
  for v in $(sudo dkms status rtw89 | sed -n 's#^rtw89/\([^,: ]*\).*#\1#p' | sort -u); do
    sudo dkms remove "rtw89/$v" --all || true
    sudo rm -rf "/usr/src/rtw89-$v"
  done
fi

say "5/7 Building + installing with DKMS"
sudo dkms install "$PWD" || die "dkms install failed - see /var/lib/dkms/rtw89/$PKGVER/build/make.log"
for d in /lib/modules/*; do
  k=$(basename "$d"); [ "$k" = "$KVER" ] && continue
  [ -e "$d/build/Makefile" ] && sudo dkms install "rtw89/$PKGVER" -k "$k" || true
done
sudo make install_fw || echo "(install_fw failed - linux-firmware probably already has it)"
sudo cp -v rtw89.conf /etc/modprobe.d/
sudo dkms status rtw89

say "Wi-Fi region (country code)"
if [ -z "$COUNTRY" ]; then
  TZNAME=$(timedatectl show -p Timezone --value 2>/dev/null)
  COUNTRY=$(awk -v tz="$TZNAME" '$3==tz {print $1; exit}' /usr/share/zoneinfo/zone.tab 2>/dev/null)
  echo "Timezone '$TZNAME' -> detected country '${COUNTRY:-unknown}'"
  if [ -t 0 ]; then
    read -r -p "Country code to use [${COUNTRY:-00}] (2 letters, e.g. TR, DE, US; 00 = world): " ANS
    [ -n "$ANS" ] && COUNTRY="$ANS"
  fi
fi
COUNTRY=$(echo "${COUNTRY:-00}" | tr '[:lower:]' '[:upper:]')
if ! echo "$COUNTRY" | grep -qE '^([A-Z]{2}|00)$'; then
  echo "Invalid code '$COUNTRY', using 00 (world)"; COUNTRY=00
fi
echo "options cfg80211 ieee80211_regdom=$COUNTRY" | sudo tee /etc/modprobe.d/regdom.conf
sudo iw reg set "$COUNTRY" 2>/dev/null || true
iw reg get 2>/dev/null | head -3

say "Performance vs battery"
if [ -z "$PERF" ] && [ -t 0 ]; then
  echo "Disabling Wi-Fi power saving gives steadier speed/latency but uses more battery."
  read -r -p "Disable Wi-Fi power saving? [y/N]: " PERF
fi
case "$PERF" in
  y|Y|yes|YES)
    sudo tee /etc/modprobe.d/rtw89-perf.conf >/dev/null <<'EOF'
options rtw89_core_git disable_ps_mode=y
options rtw89_pci_git disable_aspm_l1=y disable_aspm_l1ss=y
options rtw89_core disable_ps_mode=y
options rtw89_pci disable_aspm_l1=y disable_aspm_l1ss=y
EOF
    if [ -d /etc/NetworkManager ]; then
      sudo mkdir -p /etc/NetworkManager/conf.d
      printf '[connection]\nwifi.powersave = 2\n' | sudo tee /etc/NetworkManager/conf.d/wifi-powersave-off.conf >/dev/null
    fi
    echo "Performance mode ON (undo: sudo rm -f /etc/modprobe.d/rtw89-perf.conf /etc/NetworkManager/conf.d/wifi-powersave-off.conf)"
    ;;
  *)
    sudo rm -f /etc/modprobe.d/rtw89-perf.conf /etc/NetworkManager/conf.d/wifi-powersave-off.conf
    echo "Battery mode (power saving stays on). Rerun with PERF=y if speed is unstable."
    ;;
esac

say "6/7 Safety net: fall back to in-kernel driver if DKMS module is missing or refused"
sudo mkdir -p /usr/local/sbin
sudo tee /usr/local/sbin/rtw89-fallback >/dev/null <<'EOF'
#!/bin/sh
lsmod | grep -q '^rtw89_8852be_git' && exit 0
modprobe rtw89_8852be_git 2>/dev/null && exit 0
logger "rtw89-fallback: rtw89_8852be_git missing or refused on $(uname -r), loading in-kernel rtw89_8852be"
modprobe -i rtw89_8852be
EOF
sudo chmod 755 /usr/local/sbin/rtw89-fallback
sudo tee /etc/systemd/system/rtw89-fallback.service >/dev/null <<'EOF'
[Unit]
Description=Load in-kernel rtw89 if DKMS rtw89 is missing or refused
After=systemd-modules-load.service
Before=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rtw89-fallback

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable rtw89-fallback.service

say "7/7 Secure Boot"
if mokutil --sb-state 2>/dev/null | grep -qi enabled; then
  KEY=""
  for k in /var/lib/dkms/mok.pub /var/lib/shim-signed/mok/MOK.der; do
    [ -f "$k" ] && { KEY=$k; break; }
  done
  if [ -n "$KEY" ]; then
    if mokutil --test-key "$KEY" 2>/dev/null | grep -qi "already enrolled"; then
      echo "Signing key $KEY already enrolled."
    else
      echo "Secure Boot is ON: enrolling signing key $KEY."
      echo "Choose a simple one-time password; you'll type it once on the blue MOK screen after reboot."
      sudo mokutil --import "$KEY"
      echo ">>> On reboot: Enroll MOK -> Continue -> Yes -> enter that password -> Reboot <<<"
    fi
  else
    echo "WARNING: no DKMS signing key found - the module may be refused under Secure Boot."
  fi
  [ "$DISTRO" = arch ] && echo "NOTE: on Arch, MOK enrollment only works if you boot through shim. With sbctl or no shim, sign the module yourself or disable Secure Boot."
else
  echo "Secure Boot is off - nothing to do."
fi

say "Done"
echo "Reboot now:  sudo reboot"
echo "After reboot check:"
echo "  lsmod | grep rtw89_8852be_git        (should be listed)"
echo "  nmcli dev wifi list --rescan yes     (5 GHz networks should appear)"
echo "Log: $LOG"
