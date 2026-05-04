#!/usr/bin/env bash
set -euo pipefail

project_dir="${CI_PROJECT_DIR:-$(pwd)}"
output_dir="${OUTPUT_DIR:-$project_dir/output/scrna}"
manifest_path="${SCRNA_MANIFEST:-$project_dir/config/scrna/rp_manifest.tsv}"
data_root="${SCRNA_DATA_ROOT:-/home/zhangmeigroup/luoxin23/scrna-rp-data}"
work_dir="${SCRNA_WORK_DIR:-$data_root/work}"
download_dir="${SCRNA_DOWNLOAD_DIR:-$data_root/downloads}"
summary_dir="${SCRNA_SUMMARY_DIR:-$output_dir/results}"
log_dir="${SCRNA_LOG_DIR:-$output_dir/logs}"
heartbeat_interval="${SCRNA_HEARTBEAT_SECONDS:-300}"
stall_seconds="${SCRNA_STALL_SECONDS:-1800}"
download_retries="${SCRNA_DOWNLOAD_RETRIES:-2}"
candidate_table="${SCRNA_WES_CANDIDATE_TABLE:-$project_dir/config/wes/company-family-targets.tsv}"

mkdir -p "$download_dir" "$summary_dir" "$log_dir" "$work_dir"

main_log="$log_dir/scrna-rp-prioritization.log"
heartbeat_file="$summary_dir/heartbeat.tsv"
status_file="$summary_dir/download_status.tsv"
degrade_file="$summary_dir/degrade_report.md"

exec > >(tee -a "$main_log") 2>&1

echo "== RP scRNA prioritization =="
echo "date=$(date -Iseconds)"
echo "hostname=$(hostname)"
echo "project_dir=$project_dir"
echo "output_dir=$output_dir"
echo "data_root=$data_root"
echo "manifest_path=$manifest_path"
echo "candidate_table=$candidate_table"
echo "stall_seconds=$stall_seconds"

phase_file="$summary_dir/current_phase.txt"
printf 'timestamp\tphase\tmessage\n' > "$heartbeat_file"
printf 'dataset_id\tstatus\tattempts\tfile_count\tbytes\tmessage\n' > "$status_file"

heartbeat_loop() {
  while :; do
    local phase="unknown"
    if [[ -f "$phase_file" ]]; then
      phase="$(cat "$phase_file" 2>/dev/null || true)"
    fi
    printf '%s\t%s\talive\n' "$(date -Iseconds)" "$phase" >> "$heartbeat_file"
    sleep "$heartbeat_interval"
  done
}

heartbeat_loop &
heartbeat_pid=$!
cleanup() {
  kill "$heartbeat_pid" 2>/dev/null || true
}
trap cleanup EXIT

set_phase() {
  printf '%s\n' "$1" > "$phase_file"
  printf '%s\t%s\t%s\n' "$(date -Iseconds)" "$1" "${2:-phase change}" >> "$heartbeat_file"
}

have_downloader() {
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1
}

download_one_url() {
  local url="$1"
  local target="$2"
  local log_path="$3"

  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --retry 2 --retry-delay 10 -C - --connect-timeout 60 --max-time 0 \
      -o "$target" "$url" >> "$log_path" 2>&1
  else
    wget -c -O "$target" "$url" >> "$log_path" 2>&1
  fi
}

