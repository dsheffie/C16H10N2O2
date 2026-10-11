#!/bin/bash
# net_host.sh CONSOLE_LOG [WORKDIR] -- host side of net_test.sh (tap0 = 192.168.7.1).
# Serves WORKDIR/rx.bin on :8000, waits for the guest's TX_READY on its console log,
# fetches http://192.168.7.2/tx.bin, and checks both transfers against the md5s the
# guest printed.  Prints NET_HOST PASS/FAIL lines.  Runs until both are checked.
LOG=$1; W=${2:-/tmp/claude-1001/net_host}
mkdir -p $W
# the guest console is interleaved char-by-char with RTL ">>>>" fault lines: rebuild
# the console text before looking for the md5 lines
console() { grep -av "^\[" $LOG | sed 's/>>>>>>>> at cycle.*$//; s/>>>> [^>]*fault[^>]*//g; s/> t_rob_head[^>]*//g' | tr -d '\n'; }
[ -f $W/rx.bin ] || dd if=/dev/urandom of=$W/rx.bin bs=1024 count=64 2>/dev/null
RXMD5=$(md5sum < $W/rx.bin | cut -d' ' -f1)
echo "NET_HOST rx.bin md5 $RXMD5"
# a stale server from an earlier run would serve ITS rx.bin: refuse to start
if ss -ltn 'sport = :8000' | grep -q 8000; then echo "NET_HOST FAIL port 8000 already in use"; exit 1; fi
( cd $W && exec python3 -m http.server 8000 --bind 192.168.7.1 > $W/httpd.log 2>&1 ) &
HP=$!
trap "kill $HP 2>/dev/null" EXIT
rx_done=0; tx_done=0
while [ $rx_done = 0 ] || [ $tx_done = 0 ]; do
  sleep 10
  if [ $rx_done = 0 ] && console | grep -a -q "/tmp/rx.bin"; then
    g=$(console | grep -a -oE "[0-9a-f]{32}  /tmp/rx.bin" | head -1 | cut -c1-32)
    if [ -n "$g" ]; then
      [ "$g" = "$RXMD5" ] && echo "NET_HOST RX PASS $g" || echo "NET_HOST RX FAIL guest $g host $RXMD5"
      rx_done=1
    fi
  fi
  if [ $tx_done = 0 ] && console | grep -a -q "TX_READY"; then
    g=$(console | grep -a -oE "[0-9a-f]{32}  /www/tx.bin" | head -1 | cut -c1-32)
    if curl -s -m 600 -o $W/tx.bin http://192.168.7.2/tx.bin; then
      h=$(md5sum < $W/tx.bin | cut -d' ' -f1)
      [ "$g" = "$h" ] && echo "NET_HOST TX PASS $h" || echo "NET_HOST TX FAIL guest $g host $h"
      tx_done=1
    fi
  fi
done
