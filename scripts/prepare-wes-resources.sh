#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/prepare-wes-resources.sh \
    --base-dir /path/to/resources/hg38 \
    [--threads 8] \
    [--ref-url URL] \
    [--dbsnp-url URL] \
    [--known-indels-url URL] \
    [--mills-url URL] \
    [--bed-url URL] \
    [--gencode-gtf-url URL] \
    [--bed-padding-bp 50] \
    [--vep-cache-url URL] \
    [--skip-download] \
    [--allow-missing-known-sites] \
    [--skip-vep]

What this script does:
  - Creates a clean hg38 resource directory layout
  - Optionally downloads reference / known-sites / BED / VEP cache
  - Builds .fai and .dict for the reference if missing
  - Builds BWA index files for the reference if missing
  - Builds .tbi index files for gzipped VCF resources if missing

Recommended use:
  1. Start with --skip-download if you think the server already has resources
  2. Fill URLs only for the files that are actually missing
EOF
}

BASE_DIR=""
THREADS=1
REF_URL=""
DBSNP_URL=""
KNOWN_INDELS_URL=""
MILLS_URL=""
BED_URL=""
GENCODE_GTF_URL=""
BED_PADDING_BP=50
VEP_CACHE_URL=""
SKIP_DOWNLOAD=0
SKIP_VEP=0
ALLOW_MISSING_KNOWN_SITES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-dir) BASE_DIR="$2"; shift 2 ;;
    --threads) THREADS="$2"; shift 2 ;;
    --ref-url) REF_URL="$2"; shift 2 ;;
    --dbsnp-url) DBSNP_URL="$2"; shift 2 ;;
    --known-indels-url) KNOWN_INDELS_URL="$2"; shift 2 ;;
    --mills-url) MILLS_URL="$2"; shift 2 ;;
    --bed-url) BED_URL="$2"; shift 2 ;;
    --gencode-gtf-url) GENCODE_GTF_URL="$2"; shift 2 ;;
    --bed-padding-bp) BED_PADDING_BP="$2"; shift 2 ;;
    --vep-cache-url) VEP_CACHE_URL="$2"; shift 2 ;;
    --skip-download) SKIP_DOWNLOAD=1; shift ;;
    --allow-missing-known-sites) ALLOW_MISSING_KNOWN_SITES=1; shift ;;
    --skip-vep) SKIP_VEP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$BASE_DIR" ]]; then
  usage
  exit 2
fi

need_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Missing command: $cmd" >&2
    exit 2
  }
}

download_to() {
  local url="$1"
  local out="$2"
  local required="${3:-1}"
  if [[ -z "$url" ]]; then
    echo "Skip download for $out because URL is empty"
    return 0
  fi
  if [[ -f "$out" ]]; then
    echo "Already exists: $out"
    return 0
  fi
  echo "Downloading: $url"
  if [[ "$url" == *.gz && "$out" != *.gz ]]; then
    tmp_out="${out}.download.gz"
    rm -f "$tmp_out"
    if curl -L --fail --retry 3 -o "$tmp_out" "$url"; then
      gzip -dc "$tmp_out" > "$out"
      rm -f "$tmp_out"
      return 0
    fi
    rm -f "$tmp_out"
  elif curl -L --fail --retry 3 -o "$out" "$url"; then
    return 0
  fi

  if [[ "$required" == "1" ]]; then
    echo "Required download failed: $url" >&2
    return 1
  fi
  echo "Optional download failed and will be skipped: $url"
  return 0
}

index_vcf_if_needed() {
  local vcf="$1"
  if [[ ! -f "$vcf" ]]; then
    echo "Skip indexing missing VCF: $vcf"
    return 0
  fi
  if [[ -f "${vcf}.tbi" || -f "${vcf}.idx" ]]; then
    echo "Index already present for: $vcf"
    return 0
  fi
  echo "Indexing VCF: $vcf"
  if [[ "$vcf" == *.vcf.gz ]]; then
    tabix -f -p vcf "$vcf"
  else
    gatk IndexFeatureFile -I "$vcf"
  fi
}

build_bed_from_gencode() {
  local gtf_gz="$1"
  local out_bed="$2"
  local padding_bp="$3"
  local tmp_bed
  local sorted_bed

  tmp_bed="$(mktemp)"
  sorted_bed="$(mktemp)"

  echo "Generating BED from GENCODE GTF: $gtf_gz"
  gzip -dc "$gtf_gz" \
    | awk -F'\t' -v pad="$padding_bp" '
      BEGIN { OFS="\t" }
      $0 ~ /^#/ { next }
      $3 != "exon" { next }
      {
        attrs = $9
        is_protein_coding = 0
        if (attrs ~ /gene_type "protein_coding"/ || attrs ~ /gene_biotype "protein_coding"/ || attrs ~ /transcript_type "protein_coding"/ || attrs ~ /transcript_biotype "protein_coding"/) {
          is_protein_coding = 1
        }
        if (!is_protein_coding) {
          next
        }
        start = $4 - 1 - pad
        if (start < 0) {
          start = 0
        }
        end = $5 + pad
        print $1, start, end
      }
    ' > "$tmp_bed"

  sort -k1,1 -k2,2n -k3,3n "$tmp_bed" > "$sorted_bed"
  awk '
    BEGIN { OFS="\t" }
    NR == 1 {
      chr = $1
      start = $2
      end = $3
      next
    }
    {
      if ($1 == chr && $2 <= end) {
        if ($3 > end) {
          end = $3
        }
      } else {
        print chr, start, end
        chr = $1
        start = $2
        end = $3
      }
    }
    END {
      if (NR > 0) {
        print chr, start, end
      }
    }
  ' "$sorted_bed" > "$out_bed"

  rm -f "$tmp_bed" "$sorted_bed"
}

