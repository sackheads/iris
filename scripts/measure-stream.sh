#!/bin/zsh
# #541: idle chat-window CPU with a reply streaming in (DebugStreamProbe) vs the same window idle.
# usage: measure-stream.sh <Iris Dev.app built from measure/541-probe> <outdir>
# Needs: the GUI lease, the display awake. One Debug build; the arms differ only in environment:
# base (streaming as today), noscroll (IRIS_STREAM_NOSCROLL=1: no scroll per token), buffer
# (IRIS_STREAM_BUFFER=1: the text streams into a side buffer only its row reads, not
# AppState.conversations), both; 3 interleaved passes at 40 messages, then base and both at 200
# (IRIS_STREAM_PROBE_MESSAGES=200). Each streaming arm prints the update rate it really ran at.
# About 18 minutes. The probe makes and selects its own conversation,
# "#541 stream probe" (fixed id; its title is re-set on every launch, which the window check below
# relies on), the first time, and deletes probe conversations left by earlier probe builds.
# `residual` as a third argument runs the residual analysis instead: the both arm (buffer +
# noscroll) at 4,000 and at 400 characters a message, and with the streaming row as plain Text
# (IRIS_STREAM_PLAIN=1). About 9 minutes.
# `pair` mode, for a fix's A/B against main (#541): measure-stream.sh pair <before.app>
# <after.app> <outdir>. Both apps are built from a branch carrying this probe; the arms alternate
# before/after, 3 passes at 40 messages and 3 at 200. About 12 minutes.
set -u
if [[ $1 == pair ]]; then which=pair; before=$2; after=$3; out=$4; app=$before
else app=$1; out=$2; which=${3:-attribution}; fi
mkdir -p $out
cat > $out/winlist.swift <<'SWIFT'
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
for w in CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    where (w[kCGWindowOwnerPID as String] as? Int) == pid {
    print("id=\(w[kCGWindowNumber as String] ?? 0)", w[kCGWindowName as String] ?? "-", "alpha=\(w[kCGWindowAlpha as String] ?? "-")")
}
SWIFT
swiftc -O -o $out/winlist $out/winlist.swift || exit 1
one() {   # <label> <idle|on> <sample|-> [KEY=VALUE env for the attribution arms...]
  local label=$1 mode=$2 dosample=${3:-}; [[ $dosample == - ]] && dosample=
  shift 3 2>/dev/null
  local rate=$out/$label.rate; rm -f $rate
  local envs=(--env IRIS_STREAM_PROBE=$mode --env IRIS_STREAM_RATE_FILE=$rate)
  for kv in "$@"; do envs+=(--env $kv); done
  open -g -n $envs "$app" || return 1
  sleep 15
  local pid=$(pgrep -f "$app/Contents/MacOS/" | head -1)
  [[ -z $pid ]] && { echo "$label: no pid"; return 1; }
  open -g "$app"; sleep 8          # a reopen shows the chat window; the probe has selected its conversation
  $out/winlist $pid > $out/$label.windows.txt
  grep -q "stream probe" $out/$label.windows.txt || { echo "$label: probe conversation not on screen, run invalid"; cat $out/$label.windows.txt; kill -TERM $pid; return 1; }
  local load=$(sysctl -n vm.loadavg | awk '{print $2}')
  top -pid $(pgrep -x WindowServer) -l 31 -s 1 -stats pid,cpu,command > $out/$label.ws.txt &
  local wspid=$!
  local r0=$(cat $rate 2>/dev/null)
  top -pid $pid -l 31 -s 1 -stats pid,cpu,command > $out/$label.top.txt
  wait $wspid
  local r1=$(cat $rate 2>/dev/null)
  # Ticks per second over the measured window: a slow arm cannot pass for a cheap one.
  if [[ $mode == on && -n $r0 && -n $r1 ]]; then
    awk -v a="$r0" -v b="$r1" -v lab=$label 'BEGIN {split(a,x," "); split(b,y," "); if (y[2]>x[2]) printf "%-16s stream rate %.1f updates/s\n", lab, (y[1]-x[1])/(y[2]-x[2]); else print lab " stream rate: n/a"}'
  fi
  local ws=$(awk '/^[0-9]+ +[0-9.]+/ {n++; if (n>1) {s+=$2; c++}} END {printf "%.1f", s/c}' $out/$label.ws.txt)
  awk -v lab=$label -v l=$load -v ws=$ws '/^[0-9]+ +[0-9.]+/ {n++; if (n>1) {s+=$2; c++}} END {printf "%-14s mean %5.1f%% over %d samples, WindowServer %s%%, load1 %s\n", lab, s/c, c, ws, l}' $out/$label.top.txt
  [[ -n $dosample ]] && sample $pid 10 -file $out/$label.sample.txt >/dev/null 2>&1
  osascript -e 'quit app id "com.bnaylor.iris.dev"' 2>/dev/null; sleep 3
  kill -0 $pid 2>/dev/null && { kill -TERM $pid; sleep 2; }
  return 0
}
if [[ $which == pair ]]; then
for n in 40 200; do
  for pass in 1 2 3; do
    s=-; [[ $pass == 1 ]] && s=sample
    app=$before; one before$n-p$pass on $s IRIS_STREAM_PROBE_MESSAGES=$n
    app=$after;  one after$n-p$pass on $s IRIS_STREAM_PROBE_MESSAGES=$n
  done
