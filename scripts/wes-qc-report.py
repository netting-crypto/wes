#!/usr/bin/env python3
import argparse
import csv
import html
import json
from datetime import datetime, timezone
from pathlib import Path


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def read_json(path: Path):
    return json.loads(read_text(path))


def to_number(value):
    if value in (None, ""):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def round_value(value, digits=2):
    if value is None:
        return None
    return round(value, digits)


def percent(numerator, denominator):
    if numerator is None or denominator in (None, 0):
        return None
    return (numerator / denominator) * 100


def parse_key_value_file(path: Path):
    result = {}
    for line in read_text(path).splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        result[key.strip()] = value.strip()
    return result


def parse_markdup_metrics(path: Path):
    header = None
    values = None
    for line in read_text(path).splitlines():
        stripped = line.strip()
        if stripped.startswith("LIBRARY\tUNPAIRED_READS_EXAMINED\tREAD_PAIRS_EXAMINED"):
            header = stripped.split("\t")
            continue
        if header and stripped and not stripped.startswith("#"):
            values = stripped.split("\t")
            break
    if not header or not values or len(header) != len(values):
        return {}
    return dict(zip(header, values))


def read_sample_sheet(path: Path):
    if not path.exists():
        return []
    rows = []
    with path.open("r", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            sample_id = (row.get("sample_id") or "").strip()
            if not sample_id:
                continue
            rows.append(
                {
                    "sample_id": sample_id,
                    "family_id": (row.get("family_id") or "").strip(),
                    "role": (row.get("role") or "").strip(),
                    "affected": (row.get("affected") or "").strip(),
                    "fastq_r1": (row.get("fastq_r1") or "").strip(),
                    "fastq_r2": (row.get("fastq_r2") or "").strip(),
                    "bam_path": (row.get("bam_path") or "").strip(),
                }
            )
    return rows


def collect_fastp(out_dir: Path, sample_id: str):
    path = out_dir / "qc" / f"{sample_id}.fastp.json"
    if not path.exists():
        return {}
    data = read_json(path)
    before = (((data or {}).get("summary") or {}).get("before_filtering") or {})
    after = (((data or {}).get("summary") or {}).get("after_filtering") or {})
    return {
        "fastp_json": str(path),
        "fastp_input_reads": to_number(before.get("total_reads")),
        "fastp_output_reads": to_number(after.get("total_reads")),
        "fastp_input_bases": to_number(before.get("total_bases")),
        "fastp_output_bases": to_number(after.get("total_bases")),
        "fastp_q30_rate": round_value(to_number((after.get("q30_rate"))), 4),
        "fastp_gc_content": round_value(to_number((after.get("gc_content"))), 4),
        "fastp_retained_read_pct": round_value(
            percent(to_number(after.get("total_reads")), to_number(before.get("total_reads"))), 2
        ),
    }


def collect_markdup(out_dir: Path, sample_id: str):
    path = out_dir / "bam" / f"{sample_id}.markdup.metrics.txt"
    if not path.exists():
        return {}
    row = parse_markdup_metrics(path)
    return {
        "markdup_metrics": str(path),
        "read_pairs_examined": to_number(row.get("READ_PAIRS_EXAMINED")),
        "percent_duplication": round_value((to_number(row.get("PERCENT_DUPLICATION")) or 0) * 100, 2),
        "estimated_library_size": to_number(row.get("ESTIMATED_LIBRARY_SIZE")),
        "unpaired_reads_examined": to_number(row.get("UNPAIRED_READS_EXAMINED")),
        "unmapped_reads": to_number(row.get("UNMAPPED_READS")),
        "unpaired_read_duplicates": to_number(row.get("UNPAIRED_READ_DUPLICATES")),
        "read_pair_duplicates": to_number(row.get("READ_PAIR_DUPLICATES")),
    }


def infer_bam(out_dir: Path, sample_id: str):
    for suffix in ("bqsr.bam", "markdup.bam", "sorted.bam"):
        candidate = out_dir / "bam" / f"{sample_id}.{suffix}"
        if candidate.exists():
            return str(candidate)
    return ""


def infer_gvcf(out_dir: Path, sample_id: str):
    candidate = out_dir / "gvcf" / f"{sample_id}.g.vcf.gz"
    return str(candidate) if candidate.exists() else ""


def render_bars(rows, key, label):
    chart_rows = [(row["sample_id"], row.get(key)) for row in rows if isinstance(row.get(key), (int, float))]
    if not chart_rows:
        return f'<p class="empty">No data for {html.escape(label)}.</p>'
    max_value = max(value for _, value in chart_rows) or 0
    bars = []
    for sample, value in chart_rows:
        width = max((value / max_value) * 100, 3) if max_value else 0
        bars.append(
            f'<div class="bar-row"><div class="bar-label">{html.escape(sample)}</div>'
            f'<div class="bar-track"><div class="bar-fill" style="width:{width}%"></div></div>'
            f'<div class="bar-value">{html.escape(str(value))}</div></div>'
        )
    return "\n".join(bars)


def render_table(rows, columns):
    headers = "".join(f"<th>{html.escape(column)}</th>" for column in columns)
    body = []
    for row in rows:
        cells = "".join(f"<td>{html.escape(str(row.get(column, '')))}</td>" for column in columns)
        body.append(f"<tr>{cells}</tr>")
    return f"<table><thead><tr>{headers}</tr></thead><tbody>{''.join(body)}</tbody></table>"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", default=str(Path("output") / "wes" / "results"))
    parser.add_argument("--report-dir", default="")
    parser.add_argument("--sample-sheet", default="")
    parser.add_argument("--only-completed", action="store_true")
    args = parser.parse_args()

    out_dir = Path(args.out_dir).resolve()
    report_dir = Path(args.report_dir).resolve() if args.report_dir else out_dir / "qc-report"
    sample_sheet = Path(args.sample_sheet).resolve() if args.sample_sheet else None

    meta_map = {}
    for meta_path in sorted((out_dir / "gvcf").glob("*.meta.txt")) if (out_dir / "gvcf").exists() else []:
        meta = parse_key_value_file(meta_path)
        sample_id = meta.get("sample_id")
        if sample_id:
            meta_map[sample_id] = meta

    sheet_rows = read_sample_sheet(sample_sheet) if sample_sheet else []
    sheet_map = {row["sample_id"]: row for row in sheet_rows}

    manifest_samples = []
    manifest_path = out_dir / "run.manifest.txt"
    if manifest_path.exists():
        manifest = parse_key_value_file(manifest_path)
        manifest_samples = [item.strip() for item in manifest.get("sample_ids", "").split(",") if item.strip()]

    if sheet_rows:
        sample_ids = [row["sample_id"] for row in sheet_rows]
    else:
        sample_ids = sorted(set(manifest_samples) | set(meta_map.keys()))

    rows = []
    for sample_id in sample_ids:
        meta = meta_map.get(sample_id, {})
        sheet = sheet_map.get(sample_id, {})
        bam = meta.get("bam") or infer_bam(out_dir, sample_id) or sheet.get("bam_path", "")
        gvcf = meta.get("gvcf") or infer_gvcf(out_dir, sample_id)
        row = {
            "sample_id": sample_id,
            "family_id": meta.get("family_id") or sheet.get("family_id", ""),
            "role": meta.get("role") or sheet.get("role", ""),
            "affected": meta.get("affected") or sheet.get("affected", ""),
            "bam": bam,
            "gvcf": gvcf,
            "has_bam": 1 if bam else 0,
            "has_gvcf": 1 if gvcf else 0,
        }
        row.update(collect_fastp(out_dir, sample_id))
        row.update(collect_markdup(out_dir, sample_id))
        row["has_fastp"] = 1 if row.get("fastp_json") else 0
        row["has_markdup_metrics"] = 1 if row.get("markdup_metrics") else 0
        row["preprocess_status"] = "completed" if row["has_bam"] or row["has_markdup_metrics"] else "missing"
        rows.append(row)

    if args.only_completed:
        rows = [row for row in rows if row["preprocess_status"] == "completed"]

    summary = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "out_dir": str(out_dir),
        "sample_sheet": str(sample_sheet) if sample_sheet else "",
        "sample_count": len(rows),
        "family_count": len({row["family_id"] for row in rows if row["family_id"]}),
        "affected_count": sum(1 for row in rows if str(row["affected"]) == "1"),
        "unaffected_count": sum(1 for row in rows if str(row["affected"]) == "0"),
        "preprocess_completed": sum(1 for row in rows if row["preprocess_status"] == "completed"),
        "preprocess_missing": sum(1 for row in rows if row["preprocess_status"] != "completed"),
        "samples_with_gvcf": sum(1 for row in rows if row["gvcf"]),
        "samples_with_fastp": sum(1 for row in rows if row.get("fastp_output_reads") is not None),
        "samples_with_markdup_metrics": sum(1 for row in rows if row.get("percent_duplication") is not None),
    }

    columns = [
        "sample_id",
        "family_id",
        "role",
        "affected",
        "preprocess_status",
        "has_bam",
        "has_fastp",
        "has_markdup_metrics",
        "has_gvcf",
        "fastp_input_reads",
        "fastp_output_reads",
        "fastp_input_bases",
        "fastp_output_bases",
        "fastp_retained_read_pct",
        "fastp_q30_rate",
        "fastp_gc_content",
        "read_pairs_examined",
        "percent_duplication",
        "estimated_library_size",
        "unpaired_reads_examined",
        "unmapped_reads",
        "unpaired_read_duplicates",
        "read_pair_duplicates",
        "fastp_json",
        "markdup_metrics",
        "bam",
        "gvcf",
    ]

    completed_rows = [row for row in rows if row["preprocess_status"] == "completed"]
    markdown = "\n".join(
        [
            "# WES QC Summary",
            "",
            f"- generated_at: {summary['generated_at']}",
            f"- out_dir: {summary['out_dir']}",
            f"- sample_sheet: {summary['sample_sheet']}",
            f"- sample_count: {summary['sample_count']}",
            f"- preprocess_completed: {summary['preprocess_completed']}",
            f"- preprocess_missing: {summary['preprocess_missing']}",
            f"- family_count: {summary['family_count']}",
            f"- affected_count: {summary['affected_count']}",
            f"- unaffected_count: {summary['unaffected_count']}",
            f"- samples_with_gvcf: {summary['samples_with_gvcf']}",
            f"- samples_with_fastp: {summary['samples_with_fastp']}",
            f"- samples_with_markdup_metrics: {summary['samples_with_markdup_metrics']}",
            "",
            f"HTML: {report_dir / 'wes-qc-summary.html'}",
            f"CSV: {report_dir / 'wes-qc-summary.csv'}",
        ]
    )

    html_text = f"""<!doctype html><html lang="zh-CN"><head><meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" /><title>WES QC Summary</title><style>:root {{ --bg: #f2efe8; --panel: #fffcf6; --ink: #1f2937; --muted: #6b7280; --line: #e5ddcf; --accent: #9a3412; --accent-soft: #f59e0b; }} * {{ box-sizing: border-box; }} body {{ margin: 0; color: var(--ink); font-family: "Segoe UI", "PingFang SC", sans-serif; background: linear-gradient(180deg, #f8f4ec, var(--bg)); }} .wrap {{ max-width: 1280px; margin: 0 auto; padding: 28px 18px 48px; }} .hero, .panel {{ background: var(--panel); border: 1px solid var(--line); border-radius: 22px; box-shadow: 0 12px 28px rgba(15, 23, 42, 0.06); }} .hero {{ padding: 24px; margin-bottom: 18px; background: linear-gradient(135deg, rgba(154,52,18,.98), rgba(120,53,15,.92)); color: white; }} .hero h1 {{ margin: 0 0 8px; font-size: 32px; }} .hero p {{ margin: 0; color: rgba(255,255,255,.84); }} .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 14px; margin-bottom: 18px; }} .card {{ background: var(--panel); border: 1px solid var(--line); border-radius: 20px; padding: 16px 18px; }} .label {{ color: var(--muted); font-size: 13px; margin-bottom: 8px; }} .value {{ font-size: 28px; font-weight: 700; }} .layout {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 16px; margin-bottom: 18px; }} .panel {{ padding: 18px; }} h2 {{ margin: 0 0 12px; font-size: 20px; }} .bar-row {{ display: grid; grid-template-columns: 180px 1fr 64px; gap: 12px; align-items: center; margin: 10px 0; }} .bar-track {{ height: 12px; background: #f5ead7; border-radius: 999px; overflow: hidden; }} .bar-fill {{ height: 100%; border-radius: 999px; background: linear-gradient(90deg, var(--accent), var(--accent-soft)); }} .bar-label, .bar-value, table {{ font-size: 14px; }} table {{ width: 100%; border-collapse: collapse; }} th, td {{ padding: 10px 8px; text-align: left; border-bottom: 1px solid var(--line); }} th {{ color: var(--muted); position: sticky; top: 0; background: var(--panel); }} .table-wrap {{ max-height: 520px; overflow: auto; }} .empty {{ color: var(--muted); margin: 0; }}</style></head><body><div class="wrap"><section class="hero"><h1>WES QC Summary</h1><p>Shared staged output snapshot across completed preprocess samples.</p></section><section class="grid"><div class="card"><div class="label">Samples</div><div class="value">{summary['sample_count']}</div></div><div class="card"><div class="label">Preprocess completed</div><div class="value">{summary['preprocess_completed']}</div></div><div class="card"><div class="label">Preprocess missing</div><div class="value">{summary['preprocess_missing']}</div></div><div class="card"><div class="label">Families</div><div class="value">{summary['family_count']}</div></div><div class="card"><div class="label">Affected</div><div class="value">{summary['affected_count']}</div></div><div class="card"><div class="label">With fastp QC</div><div class="value">{summary['samples_with_fastp']}</div></div><div class="card"><div class="label">With duplication metrics</div><div class="value">{summary['samples_with_markdup_metrics']}</div></div><div class="card"><div class="label">With gVCF</div><div class="value">{summary['samples_with_gvcf']}</div></div></section><section class="layout"><div class="panel"><h2>fastp retained reads (%)</h2>{render_bars(completed_rows, 'fastp_retained_read_pct', 'fastp_retained_read_pct')}</div><div class="panel"><h2>fastp Q30 (%)</h2>{render_bars(completed_rows, 'fastp_q30_rate', 'fastp_q30_rate')}</div><div class="panel"><h2>GC content (%)</h2>{render_bars(completed_rows, 'fastp_gc_content', 'fastp_gc_content')}</div><div class="panel"><h2>Duplication (%)</h2>{render_bars(completed_rows, 'percent_duplication', 'percent_duplication')}</div></section><section class="panel"><h2>Per-sample QC table</h2><div class="table-wrap">{render_table(rows, columns)}</div></section></div></body></html>"""

    report_dir.mkdir(parents=True, exist_ok=True)
    (report_dir / "wes-qc-summary.json").write_text(
        json.dumps({"summary": summary, "rows": rows}, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    with (report_dir / "wes-qc-summary.csv").open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)
    (report_dir / "wes-qc-summary.md").write_text(markdown + "\n", encoding="utf-8")
    (report_dir / "wes-qc-summary.html").write_text(html_text, encoding="utf-8")
    print(f"WES QC report written to {report_dir}")


if __name__ == "__main__":
    main()
