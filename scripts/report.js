import fs from "node:fs";
import path from "node:path";

const OUTPUT_DIR = process.env.OUTPUT_DIR ? path.resolve(process.env.OUTPUT_DIR) : path.resolve("output", "reports");
const SUMMARY_PATH = path.join(OUTPUT_DIR, "summary.json");
const STATS_PATH = path.join(OUTPUT_DIR, "stats.json");
const REPORT_PATH = path.join(OUTPUT_DIR, "summary.html");
const MARKDOWN_PATH = path.join(OUTPUT_DIR, "summary.md");

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function countBy(items, getKey) {
  const map = new Map();
  for (const item of items) {
    const key = getKey(item);
    map.set(key, (map.get(key) || 0) + 1);
  }
  return [...map.entries()].sort((a, b) => b[1] - a[1]);
}

function sumHours(records) {
  return records.reduce((sum, item) => {
    const match = String(item.testHours ?? "").match(/\d+(\.\d+)?/);
    return sum + (match ? Number(match[0]) : 0);
  }, 0);
}

function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/\"/g, "&quot;");
}

function renderBarChart(items, maxValue) {
  return items.map(([label, value]) => {
    const width = maxValue > 0 ? Math.max((value / maxValue) * 100, 6) : 0;
    return `<div class="bar-row"><div class="bar-label">${escapeHtml(label)}</div><div class="bar-track"><div class="bar-fill" style="width:${width}%"></div></div><div class="bar-value">${value}</div></div>`;
  }).join("\n");
}

function renderTableRows(records) {
  return records.map((item) => `<tr>
    <td>${escapeHtml(item.recordNumber)}</td>
    <td>${escapeHtml(item.instrumentName)}</td>
    <td>${escapeHtml(item.sampleName)}</td>
    <td>${escapeHtml(item.sampleCount)}</td>
    <td>${escapeHtml(item.testHours)}</td>
    <td>${item.isLocked ? "已锁定" : "已更新/可更新"}</td>
  </tr>`).join("\n");
}

if (!fs.existsSync(SUMMARY_PATH)) {
  throw new Error(`缺少 ${SUMMARY_PATH}，请先运行 npm run run`);
}

const records = readJson(SUMMARY_PATH);
const stats = fs.existsSync(STATS_PATH) ? readJson(STATS_PATH) : {
  generatedAt: new Date().toISOString(),
  totalRecords: records.length,
  lockedRecords: records.filter((item) => item.isLocked).length,
  updatedRecords: records.filter((item) => !item.isLocked && item.editUrl).length,
  excelFiles: records.length
};

const instrumentCounts = countBy(records, (item) => item.instrumentName || "未命名仪器").slice(0, 8);
const statusCounts = [
  ["已锁定", records.filter((item) => item.isLocked).length],
  ["可更新", records.filter((item) => !item.isLocked).length]
];
const totalHours = sumHours(records).toFixed(1);
const topInstrumentMax = Math.max(...instrumentCounts.map(([, value]) => value), 0);
const statusMax = Math.max(...statusCounts.map(([, value]) => value), 0);

