#!/bin/bash
OUT=~/rtw89-test.txt
exec > >(tee "$OUT") 2>&1
RAW=https://raw.githubusercontent.com/fatih-gh/rtl8852be-vs-fix/testing/patches/upstream
FWURL=https://gitlab.com/kernel-firmware/linux-firmware/-/raw/c8cfb34c05799b4a320003379b328cc2b85ce771/rtw89/rtw8852b_fw-2.bin
FWSHA=0b8b054e2e4ac0a5643bb13ad4618d0f1f369a02720602afb9ff0c8ec987aaba
COMMIT=8bbbacadf6fa73c3a3195aefbd4b2ec2422ae356
PATCHES="0001-wifi-rtw89-avoid-premature-power-save-entry-for-buff.patch
0002-wifi-rtw89-enable-low-latency-power-save-optimizatio.patch
0003-wifi-rtw89-set-RA-init-rate-level-when-the-station-R.patch
0004-wifi-rtw89-coex-set-the-WL-BT-antenna-map-on-shared-.patch"
TESTURL=https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso
CON=MERCUSYS_4F24
say() { echo; echo "===== $* ====="; }
fail() { echo "!!!!! $* !!!!!"; exit 1; }

say "1/5 patching driver source"
cd ~/rtw89 || fail "no ~/rtw89 - run the repo install script first"
git fetch -q origin
git checkout -f -q "$COMMIT" || fail "checkout failed"
sed -i -e 's/u8 delta = phy_ppdu->rpl_avg - phy_ppdu->rssi_avg;/int delta = (int)phy_ppdu->rpl_avg - (int)phy_ppdu->rssi_avg;/' \
  -e 's/rssi\[i\] += delta;/rssi[i] = clamp_t(int, rssi[i] + delta, 0, U8_MAX);/' rtw8852b_common.c
[ "$(grep -c -e 'int delta = (int)phy_ppdu->rpl_avg' -e 'clamp_t(int, rssi\[i\] + delta' rtw8852b_common.c)" = 2 ] || fail "rssi fix did not apply"
for p in $PATCHES; do
  curl -fsSL "$RAW/$p" -o "/tmp/$p" || fail "download $p"
  patch -s -p1 -F3 --no-backup-if-mismatch < "/tmp/$p" || { git checkout -f -q .; fail "patch $p"; }
  echo "applied $p"
done

say "2/5 rebuilding DKMS"
for v in $(sudo dkms status rtw89 | sed -n 's#^rtw89/\([^,: ]*\).*#\1#p' | sort -u); do
  sudo dkms remove "rtw89/$v" --all >/dev/null; sudo rm -rf "/usr/src/rtw89-$v"
done
if ! sudo dkms install "$PWD"; then
  echo "BUILD FAILED - restoring unpatched driver"
  git checkout -f -q .; sudo rm -rf /usr/src/rtw89-*; sudo dkms install "$PWD"; fail "build failed"
fi

say "3/5 installing firmware v0.29.29.19"
curl -fsSL "$FWURL" -o /tmp/rtw8852b_fw-2.bin || fail "firmware download"
echo "$FWSHA  /tmp/rtw8852b_fw-2.bin" | sha256sum -c - || fail "firmware checksum mismatch"
F=/lib/firmware/rtw89/rtw8852b_fw-2.bin
mkdir -p ~/rtw89-fw-backup
for e in "" .zst .xz; do [ -e "$F$e" ] && sudo cp -a "$F$e" ~/rtw89-fw-backup/ ; done
if [ -e "$F.zst" ]; then
  zstd -q -19 -f /tmp/rtw8852b_fw-2.bin -o /tmp/fw.zst && sudo install -m644 /tmp/fw.zst "$F.zst" && sudo rm -f "$F" "$F.xz"
elif [ -e "$F.xz" ]; then
  xz -C crc32 -kf /tmp/rtw8852b_fw-2.bin && sudo install -m644 /tmp/rtw8852b_fw-2.bin.xz "$F.xz" && sudo rm -f "$F" "$F.zst"
else
  sudo install -Dm644 /tmp/rtw8852b_fw-2.bin "$F"
fi
ls -la /lib/firmware/rtw89/rtw8852b_fw-2.bin*
command -v mkinitcpio >/dev/null && sudo mkinitcpio -P >/dev/null 2>&1
command -v dracut >/dev/null && sudo dracut -f >/dev/null 2>&1

say "4/5 reloading driver"
for m in rtw89_8852be_git rtw89_8852b_git rtw89_8852b_common_git rtw89_pci_git rtw89_core_git; do sudo modprobe -r $m 2>/dev/null; done
sudo modprobe rtw89_8852be_git || fail "modprobe failed"
sleep 8
nmcli connection modify "$CON" 802-11-wireless.band a 2>/dev/null
nmcli --wait 40 connection up "$CON" >/dev/null 2>&1
sleep 8
sudo dmesg | grep -E "rtw89_8852be_git.*(git commit|Firmware version|BB version|radio A version)" | tail -4
IF=$(iw dev | awk '/Interface/{print $2; exit}')
DBG=$(sudo sh -c 'ls -d /sys/kernel/debug/ieee80211/phy*/rtw89 2>/dev/null | head -1')

measure() {
  say "$1"
  iw dev $IF get power_save
  iw dev $IF link | grep -E "freq|signal|bitrate"
  curl -s -o /dev/null -r 0-600000000 --max-time 15 -w "%{speed_download}\n" "$TESTURL" > /tmp/spd &
  sleep 9
  [ -n "$DBG" ] && sudo sh -c "cat $DBG/phy_info" | grep -E "RSSI|EVM|SNR|TX rate|RX rate" | head -6
  [ -n "$DBG" ] && sudo sh -c "cat $DBG/bb_info" | grep -E "^TP|ok:|err:|^FA|^CCA" | head -6
  wait
  echo "download: $(awk '{printf "%.0f Mbit/s", $1*8/1000000}' /tmp/spd)"
  read -r -p ">>> optional: run fast.com now and type the result (Enter to skip): " S
  [ -n "$S" ] && echo "fast.com: $S"
}

say "5/5 measuring on 5 GHz"
sudo iw dev $IF set power_save on;  sleep 3; measure "power save ON"
sudo iw dev $IF set power_save off; sleep 3; measure "power save OFF"
[ -x /usr/local/sbin/wifi-power-policy ] && sudo /usr/local/sbin/wifi-power-policy
echo; echo "Saved to $OUT"
