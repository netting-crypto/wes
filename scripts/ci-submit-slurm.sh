#!/usr/bin/env bash
set -euo pipefail

project_dir="${CI_PROJECT_DIR:-$(pwd)}"
output_dir="${OUTPUT_DIR:-$project_dir/output/wes}"
wes_mode="${WES_MODE:-smoke}"
slurm_log_dir="${SLURM_LOG_DIR:-$output_dir/slurm}"
result_subdir="${WES_RESULTS_SUBDIR:-results}"
logs_subdir="${WES_LOGS_SUBDIR:-logs}"
result_dir="$output_dir/$result_subdir"
wes_logs_dir="$output_dir/$logs_subdir"
slurm_job_name="${SLURM_JOB_NAME:-wes-pipeline}"
slurm_partition="${SLURM_PARTITION:-}"
slurm_account="${SLURM_ACCOUNT:-}"
slurm_qos="${SLURM_QOS:-}"
slurm_time="${SLURM_TIME:-}"
slurm_nodes="${SLURM_NODES:-1}"
slurm_ntasks="${SLURM_NTASKS:-1}"
slurm_cpus="${SLURM_CPUS_PER_TASK:-16}"
slurm_mem="${SLURM_MEM:-64G}"
slurm_extra_args="${SLURM_EXTRA_ARGS:-}"
slurm_poll_interval="${SLURM_POLL_INTERVAL_SECONDS:-60}"

mkdir -p "$slurm_log_dir" "$result_dir" "$wes_logs_dir"
debug_log="$slurm_log_dir/submit.log"

if [[ "$wes_mode" == "preprocess-batch" ]]; then
  bash "$project_dir/scripts/wes-submit-preprocess-array.sh"
  exit 0
fi

if [[ "$wes_mode" == "qc-report" ]]; then
  qc_out_dir="${WES_QC_OUT_DIR:-${WES_STAGE_OUT_DIR:-$result_dir}}"
  qc_report_dir="${WES_QC_REPORT_DIR:-$result_dir/qc-report}"
  qc_sample_sheet="${WES_QC_SAMPLE_SHEET:-${WES_SAMPLE_SHEET:-}}"
  qc_args=(--out-dir "$qc_out_dir" --report-dir "$qc_report_dir")
  node_bin="${NODE_BIN:-}"
  if [[ -z "$node_bin" ]]; then
    if command -v node >/dev/null 2>&1; then
      node_bin="$(command -v node)"
    elif command -v nodejs >/dev/null 2>&1; then
      node_bin="$(command -v nodejs)"
    else
      echo "Neither node nor nodejs is available on PATH" >&2
      echo "PATH=$PATH" >&2
      exit 127
    fi
  fi
  if [[ -n "$qc_sample_sheet" ]]; then
    qc_args+=(--sample-sheet "$qc_sample_sheet")
  fi
  if [[ "${WES_QC_ONLY_COMPLETED:-0}" == "1" ]]; then
    qc_args+=(--only-completed)
  fi
  echo "Generating WES QC report"
  echo "$node_bin $project_dir/scripts/wes-qc-report.js ${qc_args[*]}"
  "$node_bin" "$project_dir/scripts/wes-qc-report.js" "${qc_args[@]}"
  exit 0
fi

# Clear inherited sbatch defaults so CI submission is driven only by explicit SLURM_* variables.
unset SBATCH_ACCOUNT SBATCH_QOS SBATCH_PARTITION SBATCH_TIME SBATCH_MEM_PER_CPU SBATCH_MEM_PER_NODE SBATCH_MEM_PER_GPU SBATCH_GPUS SBATCH_NODES SBATCH_NTASKS SBATCH_CPUS_PER_TASK

