#!/bin/bash

benchmark(){
  case "$1" in
    h264_1080p_cpu)
      h264_1080p_cpu
      ;;
    h264_1080p)
      h264_1080p
      ;;
    h264_4k)
      h264_4k
      ;;
    hevc_8bit)
      hevc_8bit
      ;;
    hevc_4k_10bit)
      hevc_4k_10bit
      ;;
  esac
}

h264_1080p_cpu(){
  echo "=== CPU-only test"
  echo "h264_1080p_cpu - h264 to h264 CPU starting."
  /usr/lib/jellyfin-ffmpeg/ffmpeg -y -hide_banner -benchmark -report \
    -c:v h264 -i /config/ribblehead_1080p_h264.mp4 -c:a copy \
    -c:v h264 -preset fast -global_quality 18 -f null - 2>/dev/null
}

h264_1080p(){
  echo "=== NVENC + NVDEC test"
  echo "h264_1080p - h264_cuvid to h264_nvenc starting."
  /usr/lib/jellyfin-ffmpeg/ffmpeg -y -hide_banner -benchmark -report \
    -hwaccel cuda -hwaccel_output_format cuda -c:v h264_cuvid \
    -i /config/ribblehead_1080p_h264.mp4 -c:a copy \
    -c:v h264_nvenc -preset fast -cq 18 -look_ahead 1 -f null - 2>/dev/null
}

h264_4k(){
  echo "=== NVENC + NVDEC test)"
  echo "h264_4k - h264_cuvid to h264_nvenc starting."
  /usr/lib/jellyfin-ffmpeg/ffmpeg -y -hide_banner -benchmark -report \
    -hwaccel cuda -hwaccel_output_format cuda -c:v h264_cuvid \
    -i /config/ribblehead_4k_h264.mp4 -c:a copy \
    -c:v h264_nvenc -preset fast -cq 18 -look_ahead 1 -f null - 2>/dev/null
}

hevc_8bit(){
  echo "=== NVENC + NVDEC test"
  echo "hevc_1080p_8bit - hevc_cuvid to hevc_nvenc starting."
  /usr/lib/jellyfin-ffmpeg/ffmpeg -y -hide_banner -benchmark -report \
    -hwaccel cuda -hwaccel_output_format cuda -c:v hevc_cuvid \
    -i /config/ribblehead_1080p_hevc_8bit.mp4 -c:a copy \
    -c:v hevc_nvenc -preset fast -cq 18 -look_ahead 1 -f null - 2>/dev/null
}

hevc_4k_10bit(){
  echo "=== NVENC + NVDEC test"
  echo "hevc_4k - hevc_cuvid to hevc_nvenc starting."
  /usr/lib/jellyfin-ffmpeg/ffmpeg -y -hide_banner -benchmark -report \
    -hwaccel cuda -hwaccel_output_format cuda -c:v hevc_cuvid \
    -i /config/ribblehead_4k_hevc_10bit.mp4 -c:a copy \
    -c:v hevc_nvenc -preset fast -cq 18 -look_ahead 1 -f null - 2>/dev/null
}

cd /config
benchmark $1
