# RP scRNA First-Pass Logic

## 1. Current Goal

Current target is a first-pass single-cell support ranking for RP/IRD candidate genes, without family-level WES reprioritization.

The working scoring frame is:

1. normal cell-type relevance score
2. disease-model perturbation score
3. network support score

These three parts are summed into a single `scrna_support_score`, then combined with the current variant/gene candidate input to produce a ranked list.

The current upgraded third score is no longer a pure manual pathway label score. It is built from:

- normal-retina coexpression module assignment
- module cell-type identity
- module overlap with public RP genes
- module-level disease perturbation across `RPGR`, `rd1`, and `rd10`

## 2. Candidate Input

Current candidate table:

- `output/wes/company-analysis-results.tsv`

Current scale:

- `207` variant rows
- `90` unique genes

## 3. Datasets Already Integrated

### 3.1 Normal Human Retina

Dataset:

- `normal_human_retina_lukowski_zenodo`
- source: `Lukowski_EMBO_2019; Zenodo_5515631`

Files used:

- `lukowski_embo2019_raw_count_matrix.csv.gz`
- `lukowski_embo2019_CCA_metadata.csv`
- `lukowski_embo2019_cellbc_cellid.csv`

Current processing:

- parse raw count matrix
- map barcodes to simplified cell types
- summarize gene support across retina cell types

Current outputs contributed:

- `normal_celltype_expression_support`
- `normal_best_expression_fraction`
- `best_normal_celltype_score`

Observed cell types:

- rod
- cone
- bipolar
- amacrine
- muller
- rgc
- microglia

### 3.2 RPGR Retinal Organoid Disease Model

Dataset:

- `rpgr_organoid_srp535874`

Files used:

- `41597_2024_4124_MOESM2_ESM.xlsx`
- `41597_2024_4124_MOESM3_ESM.xlsx`
- `41597_2024_4124_MOESM4_ESM.xlsx`

Current processing:

- parse group DEG
- parse time-group DEG
- parse cell-type DEG

Current outputs contributed:

- `disease_model_support` including:
  - `rpgr_group_deg`
  - `rpgr_time_deg`
  - `rpgr_celltype_deg`
- `disease_model_detail`
- `disease_max_abs_log2fc`

### 3.5 Normal Retina Coexpression Modules

Source dataset:

- `normal_human_retina_lukowski_zenodo`

Current processing:

- sample cells across major retina cell types from the Lukowski matrix
- extract a gene-by-cell matrix for candidate genes, PanelApp retinal genes, marker genes, and curated RP priors
- compute gene-gene correlations in the normal retina reference
- build connected coexpression modules from the correlation graph
- assign each module a dominant retina cell-type label
- project disease perturbation from `RPGR`, `rd1`, and `rd10` onto each module

Current outputs contributed:

- `coexpression_module_support`
- `coexpression_module_celltype_support`
- `module_network_disease_models`
- `module_network_disease_contexts`
- `best_network_support_score`

Current local validation result:

- module `normal_module_01`
  - dominant cell type: `photoreceptor`
  - module size: `104`
  - anchors: `KCNV2;GUCA1A;UNC119;RP1;AIPL1`
- module `normal_module_02`
  - dominant cell type: `microglia`
  - module size: `7`
  - anchors: `C1QA;AIF1;PLD4;C3;CX3CR1`

### 3.3 rd1 Mouse Retina Disease Model

Dataset:

- `rd1_retina_gse212183`

File used:

- `GSE212183_RAW.tar`

Contained samples:

- `C3H-P11`
- `C3H-P13`
- `C3H-P17`
- `rd1-P11`
- `rd1-P13`
- `rd1-P17`

Current processing:

- read each sample matrix from tar
- aggregate per-gene counts
- compare `rd1 vs C3H` within the same stage
- generate DEG-like support by stage

Current outputs contributed:

- `disease_model_support` including `rd1_stage_deg`
- `disease_model_detail` including:
  - `P11 rd1_vs_C3H`
  - `P13 rd1_vs_C3H`
  - `P17 rd1_vs_C3H`
- `disease_max_abs_log2fc`

### 3.4 rd10 Mouse Retina Disease Model

Dataset:

- `rd10_retina_gse183206`

Files used:

- `GSE183206_aggr_filtered_counts_matrix.h5`
- `12915_2022_1280_MOESM4_ESM.xlsx`
- `12915_2022_1280_MOESM5_ESM.xlsx`
- `12915_2022_1280_MOESM11_ESM.xlsx`

Supporting metadata recovered:

- GEO sample metadata confirms:
  - `rd10_m`
  - `rd10_f`
  - `wt_m`
  - `wt_f`
- H5 root attributes retain library-level labels:
  - `rd10_1_M`
  - `rd10_2_F`
  - `wt_3_M`
  - `wt_4_F`

Current processing:

- keep the aggregate H5 as matrix/gene coverage evidence
- use author supplementary DEG tables instead of forcing per-cell sample reconstruction from the aggregate H5
- parse rod early degeneration support:
  - `C02_vs_C01 early_deg_rods`
- parse rod late degeneration support:
  - `C03_vs_C02 late_deg_rods`
