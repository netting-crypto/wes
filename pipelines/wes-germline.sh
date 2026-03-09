#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash pipelines/wes-germline.sh \
    --sample-sheet config/wes/samples.tsv \
    --out output/wes/results \
    --ref /path/to/hg38.fa \
    --bed /path/to/targets.bed \
    [--known-sites /path/to/known-sites1.vcf.gz] \
    [--known-sites /path/to/known-sites2.vcf.gz] \
    [--family-id FAM001] \
    [--sample SAMPLE001] \
    [--threads 16] \
    [--tmp-dir /scratch/$USER/wes-tmp] \
    [--vep-cache-dir /path/to/vep-cache] \
    [--skip-fastqc] \
    [--skip-fastp] \
    [--skip-bqsr]

Notes:
  - This is a practical first-pass germline WES pipeline for small family cohorts.
  - It is intended for smoke tests and early analysis, not clinical reporting.
  - Input sample sheet columns:
      sample_id  family_id  role  affected  fastq_r1  fastq_r2  bam_path
EOF
}

SAMPLE_SHEET=""
OUT_DIR=""
REF_FA=""
TARGET_BED=""
declare -a KNOWN_SITES_VCFS=()
FAMILY_ID=""
ONLY_SAMPLE=""
THREADS="${SLURM_CPUS_PER_TASK:-8}"
TMP_DIR="${TMPDIR:-}"
VEP_CACHE_DIR=""
SKIP_FASTQC=0
SKIP_FASTP=0
SKIP_BQSR=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sample-sheet) SAMPLE_SHEET="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --ref) REF_FA="$2"; shift 2 ;;
    --bed) TARGET_BED="$2"; shift 2 ;;
    --known-sites) KNOWN_SITES_VCFS+=("$2"); shift 2 ;;
    --family-id) FAMILY_ID="$2"; shift 2 ;;
    --sample) ONLY_SAMPLE="$2"; shift 2 ;;
    --threads) THREADS="$2"; shift 2 ;;
    --tmp-dir) TMP_DIR="$2"; shift 2 ;;
    --vep-cache-dir) VEP_CACHE_DIR="$2"; shift 2 ;;
    --skip-fastqc) SKIP_FASTQC=1; shift ;;
    --skip-fastp) SKIP_FASTP=1; shift ;;
    --skip-bqsr) SKIP_BQSR=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

require_file() {
  local path="$1"
  [[ -f "$path" ]] || { echo "Missing file: $path" >&2; exit 2; }
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing command: $cmd" >&2; exit 2; }
}

if [[ -z "$SAMPLE_SHEET" || -z "$OUT_DIR" || -z "$REF_FA" || -z "$TARGET_BED" ]]; then
  usage
  exit 2
fi

require_file "$SAMPLE_SHEET"
require_file "$REF_FA"
require_file "$TARGET_BED"
for known_sites_vcf in "${KNOWN_SITES_VCFS[@]}"; do
  require_file "$known_sites_vcf"
done

require_cmd bash
require_cmd samtools
require_cmd gatk
require_cmd tabix
if command -v bwa-mem2 >/dev/null 2>&1; then
  ALIGNER="bwa-mem2"
elif command -v bwa >/dev/null 2>&1; then
  ALIGNER="bwa"
else
  echo "Missing aligner: need bwa-mem2 or bwa" >&2
  exit 2
fi

if [[ "$SKIP_FASTQC" -eq 0 ]]; then
  require_cmd fastqc
fi
if [[ "$SKIP_FASTP" -eq 0 ]]; then
  require_cmd fastp
fi

mkdir -p "$OUT_DIR"/{logs,qc,trimmed,bam,gvcf,joint,tmp}
if [[ -z "$TMP_DIR" ]]; then
  TMP_DIR="$OUT_DIR/tmp"
fi
mkdir -p "$TMP_DIR"

if [[ ! -f "${REF_FA}.fai" ]]; then
  echo "Reference index not found: ${REF_FA}.fai" >&2
  exit 2
fi

if [[ ! -f "${REF_FA%.*}.dict" && ! -f "${REF_FA}.dict" ]]; then
  echo "Reference dict not found near: $REF_FA" >&2
  exit 2
fi

for known_sites_vcf in "${KNOWN_SITES_VCFS[@]}"; do
  if [[ ! -f "${known_sites_vcf}.tbi" && ! -f "${known_sites_vcf}.idx" ]]; then
    echo "Known-sites index not found near: $known_sites_vcf" >&2
    exit 2
  fi
done

run_log="$OUT_DIR/logs/run-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$run_log") 2>&1

echo "Starting WES germline pipeline"
echo "sample_sheet=$SAMPLE_SHEET"
echo "out_dir=$OUT_DIR"
echo "ref=$REF_FA"
echo "bed=$TARGET_BED"
echo "family_id=${FAMILY_ID:-ALL}"
echo "sample=${ONLY_SAMPLE:-ALL}"
echo "aligner=$ALIGNER"
echo "threads=$THREADS"
echo "tmp_dir=$TMP_DIR"
if [[ "${#KNOWN_SITES_VCFS[@]}" -gt 0 ]]; then
  printf 'known_sites=%s\n' "$(IFS=,; echo "${KNOWN_SITES_VCFS[*]}")"
