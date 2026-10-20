#!/usr/bin/env bash
# Software codec rate-distortion benchmark at REALTIME settings (as a remote-desktop
# client uses them). For each codec x target-bitrate: actual bitrate, encode fps
# (realtime needs >= source fps), SSIM and PSNR vs the reference.
set -u
B="$(dirname "$0")"; REF="$B/ref.y4m"
FPS=30; DUR=10
enc_of() {  # $1=codec $2=bitrate -> prints "codec|bitrate|outfile|ffmpeg-args"
  case "$1" in
    vp8)  echo "-c:v libvpx -deadline realtime -cpu-used 8 -b:v $2";;
    vp9)  echo "-c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v $2";;
    av1)  echo "-c:v libaom-av1 -usage realtime -cpu-used 8 -b:v $2";;
    h264) echo "-c:v libx264 -preset veryfast -tune zerolatency -b:v $2";;
    h265) echo "-c:v libx265 -preset ultrafast -tune zerolatency -b:v $2";;
  esac
}
ext_of() { case "$1" in vp8|vp9) echo webm;; *) echo mp4;; esac; }
printf "%-6s %-8s %10s %8s %8s %8s\n" codec target "act.kbps" "enc.fps" SSIM "PSNR.dB"
for br in 1M 2M 4M; do
  for c in vp8 vp9 av1 h264 h265; do
    out="$B/out_${c}_${br}.$(ext_of $c)"
    args=$(enc_of "$c" "$br")
    t0=$(date +%s.%N)
    ffmpeg -y -hide_banner -loglevel error -i "$REF" $args "$out" 2>/dev/null
    t1=$(date +%s.%N)
    [ -s "$out" ] || { printf "%-6s %-8s %10s\n" "$c" "$br" "FAILED"; continue; }
    bytes=$(stat -c %s "$out"); kbps=$(awk "BEGIN{printf \"%.0f\", $bytes*8/1000/$DUR}")
    encfps=$(awk "BEGIN{printf \"%.1f\", ($FPS*$DUR)/($t1-$t0)}")
    ssim=$(ffmpeg -hide_banner -loglevel error -i "$out" -i "$REF" -lavfi "[0:v][1:v]ssim" -f null - 2>&1 | grep -oE 'All:[0-9.]+' | head -1 | cut -d: -f2)
    psnr=$(ffmpeg -hide_banner -loglevel error -i "$out" -i "$REF" -lavfi "[0:v][1:v]psnr" -f null - 2>&1 | grep -oE 'average:[0-9.]+' | head -1 | cut -d: -f2)
    printf "%-6s %-8s %10s %8s %8s %8s\n" "$c" "$br" "$kbps" "$encfps" "${ssim:-?}" "${psnr:-?}"
  done
done
