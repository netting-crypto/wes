from __future__ import annotations

import csv
import io
import json
import shutil
import tarfile
import argparse
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
from sklearn.decomposition import PCA
from umap import UMAP


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RESULTS_DIR = ROOT / "output" / "scrna-local" / "networkscore-validation" / "results"
DEFAULT_SITE_DIR = ROOT / "site" / "rp-scrna-explorer"
DEFAULT_NORMAL_RETINA_DIR = ROOT / "output" / "scrna-local" / "finalscore-rd10-validation" / "normal_human_retina_lukowski_zenodo"

CELLTYPE_COLORS = {
    "rod": "#4c7cff",
    "cone": "#65c7f7",
    "photoreceptor": "#7a66ff",
    "bipolar": "#9aa6ff",
    "amacrine": "#ff8d6a",
    "muller": "#64d89f",
    "microglia": "#5ac1a8",
    "rgc": "#ff5ea8",
    "horizontal": "#f4b64f",
    "astrocyte": "#9c89b8",
    "other": "#a9b0c3",
}


def read_tsv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        rows: list[dict[str, str]] = []
        for row in reader:
            rows.append({key.lstrip("\ufeff"): value for key, value in row.items()})
        return rows


def clean(value: object) -> str:
    return " ".join(str(value or "").strip().split())


def simplify_celltype_label(label: str) -> str:
    label = clean(label).lower()
    if not label:
        return ""
    if "other" in label or "unknown" in label or "unassigned" in label:
        return ""
    mapping = [
        ("rod", ("rod", "rod pr")),
        ("cone", ("cone", "cone pr")),
        ("muller", ("muller", "mg")),
        ("amacrine", ("amacrine",)),
        ("bipolar", ("bipolar",)),
        ("microglia", ("microglia",)),
        ("rgc", ("ganglion", "rgc")),
        ("horizontal", ("horizontal",)),
        ("astrocyte", ("astrocyte", "astro")),
    ]
    for simple, tokens in mapping:
        if any(token in label for token in tokens):
            return simple
    if "photoreceptor" in label or "pr" in label:
        return "photoreceptor"
    return ""


def read_lukowski_celltype_map(dataset_dir: Path) -> dict[str, str]:
    barcode_map: dict[str, str] = {}
    candidate_files = list(sorted(dataset_dir.glob("**/*cellbc*cellid*.csv")))
    candidate_files.extend(sorted(dataset_dir.glob("**/*metadata*.csv")))
    for path in candidate_files:
        try:
            with path.open("r", encoding="utf-8", newline="") as handle:
                reader = csv.DictReader(handle)
                for row in reader:
                    normalized = {clean(k): clean(v) for k, v in row.items()}
                    barcode = normalized.get("cell.bc") or normalized.get("barcode") or normalized.get("cell.barcode") or normalized.get("cell_id")
                    label = normalized.get("cell.id.cca") or normalized.get("cell.id") or normalized.get("cluster") or normalized.get("celltype") or normalized.get("cell_type")
                    simple = simplify_celltype_label(label)
                    if barcode and simple:
                        barcode_map[barcode] = simple
        except Exception:
            continue
    return barcode_map


def select_lukowski_matrix_path(dataset_dir: Path) -> Path:
    matrix_candidates = sorted(dataset_dir.glob("**/lukowski_embo2019_raw_count_matrix.csv.gz*"))
    if not matrix_candidates:
        matrix_candidates = sorted(dataset_dir.glob("**/*raw_count_matrix*.csv.gz*"))
    if not matrix_candidates:
        raise FileNotFoundError("No Lukowski raw count matrix archive found")
    return matrix_candidates[0]


def _stream_lukowski_csv_rows(matrix_path: Path):
    with tarfile.open(matrix_path, "r:*") as tar:
        member = next((m for m in tar.getmembers() if m.isfile() and m.name.lower().endswith(".csv")), None)
        if member is None:
            raise FileNotFoundError("No CSV member found inside Lukowski matrix archive")
        fileobj = tar.extractfile(member)
        if fileobj is None:
            raise FileNotFoundError("Unable to extract Lukowski matrix CSV member")
        wrapper = io.TextIOWrapper(fileobj, encoding="utf-8", newline="")
        reader = csv.reader(wrapper)
        for row in reader:
            yield row