need_cmd bash
need_cmd mkdir
need_cmd curl
need_cmd gzip
need_cmd samtools
need_cmd gatk
need_cmd tabix
need_cmd bwa

mkdir -p "$BASE_DIR"/{reference,known-sites,targets,vep,logs}

REF_FA="$BASE_DIR/reference/Homo_sapiens_assembly38.fasta"
DBSNP_VCF="$BASE_DIR/known-sites/Homo_sapiens_assembly38.dbsnp138.vcf"
KNOWN_INDELS_VCF="$BASE_DIR/known-sites/Homo_sapiens_assembly38.known_indels.vcf.gz"
MILLS_VCF="$BASE_DIR/known-sites/Mills_and_1000G_gold_standard.indels.hg38.vcf.gz"
TARGET_BED="$BASE_DIR/targets/exome_targets.bed"
GENCODE_GTF_GZ="$BASE_DIR/targets/gencode.basic.annotation.gtf.gz"
VEP_ARCHIVE="$BASE_DIR/vep/homo_sapiens_vep_cache.tar.gz"

log_file="$BASE_DIR/logs/prepare-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$log_file") 2>&1

echo "Preparing WES resources under: $BASE_DIR"
echo "threads=$THREADS"

if [[ "$SKIP_DOWNLOAD" -eq 0 ]]; then
  download_to "$REF_URL" "$REF_FA" 1
  optional_known_sites_required=1
  if [[ "$ALLOW_MISSING_KNOWN_SITES" -eq 1 ]]; then
    optional_known_sites_required=0
  fi
  download_to "$DBSNP_URL" "$DBSNP_VCF" "$optional_known_sites_required"
  download_to "$KNOWN_INDELS_URL" "$KNOWN_INDELS_VCF" "$optional_known_sites_required"
  download_to "$MILLS_URL" "$MILLS_VCF" "$optional_known_sites_required"
  download_to "$BED_URL" "$TARGET_BED"
  if [[ ! -f "$TARGET_BED" && -n "$GENCODE_GTF_URL" ]]; then
    download_to "$GENCODE_GTF_URL" "$GENCODE_GTF_GZ" 1
  fi
  if [[ "$SKIP_VEP" -eq 0 ]]; then
    download_to "$VEP_CACHE_URL" "$VEP_ARCHIVE"
  fi
fi

if [[ ! -f "$TARGET_BED" && -f "$GENCODE_GTF_GZ" ]]; then
  build_bed_from_gencode "$GENCODE_GTF_GZ" "$TARGET_BED" "$BED_PADDING_BP"
fi

if [[ -f "$REF_FA" ]]; then
  if [[ ! -f "${REF_FA}.fai" ]]; then
    echo "Building FASTA index"
    samtools faidx "$REF_FA"
  fi

  ref_dict="${REF_FA%.*}.dict"
  if [[ ! -f "$ref_dict" ]]; then
    echo "Building sequence dictionary"
    gatk CreateSequenceDictionary -R "$REF_FA" -O "$ref_dict"
  fi

  if [[ ! -f "${REF_FA}.bwt" || ! -f "${REF_FA}.sa" || ! -f "${REF_FA}.ann" || ! -f "${REF_FA}.amb" || ! -f "${REF_FA}.pac" ]]; then
    echo "Building BWA index"
    bwa index "$REF_FA"
  fi
fi

index_vcf_if_needed "$DBSNP_VCF"
index_vcf_if_needed "$KNOWN_INDELS_VCF"
index_vcf_if_needed "$MILLS_VCF"

if [[ -f "$VEP_ARCHIVE" && "$SKIP_VEP" -eq 0 ]]; then
  vep_dir="$BASE_DIR/vep/cache"
  mkdir -p "$vep_dir"
  if [[ -z "$(find "$vep_dir" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
    echo "Extracting VEP cache archive"
    tar -xzf "$VEP_ARCHIVE" -C "$vep_dir"
  else
    echo "VEP cache directory already has content: $vep_dir"
  fi
fi

manifest="$BASE_DIR/resources.manifest.txt"
{
  echo "date=$(date -Iseconds)"
  echo "base_dir=$BASE_DIR"
  echo "ref=$REF_FA"
  echo "bwa_index_prefix=$REF_FA"
  echo "bed=$TARGET_BED"
  echo "dbsnp=$DBSNP_VCF"
  echo "known_indels=$KNOWN_INDELS_VCF"
  echo "mills=$MILLS_VCF"
  echo "vep_archive=$VEP_ARCHIVE"
  echo "log=$log_file"
} > "$manifest"

echo "Resource preparation finished."
echo "Manifest: $manifest"
