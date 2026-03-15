import fs from "node:fs";
import path from "node:path";

const args = process.argv.slice(2);

function getArg(flag, fallback = "") {
  const index = args.indexOf(flag);
  if (index === -1 || index === args.length - 1) {
    return fallback;
  }
  return args[index + 1];
}

const OUT_DIR = path.resolve(getArg("--out-dir", path.join("output", "wes", "results")));
const REPORT_DIR = path.resolve(getArg("--report-dir", path.join(OUT_DIR, "qc-report")));
const SAMPLE_SHEET = getArg("--sample-sheet", "");
const ONLY_COMPLETED = args.includes("--only-completed");

function readText(file) { return fs.readFileSync(file, "utf8"); }
function readJson(file) { return JSON.parse(readText(file)); }
function exists(file) { return fs.existsSync(file); }
function toNumber(value) {
  if (value === null || value === undefined || value === "") return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}
function round(value, digits = 2) {
  if (!Number.isFinite(value)) return null;
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}
function percent(numerator, denominator) {
  if (!Number.isFinite(numerator) || !Number.isFinite(denominator) || denominator === 0) return null;
  return (numerator / denominator) * 100;
}
function listFiles(dir, suffix) {
  if (!exists(dir)) return [];
  return fs.readdirSync(dir).filter((name) => name.endsWith(suffix)).map((name) => path.join(dir, name)).sort();
}
function parseKeyValueFile(file) {
  const result = {};
  for (const line of readText(file).split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || !trimmed.includes("=")) continue;
    const [key, ...rest] = trimmed.split("=");
    result[key] = rest.join("=");
  }
  return result;
}
function parseMarkdupMetrics(file) {
  const lines = readText(file).split(/\r?\n/);
  let header = null;
  let values = null;
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i].trim();
    if (line.startsWith("LIBRARY\tUNPAIRED_READS_EXAMINED\tREAD_PAIRS_EXAMINED")) {
      header = line.split("\t");
      values = (lines[i + 1] || "").trim().split("\t");
      break;
    }
  }
  if (!header || !values || header.length !== values.length) return {};
  const row = {};
  header.forEach((key, index) => { row[key] = values[index]; });
  return row;
}
function readManifestSamples(file) {
  if (!exists(file)) return [];
  const data = parseKeyValueFile(file);
  return String(data.sample_ids || "").split(",").map((item) => item.trim()).filter(Boolean);
}
function readSampleSheet(file) {
  if (!file || !exists(file)) return [];
  return readText(file)
    .split(/\r?\n/)
    .filter(Boolean)
    .slice(1)
    .map((line) => line.split("\t"))
    .filter((cols) => cols[0])
    .map((cols) => ({
      sample_id: cols[0] || "",
      family_id: cols[1] || "",
      role: cols[2] || "",
      affected: cols[3] || "",
      fastq_r1: cols[4] || "",
      fastq_r2: cols[5] || "",
      bam_path: cols[6] || ""
    }));
}
function collectFastp(sampleId) {
  const file = path.join(OUT_DIR, "qc", `${sampleId}.fastp.json`);
  if (!exists(file)) return {};
  const data = readJson(file);
  const summary = data.summary || {};
  const before = summary.before_filtering || {};
  const after = summary.after_filtering || {};
  return {
    fastp_json: file,
    fastp_input_reads: toNumber(before.total_reads),
    fastp_output_reads: toNumber(after.total_reads),
    fastp_input_bases: toNumber(before.total_bases),
    fastp_output_bases: toNumber(after.total_bases),
    fastp_q30_rate: round((after.q30_rate || 0) * 100, 2),
    fastp_gc_content: round((after.gc_content || 0) * 100, 2),
    fastp_retained_read_pct: round(percent(after.total_reads, before.total_reads), 2)
  };
}
function collectMarkdup(sampleId) {
  const file = path.join(OUT_DIR, "bam", `${sampleId}.markdup.metrics.txt`);
  if (!exists(file)) return {};
  const row = parseMarkdupMetrics(file);
  return {
    markdup_metrics: file,
    read_pairs_examined: toNumber(row.READ_PAIRS_EXAMINED),
    percent_duplication: round((toNumber(row.PERCENT_DUPLICATION) || 0) * 100, 2),
    estimated_library_size: toNumber(row.ESTIMATED_LIBRARY_SIZE),
    unpaired_reads_examined: toNumber(row.UNPAIRED_READS_EXAMINED),
    unmapped_reads: toNumber(row.UNMAPPED_READS),
    unpaired_read_duplicates: toNumber(row.UNPAIRED_READ_DUPLICATES),
    read_pair_duplicates: toNumber(row.READ_PAIR_DUPLICATES)
  };
}
function inferBam(sampleId) {
  const candidates = [
    path.join(OUT_DIR, "bam", `${sampleId}.bqsr.bam`),
    path.join(OUT_DIR, "bam", `${sampleId}.markdup.bam`),
    path.join(OUT_DIR, "bam", `${sampleId}.sorted.bam`)
  ];
  return candidates.find((file) => exists(file)) || "";
}
function inferGvcf(sampleId) {
  const file = path.join(OUT_DIR, "gvcf", `${sampleId}.g.vcf.gz`);
  return exists(file) ? file : "";
}
function csvEscape(value) {
  const text = String(value ?? "");
  if (/[",\n]/.test(text)) return `"${text.replace(/"/g, '""')}"`;
  return text;
}
function buildCsv(rows, columns) {
  const lines = [columns.join(","), ...rows.map((row) => columns.map((key) => csvEscape(row[key])).join(","))];
  return `${lines.join("\n")}\n`;
}
function escapeHtml(value) {
  return String(value ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
function valueForChart(row, key) { const value = row[key]; return Number.isFinite(value) ? value : null; }
function renderBars(rows, key, label) {
  const chartRows = rows.map((row) => ({ sample: row.sample_id, value: valueForChart(row, key) })).filter((row) => row.value !== null);
  const max = Math.max(...chartRows.map((row) => row.value), 0);
  if (chartRows.length === 0) return `<p class="empty">No data for ${escapeHtml(label)}.</p>`;
  return chartRows.map((row) => {
    const width = max > 0 ? Math.max((row.value / max) * 100, 3) : 0;
    return `<div class="bar-row"><div class="bar-label">${escapeHtml(row.sample)}</div><div class="bar-track"><div class="bar-fill" style="width:${width}%"></div></div><div class="bar-value">${escapeHtml(row.value)}</div></div>`;
  }).join("\n");
}
function renderTable(rows, columns) {
  const headers = columns.map((column) => `<th>${escapeHtml(column)}</th>`).join("");
  const body = rows.map((row) => `<tr>${columns.map((column) => `<td>${escapeHtml(row[column])}</td>`).join("")}</tr>`).join("\n");
  return `<table><thead><tr>${headers}</tr></thead><tbody>${body}</tbody></table>`;
}

const sampleMetaFiles = listFiles(path.join(OUT_DIR, "gvcf"), ".meta.txt");
const metaMap = new Map(sampleMetaFiles.map((file) => { const meta = parseKeyValueFile(file); return [meta.sample_id, meta]; }));
const sheetRows = readSampleSheet(SAMPLE_SHEET);
const sheetMap = new Map(sheetRows.map((row) => [row.sample_id, row]));
const manifestSamples = readManifestSamples(path.join(OUT_DIR, "run.manifest.txt"));
const sampleIds = sheetRows.length > 0 ? sheetRows.map((row) => row.sample_id) : Array.from(new Set([...manifestSamples, ...metaMap.keys()])).sort();

let rows = sampleIds.map((sampleId) => {
  const meta = metaMap.get(sampleId) || {};
  const sheet = sheetMap.get(sampleId) || {};
  const bam = meta.bam || inferBam(sampleId) || sheet.bam_path || "";
  const gvcf = meta.gvcf || inferGvcf(sampleId) || "";
  const row = {
    sample_id: sampleId,
    family_id: meta.family_id || sheet.family_id || "",
    role: meta.role || sheet.role || "",
    affected: meta.affected || sheet.affected || "",
    bam,
    gvcf,
    has_bam: bam ? 1 : 0,
    has_gvcf: gvcf ? 1 : 0,
    ...collectFastp(sampleId),
    ...collectMarkdup(sampleId)
  };
  row.has_fastp = row.fastp_json ? 1 : 0;
  row.has_markdup_metrics = row.markdup_metrics ? 1 : 0;
  row.preprocess_status = row.has_bam || row.has_markdup_metrics ? "completed" : "missing";
  return row;
});

if (ONLY_COMPLETED) rows = rows.filter((row) => row.preprocess_status === "completed");

const summary = {
  generated_at: new Date().toISOString(),
  out_dir: OUT_DIR,
  sample_sheet: SAMPLE_SHEET ? path.resolve(SAMPLE_SHEET) : "",
  sample_count: rows.length,
  family_count: new Set(rows.map((row) => row.family_id).filter(Boolean)).size,
  affected_count: rows.filter((row) => String(row.affected) === "1").length,
  unaffected_count: rows.filter((row) => String(row.affected) === "0").length,
  preprocess_completed: rows.filter((row) => row.preprocess_status === "completed").length,
  preprocess_missing: rows.filter((row) => row.preprocess_status !== "completed").length,
  samples_with_gvcf: rows.filter((row) => row.gvcf).length,
  samples_with_fastp: rows.filter((row) => Number.isFinite(row.fastp_output_reads)).length,
  samples_with_markdup_metrics: rows.filter((row) => Number.isFinite(row.percent_duplication)).length
};

const columns = ["sample_id","family_id","role","affected","preprocess_status","has_bam","has_fastp","has_markdup_metrics","has_gvcf","fastp_input_reads","fastp_output_reads","fastp_retained_read_pct","fastp_q30_rate","fastp_gc_content","read_pairs_examined","percent_duplication","estimated_library_size","bam","gvcf"];
const markdown = [
  "# WES QC Summary",
  "",
  `- generated_at: ${summary.generated_at}`,
  `- out_dir: ${summary.out_dir}`,
  `- sample_sheet: ${summary.sample_sheet}`,
  `- sample_count: ${summary.sample_count}`,
  `- preprocess_completed: ${summary.preprocess_completed}`,
  `- preprocess_missing: ${summary.preprocess_missing}`,
  `- family_count: ${summary.family_count}`,
  `- affected_count: ${summary.affected_count}`,
  `- unaffected_count: ${summary.unaffected_count}`,
  `- samples_with_gvcf: ${summary.samples_with_gvcf}`,
  `- samples_with_fastp: ${summary.samples_with_fastp}`,
  `- samples_with_markdup_metrics: ${summary.samples_with_markdup_metrics}`,
  "",
  "## Sample Table",
  "",
  `CSV: ${path.join(REPORT_DIR, "wes-qc-summary.csv")}`
].join("\n");

const completedRows = rows.filter((row) => row.preprocess_status === "completed");
const html = `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" /><title>WES QC Summary</title><style>:root { --bg: #f2efe8; --panel: #fffcf6; --ink: #1f2937; --muted: #6b7280; --line: #e5ddcf; --accent: #9a3412; --accent-soft: #f59e0b; } * { box-sizing: border-box; } body { margin: 0; color: var(--ink); font-family: "Segoe UI", "PingFang SC", sans-serif; background: linear-gradient(180deg, #f8f4ec, var(--bg)); } .wrap { max-width: 1280px; margin: 0 auto; padding: 28px 18px 48px; } .hero, .panel { background: var(--panel); border: 1px solid var(--line); border-radius: 22px; box-shadow: 0 12px 28px rgba(15, 23, 42, 0.06); } .hero { padding: 24px; margin-bottom: 18px; background: linear-gradient(135deg, rgba(154,52,18,.98), rgba(120,53,15,.92)); color: white; } .hero h1 { margin: 0 0 8px; font-size: 32px; } .hero p { margin: 0; color: rgba(255,255,255,.84); } .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 14px; margin-bottom: 18px; } .card { background: var(--panel); border: 1px solid var(--line); border-radius: 20px; padding: 16px 18px; } .label { color: var(--muted); font-size: 13px; margin-bottom: 8px; } .value { font-size: 28px; font-weight: 700; } .layout { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 16px; margin-bottom: 18px; } .panel { padding: 18px; } h2 { margin: 0 0 12px; font-size: 20px; } .bar-row { display: grid; grid-template-columns: 180px 1fr 64px; gap: 12px; align-items: center; margin: 10px 0; } .bar-track { height: 12px; background: #f5ead7; border-radius: 999px; overflow: hidden; } .bar-fill { height: 100%; border-radius: 999px; background: linear-gradient(90deg, var(--accent), var(--accent-soft)); } .bar-label, .bar-value, table { font-size: 14px; } table { width: 100%; border-collapse: collapse; } th, td { padding: 10px 8px; text-align: left; border-bottom: 1px solid var(--line); } th { color: var(--muted); position: sticky; top: 0; background: var(--panel); } .table-wrap { max-height: 520px; overflow: auto; } .empty { color: var(--muted); margin: 0; }</style></head><body><div class="wrap"><section class="hero"><h1>WES QC Summary</h1><p>Shared staged output snapshot across completed preprocess samples.</p></section><section class="grid"><div class="card"><div class="label">Samples</div><div class="value">${summary.sample_count}</div></div><div class="card"><div class="label">Preprocess completed</div><div class="value">${summary.preprocess_completed}</div></div><div class="card"><div class="label">Preprocess missing</div><div class="value">${summary.preprocess_missing}</div></div><div class="card"><div class="label">Families</div><div class="value">${summary.family_count}</div></div><div class="card"><div class="label">Affected</div><div class="value">${summary.affected_count}</div></div><div class="card"><div class="label">With fastp QC</div><div class="value">${summary.samples_with_fastp}</div></div><div class="card"><div class="label">With duplication metrics</div><div class="value">${summary.samples_with_markdup_metrics}</div></div><div class="card"><div class="label">With gVCF</div><div class="value">${summary.samples_with_gvcf}</div></div></section><section class="layout"><div class="panel"><h2>fastp retained reads (%)</h2>${renderBars(completedRows, "fastp_retained_read_pct", "fastp_retained_read_pct")}</div><div class="panel"><h2>fastp Q30 (%)</h2>${renderBars(completedRows, "fastp_q30_rate", "fastp_q30_rate")}</div><div class="panel"><h2>GC content (%)</h2>${renderBars(completedRows, "fastp_gc_content", "fastp_gc_content")}</div><div class="panel"><h2>Duplication (%)</h2>${renderBars(completedRows, "percent_duplication", "percent_duplication")}</div></section><section class="panel"><h2>Per-sample QC table</h2><div class="table-wrap">${renderTable(rows, columns)}</div></section></div></body></html>`;

fs.mkdirSync(REPORT_DIR, { recursive: true });
fs.writeFileSync(path.join(REPORT_DIR, "wes-qc-summary.json"), JSON.stringify({ summary, rows }, null, 2));
fs.writeFileSync(path.join(REPORT_DIR, "wes-qc-summary.csv"), buildCsv(rows, columns), "utf8");
fs.writeFileSync(path.join(REPORT_DIR, "wes-qc-summary.md"), `${markdown}\n`, "utf8");
fs.writeFileSync(path.join(REPORT_DIR, "wes-qc-summary.html"), html, "utf8");
console.log(`WES QC report written to ${REPORT_DIR}`);
