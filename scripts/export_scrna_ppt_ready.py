#!/usr/bin/env python3
import csv
import json
from collections import Counter
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch
from openpyxl import Workbook


ROOT = Path(r"C:\Users\witch\Documents\Playground-wes-pipeline")
RESULT_DIR = ROOT / "output" / "scrna-local" / "networkscore-validation" / "results"
OUT_DIR = ROOT / "output" / "scrna-local" / "ppt-ready"
FIG_DIR = OUT_DIR / "figures"
TABLE_DIR = OUT_DIR / "tables"


def read_tsv(path):
    with open(path, "r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def write_tsv(path, rows, fieldnames=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    if fieldnames is None:
        fieldnames = list(rows[0].keys()) if rows else ["message"]
    with open(path, "w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, delimiter="\t")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def write_csv(path, rows, fieldnames=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    if fieldnames is None:
        fieldnames = list(rows[0].keys()) if rows else ["message"]
    with open(path, "w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def safe_float(value):
    try:
        return float(value)
    except Exception:
        return 0.0


def top_n(rows, n=20):
    return rows[: min(n, len(rows))]


def normalize_label(text):
    text = str(text or "").replace("_", " ")
    mapping = {
        "rd10 retina gse183206": "rd10",
        "rd1 retina gse212183": "rd1",
        "rpgr organoid srp535874": "RPGR",
        "normal human retina lukowski zenodo": "Normal",
        "rd10 cone deg": "rd10 cone",
        "rd10 rod early deg": "rd10 early rod",
        "rd10 rod late deg": "rd10 late rod",
        "rd1 stage deg": "rd1 stage",
        "rpgr group deg": "RPGR group",
        "rpgr time deg": "RPGR time",
        "rpgr celltype deg": "RPGR celltype",
    }
    lower = text.lower()
    return mapping.get(lower, text)


def plot_top_gene_bar(gene_rows):
    rows = top_n(gene_rows, 20)
    genes = [r["gene"] for r in rows][::-1]
    scores = [safe_float(r["best_total_priority_score"]) for r in rows][::-1]
    plt.figure(figsize=(10, 8))
    plt.barh(genes, scores, color="#3b82f6")
    plt.xlabel("Total priority score")
    plt.ylabel("Gene")
    plt.title("Top 20 RP/IRD genes by integrated scRNA support")
    plt.tight_layout()
    plt.savefig(FIG_DIR / "top20_gene_total_score.png", dpi=220)
    plt.close()


def plot_stacked_scores(gene_rows):
    rows = top_n(gene_rows, 15)
    genes = [r["gene"] for r in rows]
    normal = [safe_float(r["best_normal_celltype_score"]) for r in rows]
    disease = [safe_float(r["best_disease_model_score"]) for r in rows]
    network = [safe_float(r["best_network_support_score"]) for r in rows]
    x = range(len(rows))
    plt.figure(figsize=(12, 6))
    plt.bar(x, normal, label="Normal cell-type", color="#60a5fa")
    plt.bar(x, disease, bottom=normal, label="Disease perturbation", color="#f97316")
    bottoms = [a + b for a, b in zip(normal, disease)]
    plt.bar(x, network, bottom=bottoms, label="Network support", color="#10b981")
    plt.xticks(list(x), genes, rotation=45, ha="right")
    plt.ylabel("Score")
    plt.title("Top 15 genes: three-component scRNA support scores")
    plt.legend(frameon=False)
    plt.tight_layout()
    plt.savefig(FIG_DIR / "top15_three_component_scores.png", dpi=220)
    plt.close()


def plot_dataset_overview(dataset_rows):
    labels = [normalize_label(r["dataset_id"]) for r in dataset_rows]
    genes = [safe_float(r["gene_entries"]) for r in dataset_rows]
    files = [safe_float(r["file_count"]) for r in dataset_rows]
    fig, axes = plt.subplots(1, 2, figsize=(12, 4))
    axes[0].bar(labels, genes, color="#6366f1")
    axes[0].set_title("Gene entries by dataset")
    axes[0].set_ylabel("Gene-like entries")
    axes[0].tick_params(axis="x", rotation=20)
    axes[1].bar(labels, files, color="#14b8a6")
    axes[1].set_title("Downloaded files by dataset")
    axes[1].set_ylabel("File count")
    axes[1].tick_params(axis="x", rotation=20)
    fig.suptitle("RP scRNA input datasets")
    fig.tight_layout()
    fig.savefig(FIG_DIR / "dataset_overview.png", dpi=220)
    plt.close(fig)


def parse_context_flags(value, ordered_contexts):
    items = set(filter(None, str(value or "").split(";")))
    return [1 if ctx in items else 0 for ctx in ordered_contexts]


def plot_disease_heatmap(gene_rows):
    rows = top_n(gene_rows, 20)
    contexts = [
        "rd10_cone_deg",
        "rd10_rod_early_deg",
        "rd10_rod_late_deg",
        "rd1_stage_deg",
        "rpgr_group_deg",
        "rpgr_time_deg",
        "rpgr_celltype_deg",
    ]
    matrix = [parse_context_flags(r["disease_model_support"], contexts) for r in rows]
    fig, ax = plt.subplots(figsize=(9, 8))
    im = ax.imshow(matrix, aspect="auto", cmap="Blues", vmin=0, vmax=1)
    ax.set_yticks(range(len(rows)))
    ax.set_yticklabels([r["gene"] for r in rows])
    ax.set_xticks(range(len(contexts)))
    ax.set_xticklabels([normalize_label(c) for c in contexts], rotation=35, ha="right")
    ax.set_title("Top 20 genes: disease-model evidence heatmap")
    fig.colorbar(im, ax=ax, fraction=0.03, pad=0.02)
    fig.tight_layout()
    fig.savefig(FIG_DIR / "top20_disease_evidence_heatmap.png", dpi=220)
    plt.close(fig)


def plot_network_module_summary(module_rows):
    rows = sorted(module_rows, key=lambda r: -safe_float(r["module_size"]))
    labels = [r["module_id"] for r in rows]
    sizes = [safe_float(r["module_size"]) for r in rows]
    fractions = [safe_float(r["disease_gene_fraction"]) for r in rows]
    colors = ["#2563eb" if r["dominant_celltype"] == "photoreceptor" else "#a855f7" for r in rows]
    fig, ax1 = plt.subplots(figsize=(10, 5))
    ax1.bar(labels, sizes, color=colors)
    ax1.set_ylabel("Module size")
    ax1.set_title("Normal retina coexpression modules and disease perturbation")
    ax2 = ax1.twinx()
    ax2.plot(labels, fractions, color="#ef4444", marker="o", linewidth=2)
    ax2.set_ylabel("Disease-gene fraction")
    legend_items = [
        Patch(color="#2563eb", label="photoreceptor"),
        Patch(color="#a855f7", label="microglia/other"),
    ]
    ax1.legend(handles=legend_items, frameon=False, loc="upper left")
    fig.tight_layout()
    fig.savefig(FIG_DIR / "network_module_summary.png", dpi=220)
    plt.close(fig)


def plot_model_coverage(gene_rows):
    rows = top_n(gene_rows, 20)
    model_labels = ["rd10", "rd1", "RPGR"]
    counts = []
    for row in rows:
        models = set(str(row.get("module_network_disease_models", "")).split(";"))
        counts.append([1 if label.lower() in ";".join(models).lower() else 0 for label in model_labels])
    fig, ax = plt.subplots(figsize=(8, 8))
    im = ax.imshow(counts, aspect="auto", cmap="Greens", vmin=0, vmax=1)
    ax.set_yticks(range(len(rows)))
    ax.set_yticklabels([r["gene"] for r in rows])
    ax.set_xticks(range(len(model_labels)))
    ax.set_xticklabels(model_labels)
    ax.set_title("Top 20 genes: cross-model support")
    fig.colorbar(im, ax=ax, fraction=0.03, pad=0.02)
    fig.tight_layout()
    fig.savefig(FIG_DIR / "top20_model_coverage_heatmap.png", dpi=220)
    plt.close(fig)


def build_curated_tables(gene_rows, variant_rows, dataset_rows, module_rows):
    top20_genes = []
    for row in top_n(gene_rows, 20):
        top20_genes.append({
            "gene": row["gene"],
            "total_score": row["best_total_priority_score"],
            "normal_score": row["best_normal_celltype_score"],
            "disease_score": row["best_disease_model_score"],
            "network_score": row["best_network_support_score"],
            "network_module": row["coexpression_module_support"],
            "network_celltype": row["coexpression_module_celltype_support"],
            "disease_models": row["module_network_disease_models"],
            "state_module": row["state_module_support"],
            "top_interpretation": row["top_interpretation"],
        })
    top20_variants = []
    for row in top_n(variant_rows, 20):
        top20_variants.append({
            "gene": row["gene"],
            "family_id": row["family_id"],
            "sample_id": row["sample_id"],
            "variant": row["variant"],
            "total_score": row["total_priority_score"],
            "normal_score": row["normal_celltype_score"],
            "disease_score": row["disease_model_score"],
            "network_score": row["network_support_score"],
            "network_module": row["coexpression_module_id"],
            "disease_models": row["module_network_disease_models"],
            "classification": row["classification"],
            "conclusion": row["conclusion"],
        })
    dataset_table = []
    for row in dataset_rows:
        dataset_table.append({
            "dataset_id": row["dataset_id"],
            "accession": row["accession"],
            "model": row["model"],
            "status": row["download_status"],
            "file_count": row["file_count"],
            "gene_entries": row["gene_entries"],
            "key_read_notes": row["read_notes"][:260],
        })
    module_table = []
    for row in module_rows:
        module_table.append({
            "module_id": row["module_id"],
            "dominant_celltype": row["dominant_celltype"],
            "module_size": row["module_size"],
            "anchor_genes": row["anchor_genes"],
            "disease_models": row.get("disease_models", ""),
            "disease_gene_fraction": row.get("disease_gene_fraction", ""),
            "public_rp_gene_count": row["public_rp_gene_count"],
        })
    return top20_genes, top20_variants, dataset_table, module_table


def export_workbook(top20_genes, top20_variants, dataset_table, module_table):
    wb = Workbook()
    ws = wb.active
    ws.title = "top20_genes"
    for sheet_name, rows in [
        ("top20_genes", top20_genes),
        ("top20_variants", top20_variants),
        ("dataset_overview", dataset_table),
        ("network_modules", module_table),
    ]:
        if sheet_name == "top20_genes":
            ws = wb.active
            ws.title = sheet_name
        else:
            ws = wb.create_sheet(title=sheet_name)
        headers = list(rows[0].keys()) if rows else []
        ws.append(headers)
        for row in rows:
            ws.append([row.get(h, "") for h in headers])
        ws.freeze_panes = "A2"
    wb.save(TABLE_DIR / "rp_scrna_ppt_ready_tables.xlsx")


def write_summary_markdown(summary, top20_genes, top20_variants, dataset_table, module_table):
    lines = [
        "# RP 单细胞首版汇报摘要",
        "",
        "## 1. 数据来源",
        "",
        "- 正常人视网膜：Lukowski adult human retina",
        "- 疾病模型 1：RPGR retinal organoid",
        "- 疾病模型 2：rd1 retina",
        "- 疾病模型 3：rd10 retina",
        "",
        "## 2. 处理流程",
        "",
        "1. 下载并读取 processed matrix / supplement DEG tables",
        "2. 生成正常视网膜细胞类型支持",
        "3. 提取 RPGR、rd1、rd10 的疾病扰动证据",
        "4. 在正常视网膜中构建共表达模块并映射候选基因",
        "5. 计算三部分评分：normal / disease / network",
        "",
        "## 3. 当前核心数字",
        "",
        f"- 候选变异数：{summary['candidate_rows']}",
        f"- 排序基因数：{summary['ranked_genes']}",
        f"- 共表达模块数：{len(module_table)}",
        "",
        "## 4. 主要结论",
        "",
        "- 当前最强的高优先基因集中在 photoreceptor 网络模块中。",
        "- `ABCA4`、`RDH12`、`USH2A` 在三部分评分中都保持高分。",
        "- `rd10` 已经从缺失项升级为正式 disease-model evidence 来源。",
        "- 正常视网膜共表达主模块 `normal_module_01` 被标注为 photoreceptor，并被三类疾病模型共同扰动。",
        "",
        "## 5. Top 10 基因",
        "",
    ]
    for idx, row in enumerate(top20_genes[:10], start=1):
        lines.append(
            f"{idx}. `{row['gene']}` - total {row['total_score']}, normal {row['normal_score']}, disease {row['disease_score']}, network {row['network_score']}, module `{row['network_module']}` ({row['network_celltype']})"
        )
    lines.extend([
        "",
        "## 6. 可以直接做 PPT 的页面建议",
        "",
        "1. 项目目标与评分框架",
        "2. 数据来源与处理流程",
        "3. 数据集概览",
        "4. Top 20 基因总分排序",
        "5. Top 15 三评分堆叠图",
        "6. 疾病证据热图",
        "7. 共表达模块与网络支持",
        "8. 重点基因解读与下一步计划",
        "",
        "## 7. 输出文件",
        "",
        "- `figures/`：PPT 可直接插入的 PNG 图片",
        "- `tables/`：整理好的表格与 Excel 工作簿",
        "- `ppt_storyline.md`：这一份讲稿式摘要",
        "",
    ])
    (OUT_DIR / "ppt_storyline.md").write_text("\n".join(lines) + "\n", encoding="utf-8-sig")


def main():
    FIG_DIR.mkdir(parents=True, exist_ok=True)
    TABLE_DIR.mkdir(parents=True, exist_ok=True)

    gene_rows = read_tsv(RESULT_DIR / "gene_priority_ranking.tsv")
    variant_rows = read_tsv(RESULT_DIR / "variant_priority_ranking.tsv")
    dataset_rows = read_tsv(RESULT_DIR / "read_check.tsv")
    module_rows = read_tsv(RESULT_DIR / "network_module_summary.tsv")
    summary = json.loads((RESULT_DIR / "summary.json").read_text(encoding="utf-8"))

    plot_top_gene_bar(gene_rows)
    plot_stacked_scores(gene_rows)
    plot_dataset_overview(dataset_rows)
    plot_disease_heatmap(gene_rows)
    plot_network_module_summary(module_rows)
    plot_model_coverage(gene_rows)

    top20_genes, top20_variants, dataset_table, module_table = build_curated_tables(
        gene_rows, variant_rows, dataset_rows, module_rows
    )

    write_tsv(TABLE_DIR / "top20_genes.tsv", top20_genes)
    write_csv(TABLE_DIR / "top20_genes.csv", top20_genes)
    write_tsv(TABLE_DIR / "top20_variants.tsv", top20_variants)
    write_csv(TABLE_DIR / "top20_variants.csv", top20_variants)
    write_tsv(TABLE_DIR / "dataset_overview.tsv", dataset_table)
    write_tsv(TABLE_DIR / "network_modules.tsv", module_table)
    export_workbook(top20_genes, top20_variants, dataset_table, module_table)
    write_summary_markdown(summary, top20_genes, top20_variants, dataset_table, module_table)

    manifest = {
        "source_results": str(RESULT_DIR),
        "figures": sorted([p.name for p in FIG_DIR.glob("*.png")]),
        "tables": sorted([p.name for p in TABLE_DIR.glob("*")]),
        "storyline": "ppt_storyline.md",
    }
    (OUT_DIR / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8-sig")
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
