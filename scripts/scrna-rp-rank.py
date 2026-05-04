#!/usr/bin/env python3
import argparse
import csv
import gzip
import json
import os
import re
import subprocess
import sys
import tarfile
import zipfile
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path


RP_CELL_MARKERS = {
    "rod": {"RHO", "Rho", "NRL", "Nrl", "GNAT1", "Gnat1", "PDE6A", "Pde6a", "PDE6B", "Pde6b", "CNGA1", "Cnga1", "CNGB1", "Cngb1", "RP1", "Rp1"},
    "cone": {"ARR3", "Arr3", "GNAT2", "Gnat2", "OPN1LW", "Opn1mw", "OPN1MW", "OPN1SW", "Opn1sw", "GUCA1C", "Guca1c", "PDE6C", "Pde6c"},
    "photoreceptor": {"RPGR", "Rpgr", "EYS", "Eys", "PROM1", "Prom1", "PCARE", "Pcare", "USH2A", "Ush2a", "CDHR1", "Cdhr1", "CRX", "Crx", "OTX2", "Otx2"},
    "rpe": {"RPE65", "Rpe65", "MERTK", "Mertk", "BEST1", "Best1", "RGR", "Rgr", "RLBP1", "Rlbp1"},
    "muller": {"RLBP1", "Rlbp1", "SLC1A3", "Slc1a3", "AQP4", "Aqp4", "GFAP", "Gfap", "CRABP1", "Crabp1"},
    "rgc": {"RBPMS", "Rbpms", "SNCG", "Sncg", "EBF1", "Ebf1"},
    "bipolar": {"VSX1", "Vsx1", "VSX2", "Vsx2", "GRIK1", "Grik1"},
    "amacrine": {"GAD1", "Gad1", "TFAP2A", "Tfap2a"},
    "microglia": {"C1QA", "C1qa", "CX3CR1", "Cx3cr1", "AIF1", "Aif1"},
}

GENE_CELL_PRIORS = {
    "ABCA4": ("photoreceptor", "retinoid transport / outer segment"),
    "AIPL1": ("rod", "phototransduction protein homeostasis"),
    "BEST1": ("rpe", "RPE ion/fluid homeostasis"),
    "CDHR1": ("photoreceptor", "outer segment disc organization"),
    "CERKL": ("photoreceptor", "retinal stress response"),
    "CNGA1": ("rod", "rod phototransduction"),
    "CNGB1": ("rod", "rod phototransduction"),
    "CRB1": ("photoreceptor;muller", "retinal polarity / lamination"),
    "CYP4V2": ("rpe;photoreceptor", "retinal lipid metabolism"),
    "EYS": ("photoreceptor", "photoreceptor outer segment structure"),
    "FSCN2": ("photoreceptor", "photoreceptor cytoskeleton"),
    "IMPDH1": ("photoreceptor", "retinal nucleotide metabolism vulnerability"),
    "IMPG2": ("photoreceptor", "interphotoreceptor matrix"),
    "MAK": ("photoreceptor", "ciliary axoneme regulation"),
    "MERTK": ("rpe", "RPE outer segment phagocytosis"),
    "MYO7A": ("photoreceptor;rpe", "Usher photoreceptor/RPE trafficking"),
    "NRL": ("rod", "rod fate transcription factor"),
    "PCARE": ("photoreceptor", "disc morphogenesis"),
    "PDE6A": ("rod", "rod phototransduction"),
    "PDE6B": ("rod", "rd1/rd10 causal phototransduction gene"),
    "PROM1": ("photoreceptor", "outer segment disc morphogenesis"),
    "RBP3": ("photoreceptor;rpe", "interphotoreceptor retinoid transport"),
    "RDH12": ("photoreceptor", "retinoid detoxification"),
    "RGR": ("rpe", "visual cycle related"),
    "RHO": ("rod", "rod phototransduction"),
    "ROM1": ("photoreceptor", "outer segment membrane structure"),
    "RP1": ("photoreceptor", "axoneme / outer segment structure"),
    "RPE65": ("rpe", "visual cycle"),
    "RPGR": ("photoreceptor", "connecting cilium transport"),
    "USH2A": ("photoreceptor", "periciliary / Usher complex"),
}