def generate_normal_retina_umap(dataset_dir: Path, output_json: Path, output_figure: Path) -> dict[str, object]:
    barcode_map = read_lukowski_celltype_map(dataset_dir)
    matrix_path = select_lukowski_matrix_path(dataset_dir)

    limits = {
        "rod": 1400,
        "cone": 700,
        "bipolar": 700,
        "amacrine": 380,
        "muller": 450,
        "microglia": 200,
        "rgc": 140,
        "horizontal": 120,
        "astrocyte": 80,
        "photoreceptor": 240,
    }

    rows = _stream_lukowski_csv_rows(matrix_path)
    header = next(rows)
    selected_indices: list[int] = []
    selected_barcodes: list[str] = []
    selected_celltypes: list[str] = []
    counts_by_type: dict[str, int] = {}
    for idx, barcode in enumerate(header):
        cell_type = barcode_map.get(barcode, "")
        if not cell_type:
            continue
        current = counts_by_type.get(cell_type, 0)
        limit = limits.get(cell_type, 180)
        if current >= limit:
            continue
        counts_by_type[cell_type] = current + 1
        selected_indices.append(idx)
        selected_barcodes.append(barcode)
        selected_celltypes.append(cell_type)

    if not selected_indices:
        raise RuntimeError("No Lukowski cells selected for UMAP generation")

    cell_sums = np.zeros(len(selected_indices), dtype=np.float64)
    variable_scores: list[tuple[float, str]] = []
    for row in rows:
        if not row:
            continue
        gene = clean(row[0]).upper()
        if not gene:
            continue
        vector = np.array(
            [float(row[idx + 1]) if idx + 1 < len(row) and row[idx + 1] else 0.0 for idx in selected_indices],
            dtype=np.float32,
        )
        cell_sums += vector
        score = float(np.var(np.log1p(vector)))
        nonzero = float(np.count_nonzero(vector)) / max(len(vector), 1)
        if score > 0.015 and nonzero > 0.01:
            variable_scores.append((score, gene))

    top_genes = {gene for _score, gene in sorted(variable_scores, reverse=True)[:1400]}
    if len(top_genes) < 80:
        raise RuntimeError("Too few variable genes to build a stable UMAP")

    rows = _stream_lukowski_csv_rows(matrix_path)
    _ = next(rows)
    gene_names: list[str] = []
    matrix_rows: list[np.ndarray] = []
    for row in rows:
        if not row:
            continue
        gene = clean(row[0]).upper()
        if gene not in top_genes:
            continue
        vector = np.array(
            [float(row[idx + 1]) if idx + 1 < len(row) and row[idx + 1] else 0.0 for idx in selected_indices],
            dtype=np.float32,
        )
        gene_names.append(gene)
        matrix_rows.append(vector)

    matrix = np.vstack(matrix_rows).T
    cell_sums[cell_sums == 0] = 1.0
    matrix = np.log1p((matrix / cell_sums[:, None]) * 10000.0)

    pca_dims = min(25, matrix.shape[1] - 1, matrix.shape[0] - 1)
    pca = PCA(n_components=max(pca_dims, 2), random_state=42)
    pca_embedding = pca.fit_transform(matrix)

    reducer = UMAP(
        n_components=2,
        n_neighbors=18,
        min_dist=0.28,
        metric="euclidean",
        random_state=42,
    )
    embedding = reducer.fit_transform(pca_embedding)

    points = []
    for barcode, cell_type, coords in zip(selected_barcodes, selected_celltypes, embedding.tolist()):
        points.append(
            {
                "barcode": barcode,
                "cellType": cell_type,
                "x": round(coords[0], 4),
                "y": round(coords[1], 4),
                "color": CELLTYPE_COLORS.get(cell_type, CELLTYPE_COLORS["other"]),
            }
        )

    x = embedding[:, 0]
    y = embedding[:, 1]
    plt.figure(figsize=(8.5, 7.0), dpi=160)
    for cell_type in sorted(set(selected_celltypes)):
        mask = np.array([ct == cell_type for ct in selected_celltypes])
        plt.scatter(
            x[mask],
            y[mask],
            s=8,
            c=CELLTYPE_COLORS.get(cell_type, CELLTYPE_COLORS["other"]),
            alpha=0.75,
            linewidths=0,
            label=cell_type,
        )
    plt.title("Normal human retina UMAP (Lukowski subsample)", fontsize=13)
    plt.xlabel("UMAP1")
    plt.ylabel("UMAP2")
    plt.legend(frameon=False, ncol=2, fontsize=8, loc="best")
    plt.tight_layout()
    output_figure.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(output_figure, bbox_inches="tight", facecolor="white")
    plt.close()

    payload = {
        "source": "Lukowski_EMBO_2019",
        "sampledCellCount": len(points),
        "celltypeCounts": counts_by_type,
        "featureGeneCount": len(gene_names),
        "featureGenes": gene_names[:120],
        "points": points,
    }
    output_json.parent.mkdir(parents=True, exist_ok=True)
    output_json.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return payload


