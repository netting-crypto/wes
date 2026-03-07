import fs from "node:fs";
import path from "node:path";
import { chromium } from "playwright";
import selectors from "../config/selectors.json" with { type: "json" };

const dataDir = path.resolve("data");
const storageStatePath = path.join(dataDir, "storage-state.json");
const SUCCESS_URL_PARTS = [
  "/lfsms/record/myrecord",
  "c=lfsmsrecordmyrecord"
];
const SUCCESS_TEXTS = ["我的测试", "退出", "注销"];

async function isLoggedIn(page) {
  const currentUrl = page.url();
  if (SUCCESS_URL_PARTS.some((part) => currentUrl.includes(part)) && !/login/i.test(currentUrl)) {
    return true;
  }

  for (const text of SUCCESS_TEXTS) {
    if (await page.getByText(text, { exact: false }).count()) {
      return true;
    }
  }

  return false;
}

async function waitForLogin(page, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await isLoggedIn(page)) {
      return;
    }
    await page.waitForTimeout(1000);
  }
  throw new Error("等待登录超时，未检测到进入登录后页面。");
}

async function main() {
  fs.mkdirSync(dataDir, { recursive: true });

  const launchOptions = { headless: false };
  if (process.env.CHROME_PATH) {
    launchOptions.executablePath = process.env.CHROME_PATH;
  }

  const browser = await chromium.launch(launchOptions);
  const context = await browser.newContext();
  const page = await context.newPage();

  await page.goto(selectors.loginUrl, { waitUntil: "domcontentloaded" });
  console.log("请在打开的浏览器中完成登录。检测到进入登录后页面后，会自动保存登录态。");

  await waitForLogin(page, 10 * 60 * 1000);
  await context.storageState({ path: storageStatePath });
  console.log(`登录态已保存到 ${storageStatePath}`);

  await browser.close();
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
