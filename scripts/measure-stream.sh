#!/bin/zsh
# #541: idle chat-window CPU with a reply streaming in (DebugStreamProbe) vs the same window idle.
# usage: measure-stream.sh <Iris Dev.app built from measure/541-probe> <outdir>
# Needs: the GUI lease, the display awake. One Debug build; the arms differ only in
# IRIS_STREAM_PROBE (idle | on). The probe makes and selects its own conversation,
# "#541 stream probe" (fixed id; its title is re-set on every launch, which the window check below
# relies on), the first time, and deletes probe conversations left by earlier probe builds.
set -u
app=$1; out=$2; mkdir -p $out
cat > $out/winlist.swift <<'SWIFT'
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
for w in CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    where (w[kCGWindowOwnerPID as String] as? Int) == pid {
    print("id=\(w[kCGWindowNumber as String] ?? 0)", w[kCGWindowName as String] ?? "-", "alpha=\(w[kCGWindowAlpha as String] ?? "-")")
}
SWIFT
swiftc -O -o $out/winlist $out/winlist.swift || exit 1
one() {   # <label> <idle|on> [sample]
  local label=$1 mode=$2 dosample=${3:-}
  open -g -n --env IRIS_STREAM_PROBE=$mode "$app" || return 1
  sleep 15
  local pid=$(pgrep -f "$app/Contents/MacOS/" | head -1)
  [[ -z $pid ]] && { echo "$label: no pid"; return 1; }
  open -g "$app"; sleep 8          # a reopen shows the chat window; the probe has selected its conversation
  $out/winlist $pid > $out/$label.windows.txt
  grep -q "stream probe" $out/$label.windows.txt || { echo "$label: probe conversation not on screen, run invalid"; cat $out/$label.windows.txt; kill -TERM $pid; return 1; }
  local load=$(sysctl -n vm.loadavg | awk '{print $2}')
  top -pid $(pgrep -x WindowServer) -l 31 -s 1 -stats pid,cpu,command > $out/$label.ws.txt &
  local wspid=$!
  top -pid $pid -l 31 -s 1 -stats pid,cpu,command > $out/$label.top.txt
  wait $wspid
  local ws=$(awk '/^[0-9]+ +[0-9.]+/ {n++; if (n>1) {s+=$2; c++}} END {printf "%.1f", s/c}' $out/$label.ws.txt)
  awk -v lab=$label -v l=$load -v ws=$ws '/^[0-9]+ +[0-9.]+/ {n++; if (n>1) {s+=$2; c++}} END {printf "%-14s mean %5.1f%% over %d samples, WindowServer %s%%, load1 %s\n", lab, s/c, c, ws, l}' $out/$label.top.txt
  [[ -n $dosample ]] && sample $pid 10 -file $out/$label.sample.txt >/dev/null 2>&1
  osascript -e 'quit app id "com.bnaylor.iris.dev"' 2>/dev/null; sleep 3
  kill -0 $pid 2>/dev/null && { kill -TERM $pid; sleep 2; }
  return 0
}
for pass in 1 2 3; do
  s=; [[ $pass == 1 ]] && s=sample
  one idle-p$pass idle $s
  one on-p$pass on sample
done
echo; echo "RAW per-second %CPU (first sample dropped)"
for f in $out/*.top.txt; do printf "%-14s " $(basename $f .top.txt); awk '/^[0-9]+ +[0-9.]+/ {n++; if (n>1) printf "%s ", $2} END {print ""}' $f; done
echo; echo "FRAME COUNTS per 10 s sample (main thread and all threads; a frame's sample count where it first appears)"
pats=("NSDisplayCycleFlush" "-[NSWindow(NSConstraintBasedLayoutInternal) layoutIfNeeded]" "updateWindowContentSizeExtremaIfNecessary" "NSHostingView.layout" "-[NSTableView" "noteHeightOfRows" "_tile" "sizeThatFits" "AttributeGraph" "Markdown" "NSTextLayoutManager" "CTFramesetter" "CTLine" "AttributedString" "updateMessageContent")
for f in $out/*.sample.txt; do
  echo "== $(basename $f .sample.txt)"
  for p in $pats; do printf "  %-58s %s\n" "$p" "$(grep -F -m1 -- "$p" $f | grep -oE '^[ +!:|]*[0-9]+' | grep -oE '[0-9]+$')"; done
done
echo; echo "HOT FRAMES: top of stack, first streaming sample (on-p1)"
grep -A30 "Sort by top of stack" $out/on-p1.sample.txt | sed -E 's/\(in [^)]*\)//' | cut -c1-150
