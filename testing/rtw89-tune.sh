#!/bin/bash
OUT=~/rtw89-tune.txt
exec > >(tee "$OUT") 2>&1
LFW=https://gitlab.com/kernel-firmware/linux-firmware/-/raw
FW18_URL=$LFW/f97831a2/rtw89/rtw8852b_fw-2.bin
FW18_SHA=6ff6aeb56bb5b85cba333b755f8cc1dbfe9ff6e5b16e39f6ba01ce7f1eaa7714
FW19_URL=$LFW/c8cfb34c05799b4a320003379b328cc2b85ce771/rtw89/rtw8852b_fw-2.bin
FW19_SHA=0b8b054e2e4ac0a5643bb13ad4618d0f1f369a02720602afb9ff0c8ec987aaba
CON=${CON:-MERCUSYS_4F24}
W=~/rtw89-tune
F=/lib/firmware/rtw89/rtw8852b_fw-2.bin
NAMES=${NAMES:-"OFFICIAL HYB HYB_TRK HYB_PWR"}
PASSES=${PASSES:-2}
SKIPBAND=${SKIPBAND:-0}
declare -A TAKE=([OFFICIAL]="" [HYB]="2,3,4,5,8" [HYB_TRK]="2,3,4,5,8,18" [HYB_PWR]="2,3,4,5,8,9,10,11,13,14,16,17")
say() { echo; echo "===== $* ====="; }
fail() { echo "!!!!! $* !!!!!"; exit 1; }
online() { GW=$(ip route | awk '/default/{print $3; exit}'); [ -n "$GW" ] && ping -c3 -W2 -q "$GW" >/dev/null 2>&1; }
mkdir -p $W

