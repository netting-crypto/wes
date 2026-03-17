#!/usr/bin/env bash
set -euo pipefail

project_dir="${CI_PROJECT_DIR:-$(pwd)}"
output_dir="${OUTPUT_DIR:-$project_dir/output/wes}"
slurm_log_dir="${SLURM_LOG_DIR:-$output_dir/slurm}"
logs_subdir="${WES_LOGS_SUBDIR:-logs}"
wes_logs_dir="$output_dir/$logs_subdir"

fastq_dir="${WES_FASTQ_DIR:?WES_FASTQ_DIR is required}"
sample_sheet="${WES_SAMPLE_SHEET:-$project_dir/config/wes/samples.generated.tsv}"
generate_sample_sheet="${WES_GENERATE_SAMPLE_SHEET_FROM_FASTQ:-1}"
batch_out_dir="${WES_STAGE_OUT_DIR:-$output_dir/results/preprocess-batch}"
batch_max_concurrent="${WES_BATCH_MAX_CONCURRENT:-12}"
slurm_poll_interval="${SLURM_POLL_INTERVAL_SECONDS:-60}"

slurm_job_name="${SLURM_JOB_NAME:-wes-preprocess}"
slurm_partition="${SLURM_PARTITION:-}"
slurm_account="${SLURM_ACCOUNT:-}"
slurm_qos="${SLURM_QOS:-}"
slurm_time="${SLURM_TIME:-48:00:00}"
slurm_nodes="${SLURM_NODES:-1}"
slurm_ntasks="${SLURM_NTASKS:-1}"
slurm_cpus="${SLURM_CPUS_PER_TASK:-8}"
slurm_mem="${SLURM_MEM:-32G}"
slurm_extra_args="${SLURM_EXTRA_ARGS:-}"

mkdir -p "$slurm_log_dir" "$wes_logs_dir" "$batch_out_dir"
debug_log="$slurm_log_dir/preprocess-array-submit.log"
manifest="$output_dir/result-manifest.txt"
failure_summary="$output_dir/failed-task-summary.txt"

write_manifest() {
  local final_state="${1:-UNKNOWN}"
  local final_exit_code="${2:-UNKNOWN}"
  local current_job_id="${3:-}"

  {
    echo "job_id=${current_job_id:-unknown}"
    echo "sample_sheet=$sample_sheet"
    echo "sample_count=$sample_count"
    echo "array_spec=$array_spec"
    echo "batch_out_dir=$batch_out_dir"
    echo "submit_log=$debug_log"
    echo "failure_summary=$failure_summary"
    echo "wes_mode=preprocess-batch"
    echo "final_state=$final_state"
    echo "final_exit_code=$final_exit_code"
  } > "$manifest"
}

collect_failed_task_details() {
  local current_job_id="$1"
  local final_state="$2"
  local final_exit_code="$3"
  local summary="${4:-}"
  local records=""

  {
    echo "WES preprocess array failure summary"
    echo "date=$(date -Iseconds)"
    echo "job_id=$current_job_id"
    echo "sample_sheet=$sample_sheet"
    echo "sample_count=$sample_count"
    echo "array_spec=$array_spec"
    echo "final_state=$final_state"
    echo "final_exit_code=$final_exit_code"
    if [[ -n "$summary" ]]; then
      echo "slurm_summary=$summary"
    fi
    echo
  } > "$failure_summary"

  if command -v sacct >/dev/null 2>&1; then
    records="$(sacct -n -X -j "$current_job_id" -o JobIDRaw,State,ExitCode 2>/dev/null | awk '
      NF >= 3 && $1 ~ /_/ {
        if ($2 ~ /^(FAILED|CANCELLED|TIMEOUT|OUT_OF_MEMORY|NODE_FAIL|PREEMPTED|BOOT_FAIL|DEADLINE|REVOKED)$/) {
          print $1 "|" $2 "|" $3
        }
      }')"
  fi

  if [[ -z "$records" ]]; then
    {
      echo "No failed task records were returned by sacct."
      echo "Check Slurm logs under: $slurm_log_dir"
      echo "Check task logs under: $wes_logs_dir"
    } >> "$failure_summary"
    cat "$failure_summary"
    return
  fi

  {
    echo "Failed tasks:"
    printf '%s\n' "$records"
    echo
  } >> "$failure_summary"

  while IFS='|' read -r raw_task_id task_state task_exit_code; do
    [[ -z "$raw_task_id" ]] && continue

    task_id="${raw_task_id#${current_job_id}_}"
    sample_id="$(awk -F'\t' -v target="$task_id" 'NR == 1 { next } ++i == target { print $1; exit }' "$sample_sheet")"
    stdout_log="$slurm_log_dir/preprocess-${current_job_id}_${task_id}.out"
    stderr_log="$slurm_log_dir/preprocess-${current_job_id}_${task_id}.err"
    task_log="$wes_logs_dir/preprocess-array-task-${current_job_id}_${task_id}.log"

    {
      echo "=== task $task_id sample=${sample_id:-unknown} state=$task_state exit_code=$task_exit_code ==="
      for path_label in "task log|$task_log" "stderr|$stderr_log" "stdout|$stdout_log"; do
        IFS='|' read -r label path <<< "$path_label"
        echo "--- $label: $path ---"
        if [[ -f "$path" ]]; then
          tail -n 80 "$path"
        else
          echo "missing"
        fi
        echo
      done
    } >> "$failure_summary"
  done <<< "$records"

  cat "$failure_summary"
}