submit_cmd=(
  sbatch
  --parsable
  --export=ALL
  --chdir "$project_dir"
  --job-name "$slurm_job_name"
  --nodes "$slurm_nodes"
  --ntasks "$slurm_ntasks"
  --cpus-per-task "$slurm_cpus"
  --mem "$slurm_mem"
  --output "$slurm_log_dir/slurm-%j.out"
  --error "$slurm_log_dir/slurm-%j.err"
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

submit_cmd+=("$project_dir/scripts/slurm-job.sh")

echo "Submitting Slurm job from $project_dir"
echo "SBATCH command: ${submit_cmd[*]}"
{
  echo "Submitting WES Slurm job from $project_dir"
  echo "SBATCH command: ${submit_cmd[*]}"
  echo "--- type -a sbatch ---"
  type -a sbatch || true
  echo "--- Relevant environment variables ---"
  env | sort | grep -E '^(SBATCH|SLURM|WES|OUTPUT_DIR|PATH)=' || true
} > "$debug_log"

query_job_state() {
  local id="$1"
  local state=""
  local exit_code=""

  if command -v sacct >/dev/null 2>&1; then
    local sacct_line=""
    sacct_line="$(sacct -P -n -j "$id" -o JobIDRaw,State,ExitCode 2>/dev/null | awk -F'|' -v job_id="$id" '$1 == job_id { print; exit }')"
    if [[ -n "$sacct_line" ]]; then
      IFS='|' read -r _ state exit_code <<< "$sacct_line"
      printf '%s|%s\n' "$state" "$exit_code"
      return 0
    fi
  fi

  if command -v squeue >/dev/null 2>&1; then
    state="$(squeue -h -j "$id" -o '%T' 2>/dev/null | head -n 1 | tr -d '[:space:]')"
    if [[ -n "$state" ]]; then
      printf '%s|\n' "$state"
      return 0
    fi
  fi

  printf 'UNKNOWN|\n'
}

emit_new_log_lines() {
  local label="$1"
  local path="$2"
  local last_line="$3"
  local result_var="$4"
  local line_count=0

  if [[ -f "$path" ]]; then
    line_count="$(wc -l < "$path" | tr -d '[:space:]')"
    if [[ -z "$line_count" ]]; then
      line_count=0
    fi
    if (( line_count > last_line )); then
      local start_line=$((last_line + 1))
      echo "--- ${label} (lines $((last_line + 1))-$line_count) ---"
      sed -n "${start_line},${line_count}p" "$path"
    fi
  fi

  printf -v "$result_var" '%s' "$line_count"
}

set +e
submit_output="$("${submit_cmd[@]}" 2>&1)"
submit_status=$?
set -e

printf '%s\n' "$submit_output" >> "$debug_log"

if [[ -n "$submit_output" ]]; then
  printf '%s\n' "$submit_output"
fi

job_id="$(printf '%s\n' "$submit_output" | sed -n '1s/^\([0-9][0-9]*\).*/\1/p')"
if [[ -n "$job_id" ]]; then
  printf '%s\n' "$job_id" > "$slurm_log_dir/job-id.txt"
  echo "Slurm job id: $job_id"
else
  echo "Could not parse a Slurm job id from sbatch output" >&2
  submit_status=1
fi

stdout_log=""
stderr_log=""
if [[ -n "$job_id" ]]; then
  stdout_log="$slurm_log_dir/slurm-${job_id}.out"
  stderr_log="$slurm_log_dir/slurm-${job_id}.err"
fi

if [[ $submit_status -ne 0 ]]; then
  echo "Slurm job failed with exit status $submit_status"
  if [[ -n "$stdout_log" && -f "$stdout_log" ]]; then
    echo "--- Slurm stdout (tail) ---"
    tail -n 200 "$stdout_log"
  fi
  if [[ -n "$stderr_log" && -f "$stderr_log" ]]; then
    echo "--- Slurm stderr (tail) ---"
    tail -n 200 "$stderr_log"
  fi
  exit "$submit_status"
fi

last_stdout_line=0
last_stderr_line=0
last_state=""
slurm_final_state="UNKNOWN"
slurm_final_exit=""

if [[ -n "$job_id" ]]; then
  echo "Polling Slurm job every ${slurm_poll_interval}s"
  while :; do
    state_record="$(query_job_state "$job_id")"
    IFS='|' read -r slurm_state slurm_exit_code <<< "$state_record"
    if [[ -z "$slurm_state" ]]; then
      slurm_state="UNKNOWN"
    fi

    if [[ "$slurm_state" != "$last_state" ]]; then
      echo "Slurm state: $slurm_state"
      last_state="$slurm_state"
    fi

    emit_new_log_lines "Slurm stdout" "$stdout_log" "$last_stdout_line" last_stdout_line
    emit_new_log_lines "Slurm stderr" "$stderr_log" "$last_stderr_line" last_stderr_line

    case "$slurm_state" in
      COMPLETED|FAILED|CANCELLED|TIMEOUT|OUT_OF_MEMORY|NODE_FAIL|PREEMPTED|BOOT_FAIL|DEADLINE|REVOKED)
        slurm_final_state="$slurm_state"
        slurm_final_exit="$slurm_exit_code"
        break
        ;;
    esac

    sleep "$slurm_poll_interval"
  done
fi

if [[ -n "$job_id" ]]; then
  echo "Slurm final state: $slurm_final_state"
  echo "Slurm exit code: ${slurm_final_exit:-UNKNOWN}"
  case "$slurm_final_state" in
    COMPLETED)
      ;;
    *)
      echo "Slurm job did not complete successfully: state=$slurm_final_state exit_code=${slurm_final_exit:-UNKNOWN}" >&2
      if [[ -n "$stdout_log" && -f "$stdout_log" ]]; then
        echo "--- Slurm stdout (tail) ---"
        tail -n 200 "$stdout_log"
      fi
      if [[ -n "$stderr_log" && -f "$stderr_log" ]]; then
        echo "--- Slurm stderr (tail) ---"
        tail -n 200 "$stderr_log"
      fi
      exit 1
      ;;
  esac
fi

manifest="$output_dir/result-manifest.txt"
{
  echo "job_id=$job_id"
  echo "slurm_stdout=$stdout_log"
  echo "slurm_stderr=$stderr_log"
  echo "submit_log=$debug_log"
  echo "results_dir=$result_dir"
  echo "wes_logs_dir=$wes_logs_dir"
  echo "wes_mode=${WES_MODE:-smoke}"
} > "$manifest"

if command -v find >/dev/null 2>&1; then
  find "$output_dir" -maxdepth 3 -type f | sort > "$output_dir/tree.txt" || true
fi

echo "WES artifacts prepared in $output_dir"