STATE_MODULES = {
    "cilium_outer_segment": {"RPGR", "MAK", "PCARE", "PROM1", "RP1", "USH2A", "CDHR1", "EYS"},
    "phototransduction": {"RHO", "PDE6A", "PDE6B", "CNGA1", "CNGB1", "GNAT1", "GNAT2", "NRL"},
    "visual_cycle_rpe": {"RPE65", "RGR", "RBP3", "RDH12", "MERTK", "BEST1", "ABCA4"},
    "stress_metabolism": {"CERKL", "CYP4V2", "IMPDH1", "NMNAT1", "EGR1", "CD44"},
    "synapse_structure": {"RIMS1", "CACNA2D4", "FSCN2", "ROM1"},
}


def clean(value):
    return re.sub(r"\s+", " ", str(value or "")).strip()


def upper_gene(value):
    return clean(value).split(";")[0].upper()


def read_tsv(path):
    rows = []
    with open(path, "r", encoding="utf-8-sig", newline="") as handle:
        sample = handle.read(4096)
        handle.seek(0)
        try:
            dialect = csv.Sniffer().sniff(sample, delimiters="\t,")
        except csv.Error:
            dialect = csv.excel_tab if "\t" in sample else csv.excel
        reader = csv.DictReader(handle, dialect=dialect)
        for row in reader:
            rows.append({clean(k): clean(v) for k, v in row.items()})
    return rows