const html = `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>任务初步结果报告</title>
  <style>
    :root {
      --bg: #f3efe7;
      --panel: #fffdf8;
      --ink: #1f2a37;
      --muted: #6b7280;
      --accent: #b45309;
      --accent-soft: #f59e0b;
      --line: #eadfce;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "Segoe UI", "PingFang SC", sans-serif;
      color: var(--ink);
      background: radial-gradient(circle at top left, #fff7ed, var(--bg) 45%, #efe7da 100%);
    }
    .wrap {
      max-width: 1200px;
      margin: 0 auto;
      padding: 32px 20px 48px;
    }
    .hero {
      background: linear-gradient(135deg, rgba(180,83,9,.95), rgba(120,53,15,.9));
      color: white;
      padding: 28px;
      border-radius: 24px;
      box-shadow: 0 20px 50px rgba(120,53,15,.18);
      margin-bottom: 22px;
    }
    .hero h1 { margin: 0 0 8px; font-size: 34px; }
    .hero p { margin: 0; color: rgba(255,255,255,.82); }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 16px;
      margin-bottom: 22px;
    }
    .card, .panel {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 20px;
      padding: 20px;
      box-shadow: 0 12px 30px rgba(31,42,55,.06);
    }
    .label { color: var(--muted); font-size: 13px; margin-bottom: 8px; }
    .value { font-size: 32px; font-weight: 700; }
    .layout {
      display: grid;
      grid-template-columns: 1.15fr .85fr;
      gap: 18px;
      margin-bottom: 18px;
    }
    .bar-row {
      display: grid;
      grid-template-columns: 180px 1fr 40px;
      gap: 12px;
      align-items: center;
      margin: 12px 0;
    }
    .bar-label, .bar-value { font-size: 14px; }
    .bar-track {
      height: 12px;
      background: #f4ead8;
      border-radius: 999px;
      overflow: hidden;
    }
    .bar-fill {
      height: 100%;
      border-radius: 999px;
      background: linear-gradient(90deg, var(--accent), var(--accent-soft));
    }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 14px;
    }
    th, td {
      padding: 12px 10px;
      border-bottom: 1px solid var(--line);
      text-align: left;
      vertical-align: top;
    }
    th { color: var(--muted); font-weight: 600; }
    .footer { margin-top: 16px; color: var(--muted); font-size: 13px; }
    @media (max-width: 900px) {
      .layout { grid-template-columns: 1fr; }
      .bar-row { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
  <div class="wrap">
    <section class="hero">
      <h1>任务初步结果报告</h1>
      <p>生成时间 ${escapeHtml(stats.generatedAt)}，本页由 GitLab 流水线在任务结束后自动生成。</p>
    </section>
    <section class="grid">
      <div class="card"><div class="label">总记录数</div><div class="value">${stats.totalRecords}</div></div>
      <div class="card"><div class="label">锁定记录</div><div class="value">${stats.lockedRecords}</div></div>
      <div class="card"><div class="label">可更新记录</div><div class="value">${records.filter((item) => !item.isLocked).length}</div></div>
      <div class="card"><div class="label">总机时</div><div class="value">${totalHours}</div></div>
    </section>
    <section class="layout">
      <div class="panel">
        <h2>仪器分布</h2>
        ${renderBarChart(instrumentCounts, topInstrumentMax)}
      </div>
      <div class="panel">
        <h2>任务状态</h2>
        ${renderBarChart(statusCounts, statusMax)}
      </div>
    </section>
    <section class="panel">
      <h2>记录明细</h2>
      <table>
        <thead>
          <tr><th>记录号</th><th>仪器</th><th>样品</th><th>数量</th><th>机时</th><th>状态</th></tr>
        </thead>
        <tbody>
          ${renderTableRows(records)}
        </tbody>
      </table>
      <div class="footer">Excel 文件数：${stats.excelFiles}</div>
    </section>
  </div>
</body>
</html>`;

const markdown = [
  '# 任务初步结果',
  '',
  `- 生成时间: ${stats.generatedAt}`,
  `- 总记录数: ${stats.totalRecords}`,
  `- 锁定记录: ${stats.lockedRecords}`,
  `- 可更新记录: ${records.filter((item) => !item.isLocked).length}`,
  `- 总机时: ${totalHours}`,
  '',
  '## 仪器分布',
  ...instrumentCounts.map(([label, value]) => `- ${label}: ${value}`)
].join('\n');

fs.mkdirSync(OUTPUT_DIR, { recursive: true });
fs.writeFileSync(REPORT_PATH, html, 'utf8');
fs.writeFileSync(MARKDOWN_PATH, markdown + '\n', 'utf8');
console.log(`已生成 ${REPORT_PATH}`);
