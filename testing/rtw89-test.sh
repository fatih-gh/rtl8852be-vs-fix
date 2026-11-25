#!/bin/bash
OUT=~/rtw89-test2.txt
exec > >(tee "$OUT") 2>&1
RAW=https://raw.githubusercontent.com/fatih-gh/rtl8852be-vs-fix/testing/patches/upstream
COMMIT=8bbbacadf6fa73c3a3195aefbd4b2ec2422ae356
PATCHES="0001-wifi-rtw89-avoid-premature-power-save-entry-for-buff.patch
0002-wifi-rtw89-enable-low-latency-power-save-optimizatio.patch
0003-wifi-rtw89-set-RA-init-rate-level-when-the-station-R.patch
0004-wifi-rtw89-coex-set-the-WL-BT-antenna-map-on-shared-.patch
0005-wifi-rtw89-8852b-apply-BB-v31-parameters-to-older-BB-table.patch"
TESTURL=https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso
CON=MERCUSYS_4F24
say() { echo; echo "===== $* ====="; }
fail() { echo "!!!!! $* !!!!!"; exit 1; }
online() { GW=$(ip route | awk '/default/{print $3; exit}'); [ -n "$GW" ] && ping -c3 -W2 -q "$GW" >/dev/null 2>&1; }
reload() {
  for m in rtw89_8852be_git rtw89_8852b_git rtw89_8852b_common_git rtw89_pci_git rtw89_core_git; do sudo modprobe -r $m 2>/dev/null; done
  sudo modprobe rtw89_8852be_git; sleep 10
  nmcli --wait 40 connection up "$CON" >/dev/null 2>&1; sleep 8
}
build() {
  for v in $(sudo dkms status rtw89 | sed -n 's#^rtw89/\([^,: ]*\).*#\1#p' | sort -u); do
    sudo dkms remove "rtw89/$v" --all >/dev/null; sudo rm -rf "/usr/src/rtw89-$v"
  done
  sudo dkms install "$PWD" >/tmp/dkms.log 2>&1
}
prepare() {
  git checkout -f -q "$COMMIT" || fail "checkout failed"
  sed -i -e 's/u8 delta = phy_ppdu->rpl_avg - phy_ppdu->rssi_avg;/int delta = (int)phy_ppdu->rpl_avg - (int)phy_ppdu->rssi_avg;/' \
    -e 's/rssi\[i\] += delta;/rssi[i] = clamp_t(int, rssi[i] + delta, 0, U8_MAX);/' rtw8852b_common.c
  for p in $1; do patch -s -p1 -F3 --no-backup-if-mismatch < "/tmp/$p" || fail "patch $p"; echo "applied $p"; done
}

say "1/4 downloading and applying patches"
cd ~/rtw89 || fail "no ~/rtw89"
for p in $PATCHES; do curl -fsSL "$RAW/$p" -o "/tmp/$p" || fail "download $p"; done
prepare "$PATCHES"

say "2/4 rebuilding DKMS"
build || { echo "build failed, see /tmp/dkms.log"; tail -20 /tmp/dkms.log; prepare "$(echo "$PATCHES" | head -4)"; build || fail "fallback build failed"; }

say "3/4 reloading driver on 5 GHz"
sudo dmesg | grep -E "rtw89_8852be_git.*Firmware version" | tail -1
nmcli connection modify "$CON" 802-11-wireless.band a
reload
sudo dmesg | grep -E "applied BB v31|rtw89_8852be_git.*BB version" | tail -2
if ! online; then
  echo ">>> 5 GHz not working with 0005 - rebuilding without it"
  prepare "$(echo "$PATCHES" | head -4)"; build; reload
  online || { nmcli connection modify "$CON" 802-11-wireless.band ""; reload; fail "no connection - reverted to auto band"; }
fi
IF=$(iw dev | awk '/Interface/{print $2; exit}')
DBG=$(sudo sh -c 'ls -d /sys/kernel/debug/ieee80211/phy*/rtw89 2>/dev/null | head -1')

measure() {
  say "$1"
  iw dev $IF get power_save
  iw dev $IF link | grep -E "freq|signal|bitrate"
  curl -s -o /dev/null -r 0-600000000 --max-time 15 -w "%{speed_download}\n" "$TESTURL" > /tmp/spd &
  sleep 9
  [ -n "$DBG" ] && sudo sh -c "cat $DBG/phy_info" | grep -E "RSSI|EVM|SNR|TX rate|RX rate" | head -6
  wait
  echo "download: $(awk '{printf "%.0f Mbit/s", $1*8/1000000}' /tmp/spd)"
  read -r -p ">>> optional: run fast.com now and type the result (Enter to skip): " S
  [ -n "$S" ] && echo "fast.com: $S"
}

say "4/4 measuring on 5 GHz"
sudo iw dev $IF set power_save on;  sleep 3; measure "power save ON"
sudo iw dev $IF set power_save off; sleep 3; measure "power save OFF"
[ -x /usr/local/sbin/wifi-power-policy ] && sudo /usr/local/sbin/wifi-power-policy
echo; echo "Saved to $OUT"