run_download_with_watchdog() {
  local dataset_id="$1"
  local url="$2"
  local target="$3"
  local log_path="$4"
  local last_log_size=0
  local last_file_size=0
  local last_progress_epoch
  last_progress_epoch="$(date +%s)"

  : > "$log_path"
  echo "download_url=$url" >> "$log_path"
  download_one_url "$url" "$target" "$log_path" &
  local pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    sleep 30
    local now log_size file_size
    now="$(date +%s)"
    log_size=0
    file_size=0
    [[ -f "$log_path" ]] && log_size="$(wc -c < "$log_path" | tr -d '[:space:]')"
    [[ -f "$target" ]] && file_size="$(wc -c < "$target" | tr -d '[:space:]')"
    printf '%s\tdownloading:%s\tlog_bytes=%s file_bytes=%s target=%s\n' \
      "$(date -Iseconds)" "$dataset_id" "$log_size" "$file_size" "$target" >> "$heartbeat_file"

    if [[ "$log_size" != "$last_log_size" || "$file_size" != "$last_file_size" ]]; then
      last_progress_epoch="$now"
      last_log_size="$log_size"
      last_file_size="$file_size"
    elif (( now - last_progress_epoch > stall_seconds )); then
      echo "[STALL] No log/file growth for ${stall_seconds}s; killing download pid=$pid" | tee -a "$log_path"
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
  done

  wait "$pid"
}

safe_filename_from_url() {
  local url="$1"
  local fallback="$2"
  local base
  base="${url%%\?*}"
  base="${base##*/}"
  base="${base//%5F/_}"
  base="${base//%2E/.}"
  base="${base//%2F/_}"
  base="${base//[^A-Za-z0-9._-]/_}"
  if [[ -z "$base" || "$base" == "download" || "$base" == "browse" ]]; then
    base="$fallback"
  fi
  printf '%s\n' "$base"
}

record_status() {
  local dataset_id="$1"
  local status="$2"
  local attempts="$3"
  local dataset_dir="$download_dir/$dataset_id"
  local file_count=0
  local bytes=0
  if [[ -d "$dataset_dir" ]]; then
    file_count="$(find "$dataset_dir" -type f ! -name '*.log' | wc -l | tr -d '[:space:]')"
    bytes="$(find "$dataset_dir" -type f ! -name '*.log' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}')"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$dataset_id" "$status" "$attempts" "$file_count" "$bytes" "${6:-}" >> "$status_file"
}

