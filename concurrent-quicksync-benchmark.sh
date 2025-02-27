#!/bin/bash
set -e

tests=("h264_1080p_cpu" "h264_1080p" "h264_4k" "hevc_8bit" "hevc_4k_10bit")
files=("ribblehead_1080p_h264" "ribblehead_1080p_h264" "ribblehead_4k_h264" "ribblehead_1080p_hevc_8bit" "ribblehead_4k_hevc_10bit")
declare -A results

check_deps() {
  for cmd in jq printf docker bc; do
    command -v "$cmd" >/dev/null || { echo "$cmd missing. Please install $cmd"; exit 127; }
  done
}

cleanup() { rm -rf ffmpeg*.log *.output; }

start_container() {
  if ! docker inspect jellyfin-qsvtest >/dev/null 2>&1; then
    docker pull jellyfin/jellyfin >/dev/null
    docker run --rm -d --name jellyfin-qsvtest --device=/dev/dri:/dev/dri -v "$(pwd)":/config jellyfin/jellyfin >/dev/null
  fi
  sleep 5
  docker inspect jellyfin-qsvtest | jq -r '.[].State.Running' | grep true >/dev/null || { echo "Container not running"; exit 127; }
}

stop_container() {
  docker inspect jellyfin-qsvtest | jq -r '.[].State.Running' | grep true >/dev/null && docker stop jellyfin-qsvtest >/dev/null
}

run_benchmark_concurrent() {
  local test="$1" file="$2" conc="$3"
  cleanup
  shopt -s nullglob
  local pids=()
  for ((i=1; i<=conc; i++)); do
    docker exec jellyfin-qsvtest /config/benchmark.sh "$test" "$file" >/dev/null 2>&1 &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
  local sum=0 count=0
  for log in ffmpeg-*.log; do
    while read -r sp; do
      sum=$(echo "$sum + $sp" | bc -l)
      ((count++))
    done < <(grep -Eo 'speed=[0-9]+\.[0-9]+' "$log" | sed -E 's/speed=//')
    rm -f "$log"
  done
  if (( count > 0 )); then
    echo "$(echo "scale=2; $sum / $count" | bc -l)"
  else
    echo "0"
  fi
}

run_test_concurrency() {
  local test="$1" file="$2"
  echo "--------------------------------------------------"
  echo "Starting concurrency test for $test..."
  local conc=1 last_valid=0 avg=0
  local speeds=()
  while true; do
    avg=$(run_benchmark_concurrent "$test" "$file" "$conc")
    echo "Concurrency: $conc, Average Speed: ${avg}x"
    speeds+=("$avg")
    (( $(echo "$avg < 1.0" | bc -l) )) && break || last_valid=$conc
    ((conc++))
  done
  echo "Maximum concurrency: ${last_valid}x"
  results["$test"]="${speeds[*]}"
}

print_table() {
  local cpu
  cpu=$(grep -m1 'model name' /proc/cpuinfo | cut -d':' -f2 | sed 's/^[[:space:]]*//')
  local max_cols=0
  for test in "${tests[@]}"; do
    IFS=' ' read -ra arr <<< "${results[$test]}"
    (( ${#arr[@]} > max_cols )) && max_cols=${#arr[@]}
  done
  local header="CPU\tTEST\tFILE"
  for ((i=1; i<=max_cols; i++)); do header="$header\t$i"; done
  local table="$header\n"
  for idx in "${!tests[@]}"; do
    local test="${tests[$idx]}" file="${files[$idx]}"
    IFS=' ' read -ra arr <<< "${results[$test]}"
    local row="$cpu\t$test\t$file"
    for ((j=0; j<max_cols; j++)); do
      if (( j < ${#arr[@]} )); then
        row="$row\t${arr[j]}x"
      else
        row="$row\t–"
      fi
    done
    table="$table$row\n"
  done
  echo -e "$table" | column -t -s $'\t'
}

main() {
  check_deps
  cleanup
  start_container
  for idx in "${!tests[@]}"; do
    run_test_concurrency "${tests[$idx]}" "${files[$idx]}"
  done
  stop_container
  echo ""
  print_table
}

main
