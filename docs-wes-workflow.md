# WES Workflow Notes

## Pipeline stages
1. Resource preparation
- Input: hg38 reference, BED, known-sites path definitions.
- Output: reference sidecars and known-sites resources ready on server.

2. Preprocess
- Input: FASTQ pairs or existing BAM.
- Steps: optional FastQC, optional fastp, alignment, sort, MarkDuplicates, optional BQSR.
- Output:
  - `bam/*.sorted.bam`
  - `bam/*.markdup.bam`
  - `bam/*.markdup.metrics.txt`
  - optional `bam/*.bqsr.bam`
  - `qc/*.fastp.json` and `qc/*.fastp.html`

3. Per-sample gVCF
- Input: staged BAM from preprocess.
- Step: `HaplotypeCaller -ERC GVCF`.
- Output:
  - `gvcf/*.g.vcf.gz`
  - `gvcf/*.g.vcf.gz.tbi` or `.idx`
  - `gvcf/*.meta.txt`

4. Joint calling
- Input: all selected sample gVCFs in the same run.
- Steps: `CombineGVCFs`, `GenotypeGVCFs`, SNP/INDEL split, hard filtering, merge.
- Output:
  - `joint/combined.g.vcf.gz`
  - `joint/joint.raw.vcf.gz`
  - `joint/joint.snp.filtered.vcf.gz`
  - `joint/joint.indel.filtered.vcf.gz`
  - `joint/joint.filtered.vcf.gz`

5. Annotation and interpretation
- Current pipeline only has optional VEP skeleton.
- Population-frequency filtering and disease interpretation belong here, not in preprocess.

## Family metadata
The sample sheet already carries:
- `family_id`
- `role` such as `proband`, `father`, `mother`
- `affected` where `1` is affected and `0` is unaffected

Current usage:
- used as sample metadata and read-group context
- used to subset by family or sample at run time

Not yet implemented:
- trio-aware inheritance filtering
- automatic de novo / recessive / compound-heterozygous prioritization

So yes, this family information is important, but I already know the schema and the pipeline can already carry it through. The missing part is downstream interpretation logic, not metadata storage.

## Common population variants
The current WES pipeline does NOT yet remove common population variants as part of the primary calling steps.

What is already done:
- technical hard filters at the VCF level
- optional annotation skeleton via VEP

What is not yet done:
- gnomAD / ExAC / 1000G frequency filtering
- ClinVar-driven pathogenicity prioritization
- disease-panel or phenotype-aware ranking

This is deliberate. Population-frequency filtering should happen after technical calling and annotation, otherwise you mix technical QC with biological interpretation.

## Practical next step
- treat preprocess as the stable production layer
- use the completed 24-sample staged outputs to generate QC summaries
- then add annotation plus population filtering as a downstream interpretation layer