def numeric(value: str | None) -> float | int | None:
    if value is None or value == "":
        return None
    try:
        if "." in value:
            return float(value)
        return int(value)
    except ValueError:
        return value


def split_semicolon(value: str | None) -> list[str]:
    if not value:
        return []
    return [item for item in value.split(";") if item]


def clean_row(row: dict[str, str]) -> dict[str, object]:
    cleaned: dict[str, object] = {}
    for key, value in row.items():
        if value is None:
            cleaned[key] = ""
            continue
        if not isinstance(value, str):
            cleaned[key] = value
            continue
        if key.endswith("_score") or key.endswith("_fraction") or key.endswith("_log2fc") or key in {
            "best_total_priority_score",
            "best_wes_score",
            "best_scrna_support_score",
            "variant_count",
            "family_count",
            "sample_count",
            "module_size",
            "public_rp_gene_count",
            "disease_gene_count",
            "disease_gene_fraction",
            "disease_max_abs_log2fc",
            "coexpression_module_size",
            "coexpression_module_membership",
            "module_network_disease_fraction",
            "wes_score",
            "normal_celltype_score",
            "disease_model_score",
            "network_support_score",
            "scrna_support_score",
            "total_priority_score",
        }:
            cleaned[key] = numeric(value)
        elif ";" in value:
            cleaned[key] = split_semicolon(value)
        else:
            cleaned[key] = value
    return cleaned


def workflow_steps() -> list[dict[str, object]]:
    return [
        {
            "id": "step-01",
            "title": "数据接入",
            "summary": "纳入正常人视网膜、RPGR 类器官、rd1 视网膜和 rd10 视网膜四类 processed 数据与补充 DEG 表。",
            "outputs": ["4 类数据", "207 条候选变异", "90 个候选基因"],
        },
        {
            "id": "step-02",
            "title": "正常细胞类型评分",
            "summary": "基于 Lukowski 正常成人视网膜，评估候选基因在 rod、cone、bipolar、amacrine、Muller、RGC 和 microglia 中的表达支持。",
            "outputs": ["best_normal_celltype_score", "cell_type_support"],
        },
        {
            "id": "step-03",
            "title": "疾病扰动评分",
            "summary": "整合 RPGR、rd1、rd10 的 group、time、cell-type 与 stage 层面 DEG 证据，形成疾病模型扰动支持。",
            "outputs": ["best_disease_model_score", "disease_model_detail"],
        },
        {
            "id": "step-04",
            "title": "网络支持评分",
            "summary": "从正常视网膜抽取共表达模块，再把疾病模型扰动投影到模块层，计算模块级网络支持分。",
            "outputs": ["best_network_support_score", "normal_module_01 photoreceptor"],
        },
        {
            "id": "step-05",
            "title": "候选优先级排序",
            "summary": "输出基因级和变异级优先级结果，供解释增强、图表生成和站点展示使用。",
            "outputs": ["gene_priority_ranking.tsv", "variant_priority_ranking.tsv"],
        },
    ]


