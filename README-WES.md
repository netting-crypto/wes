# WES First-Pass Pipeline

This directory contains a practical first-pass germline WES pipeline for small family cohorts.

## What this is for

- Disease + parents or partial-parent families
- Peripheral blood germline WES
- First smoke test on a Slurm cluster
- Producing aligned BAMs, per-sample gVCFs, and a small joint-called family VCF

## What this is not

- Not a finished clinical interpretation workflow
- Not tuned for very large cohorts
- Not a replacement for downstream family segregation review

## Recommended first run

The GitLab / Slurm default is now a smoke test, not the full WES pipeline.
That smoke test checks:

- whether the compute node has outbound network
- whether common bioinformatics commands are already present
- whether the output directory is writable
- whether one chosen FASTQ pair is visible from the compute node
- whether `conda` can install the missing tools on the compute node
- whether the configured reference / BED / known-sites paths exist

1. Copy `config/wes/run.env.example` to `config/wes/run.env`
2. Copy `config/wes/samples.example.tsv` to `config/wes/samples.tsv`
3. Replace the placeholder sample IDs and file paths
4. The current GitLab / Slurm default first runs `WES_MODE=prepare-resources`.
   That job prepares a clean `hg38` reference plus Broad-style known-sites files
   on the compute node under `WES_RESOURCE_BASE`.
5. On the server run if you want to inspect manually:

```bash
bash scripts/wes-check-server.sh config/wes/run.env
```

If hg38 / known-sites / BED are not ready yet:

```bash
cp config/wes/resources.env.example config/wes/resources.env
# edit the paths or URLs you actually want to use
source config/wes/resources.env
bash scripts/prepare-wes-resources.sh --base-dir "$WES_RESOURCE_BASE" --skip-download
```

6. After the resource-preparation job succeeds, switch back to `WES_MODE=smoke`
   or `WES_MODE=pipeline` and pick one sample for a real smoke-test pipeline run:

```bash
bash pipelines/wes-germline.sh \
  --sample-sheet config/wes/samples.tsv \
  --out output/wes/results/smoke-test \
  --ref /path/to/Homo_sapiens_assembly38.fasta \
  --bed /path/to/exome_targets.bed \
  --known-sites /path/to/Homo_sapiens_assembly38.dbsnp138.vcf \
  --known-sites /path/to/Homo_sapiens_assembly38.known_indels.vcf.gz \
  --known-sites /path/to/Mills_and_1000G_gold_standard.indels.hg38.vcf.gz \
  --sample AMD001 \
  --threads 16 \
  --skip-fastqc
```

If the reference is ready but Broad-style known-sites files are still being
collected, do the first real run with `--skip-bqsr`. The example
`config/wes/run.env.example` now sets `WES_PIPELINE_EXTRA_ARGS="--skip-bqsr"`
for that first pass.

7. After that, run one family with `--family-id FAM001`

## Stage split

The main pipeline now supports staged execution with `--stage`:

- `all`: full end-to-end run
- `preprocess`: stop after per-sample BAM generation (`fastp -> bwa mem -> sort -> MarkDuplicates -> optional BQSR`)
- `gvcf`: use existing BAMs and run per-sample `HaplotypeCaller`
- `joint`: use existing per-sample gVCFs and run joint calling plus filtering

If `--stage gvcf` or `--stage joint` is used, the script first looks for staged
files under the current `--out` directory before failing.

Example: batch pre-processing only

```bash
bash scripts/generate-wes-sample-sheet.sh \
  --fastq-dir /path/to/fastq \
  --out config/wes/samples.generated.tsv

bash pipelines/wes-germline.sh \
  --sample-sheet config/wes/samples.generated.tsv \
  --out output/wes/results/preprocess-only \
  --ref /path/to/Homo_sapiens_assembly38.fasta \
  --bed /path/to/exome_targets.bed \
  --threads 24 \
  --skip-bqsr \
  --stage preprocess
```

## Smoke-test outputs

The smoke-test job writes:

- `output/wes/logs/smoke-test.log`
- `output/wes/logs/conda-create.stdout.log`
- `output/wes/logs/conda-create.stderr.log`
- `output/wes/smoke-summary.txt`
- `output/wes/tree.txt`
- Slurm stdout / stderr under `output/wes/slurm/`

The temporary conda environment is intentionally created outside `output/wes/`
and removed at the end, so GitLab artifacts stay small enough to upload.

## Resource-preparation outputs

The resource-preparation job writes:

- `output/wes/prepare-resources-summary.txt`
- `output/wes/logs/prepare-resources.log`
- `output/wes/logs/resource-conda.stdout.log`
- `output/wes/logs/resource-conda.stderr.log`
- Slurm stdout / stderr under `output/wes/slurm/`

## Family structures supported

- proband + father + mother
- proband + father only
- proband + mother only
- proband only

The sample sheet leaves missing family members out; no fake rows are needed.

## Suggested reference build

Use `hg38 / GRCh38` unless you already have a legacy `hg19` ecosystem you must stay with.

## Minimum resource set

- Reference FASTA for hg38 / GRCh38
- FASTA index `.fai`
- FASTA sequence dictionary `.dict`
- Exome target BED matching your capture kit
- One or more known-sites VCFs for first-pass BQSR
- Optional VEP cache for annotation

For first smoke tests, if known-sites are not ready, you can temporarily add `--skip-bqsr`.
When they are ready, pass all available Broad-style known-sites files with repeated
`--known-sites` arguments.

## Reference and best-practice notes

- GATK preprocessing:
  https://gatk.broadinstitute.org/hc/en-us/articles/360035535912-Data-pre-processing-for-variant-discovery
- GATK joint calling:
  https://gatk.broadinstitute.org/hc/en-us/articles/360035890431-The-logic-of-joint-calling-for-germline-short-variants
- GATK hard filtering:
  https://gatk.broadinstitute.org/hc/en-us/articles/360035890471-Hard-filtering-germline-short-variants
- GATK resource bundle overview:
  https://gatk.broadinstitute.org/hc/en-us/articles/360035889631-Where-can-I-find-known-variants-training-and-truth-sets-and-other-resource-files
- GATK reference build guidance:
  https://gatk.broadinstitute.org/hc/en-us/articles/360035890951-Human-genome-reference-builds-GRCh38-or-hg38-b37-hg19
- Ensembl VEP:
  https://www.ensembl.org/info/docs/tools/vep/
- Ensembl VEP cache:
  https://www.ensembl.org/info/docs/tools/vep/script/vep_cache.html