else
  echo "known_sites=NONE"
fi

declare -a SAMPLE_IDS=()
declare -A SAMPLE_FAMILY=()
declare -A SAMPLE_ROLE=()
declare -A SAMPLE_AFFECTED=()
declare -A SAMPLE_R1=()
declare -A SAMPLE_R2=()
declare -A SAMPLE_BAM=()

while IFS=$'\t' read -r sample_id family_id role affected fastq_r1 fastq_r2 bam_path; do
  [[ -n "${sample_id:-}" ]] || continue
  [[ "$sample_id" == "sample_id" ]] && continue

  if [[ -n "$FAMILY_ID" && "$family_id" != "$FAMILY_ID" ]]; then
    continue
  fi
  if [[ -n "$ONLY_SAMPLE" && "$sample_id" != "$ONLY_SAMPLE" ]]; then
    continue
  fi

  SAMPLE_IDS+=("$sample_id")
  SAMPLE_FAMILY["$sample_id"]="$family_id"
  SAMPLE_ROLE["$sample_id"]="$role"
  SAMPLE_AFFECTED["$sample_id"]="$affected"
  SAMPLE_R1["$sample_id"]="$fastq_r1"
  SAMPLE_R2["$sample_id"]="$fastq_r2"
  SAMPLE_BAM["$sample_id"]="$bam_path"
done < "$SAMPLE_SHEET"

if [[ "${#SAMPLE_IDS[@]}" -eq 0 ]]; then
  echo "No samples selected from sample sheet." >&2
  exit 2
fi

declare -a GVCFS=()
known_sites_args=()
for known_sites_vcf in "${KNOWN_SITES_VCFS[@]}"; do
  known_sites_args+=(--known-sites "$known_sites_vcf")
done

for sample_id in "${SAMPLE_IDS[@]}"; do
  echo
  echo "==== Sample: $sample_id ===="
  family_id="${SAMPLE_FAMILY[$sample_id]}"
  role="${SAMPLE_ROLE[$sample_id]}"
  affected="${SAMPLE_AFFECTED[$sample_id]}"
  raw_r1="${SAMPLE_R1[$sample_id]}"
  raw_r2="${SAMPLE_R2[$sample_id]}"
  input_bam="${SAMPLE_BAM[$sample_id]}"

  final_bam=""
  if [[ -n "$input_bam" ]]; then
    require_file "$input_bam"
    final_bam="$input_bam"
    echo "Using existing BAM: $final_bam"
  else
    require_file "$raw_r1"
    require_file "$raw_r2"

    work_r1="$raw_r1"
    work_r2="$raw_r2"

    if [[ "$SKIP_FASTQC" -eq 0 ]]; then
      fastqc --threads "$THREADS" --outdir "$OUT_DIR/qc" "$work_r1" "$work_r2"
    fi

    if [[ "$SKIP_FASTP" -eq 0 ]]; then
      trimmed_r1="$OUT_DIR/trimmed/${sample_id}.R1.fastq.gz"
      trimmed_r2="$OUT_DIR/trimmed/${sample_id}.R2.fastq.gz"
      fastp \
        --thread "$THREADS" \
        --in1 "$work_r1" \
        --in2 "$work_r2" \
        --out1 "$trimmed_r1" \
        --out2 "$trimmed_r2" \
        --json "$OUT_DIR/qc/${sample_id}.fastp.json" \
        --html "$OUT_DIR/qc/${sample_id}.fastp.html"
      work_r1="$trimmed_r1"
      work_r2="$trimmed_r2"
    fi

    sorted_bam="$OUT_DIR/bam/${sample_id}.sorted.bam"
    rg="@RG\tID:${sample_id}\tSM:${sample_id}\tPL:ILLUMINA\tLB:${family_id:-NA}\tPU:${sample_id}"
    "$ALIGNER" mem -t "$THREADS" -R "$rg" "$REF_FA" "$work_r1" "$work_r2" \
      | samtools sort -@ "$THREADS" -o "$sorted_bam" -
    samtools index -@ "$THREADS" "$sorted_bam"

    markdup_bam="$OUT_DIR/bam/${sample_id}.markdup.bam"
    gatk MarkDuplicates \
      -I "$sorted_bam" \
      -O "$markdup_bam" \
      -M "$OUT_DIR/bam/${sample_id}.markdup.metrics.txt" \
      --CREATE_INDEX true \
      --TMP_DIR "$TMP_DIR"

    if [[ "$SKIP_BQSR" -eq 0 && "${#KNOWN_SITES_VCFS[@]}" -gt 0 ]]; then
      recal_table="$OUT_DIR/bam/${sample_id}.recal.table"
      final_bam="$OUT_DIR/bam/${sample_id}.bqsr.bam"
      gatk BaseRecalibrator \
        -R "$REF_FA" \
        -I "$markdup_bam" \
        "${known_sites_args[@]}" \
        -L "$TARGET_BED" \
        -O "$recal_table"
      gatk ApplyBQSR \
        -R "$REF_FA" \
        -I "$markdup_bam" \
        --bqsr-recal-file "$recal_table" \
        -O "$final_bam"
      samtools index -@ "$THREADS" "$final_bam"
    else
      final_bam="$markdup_bam"
    fi
  fi

  sample_gvcf="$OUT_DIR/gvcf/${sample_id}.g.vcf.gz"
  gatk HaplotypeCaller \
    -R "$REF_FA" \
    -I "$final_bam" \
    -L "$TARGET_BED" \
    -ERC GVCF \
    -O "$sample_gvcf"
  gatk IndexFeatureFile -I "$sample_gvcf"
  GVCFS+=("$sample_gvcf")

  cat > "$OUT_DIR/gvcf/${sample_id}.meta.txt" <<EOF