def build_payload(results_dir: Path, normal_retina_dir: Path) -> dict[str, object]:
    with (results_dir / "summary.json").open("r", encoding="utf-8") as handle:
        summary = json.load(handle)

    genes = [clean_row(row) for row in read_tsv(results_dir / "gene_priority_ranking.tsv")]
    variants = [clean_row(row) for row in read_tsv(results_dir / "variant_priority_ranking.tsv")]
    modules = [clean_row(row) for row in read_tsv(results_dir / "network_module_summary.tsv")]
    datasets = [clean_row(row) for row in summary.get("datasets", [])]
    umap_cache = results_dir / "normal_retina_umap_points.json"
    umap_figure = results_dir / "normal_retina_umap.png"
    umap = load_or_build_umap(normal_retina_dir, umap_cache, umap_figure)

    top_genes = genes[:20]
    top_variants = variants[:20]

    score_ranges = {
        "normal": max((row.get("best_normal_celltype_score") or 0) for row in top_genes),
        "disease": max((row.get("best_disease_model_score") or 0) for row in top_genes),
        "network": max((row.get("best_network_support_score") or 0) for row in top_genes),
        "total": max((row.get("best_total_priority_score") or 0) for row in top_genes),
    }

    overview = {
        "candidate_rows": summary["candidate_rows"],
        "ranked_genes": summary["ranked_genes"],
        "dataset_count": len(summary["datasets"]),
        "module_count": len(summary["network_modules"]),
        "top_gene": top_genes[0]["gene"] if top_genes else "",
        "photoreceptor_module_size": modules[0]["module_size"] if modules else 0,
    }

    key_findings = [
        "normal_module_01 是当前网络层最核心的 photoreceptor 模块，并携带大量已知 RP/IRD 基因。",
        "ABCA4、RDH12 和 USH2A 在正常表达、疾病扰动和共表达网络三层证据下都保持高优先级。",
        "疾病支持不再依赖单一模型，RPGR、rd1 和 rd10 已经形成交叉支撑。",
        "网站直接消费与排序结果同源的本地产物，因此浏览界面、图表导出和解释结论基于同一证据底座。",
    ]

    return {
        "generatedAt": summary.get("generated_at", ""),
        "overview": overview,
        "scoreRanges": score_ranges,
        "datasets": datasets,
        "modules": modules,
        "topGenes": top_genes,
        "topVariants": top_variants,
        "allGenes": genes,
        "allVariants": variants,
        "umap": umap,
        "workflow": workflow_steps(),
        "keyFindings": key_findings,
        "toolOutputs": {
            "resultsDir": str(results_dir),
            "normalRetinaDir": str(normal_retina_dir),
            "siteType": "scrna_evidence_explorer",
        },
    }


def prepare_site_assets(site_dir: Path) -> Path:
    assets_dir = site_dir / "assets"
    assets_dir.mkdir(parents=True, exist_ok=True)
    return assets_dir


def write_payload(payload: dict[str, object], assets_dir: Path) -> None:
    serialized = json.dumps(payload, ensure_ascii=False, indent=2)
    (assets_dir / "site-data.js").write_text(f"window.SCRNA_EXPLORER_DATA = {serialized};\n", encoding="utf-8")


def mirror_static_site_template(site_dir: Path) -> None:
    source_site_dir = ROOT / "site" / "rp-scrna-explorer"
    site_dir.mkdir(parents=True, exist_ok=True)
    for name in ("index.html", "styles.css", "app.js"):
        source = source_site_dir / name
        target = site_dir / name
        if source.resolve() == target.resolve():
            continue
        shutil.copy2(source, target)


def load_or_build_umap(normal_retina_dir: Path, cache_path: Path, figure_path: Path) -> dict[str, object]:
    if cache_path.exists():
        with cache_path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    return generate_normal_retina_umap(normal_retina_dir, cache_path, figure_path)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--results-dir", default=str(DEFAULT_RESULTS_DIR))
    parser.add_argument("--site-dir", default=str(DEFAULT_SITE_DIR))
    parser.add_argument("--normal-retina-dir", default=str(DEFAULT_NORMAL_RETINA_DIR))
    args = parser.parse_args()

    results_dir = Path(args.results_dir)
    site_dir = Path(args.site_dir)
    normal_retina_dir = Path(args.normal_retina_dir)

    mirror_static_site_template(site_dir)
    assets_dir = prepare_site_assets(site_dir)
    payload = build_payload(results_dir, normal_retina_dir)
    write_payload(payload, assets_dir)
    print(f"Wrote site assets to {site_dir}")


if __name__ == "__main__":
    main()
