#!/bin/bash
# Enter a solve.py move list in the game: move the cursor with the arrow keys
# and select each cell with Return. Keys are held briefly; instant xdotool taps
# fall between the game's input polls and get ignored.
#
# usage: play.sh CUR_ROW CUR_COL  r,c r,c ...
#   CUR_ROW/CUR_COL = where the puzzle's selection cursor is right now.
# DISPLAY_GAME overrides the target display (default :1), the Xwayland server the game runs on in Gaming Mode
# (:0 is Steam itself); check with: DISPLAY=:1 xdotool getactivewindow getwindowname
set -eu
export DISPLAY=${DISPLAY_GAME:-:1}
k() { xdotool keydown "$1"; sleep 0.12; xdotool keyup "$1"; sleep 0.35; }
r=$1; c=$2; shift 2
for t in "$@"; do
  tr=${t%,*}; tc=${t#*,}
  while [ "$r" -lt "$tr" ]; do k Down; r=$((r+1)); done
  while [ "$r" -gt "$tr" ]; do k Up; r=$((r-1)); done
  while [ "$c" -lt "$tc" ]; do k Right; c=$((c+1)); done
  while [ "$c" -gt "$tc" ]; do k Left; c=$((c-1)); done
  k Return; sleep 1.2
done
