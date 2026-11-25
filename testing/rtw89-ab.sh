#!/bin/bash
OUT=~/rtw89-ab.txt
exec > >(tee "$OUT") 2>&1
RAW=https://raw.githubusercontent.com/fatih-gh/rtl8852be-vs-fix/testing/patches/upstream
COMMIT=8bbbacadf6fa73c3a3195aefbd4b2ec2422ae356
PATCHES="0001-wifi-rtw89-avoid-premature-power-save-entry-for-buff.patch
0002-wifi-rtw89-enable-low-latency-power-save-optimizatio.patch
0003-wifi-rtw89-set-RA-init-rate-level-when-the-station-R.patch
0004-wifi-rtw89-coex-set-the-WL-BT-antenna-map-on-shared-.patch"
TESTURL=https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso
CON=MERCUSYS_4F24
REGS="0x12008 0x112a8 0x132a8 0x11210 0x13210"
V31="0x08000000 0x33337025 0x33337025 0xc0000c06 0xc0000c06"
ROUNDS=3
say() { echo; echo "===== $* ====="; }
fail() { echo "!!!!! $* !!!!!"; exit 1; }
online() { GW=$(ip route | awk '/default/{print $3; exit}'); [ -n "$GW" ] && ping -c3 -W2 -q "$GW" >/dev/null 2>&1; }

say "1/4 driver without the BB patch (0001-0004 + rssi fix)"
cd ~/rtw89 || fail "no ~/rtw89"
for p in $PATCHES; do curl -fsSL "$RAW/$p" -o "/tmp/$p" || fail "download $p"; done
git checkout -f -q "$COMMIT" || fail "checkout"
sed -i -e 's/u8 delta = phy_ppdu->rpl_avg - phy_ppdu->rssi_avg;/int delta = (int)phy_ppdu->rpl_avg - (int)phy_ppdu->rssi_avg;/' \
  -e 's/rssi\[i\] += delta;/rssi[i] = clamp_t(int, rssi[i] + delta, 0, U8_MAX);/' rtw8852b_common.c
for p in $PATCHES; do patch -s -p1 -F3 --no-backup-if-mismatch < "/tmp/$p" || fail "patch $p"; done
for v in $(sudo dkms status rtw89 | sed -n 's#^rtw89/\([^,: ]*\).*#\1#p' | sort -u); do
  sudo dkms remove "rtw89/$v" --all >/dev/null; sudo rm -rf "/usr/src/rtw89-$v"
done
sudo dkms install "$PWD" >/tmp/dkms.log 2>&1 || { tail -20 /tmp/dkms.log; fail "build"; }

say "2/4 reload + connect on 5 GHz, power save off"
for m in rtw89_8852be_git rtw89_8852b_git rtw89_8852b_common_git rtw89_pci_git rtw89_core_git; do sudo modprobe -r $m 2>/dev/null; done
sudo modprobe rtw89_8852be_git; sleep 10
nmcli connection modify "$CON" 802-11-wireless.band a
nmcli --wait 40 connection up "$CON" >/dev/null 2>&1; sleep 8
online || { nmcli connection modify "$CON" 802-11-wireless.band ""; nmcli connection up "$CON" >/dev/null 2>&1; fail "no 5 GHz connection - back to auto band"; }
IF=$(iw dev | awk '/Interface/{print $2; exit}')
sudo iw dev $IF set power_save off
DBG=$(sudo sh -c 'ls -d /sys/kernel/debug/ieee80211/phy*/rtw89 2>/dev/null | head -1')
[ -n "$DBG" ] || fail "debugfs not found"
iw dev $IF link | grep -E "freq|signal"

rd() { sudo sh -c "echo '$1 4' > $DBG/read_reg; cat $DBG/read_reg" | grep -oE '=0x[0-9a-f]+' | tr -d '='; }
wr() { sudo sh -c "echo '$1 $2 4' > $DBG/write_reg"; }
apply() { set -- $1; for r in $REGS; do wr "$r" "$1"; shift; done; }
DEF=""; for r in $REGS; do DEF="$DEF $(rd $r)"; done
echo "current (old) values:$DEF"
echo "v31 values:           $V31"

say "3/4 A/B rounds (A = old values, B = v31 values)"
: > /tmp/ab
measure() {
  apply "$2"; sleep 6
  SPD=$(curl -s -o /dev/null -r 0-600000000 --max-time 12 -w "%{speed_download}" "$TESTURL" | awk '{printf "%.0f", $1*8/1000000}')
  PI=$(sudo sh -c "cat $DBG/phy_info")
  RSSI=$(echo "$PI" | grep -m1 -oE 'RSSI: -?[0-9]+' | grep -oE -- '-?[0-9]+$')
  SNR=$(echo "$PI" | grep -m1 -oE 'SNR: [0-9]+' | grep -oE '[0-9]+$')
  EVM=$(echo "$PI" | grep -m1 -oE 'EVM: \[[0-9.]+' | grep -oE '[0-9.]+$')
  RX=$(echo "$PI" | grep -m1 -oE 'RX rate[^:]*: [^(]*' | sed 's/RX rate[^:]*: //')
  printf "%s round %s: %4s Mbit/s  RSSI %s  SNR %s  EVM %s  RX %s\n" "$1" "$3" "$SPD" "$RSSI" "$SNR" "$EVM" "$RX" | tee -a /tmp/ab
}
for i in $(seq $ROUNDS); do
  measure A "$DEF" $i
  measure B "$V31" $i
done

say "4/4 summary"
for s in A B; do
  awk -v s=$s '$1==s {n++; sum+=$4; split($0,a,"SNR "); split(a[2],b," "); snr+=b[1]} END {if(n) printf "%s: avg %.0f Mbit/s, avg SNR %.1f over %d rounds\n", s, sum/n, snr/n, n}' /tmp/ab
done
apply "$DEF"
echo "Left on A (old values = current driver). Saved to $OUT"
[ -x /usr/local/sbin/wifi-power-policy ] && sudo /usr/local/sbin/wifi-power-policy