- parse cone `rd10 vs wt` support:
  - `C04 rd10_vs_wt_cones`

Current outputs contributed:

- `disease_model_support` including:
  - `rd10_rod_early_deg`
  - `rd10_rod_late_deg`
  - `rd10_cone_deg`
- `disease_model_detail`
- `disease_max_abs_log2fc`

### 3.6 Public RP/IRD Gene Universe

Source:

- `PanelApp retinal disorders`

Current role:

- external prior support
- helps identify genes already known in RP/IRD panels

## 4. Current Output Tables

Main working output directory:

- `output/scrna-local/networkscore-validation/results/`

Key files:

- `network_module_summary.tsv`
- `gene_priority_ranking.tsv`
- `variant_priority_ranking.tsv`
- `evidence_breakdown.tsv`
- `read_check.tsv`
- `degrade_report.md`

## 5. Current Score Fields

### Gene-level fields

- `best_total_priority_score`
- `best_wes_score`
- `best_normal_celltype_score`
- `best_disease_model_score`
- `best_network_support_score`
- `best_scrna_support_score`

### Evidence fields

- `cell_type_support`
- `normal_celltype_expression_support`
- `normal_best_expression_fraction`
- `disease_model_support`
- `disease_model_detail`
- `disease_max_abs_log2fc`
- `coexpression_module_support`
- `coexpression_module_celltype_support`
- `coexpression_module_anchor_genes`
- `module_network_disease_models`
- `module_network_disease_contexts`
- `state_module_support`
- `public_rp_gene_support`
- `top_interpretation`

## 6. Current Top Genes

Based on the current upgraded network-score run:

1. `ABCA4` - normal `55`, disease `60`, network `35`, total `205`
2. `RDH12` - normal `55`, disease `60`, network `35`, total `205`
3. `USH2A` - normal `55`, disease `60`, network `35`, total `205`
4. `EYS` - normal `55`, disease `50`, network `35`, total `195`
5. `CNGA1` - normal `55`, disease `60`, network `35`, total `190`
6. `CRB1` - normal `55`, disease `60`, network `35`, total `190`
7. `IMPG2` - normal `55`, disease `60`, network `35`, total `190`
8. `MAK` - normal `55`, disease `60`, network `35`, total `190`

Representative newly integrated rd10-supported genes now include:

- `ABCA4` via `rd10_rod_late_deg`
- `RDH12` via `rd10_cone_deg` and `rd10_rod_early_deg`
- `CNGA1` via `rd10_cone_deg` and `rd10_rod_early_deg`
- `RHO` via `rd10_cone_deg` and `rd10_rod_late_deg`
- `PDE6B` via `rd10_cone_deg`

Representative network-supported genes now include:

- `ABCA4` in `normal_module_01[photoreceptor]`
- `USH2A` in `normal_module_01[photoreceptor]`
- `RPGR` in `normal_module_01[photoreceptor]`
- `PDE6B` in `normal_module_01[photoreceptor]`
- `RHO` in `normal_module_01[photoreceptor]`

## 7. Plot-Ready Items

Already suitable for plotting now:

1. top ranked genes bar plot
   - x: gene
   - y: `best_total_priority_score`

2. stacked component score plot
   - x: gene
   - y: three components
   - fields:
     - `best_normal_celltype_score`
     - `best_disease_model_score`
     - `best_network_support_score`

3. disease evidence heatmap
   - rows: top genes
   - columns:
     - `rd10_rod_early_deg`
     - `rd10_rod_late_deg`
     - `rd10_cone_deg`
     - `rd1_stage_deg`
     - `rpgr_group_deg`
     - `rpgr_time_deg`
     - `rpgr_celltype_deg`

4. coexpression module heatmap
   - rows: top genes
   - columns:
     - `coexpression_module_support`
     - `coexpression_module_celltype_support`
     - `module_network_disease_models`

5. normal cell-type support heatmap
   - rows: top genes
   - columns:
     - rod
     - cone
     - bipolar
     - amacrine
     - muller
     - rgc
     - microglia

6. rd1 stage DEG support summary
   - x: stage (`P11`, `P13`, `P17`)
   - y: number of DEG-like genes
   - current values:
     - `P11: 5557`
     - `P13: 6693`
     - `P17: 8574`

7. disease perturbation strength plot
   - x: top genes
   - y: `disease_max_abs_log2fc`

8. candidate coverage summary
   - total candidate variants
   - total unique genes
   - genes with normal support
   - genes with rd10 support
   - genes with RPGR support
   - genes with rd1 support

## 8. Recommended Immediate Figures

For the first-pass report, the highest-yield figures are:

1. top 20 genes ranked bar plot
2. top 20 genes three-component stacked score plot
3. top 20 genes disease evidence heatmap
4. top 20 genes coexpression-module support heatmap

## 9. Remaining Work Before First-Pass Completion

1. decide whether to promote `networkscore-validation` as the new first-pass default result set
2. create plotting script(s) for the top summary figures
3. decide whether to keep `rd10` driven by author DEG supplements only, or invest further in per-cell sample reconstruction from the aggregate H5
