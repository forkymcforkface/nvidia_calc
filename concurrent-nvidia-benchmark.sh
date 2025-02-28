#!/bin/bash

start(){
  cleanup
  dep_check
  start_container "$@"
}

dep_check(){
  if ! command -v jq >/dev/null; then
    echo "jq missing. Please install jq"
    exit 127
  fi
  if ! command -v intel_gpu_top >/dev/null; then
    echo "intel_gpu_top missing. Please install intel-gpu-tools"
    exit 127
  fi
  if ! command -v printf >/dev/null; then
    echo "printf missing. Please install printf"
    exit 127
  fi
  if ! command -v docker >/dev/null; then
    echo "Docker missing. Please install Docker"
    exit 127
  fi
}

cleanup(){
  rm -rf ffmpeg*.log *.output *.nvsmi
}

start_container(){
  if ! docker inspect jellyfin-qsvtest >/dev/null 2>&1; then
    docker pull jellyfin/jellyfin >/dev/null
    docker run --rm -d --name jellyfin-qsvtest \
      --device=/dev/dri:/dev/dri \
      --device=/dev/nvidia0:/dev/nvidia0 \
      --device=/dev/nvidiactl:/dev/nvidiactl \
      --device=/dev/nvidia-modeset:/dev/nvidia-modeset \
      --device=/dev/nvidia-uvm-tools:/dev/nvidia-uvm-tools \
      --device=/dev/nvidia-uvm:/dev/nvidia-uvm \
      -e NVIDIA_DRIVER_CAPABILITIES=all \
      -e NVIDIA_VISIBLE_DEVICES=all \
      --runtime=nvidia \
      -v "$(pwd)":/config jellyfin/jellyfin >/dev/null
  fi
  sleep 5s
  if docker inspect jellyfin-qsvtest | jq -r '.[].State.Running' | grep true >/dev/null; then
    # Always run concurrency tests by default.
    max_concurrency_all
  else
    echo "Jellyfin NVENC test container not running"
    exit 127
  fi
}

stop_container(){
  if docker inspect jellyfin-qsvtest | jq -r '.[].State.Running' | grep true >/dev/null; then
    docker stop jellyfin-qsvtest > /dev/null
  fi
}

# Original sequential benchmark function – calls your benchmark.sh script.
benchmarks(){
  docker exec -it jellyfin-qsvtest /config/benchmark-nvenc.sh "$1"
}

# Run N concurrent sessions of a given test type.
concurrent_benchmarks(){
  local test_type=$1
  local concurrency=$2
  rm -f ffmpeg*.log
  local pids=()
  for i in $(seq 1 "$concurrency"); do
    # Run each instance in the background without printing ffmpeg output.
    docker exec jellyfin-qsvtest /config/benchmark.sh "$test_type" > /dev/null 2>&1 &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do
    wait "$pid"
  done

  local total_speed=0
  local count=0
  for log in ffmpeg*.log; do
    while IFS= read -r sp; do
      total_speed=$(echo "$total_speed + $sp" | bc -l)
      count=$((count+1))
    done < <(grep -Eo 'speed=[[:space:]]*[0-9]+(\.[0-9]+)?' "$log" | sed -E 's/speed=[[:space:]]*//')
    rm -f "$log"
  done

  if [ $count -gt 0 ]; then
    avg_speed=$(echo "scale=2; $total_speed / $count" | bc -l)
    echo "$avg_speed"
  else
    echo ""
  fi
}

# Increment concurrency until the aggregated average speed falls below 1.0×.
max_concurrency_test(){
  local test_type=$1
  echo "Starting concurrency test for $test_type..."
  local concurrency=1
  local avg_speed=0
  local last_valid=0

  while true; do
    # Print a temporary "Running" status.
    echo -ne "Concurrency: $concurrency, Running\r"
    avg_speed=$(concurrent_benchmarks "$test_type" "$concurrency")
    # Clear the "Running" message by printing the result on a new line.
    echo "Concurrency: $concurrency, Average Speed: ${avg_speed}x"
    if [ -z "$avg_speed" ]; then
      break
    fi
    if (( $(echo "$avg_speed < 1.0" | bc -l) )); then
      break
    else
      last_valid=$concurrency
    fi
    concurrency=$((concurrency+1))
  done
  echo "Maximum concurrency: ${last_valid}x"
}

# Loop through all tests and run concurrency tests.
max_concurrency_all(){
  tests=( "h264_1080p_cpu" "h264_1080p" "h264_4k" "hevc_8bit" "hevc_4k_10bit" )
  for test in "${tests[@]}"; do
    echo "--------------------------------------------------"
    max_concurrency_test "$test"
  done
  stop_container
}

main(){
  quicksyncstats_arr=("CPU|TEST|FILE|BITRATE|TIME|AVG_FPS|AVG_SPEED|AVG_WATTS")
  cpuinfo_model="$(grep -m1 'model name' /proc/cpuinfo | cut -d':' -f2)"
  cpu_model="${cpuinfo_model:-CPU}"
  gpu_model=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n 1)
  gpu_model="${gpu_model:-GPU}"

  benchmarks h264_1080p_cpu
  benchmarks h264_1080p
  benchmarks h264_4k
  benchmarks hevc_8bit
  benchmarks hevc_4k_10bit

  printf '%s\n' "${quicksyncstats_arr[@]}" | column -t -s '|'
  printf "\n"
  unset quicksyncstats_arr
  stop_container
}

# Run the concurrency tests by default.
start
