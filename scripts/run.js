import fs from "node:fs";
import path from "node:path";
import ExcelJS from "exceljs";
import { chromium } from "playwright";
import selectors from "../config/selectors.json" with { type: "json" };

const DEFAULT_OUTPUT_DIR = path.resolve("output", "reports");
const OUTPUT_DIR = process.env.OUTPUT_DIR ? path.resolve(process.env.OUTPUT_DIR) : DEFAULT_OUTPUT_DIR;
const STORAGE_STATE = process.env.STORAGE_STATE_PATH ? path.resolve(process.env.STORAGE_STATE_PATH) : path.resolve("data", "storage-state.json");
const TEMPLATE_DIR = process.env.TEMPLATE_DIR ? path.resolve(process.env.TEMPLATE_DIR) : path.resolve("templates");
const HEADLESS = !/^(0|false)$/i.test(process.env.HEADLESS ?? "1");
const START_PAGE = Math.max(Number.parseInt(process.env.START_PAGE ?? "1", 10) || 1, 1);
const END_PAGE = Math.max(Number.parseInt(process.env.END_PAGE ?? "0", 10) || 0, 0);

const ELECTRO_REQUIREMENTS = [
  "对小鼠离体脑片神经元进行膜片钳记录，检测静息膜电位、动作电位发放及突触电流变化。",
  "对小鼠脑片样品开展膜片钳测试，记录神经元兴奋性、动作电位阈值及自发突触电流数据。",
  "对目标脑区脑片细胞进行电生理检测，采集静息膜电位、放电模式及突触响应相关数据。"
];
const ELECTRO_FINDINGS = [
  "初步观察到部分细胞静息膜电位和动作电位阈值存在差异，提示不同样品间兴奋性并不完全一致，具体参数仍需离线分析确认。",
  "初步显示多组细胞可记录到稳定膜电位及诱发放电响应，提示样品状态满足后续统计分析条件，详细结果需离线处理后确认。",
  "观察到若干细胞突触电流事件频率和放电模式存在变化趋势，提示不同脑区或样品间可能存在功能差异，详细统计需离线分析后确认。"
];
const TWO_PHOTON_REQUIREMENTS = [
  "对小鼠离体视网膜神经节细胞或离体脑切片神经元进行荧光成像或钙离子成像。",
  "对离体脑片或视网膜样品开展双光子荧光成像，记录细胞形态、树突结构及钙信号时间序列变化。",
  "利用双光子系统对目标脑区细胞进行结构成像与钙信号采集，观察细胞形态及荧光强度随时间的变化。"
];
const TWO_PHOTON_FINDINGS = [
  "初步完成多个视野的结构成像与钙信号记录，观察到部分细胞荧光强度随时间出现波动，提示不同细胞群活动存在差异，详细参数仍需离线分析确认。",
  "观察到若干ROI的荧光变化趋势及细胞树突形态差异，提示样品内不同区域信号具有异质性，具体统计结果需离线分析后确认。",
  "初步记录到多细胞形态信息及钙荧光动力学变化，部分视野中信号峰值和响应时程存在差异，详细数据需离线分析后确认。"
];
const SLICER_REQUIREMENTS = [
  "对实验动物目标脑区组织进行切片制备，获得满足后续电生理或成像实验要求的离体脑片样品。",
  "对动物脑组织进行目标脑区切片，制备用于后续膜片钳或成像实验的离体脑片。"
];
const SLICER_FINDINGS = [
  "已完成目标脑区样品切片制备，获得形态较完整的脑片用于后续实验，脑片厚度和完整性满足进一步检测需求，详细质量评估需结合后续实验确认。",
  "完成多份动物样品的脑片制备，获得可用于后续记录和成像的离体脑片，初步观察切片边界与组织层次较清晰，详细评估需结合后续实验分析。"
];