done
elif [[ $which == residual ]]; then
B=(IRIS_STREAM_NOSCROLL=1 IRIS_STREAM_BUFFER=1)
for pass in 1 2 3; do
  s=-; [[ $pass == 1 ]] && s=sample
  one long-p$pass on $s $B
  one short-p$pass on $s $B IRIS_STREAM_MAXCHARS=400
  one plain-p$pass on $s $B IRIS_STREAM_PLAIN=1
done
else
# #541 attribution: four arms, interleaved, 40 messages; then base and both at 200 messages.
for pass in 1 2 3; do
  s=-; [[ $pass == 1 ]] && s=sample
  one base-p$pass on $s
  one noscroll-p$pass on $s IRIS_STREAM_NOSCROLL=1
  one buffer-p$pass on $s IRIS_STREAM_BUFFER=1
  one both-p$pass on $s IRIS_STREAM_NOSCROLL=1 IRIS_STREAM_BUFFER=1
done
for pass in 1 2 3; do
  s=-; [[ $pass == 1 ]] && s=sample
  one base200-p$pass on $s IRIS_STREAM_PROBE_MESSAGES=200
  one both200-p$pass on $s IRIS_STREAM_PROBE_MESSAGES=200 IRIS_STREAM_NOSCROLL=1 IRIS_STREAM_BUFFER=1
done
fi
echo; echo "RAW per-second %CPU (first sample dropped)"
for f in $out/*.top.txt; do printf "%-14s " $(basename $f .top.txt); awk '/^[0-9]+ +[0-9.]+/ {n++; if (n>1) printf "%s ", $2} END {print ""}' $f; done
echo; echo "FRAME COUNTS per 10 s sample (main thread and all threads; a frame's sample count where it first appears)"
pats=("NSDisplayCycleFlush" "-[NSWindow(NSConstraintBasedLayoutInternal) layoutIfNeeded]" "updateWindowContentSizeExtremaIfNecessary" "NSHostingView.layout" "-[NSTableView" "noteHeightOfRows" "_tile" "sizeThatFits" "AttributeGraph" "Markdown" "NSTextLayoutManager" "CTFramesetter" "CTLine" "AttributedString" "updateMessageContent")
for f in $out/*.sample.txt; do
  echo "== $(basename $f .sample.txt)"
  for p in $pats; do printf "  %-58s %s\n" "$p" "$(grep -F -m1 -- "$p" $f | grep -oE '^[ +!:|]*[0-9]+' | grep -oE '[0-9]+$')"; done
done
echo; echo "HOT FRAMES: top of stack, first baseline sample (base-p1)"
grep -A30 "Sort by top of stack" $out/$([[ $which == pair ]] && echo before40 || ([[ $which == residual ]] && echo long || echo base))-p1.sample.txt | sed -E 's/\(in [^)]*\)//' | cut -c1-150
