#!/bin/bash

start(){
  cleanup
  dep_check
  start_container
}

dep_check(){
  if ! which jq >/dev/null; then
    echo "jq missing. Please install jq"
    exit 127
  fi
  if ! which intel_gpu_top >/dev/null; then
    echo "intel_gpu_top missing. Please install intel-gpu-tools"
    exit 127
  fi
  if ! which printf >/dev/null; then
    echo "printf missing. Please install printf"
    exit 127
  fi
  if ! which docker >/dev/null; then
    echo "Docker missing. Please install Docker"
    exit 127
  fi
}

cleanup(){
  rm -rf ffmpeg*.log
  rm -rf *.output
  rm -rf *.nvsmi
}

start_container(){
  if ! $(docker inspect jellyfin-qsvtest >/dev/null 2>&1); then
    docker pull jellyfin/jellyfin >/dev/null
    docker run --rm -it -d --name jellyfin-qsvtest \
      --device=/dev/dri:/dev/dri \
      --device=/dev/nvidia0:/dev/nvidia0 \
      --device=/dev/nvidiactl:/dev/nvidiactl \
      --device=/dev/nvidia-modeset:/dev/nvidia-modeset \
      --device=/dev/nvidia-uvm-tools:/dev/nvidia-uvm-tools \
      --device=/dev/nvidia-uvm:/dev/nvidia-uvm \
      -e NVIDIA_DRIVER_CAPABILITIES=all \
      -e NVIDIA_VISIBLE_DEVICES=all \
      --runtime=nvidia \
      -v $(pwd):/config jellyfin/jellyfin >/dev/null
  fi
  sleep 5s
  if $(docker inspect jellyfin-qsvtest | jq -r '.[].State.Running'); then
    main
  else
    echo "Jellyfin NVENC test container not running"
    exit 127
  fi
}

stop_container(){
  if $(docker inspect jellyfin-qsvtest | jq -r '.[].State.Running'); then
    docker stop jellyfin-qsvtest > /dev/null
  fi
}

benchmarks(){
  # Log wattage
  if [ "$1" = "h264_1080p_cpu" ]; then
      intel_gpu_top -s 100ms -l -o $1.output &
      watt_pid=$(echo $!)
  else
      nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits -lms 100 > $1.nvsmi &
      watt_pid=$(echo $!)
  fi

  docker exec -it jellyfin-qsvtest /config/benchmark.sh $1

  kill -s SIGINT $watt_pid
  sleep 1s

  if [ "$1" = "h264_1080p_cpu" ]; then
      watt_values=$(awk '{ print $5 }' $1.output | grep -Ev '^0|Power|gpu')
      if [ -z "$watt_values" ]; then
          avg_watts="N/A"
      else
          total_watts=$(echo "$watt_values" | paste -sd+ - | bc)
          total_count=$(echo "$watt_values" | wc -l)
          avg_watts=$(echo "scale=2; $total_watts / $total_count" | bc -l)
      fi
      rm -f $1.output
  else
      watt_values=$(grep -Eo '^[0-9]+(\.[0-9]+)?' $1.nvsmi)
      if [ -z "$watt_values" ]; then
          avg_watts="N/A"
      else
          total_watts=$(echo "$watt_values" | paste -sd+ - | bc)
          total_count=$(echo "$watt_values" | wc -l)
          avg_watts=$(echo "scale=2; $total_watts / $total_count" | bc -l)
      fi
      rm -f $1.nvsmi
  fi

  for i in $(ls ffmpeg-*.log); do
    fps_values=$(grep -Eo 'fps=[[:space:]]*[0-9]+(\.[0-9]+)?' "$i" | sed -E 's/fps=[[:space:]]*//')
    if [ -z "$fps_values" ]; then
      avg_fps="N/A"
    else
      total_fps=$(echo "$fps_values" | paste -sd+ - | bc)
      fps_count=$(echo "$fps_values" | wc -l)
      avg_fps=$(echo "scale=2; $total_fps / $fps_count" | bc -l)
    fi

    speed_values=$(grep -Eo 'speed=[[:space:]]*[0-9]+(\.[0-9]+)?' "$i" | sed -E 's/speed=[[:space:]]*//')
    if [ -z "$speed_values" ]; then
      avg_speed="N/A"
    else
      total_speed=$(echo "$speed_values" | paste -sd+ - | bc)
      speed_count=$(echo "$speed_values" | wc -l)
      avg_speed=$(echo "scale=2; $total_speed / $speed_count" | bc -l)
      avg_speed="${avg_speed}x"
    fi

    bitrate=$(grep -Eo 'bitrate: [0-9]+' "$i" | sed -E 's/bitrate:[[:space:]]*//')
    total_time=$(grep -Eo 'rtime=[0-9]+\.[0-9]+s' "$i" | sed 's/rtime=//')
    rm -f "$i"
  done

  if [ "$1" = "h264_1080p_cpu" ]; then
      device="$cpu_model"
  else
      device="$gpu_model"
  fi

  quicksyncstats_arr+=("$device|$1|$2|$bitrate|$total_time|$avg_fps|$avg_speed|$avg_watts")
  clear_vars
}

clear_vars(){
  for var in total_watts total_count avg_watts total_fps fps_count avg_fps total_speed speed_count avg_speed bitrate total_time; do
    unset $var
  done
}

main(){
  quicksyncstats_arr=("CPU|TEST|FILE|BITRATE|TIME|AVG_FPS|AVG_SPEED|AVG_WATTS")
  cpuinfo_model="$(grep -m1 'model name' /proc/cpuinfo | cut -d':' -f2)"
  cpu_model="${cpuinfo_model:-CPU}"
  gpu_model=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n 1)
  gpu_model="${gpu_model:-GPU}"

  benchmarks h264_1080p_cpu ribblehead_1080p_h264
  benchmarks h264_1080p ribblehead_1080p_h264
  benchmarks h264_4k ribblehead_4k_h264
  benchmarks hevc_8bit ribblehead_1080p_hevc_8bit
  benchmarks hevc_4k_10bit ribblehead_4k_hevc_10bit

  printf '%s\n' "${quicksyncstats_arr[@]}" | column -t -s '|'
  printf "\n"
  unset quicksyncstats_arr
  stop_container
}

start
