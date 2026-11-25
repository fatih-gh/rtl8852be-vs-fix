#!/bin/bash
OUT=~/rtw89-fwab.txt
exec > >(tee "$OUT") 2>&1
RAW=https://raw.githubusercontent.com/fatih-gh/rtl8852be-vs-fix/testing/patches/upstream
LFW=https://gitlab.com/kernel-firmware/linux-firmware/-/raw
FW18_URL=$LFW/f97831a2/rtw89/rtw8852b_fw-2.bin
FW18_SHA=6ff6aeb56bb5b85cba333b755f8cc1dbfe9ff6e5b16e39f6ba01ce7f1eaa7714
FW19_URL=$LFW/c8cfb34c05799b4a320003379b328cc2b85ce771/rtw89/rtw8852b_fw-2.bin
FW19_SHA=0b8b054e2e4ac0a5643bb13ad4618d0f1f369a02720602afb9ff0c8ec987aaba
HYB_SHA=81664e37a3f47f5691885ad31f76970ccd01d85c23e5f7e618be1cf4ca6b61f2
COMMIT=8bbbacadf6fa73c3a3195aefbd4b2ec2422ae356
PATCHES="0001-wifi-rtw89-avoid-premature-power-save-entry-for-buff.patch
0002-wifi-rtw89-enable-low-latency-power-save-optimizatio.patch
0003-wifi-rtw89-set-RA-init-rate-level-when-the-station-R.patch
0004-wifi-rtw89-coex-set-the-WL-BT-antenna-map-on-shared-.patch
0006-wifi-rtw89-8852b-update-default-value-for-ANA-SWR.patch"
TESTURL=https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso
CON=MERCUSYS_4F24
ROUNDS=3
W=~/rtw89-fwab
F=/lib/firmware/rtw89/rtw8852b_fw-2.bin
say() { echo; echo "===== $* ====="; }
fail() { echo "!!!!! $* !!!!!"; exit 1; }
online() { GW=$(ip route | awk '/default/{print $3; exit}'); [ -n "$GW" ] && ping -c3 -W2 -q "$GW" >/dev/null 2>&1; }
mkdir -p $W

say "1/5 downloads (patches + official firmware v0.29.29.18 and v0.29.29.19)"
for p in $PATCHES; do curl -fsSL "$RAW/$p" -o "$W/$p" || fail "download $p"; done
curl -fsSL "$FW18_URL" -o $W/fw18.bin && echo "$FW18_SHA  $W/fw18.bin" | sha256sum -c - || fail "fw18"
curl -fsSL "$FW19_URL" -o $W/fw19.bin && echo "$FW19_SHA  $W/fw19.bin" | sha256sum -c - || fail "fw19"
command -v python3 >/dev/null || sudo pacman -S --needed --noconfirm python || fail "python3 needed"
command -v zstd >/dev/null || sudo pacman -S --needed --noconfirm zstd

say "2/5 building hybrid firmware (0.29.29.18 program + 0.29.29.19 BB/RF/NCTL tables)"
cat > $W/hyb.py <<'EOF'
import struct, sys
def split(p):
    d = open(p, 'rb').read()
    last = [struct.unpack_from('<BBBBII', d, 16 + i * 16) for i in range(d[1])][-1]
    off = (last[4] + last[5] + 15) & ~15
    head, elms = d[:off], []
    while off + 32 < len(d):
        eid, esz = struct.unpack_from('<II', d, off)
        elms.append((eid, d[off:off + 32 + esz]))
        off = (off + 32 + esz + 15) & ~15
    return head, elms
bh, be = split(sys.argv[1])
dh, de = split(sys.argv[2])
keep = {2, 3, 4, 5, 8}
donor = {e[0]: e for e in de if e[0] in keep}
out = bytearray(bh)
for eid, raw in [donor[e[0]] if e[0] in keep else e for e in be]:
    out += raw
    while len(out) % 16:
        out += b'\0'
open(sys.argv[3], 'wb').write(bytes(out))
EOF
python3 -I $W/hyb.py $W/fw18.bin $W/fw19.bin $W/hyb.bin && echo "$HYB_SHA  $W/hyb.bin" | sha256sum -c - || fail "hybrid build/checksum"

say "3/5 driver: 8bbbaca + rssi fix + 0001-0004 + 0006"
cd ~/rtw89 || fail "no ~/rtw89"
prep() {
  git checkout -f -q "$COMMIT" || fail "checkout"
  sed -i -e 's/u8 delta = phy_ppdu->rpl_avg - phy_ppdu->rssi_avg;/int delta = (int)phy_ppdu->rpl_avg - (int)phy_ppdu->rssi_avg;/' \
    -e 's/rssi\[i\] += delta;/rssi[i] = clamp_t(int, rssi[i] + delta, 0, U8_MAX);/' rtw8852b_common.c
  for p in $1; do patch -s -p1 -F3 --no-backup-if-mismatch < "$W/$p" || fail "patch $p"; done
}
build() {
  for v in $(sudo dkms status rtw89 | sed -n 's#^rtw89/\([^,: ]*\).*#\1#p' | sort -u); do
    sudo dkms remove "rtw89/$v" --all >/dev/null; sudo rm -rf "/usr/src/rtw89-$v"
  done
  sudo dkms install "$PWD" >$W/dkms.log 2>&1
}
prep "$PATCHES"
build || { echo "build with 0006 failed - using 0001-0004"; prep "$(echo "$PATCHES" | head -4)"; build || fail "build failed"; }

