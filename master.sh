#!/bin/bash
# マスタリング: EQ(こもり除去+プレゼンス+高域) + 軽コンプ + Spotify基準 -14 LUFS
# 使い方: bash master.sh input.flac output.mp3
set -euo pipefail
IN="$1"; OUT="$2"
ffmpeg -v error -y -i "$IN" -af "
  highpass=f=25,
  equalizer=f=250:t=q:w=1.2:g=-1.5,
  equalizer=f=3500:t=q:w=1.0:g=1.5,
  treble=g=2.5:f=8000,
  acompressor=threshold=-18dB:ratio=2:attack=12:release=180:makeup=2,
  loudnorm=I=-14:TP=-1.0:LRA=11
" -ar 48000 -codec:a libmp3lame -q:a 0 "$OUT"
echo "done: $OUT"
