#!/usr/bin/env bash
# The sound she makes when she has heard her name (Audio.chime): any clip of
# yours, made into what the app plays — mono, 32 kHz, 16-bit WAV, peak at
# -1 dBFS so it carries across a room (the breaths needed +20 dB for that,
# 2026-09-18), 5 ms fades so it never clicks, at most 3 seconds.
#
#   scripts/set-wake-sound.sh ~/Downloads/fairy.wav [peak dBFS, default -1]     then commit + push
#   scripts/set-wake-sound.sh --clear                   back to her breaths
#
# The clip is yours to supply: nothing here fetches one.
set -euo pipefail
out="$(dirname "$0")/../Haru/Resources/wake/wake-listen.wav"
if [ "${1:-}" = "--clear" ]; then rm -f "$out"; echo "cleared: her breaths again"; exit 0; fi
src="${1:?a sound file}"
# Peak in dBFS, optional second argument. -1 suits a soft breath; a dense,
# bright clip at -1 is piercing (the fairy "Hey!" went to -10, 2026-09-19).
target="${2:--1}"
[ -f "$src" ] || { echo "no such file: $src" >&2; exit 1; }
peak=$(ffmpeg -hide_banner -nostats -i "$src" -t 3 -af volumedetect -f null - 2>&1 | sed -n 's/.*max_volume: \(-\?[0-9.]*\) dB/\1/p')
gain=$(python3 -c "print(round(float('${target}') - float('${peak:-0}'), 2))")
dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$src")
end=$(python3 -c "print(max(0.0, round(min(3.0, float('$dur')) - 0.005, 3)))")
ffmpeg -hide_banner -loglevel error -y -i "$src" -t 3 -ac 1 -ar 32000 -af "volume=${gain}dB,afade=t=in:d=0.005,afade=t=out:st=${end}:d=0.005" -c:a pcm_s16le "$out"
echo "wake sound set: $(basename "$src") → $out (gain ${gain} dB)"