usefw() {
  zstd -q -19 -f "$1" -o $W/cur.zst && sudo install -m644 $W/cur.zst "$F.zst" && sudo rm -f "$F" "$F.xz"
  for m in rtw89_8852be_git rtw89_8852b_git rtw89_8852b_common_git rtw89_pci_git rtw89_core_git; do sudo modprobe -r $m 2>/dev/null; done
  sudo modprobe rtw89_8852be_git; sleep 10
  nmcli connection modify "$CON" 802-11-wireless.band a
  nmcli --wait 40 connection up "$CON" >/dev/null 2>&1; sleep 8
  online || { nmcli --wait 40 connection up "$CON" >/dev/null 2>&1; sleep 8; }
  IF=$(iw dev | awk '/Interface/{print $2; exit}')
  sudo iw dev $IF set power_save off 2>/dev/null
  DBG=$(sudo sh -c 'ls -d /sys/kernel/debug/ieee80211/phy*/rtw89 2>/dev/null | head -1')
  sudo dmesg | grep -E "rtw89_8852be_git.*(radio A version|BB version)" | tail -2 | sed 's/.*: /   /'
}
: > $W/res
measure() {
  if ! online; then echo "$1 round $2: OFFLINE" | tee -a $W/res; return 1; fi
  sleep 4
  SPD=$(curl -s -o /dev/null -r 0-600000000 --max-time 12 -w "%{speed_download}" "$TESTURL" | awk '{printf "%.0f", $1*8/1000000}')
  PI=$(sudo sh -c "cat $DBG/phy_info")
  RSSI=$(echo "$PI" | grep -m1 -oE 'RSSI: -?[0-9]+' | grep -oE -- '-?[0-9]+$')
  SNR=$(echo "$PI" | grep -m1 -oE 'SNR: [0-9]+' | grep -oE '[0-9]+$')
  EVM=$(echo "$PI" | grep -m1 -oE 'EVM: \[[0-9.]+' | grep -oE '[0-9.]+$')
  RX=$(echo "$PI" | grep -m1 -oE 'RX rate[^:]*: [^(]*' | sed 's/RX rate[^:]*: //')
  printf "%s round %s: %4s Mbit/s  RSSI %s  SNR %s  EVM %s  RX %s\n" "$1" "$2" "$SPD" "$RSSI" "$SNR" "$EVM" "$RX" | tee -a $W/res
}

say "4/5 A/B rounds on 5 GHz, power save off (OLD = 0.29.29.18, HYB = hybrid)"
HYB_OK=1
for i in $(seq $ROUNDS); do
  usefw $W/fw18.bin; measure OLD $i
  if [ $HYB_OK = 1 ]; then usefw $W/hyb.bin; measure HYB $i || HYB_OK=0; fi
done

say "5/5 summary"
for s in OLD HYB; do
  awk -v s=$s '$1==s && $4!="OFFLINE" {n++; sum+=$4; split($0,a,"SNR "); split(a[2],b," "); snr+=b[1]; split($0,c,"EVM "); split(c[2],e," "); evm+=e[1]} END {if(n) printf "%s: avg %.0f Mbit/s, SNR %.1f, EVM %.1f over %d rounds\n", s, sum/n, snr/n, evm/n, n; else print s": no successful rounds"}' $W/res
done
OLDAVG=$(awk '$1=="OLD" && $4!="OFFLINE" {n++; s+=$4} END {print (n? s/n : 0)}' $W/res)
HYBAVG=$(awk '$1=="HYB" && $4!="OFFLINE" {n++; s+=$4} END {print (n? s/n : 0)}' $W/res)
if [ $HYB_OK = 1 ] && awk -v h=$HYBAVG -v o=$OLDAVG 'BEGIN{exit !(h > o*1.2)}'; then
  echo ">>> hybrid clearly faster - keeping hybrid firmware"; usefw $W/hyb.bin
else
  echo ">>> keeping official 0.29.29.18"; usefw $W/fw18.bin
fi
command -v mkinitcpio >/dev/null && sudo mkinitcpio -P >/dev/null 2>&1
[ -x /usr/local/sbin/wifi-power-policy ] && sudo /usr/local/sbin/wifi-power-policy
online || { nmcli connection modify "$CON" 802-11-wireless.band ""; nmcli connection up "$CON" >/dev/null 2>&1; echo "5 GHz offline - switched to auto band"; }
echo "Saved to $OUT"
