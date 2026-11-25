#!/bin/bash
OUT=~/rtw89-ra.txt
exec > >(tee "$OUT") 2>&1
P=0007-wifi-rtw89-add-ra_init_lv-module-parameter.patch
SHA=da67e84f8182449e382f8d53968c2a5a69369d53f5fa653c3a71f8dd42d6eba1
URL=https://raw.githubusercontent.com/fatih-gh/rtl8852be-vs-fix/testing/patches/experimental/$P
CON=${CON:-MERCUSYS_4F24}
PARAM=/sys/module/rtw89_core_git/parameters/ra_init_lv
say() { echo; echo "===== $* ====="; }
fail() { echo "!!!!! $* !!!!!"; exit 1; }
IF=$(iw dev | awk '/Interface/{print $2; exit}')
DBG=$(sudo sh -c 'ls -d /sys/kernel/debug/ieee80211/phy*/rtw89 2>/dev/null | head -1')

if [ ! -e $PARAM ]; then
  say "1/3 adding ra_init_lv option to the installed driver"
  SRCV=$(ls -d /usr/src/rtw89-* 2>/dev/null | head -1)
  [ -n "$SRCV" ] || fail "no DKMS source in /usr/src - run the install script first"
  V=${SRCV##*/rtw89-}
  curl -fsSL "$URL" -o /tmp/$P || fail "download"
  echo "$SHA  /tmp/$P" | sha256sum -c - || fail "checksum"
  sudo patch -s -p1 -F3 --no-backup-if-mismatch -d "$SRCV" < /tmp/$P || fail "patch did not apply"
  sudo dkms build -m rtw89 -v "$V" --force >/tmp/dkms.log 2>&1 && sudo dkms install -m rtw89 -v "$V" --force >>/tmp/dkms.log 2>&1 || { tail -20 /tmp/dkms.log; fail "build"; }
  for m in rtw89_8852be_git rtw89_8852b_git rtw89_8852b_common_git rtw89_pci_git rtw89_core_git; do sudo modprobe -r $m 2>/dev/null; done
  sudo modprobe rtw89_8852be_git; sleep 12
  nmcli --wait 40 connection up "$CON" >/dev/null 2>&1; sleep 6
  [ -e $PARAM ] || fail "option not present after reload"
fi
IF=$(iw dev | awk '/Interface/{print $2; exit}')
DBG=$(sudo sh -c 'ls -d /sys/kernel/debug/ieee80211/phy*/rtw89 2>/dev/null | head -1')
command -v speedtest-cli >/dev/null || sudo pacman -S --needed --noconfirm speedtest-cli

txrate() { sudo sh -c "cat $DBG/phy_info" | grep -m1 -oE 'TX rate[^(]*' | sed 's/TX rate \[[0-9, ]*\]: //'; }
run() {
  echo $1 | sudo tee $PARAM >/dev/null
  nmcli --wait 40 connection up "$CON" >/dev/null 2>&1; sleep 8
  sudo iw dev $IF set power_save off
  local sig s1 s2 tx
  sig=$(iw dev $IF link | grep -oE 'signal: -?[0-9]+' | grep -oE -- '-?[0-9]+')
  (sleep 8; txrate > /tmp/tx.$$) &
  s1=$(timeout 60 speedtest-cli --secure --simple 2>/dev/null | awk '/Download/{print $2}')
  wait; tx=$(cat /tmp/tx.$$ 2>/dev/null); rm -f /tmp/tx.$$
  s2=$(timeout 60 speedtest-cli --secure --simple 2>/dev/null | awk '/Download/{print $2}')
  printf "lv=%s %s | signal at connect %s dBm | %6s %6s Mbit/s | tx during test: %s\n" "$1" "$2" "$sig" "${s1:-0}" "${s2:-0}" "$tx" | tee -a /tmp/ra.res
}

say "2/3 A/B: lv=0 (current logic) vs lv=1 (always start high), reconnect each time"
echo "Keep the laptop still, doors as they are, no other network use."
: > /tmp/ra.res
for r in 1 2 3; do run 0 R$r; run 1 R$r; done

say "3/3 summary"
awk '{split($1,a,"="); v=a[2]; s[v]+=$9+$10; c[v]+=2} END {for (k in s) printf "lv=%s: avg %.0f Mbit/s\n", k, s[k]/c[k]}' /tmp/ra.res | sort
BEST=$(awk '{split($1,a,"="); v=a[2]; s[v]+=$9+$10; c[v]+=2} END {for (k in s) printf "%s %.1f\n", k, s[k]/c[k]}' /tmp/ra.res | sort -k2 -nr | head -1 | cut -d' ' -f1)
echo "options rtw89_core_git ra_init_lv=$BEST" | sudo tee /etc/modprobe.d/rtw89-ra.conf
echo $BEST | sudo tee $PARAM >/dev/null
nmcli connection up "$CON" >/dev/null 2>&1
[ -x /usr/local/sbin/wifi-power-policy ] && sudo /usr/local/sbin/wifi-power-policy
echo ">>> kept ra_init_lv=$BEST (persists via /etc/modprobe.d/rtw89-ra.conf). Saved to $OUT"