sample_id=$sample_id
family_id=$family_id
role=$role
affected=$affected
bam=$final_bam
gvcf=$sample_gvcf
EOF
done

combined_gvcf="$OUT_DIR/joint/combined.g.vcf.gz"
genotyped_vcf="$OUT_DIR/joint/joint.raw.vcf.gz"
snp_vcf="$OUT_DIR/joint/joint.snp.filtered.vcf.gz"
indel_vcf="$OUT_DIR/joint/joint.indel.filtered.vcf.gz"
merged_vcf="$OUT_DIR/joint/joint.filtered.vcf.gz"

combine_args=()
for gvcf in "${GVCFS[@]}"; do
  combine_args+=(-V "$gvcf")
done

gatk CombineGVCFs \
  -R "$REF_FA" \
  "${combine_args[@]}" \
  -O "$combined_gvcf"

gatk GenotypeGVCFs \
  -R "$REF_FA" \
  -V "$combined_gvcf" \
  -O "$genotyped_vcf"

gatk SelectVariants \
  -R "$REF_FA" \
  -V "$genotyped_vcf" \
  --select-type-to-include SNP \
  -O "$OUT_DIR/joint/joint.snp.raw.vcf.gz"

gatk VariantFiltration \
  -R "$REF_FA" \
  -V "$OUT_DIR/joint/joint.snp.raw.vcf.gz" \
  --filter-name "SNP_QD" --filter-expression "QD < 2.0" \
  --filter-name "SNP_FS" --filter-expression "FS > 60.0" \
  --filter-name "SNP_MQ" --filter-expression "MQ < 40.0" \
  --filter-name "SNP_MQRankSum" --filter-expression "MQRankSum < -12.5" \
  --filter-name "SNP_ReadPosRankSum" --filter-expression "ReadPosRankSum < -8.0" \
  -O "$snp_vcf"

gatk SelectVariants \
  -R "$REF_FA" \
  -V "$genotyped_vcf" \
  --select-type-to-include INDEL \
  -O "$OUT_DIR/joint/joint.indel.raw.vcf.gz"

gatk VariantFiltration \
  -R "$REF_FA" \
  -V "$OUT_DIR/joint/joint.indel.raw.vcf.gz" \
  --filter-name "INDEL_QD" --filter-expression "QD < 2.0" \
  --filter-name "INDEL_FS" --filter-expression "FS > 200.0" \
  --filter-name "INDEL_ReadPosRankSum" --filter-expression "ReadPosRankSum < -20.0" \
  -O "$indel_vcf"

gatk MergeVcfs -I "$snp_vcf" -I "$indel_vcf" -O "$merged_vcf"
tabix -f -p vcf "$merged_vcf"

if command -v vep >/dev/null 2>&1 && [[ -n "$VEP_CACHE_DIR" ]]; then
  vep \
    --cache \
    --dir_cache "$VEP_CACHE_DIR" \
    --assembly GRCh38 \
    --offline \
    --input_file "$merged_vcf" \
    --output_file "$OUT_DIR/joint/joint.filtered.vep.vcf" \
    --vcf \
    --fork "$THREADS"
fi

manifest="$OUT_DIR/run.manifest.txt"
{
  echo "date=$(date -Iseconds)"
  echo "ref=$REF_FA"
  echo "bed=$TARGET_BED"
  if [[ "${#KNOWN_SITES_VCFS[@]}" -gt 0 ]]; then
    printf 'known_sites=%s\n' "$(IFS=,; echo "${KNOWN_SITES_VCFS[*]}")"
  else
    echo "known_sites=NONE"
  fi
  echo "samples=${#SAMPLE_IDS[@]}"
  printf 'sample_ids=%s\n' "$(IFS=,; echo "${SAMPLE_IDS[*]}")"
  echo "joint_vcf=$merged_vcf"
  echo "log=$run_log"
} > "$manifest"

echo "Pipeline finished successfully."
echo "Manifest: $manifest"
