#!/bin/sh
# Makes the test clips from the scripts in samples/ with macOS `say` (16 kHz mono WAV, not committed).
set -e
cd "$(dirname "$0")/../samples"
for name in talk good ramble; do
  script=$name.txt
  [ "$name" = talk ] && script=script.txt
  say -v Samantha -r 175 -f "$script" -o "$name.wav" --file-format=WAVE --data-format=LEI16@16000
  echo "samples/$name.wav"
done