if [[ "$generate_sample_sheet" == "1" ]]; then
  bash "$project_dir/scripts/generate-wes-sample-sheet.sh" \
    --fastq-dir "$fastq_dir" \
    --out "$sample_sheet"
fi

sample_count="$(awk 'NR > 1 && $1 != "" { count++ } END { print count + 0 }' "$sample_sheet")"
if [[ "$sample_count" -eq 0 ]]; then
  echo "No samples found in sample sheet: $sample_sheet" >&2
  write_manifest "FAILED" "2" ""
  exit 2
fi

array_spec="1-${sample_count}%${batch_max_concurrent}"

submit_cmd=(
  sbatch
  --parsable
  --export=ALL
  --chdir "$project_dir"
  --job-name "$slurm_job_name"
  --array "$array_spec"
  --nodes "$slurm_nodes"
  --ntasks "$slurm_ntasks"
  --cpus-per-task "$slurm_cpus"
  --mem "$slurm_mem"
  --output "$slurm_log_dir/preprocess-%A_%a.out"
  --error "$slurm_log_dir/preprocess-%A_%a.err"
)

if [[ -n "$slurm_time" ]]; then
  submit_cmd+=(--time "$slurm_time")
fi
if [[ -n "$slurm_partition" ]]; then
  submit_cmd+=(--partition "$slurm_partition")
fi
if [[ -n "$slurm_account" ]]; then
  submit_cmd+=(--account "$slurm_account")
fi
if [[ -n "$slurm_qos" ]]; then
  submit_cmd+=(--qos "$slurm_qos")
fi
if [[ -n "$slurm_extra_args" ]]; then
  extra_parts=()
  read -r -a extra_parts <<< "$slurm_extra_args"
  submit_cmd+=("${extra_parts[@]}")
fi

submit_cmd+=("$project_dir/scripts/wes-preprocess-array-task.sh")

{
  echo "Submitting WES preprocess array"
  echo "sample_sheet=$sample_sheet"
  echo "sample_count=$sample_count"
  echo "array_spec=$array_spec"
  echo "batch_out_dir=$batch_out_dir"
  echo "SBATCH command: ${submit_cmd[*]}"
} > "$debug_log"

echo "Submitting WES preprocess array"
echo "sample_sheet=$sample_sheet"
echo "sample_count=$sample_count"
echo "array_spec=$array_spec"
echo "SBATCH command: ${submit_cmd[*]}"

set +e
submit_output="$(${submit_cmd[@]} 2>&1)"
submit_status=$?
set -e
printf '%s\n' "$submit_output" >> "$debug_log"
if [[ -n "$submit_output" ]]; then
  printf '%s\n' "$submit_output"
fi
if [[ $submit_status -ne 0 ]]; then
  echo "Slurm array submission failed with exit status $submit_status" >&2
  write_manifest "SUBMIT_FAILED" "$submit_status" ""
  {
    echo "WES preprocess array submission failed"
    echo "date=$(date -Iseconds)"
    echo "sample_sheet=$sample_sheet"
    echo "sample_count=$sample_count"
    echo "array_spec=$array_spec"
    echo "submit_status=$submit_status"
    echo
    printf '%s\n' "$submit_output"
  } > "$failure_summary"
  exit "$submit_status"
fi

job_id="$(printf '%s\n' "$submit_output" | sed -n '1s/^\([0-9][0-9]*\).*/\1/p')"
if [[ -z "$job_id" ]]; then
  echo "Could not parse a Slurm array job id from sbatch output" >&2
  write_manifest "SUBMIT_FAILED" "1" ""
  {
    echo "Could not parse a Slurm array job id from sbatch output"
    echo "date=$(date -Iseconds)"
    echo "sample_sheet=$sample_sheet"
    echo
    printf '%s\n' "$submit_output"
  } > "$failure_summary"
  exit 1
fi

echo "Slurm array job id: $job_id"
printf '%s\n' "$job_id" > "$slurm_log_dir/job-id.txt"

last_summary=""
while :; do
  if command -v sacct >/dev/null 2>&1; then
    summary="$(sacct -n -X -j "$job_id" -o State 2>/dev/null | awk '
      NF {
        state=$1
        counts[state]++
        total++
      }
      END {
        for (s in counts) {
          printf "%s=%d ", s, counts[s]
        }
        printf "TOTAL=%d", total
      }')"
    if [[ -n "$summary" && "$summary" != "$last_summary" ]]; then
      echo "Slurm array summary: $summary"
      last_summary="$summary"
    fi

    root_state="$(sacct -P -n -j "$job_id" -o JobIDRaw,State,ExitCode 2>/dev/null | awk -F'|' -v root="$job_id" '$1 == root { print $2 "|" $3; exit }')"
    if [[ -n "$root_state" ]]; then
      IFS='|' read -r state exit_code <<< "$root_state"
      case "$state" in
        COMPLETED)
          echo "Slurm array final state: $state"
          echo "Slurm array exit code: $exit_code"
          write_manifest "$state" "$exit_code" "$job_id"
          break
          ;;
        FAILED|CANCELLED|TIMEOUT|OUT_OF_MEMORY|NODE_FAIL|PREEMPTED|BOOT_FAIL|DEADLINE|REVOKED)
          echo "Slurm array final state: $state"
          echo "Slurm array exit code: $exit_code"
          write_manifest "$state" "$exit_code" "$job_id"
          collect_failed_task_details "$job_id" "$state" "$exit_code" "$last_summary"
          exit 1
          ;;
      esac
    fi
  fi
  sleep "$slurm_poll_interval"
done

echo "WES preprocess array finished successfully."
echo "Manifest: $manifest"