def write_tsv(path, rows, fieldnames=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    if fieldnames is None:
        keys = []
        for row in rows:
            for key in row:
                if key not in keys:
                    keys.append(key)
        fieldnames = keys or ["message"]
    with open(path, "w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, delimiter="\t", extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def read_manifest(path):
    return read_tsv(path)


def parse_download_status(path):
    if path and Path(path).exists():
        return {row.get("dataset_id", ""): row for row in read_tsv(path)}
    return {}


def find_candidate_table(explicit):
    candidates = [explicit] if explicit else []
    candidates.extend([
        "config/wes/company-analysis-results.tsv",
        "config/wes/company-hotspots.tsv",
        "config/wes/company-family-targets.tsv",
        "output/wes/results/family_candidates_functional_classified.csv",
    ])
    available = []
    for item in candidates:
        if item and Path(item).exists():
            try:
                row_count = len(read_tsv(item))
            except Exception:
                row_count = -1
            available.append((row_count, Path(item)))
    if available:
        available.sort(key=lambda pair: pair[0], reverse=True)
        return available[0][1]
    return None


def read_candidates(path):
    if not path:
        return []
    rows = read_tsv(path)
    out = []
    last_context = {
        "family_id": "",
        "sample_id": "",
        "classification": "",
        "conclusion": "",
    }
    for row in rows:
        gene = row.get("gene") or row.get("基因") or row.get("Gene")
        if not clean(gene):
            continue
        family_id = row.get("family_id") or row.get("Family") or row.get("样本名称") or last_context["family_id"]
        sample_id = row.get("sample_id") or row.get("lab_id") or row.get("实验室编号") or row.get("优乐编号") or last_context["sample_id"]
        classification = row.get("classification") or row.get("致病性评级") or row.get("acmg_classification") or last_context["classification"]
        conclusion = row.get("conclusion") or row.get("报告结论") or last_context["conclusion"]
        variant = row.get("variant") or row.get("变异（标准转录本对应注释）") or row.get("variant_hgvs") or ""
        out.append({
            "family_id": family_id,
            "sample_id": sample_id,
            "gene": upper_gene(gene),
            "variant": variant,
            "classification": classification,
            "conclusion": conclusion,
            "source_row": json.dumps(row, ensure_ascii=False),
        })
        last_context.update({
            "family_id": family_id,
            "sample_id": sample_id,
            "classification": classification,
            "conclusion": conclusion,
        })
    return out


def add_gene(gene_set, value):
    value = clean(value)
    if not value:
        return
    # Keep likely gene symbols; avoid adding barcodes or coordinates.
    if re.fullmatch(r"[A-Za-z][A-Za-z0-9_.-]{1,30}", value):
        gene_set.add(value.upper())


def genes_from_text_file(path, limit=200000):
    genes = set()
    opener = gzip.open if str(path).endswith(".gz") else open
    try:
        with opener(path, "rt", encoding="utf-8", errors="ignore") as handle:
            for i, line in enumerate(handle):
                if i > limit:
                    break
                raw = line.rstrip("\n")
                if raw.count(",") > raw.count("\t"):
                    parts = raw.split(",")
                else:
                    parts = raw.split("\t")
                for part in parts[:3]:
                    add_gene(genes, part)
    except Exception:
        pass
    return genes


def genes_from_tar(path):
    genes = set()
    members = []
    try:
        with tarfile.open(path, "r:*") as tar:
            for member in tar.getmembers():
                name = member.name.lower()
                if any(token in name for token in ("features.tsv", "genes.tsv", "gene.tsv")):
                    members.append(member.name)
                    fileobj = tar.extractfile(member)
                    if fileobj:
                        stream = fileobj
                        if name.endswith(".gz"):
                            stream = gzip.GzipFile(fileobj=fileobj)
                        for i, raw in enumerate(stream):
                            if i > 300000:
                                break
                            if isinstance(raw, bytes):
                                line = raw.decode("utf-8", errors="ignore")
                            else:
                                line = str(raw)
                            parts = line.rstrip("\n").split("\t")
                            for part in parts[:3]:
                                add_gene(genes, part)
    except Exception:
        pass
    return genes, members


def genes_from_h5(path):
    genes = set()
    detail = []
    try:
        import h5py  # type: ignore
        with h5py.File(path, "r") as handle:
            possible = [
                "matrix/features/name",
                "matrix/features/id",
                "features/name",
                "features/id",
                "gene_names",
                "genes",
            ]
            for key in possible:
                if key in handle:
                    data = handle[key][:]
                    detail.append(key)
                    for item in data[:300000]:
                        if isinstance(item, bytes):
                            item = item.decode("utf-8", errors="ignore")
                        add_gene(genes, item)
    except Exception as exc:
        detail.append(f"h5py_unavailable_or_failed:{exc.__class__.__name__}")
        if command_exists("strings"):
            try:
                proc = subprocess.Popen(["strings", str(path)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, errors="ignore")
                assert proc.stdout is not None
                for i, line in enumerate(proc.stdout):
                    if i > 500000:
                        proc.kill()
                        break
                    add_gene(genes, line.strip())
                proc.wait(timeout=5)
                detail.append(f"strings_fallback_gene_like_entries={len(genes)}")
            except Exception as fallback_exc:
                detail.append(f"strings_fallback_failed:{fallback_exc.__class__.__name__}")
    return genes, detail


def command_exists(name):
    try:
        subprocess.run([name, "--version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        return True
    except Exception:
        return False


def xlsx_shared_strings(zipf):
    strings = []
    try:
        root = ET.fromstring(zipf.read("xl/sharedStrings.xml"))
    except Exception:
        return strings
    ns = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
    for si in root.findall("m:si", ns):
        texts = [t.text or "" for t in si.findall(".//m:t", ns)]
        strings.append("".join(texts))
    return strings


def genes_from_xlsx(path):
    genes = set()
    hit_rows = 0
    try:
        with zipfile.ZipFile(path) as zipf:
            shared = xlsx_shared_strings(zipf)
            sheets = [name for name in zipf.namelist() if name.startswith("xl/worksheets/sheet") and name.endswith(".xml")]
            ns = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
            for sheet in sheets[:5]:
                root = ET.fromstring(zipf.read(sheet))
                for row in root.findall(".//m:row", ns):
                    values = []
                    for cell in row.findall("m:c", ns):
                        ctype = cell.attrib.get("t")
                        v = cell.find("m:v", ns)
                        if v is None or v.text is None:
                            continue
                        text = v.text
                        if ctype == "s":
                            try:
                                text = shared[int(text)]
                            except Exception:
                                pass
                        values.append(text)
                    for value in values[:8]:
                        before = len(genes)
                        add_gene(genes, value)
                        if len(genes) > before:
                            hit_rows += 1
    except Exception:
        pass
    return genes, hit_rows


def inspect_dataset_files(dataset_dir):
    genes = set()
    notes = []
    files = []
    bytes_total = 0
    for path in sorted(Path(dataset_dir).glob("**/*")):
        if not path.is_file() or path.name.endswith(".log"):
            continue
        files.append(path)
        try:
            bytes_total += path.stat().st_size
        except OSError:
            pass
        suffixes = "".join(path.suffixes).lower()
        if suffixes.endswith(".tar") or ".tar." in suffixes:
            tar_genes, members = genes_from_tar(path)
            genes.update(tar_genes)
            notes.append(f"{path.name}:tar_gene_entries={len(tar_genes)} members={';'.join(members[:5])}")
        elif suffixes.endswith(".h5") or suffixes.endswith(".hdf5"):
            h5_genes, detail = genes_from_h5(path)
            genes.update(h5_genes)
            notes.append(f"{path.name}:h5_gene_entries={len(h5_genes)} detail={';'.join(detail[:3])}")
        elif suffixes.endswith(".xlsx"):
            xlsx_genes, hit_rows = genes_from_xlsx(path)
            genes.update(xlsx_genes)
            notes.append(f"{path.name}:xlsx_gene_like_entries={len(xlsx_genes)} rows={hit_rows}")
        elif any(suffixes.endswith(ext) for ext in (".tsv", ".tsv.gz", ".csv", ".csv.gz", ".txt", ".txt.gz")):
            text_genes = genes_from_text_file(path)
            genes.update(text_genes)
            notes.append(f"{path.name}:text_gene_like_entries={len(text_genes)}")
    return genes, files, bytes_total, notes


def marker_cell_types_for_gene(gene):
    hits = []
    for cell_type, markers in RP_CELL_MARKERS.items():
        if gene in {m.upper() for m in markers}:
            hits.append(cell_type)
    prior = GENE_CELL_PRIORS.get(gene)
    if prior:
        hits.extend(prior[0].split(";"))
    return sorted(set(hits))


def state_modules_for_gene(gene):
    return sorted(name for name, genes in STATE_MODULES.items() if gene in genes)


def wes_score(row):
    text = " ".join([row.get("classification", ""), row.get("conclusion", "")]).upper()
    score = 0
    if any(token in text for token in ("PAT", "PATHOGENIC", "致病")):
        score += 35
    if any(token in text for token in ("LIKELY", "LP", "可能")):
        score += 25
    if "VUS" in text or "UNCERTAIN" in text or "临床意义不明确" in text:
        score += 15
    if row.get("family_id"):
        score += 5
    return score


def build_scores(candidates, dataset_gene_sets, dataset_status):
    variant_rows = []
    evidence_rows = []
    gene_agg = {}

    disease_dataset_ids = [d for d in dataset_gene_sets if any(x in d.lower() for x in ("rd1", "rd10", "rpgr"))]
    normal_dataset_ids = [d for d in dataset_gene_sets if "normal" in d.lower() or "nsr" in d.lower()]

    for row in candidates:
        gene = row["gene"]
        base = wes_score(row)
        cell_types = marker_cell_types_for_gene(gene)
        modules = state_modules_for_gene(gene)
        normal_hits = [d for d in normal_dataset_ids if gene in dataset_gene_sets.get(d, set())]
        disease_hits = [d for d in disease_dataset_ids if gene in dataset_gene_sets.get(d, set())]
        any_hits = [d for d, genes in dataset_gene_sets.items() if gene in genes]
        prior = GENE_CELL_PRIORS.get(gene)

        expression_score = 0
        if cell_types:
            expression_score += 20
        if normal_hits:
            expression_score += 10
        if disease_hits:
            expression_score += 15 + 5 * min(len(disease_hits), 3)
        elif any_hits:
            expression_score += 5
        if modules:
            expression_score += 10
        if prior:
            expression_score += 10

        downgrade = []
        if not any_hits:
            downgrade.append("gene_not_observed_in_downloaded_matrices_or_supplements")
        if disease_hits and not normal_hits:
            downgrade.append("support_from_disease_model_only")
        if not cell_types:
            downgrade.append("no_marker_or_curated_cell_type_prior")
        if any("failed" == dataset_status.get(d, {}).get("status") for d in dataset_status):
            downgrade.append("one_or_more_dataset_downloads_failed")

        total = base + expression_score - 5 * len(downgrade)
        evidence = {
            "gene": gene,
            "family_id": row.get("family_id", ""),
            "sample_id": row.get("sample_id", ""),
            "variant": row.get("variant", ""),
            "wes_score": base,
            "scrna_support_score": expression_score,
            "total_priority_score": total,
            "cell_type_support": ";".join(cell_types),
            "state_module_support": ";".join(modules),
            "normal_dataset_hits": ";".join(normal_hits),
            "disease_dataset_hits": ";".join(disease_hits),
            "all_dataset_hits": ";".join(any_hits),
            "downgrade_flags": ";".join(sorted(set(downgrade))),
            "classification": row.get("classification", ""),
            "conclusion": row.get("conclusion", ""),
            "interpretation": build_interpretation(gene, cell_types, modules, disease_hits, downgrade),
        }
        evidence_rows.append(evidence)
        variant_rows.append(evidence.copy())

        agg = gene_agg.setdefault(gene, {
            "gene": gene,
            "variant_count": 0,
            "families": set(),
            "samples": set(),
            "best_total_priority_score": -999,
            "best_wes_score": 0,
            "best_scrna_support_score": 0,
            "cell_type_support": set(),
            "state_module_support": set(),
            "normal_dataset_hits": set(),
            "disease_dataset_hits": set(),
            "downgrade_flags": set(),
            "top_interpretation": "",
        })
        agg["variant_count"] += 1
        if row.get("family_id"):
            agg["families"].add(row["family_id"])
        if row.get("sample_id"):
            agg["samples"].add(row["sample_id"])
        if total > agg["best_total_priority_score"]:
            agg["best_total_priority_score"] = total
            agg["top_interpretation"] = evidence["interpretation"]
        agg["best_wes_score"] = max(agg["best_wes_score"], base)
        agg["best_scrna_support_score"] = max(agg["best_scrna_support_score"], expression_score)
        agg["cell_type_support"].update(cell_types)
        agg["state_module_support"].update(modules)
        agg["normal_dataset_hits"].update(normal_hits)
        agg["disease_dataset_hits"].update(disease_hits)
        agg["downgrade_flags"].update(downgrade)

    gene_rows = []
    for agg in gene_agg.values():
        gene_rows.append({
            "gene": agg["gene"],
            "best_total_priority_score": agg["best_total_priority_score"],
            "best_wes_score": agg["best_wes_score"],
            "best_scrna_support_score": agg["best_scrna_support_score"],
            "variant_count": agg["variant_count"],
            "family_count": len(agg["families"]),
            "sample_count": len(agg["samples"]),
            "family_ids": ";".join(sorted(agg["families"])),
            "cell_type_support": ";".join(sorted(agg["cell_type_support"])),
            "state_module_support": ";".join(sorted(agg["state_module_support"])),
            "normal_dataset_hits": ";".join(sorted(agg["normal_dataset_hits"])),
            "disease_dataset_hits": ";".join(sorted(agg["disease_dataset_hits"])),
            "downgrade_flags": ";".join(sorted(agg["downgrade_flags"])),
            "top_interpretation": agg["top_interpretation"],
        })

    gene_rows.sort(key=lambda r: (-float(r["best_total_priority_score"]), r["gene"]))
    variant_rows.sort(key=lambda r: (-float(r["total_priority_score"]), r["gene"], r["variant"]))
    evidence_rows.sort(key=lambda r: (-float(r["total_priority_score"]), r["gene"], r["variant"]))
    return gene_rows, variant_rows, evidence_rows


def build_interpretation(gene, cell_types, modules, disease_hits, downgrade):
    parts = []
    if cell_types:
        parts.append(f"{gene} has RP-relevant cell-type support: {', '.join(cell_types)}")
    if modules:
        parts.append(f"mechanism module: {', '.join(modules)}")
    if disease_hits:
        parts.append(f"observed in disease-model datasets: {', '.join(disease_hits)}")
    if not parts:
        parts.append(f"{gene} needs manual review before using scRNA as support")
    if downgrade:
        parts.append(f"limits: {', '.join(sorted(set(downgrade)))}")
    return "; ".join(parts)


def write_degrade_report(path, manifest_rows, status_map, dataset_summaries, candidates, gene_rows):
    downloaded = [d for d, s in status_map.items() if s.get("status") == "downloaded"]
    failed = [d for d, s in status_map.items() if s.get("status") == "failed"]
    summary_by_dataset = {row["dataset_id"]: row for row in dataset_summaries}
    manifest_by_dataset = {row.get("dataset_id", ""): row for row in manifest_rows}
    usable_downloads = []
    for dataset_id in downloaded:
        summary = summary_by_dataset.get(dataset_id, {})
        manifest = manifest_by_dataset.get(dataset_id, {})
        file_type = clean(manifest.get("file_type", "")).lower()
        gene_entries = int(summary.get("gene_entries", 0) or 0)
        if file_type == "html":
            continue
        if gene_entries > 0:
            usable_downloads.append(dataset_id)

    if len(usable_downloads) >= len(manifest_rows) and gene_rows:
        level = "complete"
    elif all(any(key in d for d in usable_downloads) for key in ("rpgr", "rd1", "rd10")) and gene_rows:
        level = "degrade_1_rpgr_rd1_rd10"
    elif any("rd1" in d for d in usable_downloads) and any("rd10" in d for d in usable_downloads) and gene_rows:
        level = "degrade_2_mouse_models"
    else:
        level = "degrade_3_manifest_or_partial_download"

    lines = [
        "# RP scRNA Degrade Report",
        "",
        f"- degrade_level: {level}",
        f"- downloaded_datasets: {', '.join(downloaded) if downloaded else 'none'}",
        f"- usable_downloads: {', '.join(usable_downloads) if usable_downloads else 'none'}",
        f"- failed_datasets: {', '.join(failed) if failed else 'none'}",
        f"- candidate_rows: {len(candidates)}",
        f"- ranked_genes: {len(gene_rows)}",
        "",
        "## Dataset Read Checks",
        "",
    ]
    for row in dataset_summaries:
        lines.append(f"- {row['dataset_id']}: status={row['download_status']}, files={row['file_count']}, bytes={row['bytes']}, gene_entries={row['gene_entries']}")
        if row.get("read_notes"):
            lines.append(f"  read_notes={row['read_notes'][:500]}")
    lines.extend([
        "",
        "## Interpretation Rule",
        "",
        "Single-cell evidence is used only as an RP interpretation-enhancement and candidate-prioritization layer. It does not replace ACMG classification, segregation, or clinical reporting evidence.",
        "",
        "## Next Runnable Step",
        "",
        "Rerun the GitLab job with WES_MODE=scRNA-rp-prioritization. Existing partial downloads are resumable because curl/wget uses continuation where supported.",
    ])
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--download-dir", required=True)
    parser.add_argument("--status", required=True)
    parser.add_argument("--candidate-table", default="")
    parser.add_argument("--out-dir", required=True)
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    manifest_rows = read_manifest(args.manifest)
    status_map = parse_download_status(args.status)

    dataset_gene_sets = {}
    dataset_summaries = []
    for row in manifest_rows:
        dataset_id = row.get("dataset_id", "")
        dataset_dir = Path(args.download_dir) / dataset_id
        genes, files, bytes_total, notes = inspect_dataset_files(dataset_dir)
        dataset_gene_sets[dataset_id] = genes
        dataset_summaries.append({
            "dataset_id": dataset_id,
            "accession": row.get("accession", ""),
            "model": row.get("model", ""),
            "download_status": status_map.get(dataset_id, {}).get("status", "not_attempted"),
            "file_count": len(files),
            "bytes": bytes_total,
            "gene_entries": len(genes),
            "read_notes": " | ".join(notes),
        })

    candidate_path = find_candidate_table(args.candidate_table)
    candidates = read_candidates(candidate_path)
    if not candidates:
        # Keep the pipeline useful even before WES candidate tables are mounted.
        for gene in ["RPGR", "PDE6B", "RHO", "USH2A", "CRB1", "EYS", "RPE65"]:
            candidates.append({"family_id": "", "sample_id": "", "gene": gene, "variant": "", "classification": "", "conclusion": "fallback_seed", "source_row": "{}"})

    gene_rows, variant_rows, evidence_rows = build_scores(candidates, dataset_gene_sets, status_map)

    write_tsv(out_dir / "read_check.tsv", dataset_summaries)
    write_tsv(out_dir / "gene_priority_ranking.tsv", gene_rows)
    write_tsv(out_dir / "variant_priority_ranking.tsv", variant_rows)
    write_tsv(out_dir / "evidence_breakdown.tsv", evidence_rows)
    write_degrade_report(out_dir / "degrade_report.md", manifest_rows, status_map, dataset_summaries, candidates, gene_rows)

    summary = {
        "candidate_table": str(candidate_path) if candidate_path else "",
        "candidate_rows": len(candidates),
        "ranked_genes": len(gene_rows),
        "datasets": dataset_summaries,
        "top_genes": gene_rows[:20],
    }
    (out_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({
        "candidate_rows": len(candidates),
        "ranked_genes": len(gene_rows),
        "outputs": [
            str(out_dir / "read_check.tsv"),
            str(out_dir / "gene_priority_ranking.tsv"),
            str(out_dir / "variant_priority_ranking.tsv"),
            str(out_dir / "evidence_breakdown.tsv"),
            str(out_dir / "degrade_report.md"),
        ],
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