download_manifest() {
  if [[ ! -f "$manifest_path" ]]; then
    echo "Manifest not found: $manifest_path" >&2
    exit 2
  fi
  if ! have_downloader; then
    echo "Neither curl nor wget is available" >&2
    exit 127
  fi

  set_phase "download" "starting manifest downloads"
  tail -n +2 "$manifest_path" | while IFS=$'\t' read -r dataset_id priority species model accession source_url download_urls file_type expected_file has_author_annotation notes; do
    [[ -z "${dataset_id:-}" ]] && continue
    local_dataset_dir="$download_dir/$dataset_id"
    mkdir -p "$local_dataset_dir"
    echo "--- dataset=$dataset_id priority=$priority model=$model accession=$accession ---"
    echo "$notes" > "$local_dataset_dir/notes.txt"
    printf '%s\n' "$source_url" > "$local_dataset_dir/source_url.txt"
    printf '%s\n' "$download_urls" > "$local_dataset_dir/download_urls.txt"

    IFS='|' read -r -a urls <<< "$download_urls"
    IFS=';' read -r -a expected_files <<< "$expected_file"
    dataset_status="downloaded"
    attempts=0
    message=""

    required_count=1
    if (( ${#expected_files[@]} > 1 )); then
      required_count="${#expected_files[@]}"
    fi

    if (( required_count > 1 && ${#urls[@]} != required_count )); then
      dataset_status="failed"
      message="expected_file/url count mismatch expected=${#expected_files[@]} urls=${#urls[@]}"
      echo "[WARN] $message"
      record_status "$dataset_id" "$dataset_status" "$attempts" "" "" "$message"
      continue
    fi

    if (( required_count == 1 )); then
      target_name="${expected_files[0]:-$(safe_filename_from_url "${urls[0]}" "${dataset_id}.${file_type}")}"
      if [[ "$file_type" == "html" ]]; then
        target_name="${dataset_id}.metadata.html"
      fi
      target="$local_dataset_dir/$target_name"

      file_downloaded=0
      for url in "${urls[@]}"; do
        [[ -z "$url" ]] && continue
        for attempt in $(seq 1 "$download_retries"); do
          attempts=$((attempts + 1))
          log_path="$local_dataset_dir/download-${target_name}-attempt${attempt}.log"
          echo "Downloading $dataset_id attempt=$attempt target=$target"
          set +e
          run_download_with_watchdog "$dataset_id" "$url" "$target" "$log_path"
          status=$?
          set -e
          if [[ $status -eq 0 && -s "$target" ]]; then
            message="downloaded $target_name"
            file_downloaded=1
            break 2
          fi
          message="failed url=$url status=$status"
          echo "[WARN] $message"
        done
      done

      if (( file_downloaded == 0 )); then
        dataset_status="failed"
      fi
    else
      downloaded_files=0
      failed_files=()
      for idx in "${!urls[@]}"; do
        url="${urls[$idx]}"
        [[ -z "$url" ]] && continue
        target_name="${expected_files[$idx]}"
        [[ -z "$target_name" ]] && target_name="$(safe_filename_from_url "$url" "${dataset_id}_${idx}.${file_type}")"
        target="$local_dataset_dir/$target_name"
        file_downloaded=0

        for attempt in $(seq 1 "$download_retries"); do
          attempts=$((attempts + 1))
          log_path="$local_dataset_dir/download-${target_name}-attempt${attempt}.log"
          echo "Downloading $dataset_id file=$target_name attempt=$attempt target=$target"
          set +e
          run_download_with_watchdog "$dataset_id" "$url" "$target" "$log_path"
          status=$?
          set -e
          if [[ $status -eq 0 && -s "$target" ]]; then
            downloaded_files=$((downloaded_files + 1))
            file_downloaded=1
            break
          fi
          echo "[WARN] failed url=$url status=$status"
        done

        if (( file_downloaded == 0 )); then
          failed_files+=("$target_name")
        fi
      done

      if (( downloaded_files == required_count )); then
        message="downloaded ${downloaded_files}/${required_count} required files"
      else
        dataset_status="failed"
        message="missing required files: ${failed_files[*]}"
      fi
    fi

    record_status "$dataset_id" "$dataset_status" "$attempts" "" "" "$message"
  done
}

build_checks_and_ranking() {
  set_phase "ranking" "running read checks and candidate ranking"
  local python_bin=""
  if command -v python3 >/dev/null 2>&1; then
    python_bin="python3"
  elif command -v python >/dev/null 2>&1; then
    python_bin="python"
  else
    echo "No Python interpreter available for ranking" >&2
    exit 127
  fi

  "$python_bin" "$project_dir/scripts/scrna-rp-rank.py" \
    --manifest "$manifest_path" \
    --download-dir "$download_dir" \
    --status "$status_file" \
    --candidate-table "$candidate_table" \
    --out-dir "$summary_dir"
}

write_tree() {
  set_phase "finalize" "writing artifact tree"
  find "$summary_dir" -maxdepth 2 -type f | sort > "$output_dir/tree.txt" || true
  {
    echo "# RP scRNA run"
    echo
    echo "- date: $(date -Iseconds)"
    echo "- data_root: $data_root"
    echo "- manifest: $manifest_path"
    echo "- candidate_table: $candidate_table"
    echo "- main_log: $main_log"
    echo
    echo "## Download status"
    echo
    if [[ -f "$status_file" ]]; then
      sed -n '1,80p' "$status_file"
    fi
    echo
    echo "## Degrade report"
    echo
    if [[ -f "$degrade_file" ]]; then
      cat "$degrade_file"
    fi
  } > "$summary_dir/run_summary.md"
}

download_manifest
build_checks_and_ranking
write_tree
set_phase "done" "RP scRNA prioritization finished"
echo "RP scRNA prioritization artifacts prepared in $summary_dir"