say "1/5 tools and official firmware"
for t in python3:python zstd:zstd speedtest-cli:speedtest-cli; do
  command -v ${t%%:*} >/dev/null || sudo pacman -S --needed --noconfirm ${t##*:} >/dev/null || echo "could not install ${t##*:}"
done
[ -f $W/fw18.bin ] || curl -fsSL "$FW18_URL" -o $W/fw18.bin
[ -f $W/fw19.bin ] || curl -fsSL "$FW19_URL" -o $W/fw19.bin
echo "$FW18_SHA  $W/fw18.bin" | sha256sum -c - || fail "fw18 checksum"
echo "$FW19_SHA  $W/fw19.bin" | sha256sum -c - || fail "fw19 checksum"

say "2/5 building variants"
cat > $W/mix.py <<'EOF'
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
take = {int(x) for x in sys.argv[4].split(',') if x}
donor = {}
for eid, raw in de:
    donor.setdefault(eid, []).append(raw)
elms, done = [], set()
for eid, raw in be:
    if eid in take:
        if eid not in done:
            elms += donor.get(eid, [])
            done.add(eid)
    else:
        elms.append(raw)
for eid in sorted(take - done):
    elms += donor.get(eid, [])
out = bytearray(bh)
for i, raw in enumerate(elms):
    out += raw
    while i < len(elms) - 1 and len(out) % 16:
        out += b'\0'
open(sys.argv[3], 'wb').write(bytes(out))
EOF
for n in $NAMES; do python3 -I $W/mix.py $W/fw18.bin $W/fw19.bin $W/$n.bin "${TAKE[$n]}" || fail "build $n"; done
echo "977c54aedd7966c63cb6cb13dd919535f82c8f24d878eb49d7f43e5312258125  $W/HYB.bin" | sha256sum -c - || fail "HYB checksum"
cmp -s $W/OFFICIAL.bin $W/fw18.bin || fail "OFFICIAL rebuild mismatch"
ls -la $W/*.bin

usefw() {
  zstd -q -19 -f "$W/$1.bin" -o $W/cur.zst && sudo install -m644 $W/cur.zst "$F.zst" && sudo rm -f "$F" "$F.xz"
  for m in rtw89_8852be_git rtw89_8852b_git rtw89_8852b_common_git rtw89_pci_git rtw89_core_git; do sudo modprobe -r $m 2>/dev/null; done
  sudo modprobe rtw89_8852be_git; sleep 10
  nmcli connection modify "$CON" 802-11-wireless.band "$2"
  nmcli --wait 40 connection up "$CON" >/dev/null 2>&1; sleep 8
  online || { nmcli --wait 40 connection up "$CON" >/dev/null 2>&1; sleep 8; }
  IF=$(iw dev | awk '/Interface/{print $2; exit}')
  sudo iw dev $IF set power_save off 2>/dev/null
}
speed() {
  local j
  j=$(timeout 60 speedtest-cli --secure --json 2>/dev/null)
  if [ -n "$j" ]; then
    echo "$j" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print("%.0f %.0f" % (d["download"]/1e6, d["ping"]))' 2>/dev/null && return
  fi
  local t=0 u
  for u in https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso https://mirrors.kernel.org/archlinux/iso/latest/archlinux-x86_64.iso https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.tar.xz; do
    curl -s -o /dev/null --max-time 12 -w "%{speed_download}\n" "$u" >> $W/par.$$ &
  done
  wait
  t=$(awk '{s+=$1} END {printf "%.0f", s*8/1e6}' $W/par.$$); rm -f $W/par.$$
  echo "$t 0"
}
rxrate() {
  local r1 r2
  r1=$(cat /sys/class/net/$IF/statistics/rx_bytes); sleep 3; r2=$(cat /sys/class/net/$IF/statistics/rx_bytes)
  echo $(( (r2 - r1) * 8 / 3 / 1000000 ))
}
quiet() {
  local i bg
  for i in $(seq 20); do
    bg=$(rxrate)
    [ "$bg" -lt 2 ] && return 0
    echo "   other traffic detected (${bg} Mbit/s) - close fast.com/downloads, waiting..."
    sleep 7
  done
  echo "   WARNING: background traffic did not stop - this result may be low"
}
run() {
  local n=$1 band=$2 tag=$3
  usefw $n $band
  if ! online; then echo "$tag $n OFFLINE" | tee -a $W/res; return; fi
  timeout 20 curl -s -o /dev/null --max-time 15 https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso
  local a b
  quiet; a=$(speed)
  quiet; b=$(speed)
  printf "%s %s %s %s %s %s\n" "$tag" "$n" $a $b | tee -a $W/res
}

say "3/5 measuring firmware variants on 5 GHz (mirrored order, power save off)"
echo "Do not use the network during this test (no fast.com, downloads, streaming)."
: > $W/res
FWD=""; for n in $NAMES; do FWD="$FWD $n"; done
REV=$(echo $FWD | tr ' ' '\n' | tac | tr '\n' ' ')
for p in $(seq $PASSES); do
  if [ $((p % 2)) = 1 ]; then ORDER=$FWD; else ORDER=$REV; fi
  for n in $ORDER; do run $n a P$p; done
done

say "4/5 choosing the fastest firmware"
BEST=$(awk '$3!="OFFLINE" {s[$2]+=$3+$5; c[$2]+=2} $3=="OFFLINE" {bad[$2]=1} END {for (n in s) if (!bad[n]) printf "%s %.1f\n", n, s[n]/c[n]}' $W/res | sort -k2 -nr | tee $W/rank | head -1 | awk '{print $1}')
echo "ranking (avg Mbit/s):"; cat $W/rank
[ -n "$BEST" ] || BEST=OFFICIAL
echo ">>> fastest firmware: $BEST"
BEST5=$(awk -v b=$BEST '$1==b {print $2}' $W/rank)

BAND=a
if [ "$SKIPBAND" != 1 ]; then
  say "5/5 band check with $BEST (5 GHz vs 2.4 GHz)"
  run $BEST bg B24
  run $BEST bg B24
  B24=$(awk -v b=$BEST '$1=="B24" && $2==b && $3!="OFFLINE" {s+=$3+$5; c+=2} END {printf "%.1f", c? s/c : 0}' $W/res)
  echo "5 GHz avg: ${BEST5:-0}  2.4 GHz avg: $B24"
  if awk -v a=${BEST5:-0} -v g=$B24 'BEGIN{exit !(g > a*1.15)}'; then BAND=bg; fi
fi
echo ">>> installing $BEST with band $([ $BAND = a ] && echo 5GHz || echo 2.4GHz)"
usefw $BEST $BAND
online || { nmcli connection modify "$CON" 802-11-wireless.band ""; nmcli connection up "$CON" >/dev/null 2>&1; echo "offline - switched to auto band"; }
cp $W/$BEST.bin $W/selected.bin
command -v mkinitcpio >/dev/null && sudo mkinitcpio -P >/dev/null 2>&1
[ -x /usr/local/sbin/wifi-power-policy ] && sudo /usr/local/sbin/wifi-power-policy
sudo dmesg | grep -E "rtw89_8852be_git.*(radio A version|BB version)" | tail -2 | sed 's/.*: /   /'
echo "raw results: $W/res   Saved to $OUT"