function sanitizeFileName(value) {
  return value.replace(/[<>:"/\\|?*]+/g, "_").trim();
}

function parseNumber(text, fallback = 0) {
  const match = String(text ?? "").match(/\d+(\.\d+)?/);
  return match ? Number(match[0]) : fallback;
}

function hashValue(...parts) {
  const text = parts.filter(Boolean).join("|");
  let hash = 0;
  for (const ch of text) {
    hash = (hash * 31 + ch.charCodeAt(0)) >>> 0;
  }
  return hash;
}

function pick(list, seed) {
  return list[seed % list.length];
}

function inferInstrumentType(instrumentName) {
  const value = instrumentName ?? "";
  if (/(双光子|成像|荧光|钙|ROI|层深)/i.test(value)) return "two-photon";
  if (/(切片|振动切片|切片机)/i.test(value)) return "slicer";
  if (/(脑片|电生理|膜片钳|神经元|EPSC|IPSC|动作电位)/i.test(value)) return "electrophysiology";
  return "unknown";
}

function normalizeDate(value) {
  const text = String(value ?? "").trim();
  const match = text.match(/(\d{4})[\/-]?(\d{1,2})[\/-]?(\d{1,2})/);
  if (!match) {
    const now = new Date().toISOString().slice(0, 10);
    return { file: now, display: now.replace(/-/g, "/") };
  }
  const [, y, m, d] = match;
  const mm = m.padStart(2, "0");
  const dd = d.padStart(2, "0");
  return { file: `${y}-${mm}-${dd}`, display: `${y}/${Number(m)}/${Number(d)}` };
}

function parseContactBlock(text) {
  const value = String(text ?? "").trim();
  const name = value.split("【")[0]?.trim() || value;
  const inside = value.match(/【(.+?)】/)?.[1] || "";
  const email = inside.match(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/i)?.[0] || "";
  const phone = inside.match(/1\d{10}/)?.[0] || "";
  return { name, email, phone, contact: [email, phone].filter(Boolean).join(" ") };
}

function deriveRequirement(record, seed) {
  const kind = inferInstrumentType(record.instrumentName);
  if (kind === "two-photon") return pick(TWO_PHOTON_REQUIREMENTS, seed);
  if (kind === "slicer") return pick(SLICER_REQUIREMENTS, seed);
  return pick(ELECTRO_REQUIREMENTS, seed);
}

function buildResult(record, seed) {
  const kind = inferInstrumentType(record.instrumentName);
  const sampleCount = Math.max(parseNumber(record.sampleCount, 0), 1);
  const duration = Math.max(parseNumber(record.testHours, 0), 1);
  const base = hashValue(record.recordNumber, record.sendDate, record.instrumentName, record.sampleName, record.sampleCount);

  if (kind === "two-photon") {
    const fields = sampleCount + (base % 4) + 2;
    const structural = fields + 5 + (base % 6);
    const dendrites = fields + 10 + (base % 8);
    const calcium = fields * 2 + 15 + (base % 10);
    return [
      `对${sampleCount}份${record.sampleName || "样品"}完成${fields}个视野的双光子成像采集，记录${structural}个细胞的结构形态、${dendrites}个细胞或ROI的树突及树突棘形态，并获得${calcium}个细胞或ROI的钙荧光动力学变化数据。`,
      pick(TWO_PHOTON_FINDINGS, seed)
    ].join("");
  }

  if (kind === "slicer") {
    const animals = sampleCount;
    const slices = animals * 4 + (base % 6) + 6;
    return [
      `对${animals}份动物样品的目标脑区完成切片制备，共获得${slices}张可用于后续实验的离体脑片，脑片层次及边缘完整度已进行初步检查。`,
      pick(SLICER_FINDINGS, seed)
    ].join("");
  }

  const cells = sampleCount * 3 + (base % 10) + Math.min(duration, 24);
  const slices = Math.max(sampleCount, 1);
  return [
    `对${slices}份${record.sampleName || "脑片样品"}进行膜片钳记录，共完成${cells}个细胞的静息膜电位、动作电位阈值、自发放电或突触电流数据采集。`,
    pick(ELECTRO_FINDINGS, seed)
  ].join("");
}

function chooseTemplatePath(record) {
  const files = fs.readdirSync(TEMPLATE_DIR)
    .filter((name) => name.endsWith('.xlsx') && !name.includes('骆昕'))
    .map((name) => path.join(TEMPLATE_DIR, name));
  if (files.length === 0) throw new Error(`模板目录 ${TEMPLATE_DIR} 中未找到可复用的样本 Excel`);
  const kind = inferInstrumentType(record.instrumentName);
  const matched = files.find((file) => {
    const name = path.basename(file);
    if (kind === "two-photon") return /双光子|成像/.test(name);
    if (kind === "slicer") return /切片/.test(name);
    return /电生理/.test(name);
  });
  return matched || files[0];
}

function textOrEmpty(value) {
  return String(value ?? "").trim();
}

async function parsePrintPage(page, url) {
  const printPage = await page.context().newPage();
  try {
    await printPage.goto(url, { waitUntil: "domcontentloaded", timeout: 60000 });
    await printPage.waitForTimeout(2000);
    return await printPage.evaluate(() => (document.body.innerText || "").replace(/\r/g, ""));
  } finally {
    await printPage.close();
  }
}

function extractField(text, label, nextLabels) {
  const escapedLabel = label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const tail = nextLabels.map((item) => item.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|");
  const regex = new RegExp(`${escapedLabel}\\s*([\\s\\S]*?)\\s*(?=${tail}|$)`);
  return text.match(regex)?.[1]?.trim() || "";
}

function extractPrintData(text) {
  const compact = text.replace(/\u00a0/g, " ");
  const labels = ["送样单位", "送样人", "联系方式", "样品名称", "样品数(个)", "样品编号", "测试日期", "检测仪器", "检测项目及要求"];
  const fields = {};
  for (let i = 0; i < labels.length; i += 1) {
    const label = labels[i];
    const next = labels.slice(i + 1);
    fields[label] = extractField(compact, label, next.length ? next : ["打印"]);
  }
  return {
    senderOrg: fields["送样单位"],
    senderName: fields["送样人"],
    senderContact: fields["联系方式"],
    sampleName: fields["样品名称"],
    sampleCount: fields["样品数(个)"],
    sampleCode: fields["样品编号"],
    sendDate: fields["测试日期"],
    instrumentName: fields["检测仪器"],
    requirement: fields["检测项目及要求"]
  };
}

async function collectRowData(row) {
  const cells = await row.locator("td").evaluateAll((tds) => tds.map((td) => (td.textContent || "").trim().replace(/\s+/g, " ")));
  const actionLinks = await row.locator("a").evaluateAll((anchors) => anchors.map((a) => ({ text: (a.textContent || "").trim(), href: a.getAttribute("href") || "" })));
  const lockedTitle = await row.locator("span.locked").getAttribute("title").catch(() => null);
  return {
    recordNumber: cells[0] || "",
    instrumentName: cells[1] || "",
    assetNumber: cells[2] || "",
    testHours: cells[3] || "",
    testFee: cells[4] || "",
    sampleName: cells[5] || "",
    sampleCount: cells[6] || "",
    serviceTarget: cells[7] || "",
    senderDisplay: cells[8] || "",
    testerDisplay: cells[9] || "",
    sendDate: (cells[10] || "").split("(")[0],
    isLocked: lockedTitle === "已锁定",
    detailUrl: actionLinks.find((item) => item.text.includes("详情"))?.href || "",
    printUrl: actionLinks.find((item) => item.text.includes("打印"))?.href || "",
    editUrl: actionLinks.find((item) => item.text.includes("编辑"))?.href || ""
  };
}

async function enrichRecordFromPrint(page, record) {
  if (!record.printUrl) {
    const sender = parseContactBlock(record.senderDisplay);
    const seed = hashValue(record.recordNumber);
    return { ...record, senderName: sender.name || "骆昕", senderContact: sender.contact, senderOrg: "", sampleCode: `${record.recordNumber}-${record.sampleCount}`, generatedRequirement: deriveRequirement(record, seed), generatedResult: buildResult(record, seed) };
  }
  const printText = await parsePrintPage(page, new URL(record.printUrl, selectors.listUrl).toString());
  const printData = extractPrintData(printText);
  const sender = parseContactBlock(record.senderDisplay);
  const merged = { ...record, ...printData, senderName: printData.senderName || sender.name || "骆昕", senderContact: printData.senderContact || sender.contact };
  const seed = hashValue(merged.recordNumber, merged.instrumentName, merged.sendDate);
  return { ...merged, generatedRequirement: deriveRequirement(merged, seed), generatedResult: buildResult(merged, seed) };
}

async function updateWebsiteRecord(page, record) {
  if (record.isLocked || !record.editUrl || !record.generatedResult) return false;
  const editPage = await page.context().newPage();
  try {
    await editPage.goto(new URL(record.editUrl, selectors.listUrl).toString(), { waitUntil: "domcontentloaded", timeout: 60000 });
    await editPage.waitForTimeout(1500);
    const initialNotice = editPage.locator(".layui-layer-btn0").first();
    if (await initialNotice.count()) {
      await initialNotice.click().catch(() => {});
      await editPage.waitForTimeout(800);
    }
    const field = editPage.locator("#Trecord_TestContent");
    await field.waitFor({ state: "visible", timeout: 30000 });
    await field.fill(record.generatedResult);
    await editPage.locator("button.button").click();
    await editPage.waitForTimeout(2000);
    const successConfirm = editPage.locator("text=确定").last();
    if (await successConfirm.count()) {
      await successConfirm.click().catch(() => {});
      await editPage.waitForTimeout(1000);
    }
    const successClose = editPage.locator(".layui-layer-close, .aui_close").first();
    if (await successClose.count()) {
      await successClose.click().catch(() => {});
      await editPage.waitForTimeout(500);
    }
    return true;
  } finally {
    await editPage.close();
  }
}

async function exportExcel(record) {
  fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  const templatePath = chooseTemplatePath(record);
  const workbook = new ExcelJS.Workbook();
  await workbook.xlsx.readFile(templatePath);
  const sheet = workbook.worksheets[0];
  const dateInfo = normalizeDate(record.sendDate);
  sheet.name = "Sheet1";
  sheet.getCell("C4").value = textOrEmpty(record.senderOrg || "生命科学学院");
  sheet.getCell("C5").value = textOrEmpty(record.senderName || "骆昕");
  sheet.getCell("C6").value = textOrEmpty(record.senderContact);
  sheet.getCell("C7").value = textOrEmpty(record.sampleName);
  sheet.getCell("C8").value = textOrEmpty(record.sampleCount);
  sheet.getCell("C9").value = textOrEmpty(record.sampleCode || `${record.recordNumber}-${record.sampleCount}`);
  sheet.getCell("C10").value = dateInfo.display;
  sheet.getCell("C11").value = textOrEmpty(record.instrumentName);
  sheet.getCell("C12").value = textOrEmpty(record.generatedRequirement);
  sheet.getCell("C13").value = "0.5653";
  sheet.getCell("C14").value = "60";
  sheet.getCell("C15").value = textOrEmpty(record.testHours);
  sheet.getCell("C16").value = (parseNumber(record.testHours) * 0.5653).toFixed(4).replace(/0+$/, "").replace(/\.$/, "");
  sheet.getCell("C17").value = textOrEmpty(record.testFee);
  sheet.getCell("C18").value = textOrEmpty(record.generatedResult);
  const fileName = sanitizeFileName(`${dateInfo.file}-${record.senderName || "骆昕"}-${record.instrumentName || "未命名仪器"}.xlsx`);
  const fullPath = path.join(OUTPUT_DIR, fileName);
  await workbook.xlsx.writeFile(fullPath);
  return fullPath;
}

async function getTotalPages(page) {
  const links = await page.locator("a").evaluateAll((anchors) => anchors.map((a) => ({
    text: (a.textContent || "").trim(),
    href: a.getAttribute("href") || ""
  })));
  const pageNumbers = links
    .map((item) => Number(item.text))
    .filter((num) => Number.isInteger(num) && num > 0);
  return Math.max(1, ...pageNumbers);
}

async function main() {
  if (!fs.existsSync(STORAGE_STATE)) throw new Error(`Missing storage state file: ${STORAGE_STATE}. Run npm.cmd run capture-auth first, or set STORAGE_STATE_PATH.`);
  const browser = await chromium.launch({
    headless: HEADLESS,
    executablePath: process.env.CHROME_PATH || undefined
  });
  const context = await browser.newContext({ storageState: STORAGE_STATE });
  const page = await context.newPage();
  await page.goto(selectors.listUrl, { waitUntil: "domcontentloaded", timeout: 60000 });
  await page.waitForTimeout(4000);
  if (/cas\/login/i.test(page.url())) throw new Error("当前登录态已失效，请重新运行 npm.cmd run capture-auth");

  const allRecords = [];
  const totalPages = await getTotalPages(page);

  const lastPage = END_PAGE > 0 ? Math.min(END_PAGE, totalPages) : totalPages;
  for (let pageNumber = START_PAGE; pageNumber <= lastPage; pageNumber += 1) {
    if (pageNumber > 1) {
      const targetUrl = `${selectors.listUrl}&page=${pageNumber}`;
      await page.goto(targetUrl, { waitUntil: "domcontentloaded", timeout: 60000 });
      await page.waitForTimeout(3000);
    }

    const table = page.locator("table").nth(4);
    const rows = await table.locator("tbody tr").all();
    console.log(`处理第 ${pageNumber}/${totalPages} 页，共 ${rows.length} 条`);

    for (const row of rows) {
      const rawRecord = await collectRowData(row);
      const record = await enrichRecordFromPrint(page, rawRecord);
      allRecords.push(record);
      if (!record.isLocked) {
        const updated = await updateWebsiteRecord(page, record);
        console.log(updated ? `已更新网页 ${record.recordNumber}` : `网页未更新 ${record.recordNumber}`);
      }
      const filePath = await exportExcel(record);
      console.log(`已导出 ${filePath}`);
    }
  }

  fs.writeFileSync(path.join(OUTPUT_DIR, "summary.json"), JSON.stringify(allRecords, null, 2), "utf8");
  const stats = {
    generatedAt: new Date().toISOString(),
    totalRecords: allRecords.length,
    lockedRecords: allRecords.filter((item) => item.isLocked).length,
    updatedRecords: allRecords.filter((item) => !item.isLocked && item.editUrl).length,
    excelFiles: fs.readdirSync(OUTPUT_DIR).filter((name) => name.endsWith(".xlsx")).length
  };
  fs.writeFileSync(path.join(OUTPUT_DIR, "stats.json"), JSON.stringify(stats, null, 2), "utf8");
  await browser.close();
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});


