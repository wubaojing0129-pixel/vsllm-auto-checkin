import { chromium } from 'playwright';
import { access, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, '..');
const authDir = path.join(rootDir, '.auth', 'vsllm-profile');
const loginLockPath = path.join(rootDir, '.auth', 'login-browser.lock');
const logDir = path.join(rootDir, 'logs');
const screenshotDir = path.join(rootDir, 'screenshots');
const browserExecutableCandidates = [
  process.env.VSLLM_BROWSER_EXECUTABLE,
  process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, 'Google', 'Chrome', 'Application', 'chrome.exe'),
  process.env.PROGRAMFILES && path.join(process.env.PROGRAMFILES, 'Google', 'Chrome', 'Application', 'chrome.exe'),
  process.env['PROGRAMFILES(X86)'] && path.join(process.env['PROGRAMFILES(X86)'], 'Google', 'Chrome', 'Application', 'chrome.exe'),
  process.env.PROGRAMFILES && path.join(process.env.PROGRAMFILES, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
  process.env['PROGRAMFILES(X86)'] && path.join(process.env['PROGRAMFILES(X86)'], 'Microsoft', 'Edge', 'Application', 'msedge.exe')
].filter(Boolean);

const targetUrl = process.env.VSLLM_URL || 'https://vsllm.com/console/personal';
const drawLimit = Number.parseInt(process.env.VSLLM_DRAW_LIMIT || '3', 10);
const slowMo = Number.parseInt(process.env.VSLLM_SLOWMO || '0', 10);
const watchIntervalMinutes = readPositiveInteger(process.env.VSLLM_WATCH_INTERVAL_MINUTES, 180);
const watchBufferMinutes = readPositiveInteger(process.env.VSLLM_WATCH_BUFFER_MINUTES, 2);
const args = new Set(process.argv.slice(2));

const isLoginAutoMode = args.has('--login-auto');
const isManualBrowserLoginMode = args.has('--login-browser');
const isLoginMode = args.has('--login') || isLoginAutoMode;
const isWatchMode = args.has('--watch');
const headed = isLoginMode || args.has('--headed') || process.env.VSLLM_HEADLESS === 'false';
const keepOpen = args.has('--keep-open');

function readPositiveInteger(value, fallback) {
  const parsed = Number.parseInt(value || '', 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function nowText() {
  return new Date().toLocaleString('zh-CN', { hour12: false });
}

function log(message) {
  console.log(`[${nowText()}] ${message}`);
}

function formatDuration(milliseconds) {
  const totalSeconds = Math.max(Math.ceil(milliseconds / 1000), 0);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;

  const parts = [];
  if (hours) parts.push(`${hours}小时`);
  if (minutes) parts.push(`${minutes}分钟`);
  if (!hours && !minutes) parts.push(`${seconds}秒`);
  return parts.join('');
}

function formatTime(date) {
  return date.toLocaleString('zh-CN', { hour12: false });
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function ensureDirs() {
  await mkdir(authDir, { recursive: true });
  await mkdir(logDir, { recursive: true });
  await mkdir(screenshotDir, { recursive: true });
}

async function fileExists(filePath) {
  try {
    await access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function getBrowserLaunchOptions() {
  const executablePath = await getBrowserExecutablePath();
  return executablePath ? { executablePath } : {};
}

async function getBrowserExecutablePath() {
  for (const candidate of browserExecutableCandidates) {
    if (await fileExists(candidate)) {
      log(`浏览器内核：使用本机浏览器 ${candidate}`);
      return candidate;
    }
  }

  log('浏览器内核：未找到本机 Chrome/Edge，将尝试 Playwright 自带 Chromium。');
  return '';
}

async function waitForEnter() {
  await new Promise((resolve) => {
    process.stdin.resume();
    process.stdin.once('data', resolve);
  });
}

async function processIsRunning(pid) {
  if (!pid) {
    return false;
  }

  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function claimLoginLock() {
  await mkdir(path.dirname(loginLockPath), { recursive: true });

  const existing = await readFile(loginLockPath, 'utf8').catch(() => '');
  const existingPid = Number.parseInt(existing, 10);
  if (await processIsRunning(existingPid)) {
    log(`检测到已有首次登录流程还在运行，PID=${existingPid}。请先完成那个窗口，或运行控制台里的“清理残留登录”，也可以运行 stop-login-browser.ps1。`);
    process.exitCode = 3;
    return false;
  }

  await writeFile(loginLockPath, String(process.pid), 'utf8');
  return true;
}

async function releaseLoginLock() {
  await rm(loginLockPath, { force: true }).catch(() => {});
}

async function verifyLoginProfile() {
  const executablePath = await getBrowserExecutablePath();
  const browserLaunchOptions = executablePath ? { executablePath } : {};
  let context;

  try {
    context = await chromium.launchPersistentContext(authDir, {
      ...browserLaunchOptions,
      headless: true,
      viewport: { width: 1280, height: 900 },
      locale: 'zh-CN',
      ignoreDefaultArgs: ['--enable-automation'],
      args: [
        '--disable-notifications',
        '--disable-dev-shm-usage',
        '--disable-blink-features=AutomationControlled',
        '--disable-infobars'
      ]
    });

    const page = context.pages()[0] || await context.newPage();
    await page.goto(targetUrl, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => {});

    const loginVisible = await page.getByText(/登录|注册|验证码|手机号|邮箱登录/).first().isVisible({ timeout: 1500 }).catch(() => false);
    const passwordVisible = await page.locator('input[type="password"]').first().isVisible({ timeout: 1000 }).catch(() => false);
    const personalVisible = await hasPersonalPageHints(page).catch(() => false);

    return personalVisible && !loginVisible && !passwordVisible;
  } catch (error) {
    log(`登录态检查失败：${error?.message || error}`);
    if (String(error?.message || error).match(/process|profile|Singleton|lock|being used|正在使用/i)) {
      log('请确认刚才打开的登录浏览器窗口已经关闭，再按 Enter。');
    }
    return false;
  } finally {
    await context?.close().catch(() => {});
  }
}

async function loginWithNormalBrowser() {
  if (!(await claimLoginLock())) {
    return;
  }

  const executablePath = await getBrowserExecutablePath();
  if (!executablePath) {
    log('没有找到本机 Chrome/Edge。请安装 Chrome 或 Edge 后重试。');
    process.exitCode = 1;
    await releaseLoginLock();
    return;
  }

  try {
    log('即将打开普通 Chrome/Edge 登录窗口。这个窗口不是自动化浏览器，适合处理 Google 登录。');
    log('请在打开的窗口里完成 VSLLM 登录，确认进入个人中心后，关闭那个浏览器窗口。');
    log('关闭浏览器窗口后，回到这里按 Enter。');

    const child = spawn(executablePath, [
      `--user-data-dir=${authDir}`,
      '--no-first-run',
      '--no-default-browser-check',
      targetUrl
    ], {
      detached: true,
      stdio: 'ignore'
    });

    child.unref();
    await waitForEnter();

    log('正在检查登录态...');
    if (await verifyLoginProfile()) {
      log('登录态检查通过。现在可以运行 API翻牌一次 或 API守候抽奖。');
    } else {
      log('登录态检查未通过：没有在专用登录目录里检测到 VSLLM 个人中心。');
      log('请重新运行首次登录，并确认：1. 登录的是新打开的专用 Chrome/Edge 窗口；2. 已看到 VSLLM 个人中心；3. 关闭该窗口后再按 Enter。');
      process.exitCode = 2;
    }
  } finally {
    await releaseLoginLock();
  }
}

async function saveDebug(page, label) {
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const screenshotPath = path.join(screenshotDir, `${stamp}-${label}.png`);
  const htmlPath = path.join(logDir, `${stamp}-${label}.html`);
  await page.screenshot({ path: screenshotPath, fullPage: true }).catch(() => {});
  await writeFile(htmlPath, await page.content(), 'utf8').catch(() => {});
  log(`已保存调试文件：${screenshotPath}`);
}

async function isProbablyLoggedIn(page) {
  const loginHints = [
    page.getByText(/登录|注册|验证码|手机号|邮箱登录/).first(),
    page.locator('input[type="password"]').first()
  ];

  for (const hint of loginHints) {
    if (await hint.isVisible({ timeout: 1500 }).catch(() => false)) {
      return false;
    }
  }

  if (await hasPersonalPageHints(page)) {
    return true;
  }

  return true;
}

async function hasPersonalPageHints(page) {
  const personalHints = [
    page.getByText('每日签到').first(),
    page.getByText('试试手气').first(),
    page.getByText('个人设置').first(),
    page.getByText('我的应援记录').first()
  ];

  for (const hint of personalHints) {
    if (await hint.isVisible({ timeout: 2000 }).catch(() => false)) {
      return true;
    }
  }

  return false;
}

async function expandSection(page, title) {
  const titleNode = page.getByText(title, { exact: true }).first();
  if (!(await titleNode.isVisible({ timeout: 4000 }).catch(() => false))) {
    return false;
  }

  const section = titleNode.locator('xpath=ancestor-or-self::*[contains(@class,"ant-collapse-item")][1]');
  if (await section.count()) {
    const body = section.locator('.ant-collapse-content, [class*="collapse-content"]').first();
    if (await body.isVisible({ timeout: 1000 }).catch(() => false)) {
      return true;
    }
    await titleNode.click().catch(async () => {
      await section.click();
    });
    await page.waitForTimeout(800);
    return true;
  }

  await titleNode.click().catch(() => {});
  await page.waitForTimeout(800);
  return true;
}

async function clickFirstVisible(locator, timeout = 1500) {
  const count = await locator.count().catch(() => 0);
  for (let index = 0; index < count; index += 1) {
    const item = locator.nth(index);
    if (await item.isVisible({ timeout }).catch(() => false)) {
      await item.click();
      return true;
    }
  }
  return false;
}

function checkInButtonCandidates(page) {
  return [
    page.getByRole('button', { name: /^立即签到$/ }),
    page.getByRole('button', { name: /立即签到|马上签到|点击签到|去签到/ }),
    page.locator('button').filter({ hasText: /立即签到|马上签到|点击签到|去签到/ }),
    page.locator('[role="button"]').filter({ hasText: /立即签到|马上签到|点击签到|去签到/ })
  ];
}

async function hasVisibleCheckInButton(page) {
  for (const candidate of checkInButtonCandidates(page)) {
    const count = await candidate.count().catch(() => 0);
    for (let index = 0; index < count; index += 1) {
      if (await candidate.nth(index).isVisible({ timeout: 500 }).catch(() => false)) {
        return true;
      }
    }
  }
  return false;
}

async function clickCheckInButton(page) {
  for (const candidate of checkInButtonCandidates(page)) {
    if (await clickFirstVisible(candidate, 800)) {
      return true;
    }
  }

  return page.evaluate(() => {
    const match = [...document.querySelectorAll('button,[role="button"]')]
      .find((element) => /立即签到|马上签到|点击签到|去签到/.test((element.textContent || '').trim()));
    if (!match) {
      return false;
    }
    match.click();
    return true;
  }).catch(() => false);
}

async function hasConfirmedCheckIn(page) {
  const successText = page.getByText(/今日已签到|已完成签到|签到成功|已签到成功/).first();
  if (await successText.isVisible({ timeout: 800 }).catch(() => false)) {
    return true;
  }
  return !(await hasVisibleCheckInButton(page));
}

async function waitForCheckInConfirmed(page, timeoutMs = 6000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await hasConfirmedCheckIn(page)) {
      return true;
    }
    await page.waitForTimeout(500);
  }
  return false;
}

async function runCheckIn(page) {
  await expandSection(page, '每日签到');

  if (!(await hasVisibleCheckInButton(page)) && await hasConfirmedCheckIn(page)) {
    log('每日签到：今天已经签到，跳过。');
    return { changed: false, status: 'already-signed' };
  }

  if (await clickCheckInButton(page)) {
    await page.waitForLoadState('networkidle', { timeout: 5000 }).catch(() => {});
    await page.waitForTimeout(1200);
    if (await waitForCheckInConfirmed(page)) {
      log('每日签到：已确认签到成功。');
      return { changed: true, status: 'confirmed' };
    }

    log('每日签到：已点击签到按钮，但页面仍显示可签到，未确认成功。');
    return { changed: false, status: 'unconfirmed' };
  }

  log('每日签到：没有找到“立即签到”按钮，可能页面结构变化或已签到。');
  return { changed: false, status: 'not-found' };
}

async function readDrawStatus(page) {
  const chanceText = await page.getByText(/\d+\s*\/\s*\d+\s*次/).first().textContent({ timeout: 3000 }).catch(() => '');
  const match = chanceText?.match(/(\d+)\s*\/\s*(\d+)\s*次/);
  if (!match) {
    return { used: null, total: null, remaining: null, raw: chanceText || '' };
  }

  const used = Number.parseInt(match[1], 10);
  const total = Number.parseInt(match[2], 10);
  const available = Math.max(used, 0);
  return { used, available, total, remaining: available, raw: chanceText };
}

function parseCooldownText(text) {
  if (!text || !/(后可再抽|可再抽|冷却)/.test(text)) {
    return null;
  }

  const compactText = text.replace(/\s+/g, '');
  const hour = compactText.match(/(\d+)小时/);
  const minute = compactText.match(/(\d+)分(?:钟)?/);
  const second = compactText.match(/(\d+)秒/);

  const hours = hour ? Number.parseInt(hour[1], 10) : 0;
  const minutes = minute ? Number.parseInt(minute[1], 10) : 0;
  const seconds = second ? Number.parseInt(second[1], 10) : 0;
  const totalSeconds = hours * 3600 + minutes * 60 + seconds;

  return totalSeconds > 0 ? totalSeconds * 1000 : null;
}

async function readDrawCooldownMs(page) {
  const bodyText = await page.locator('body').innerText({ timeout: 3000 }).catch(() => '');
  const lines = bodyText
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);

  for (const line of lines) {
    const parsed = parseCooldownText(line);
    if (parsed) {
      return { milliseconds: parsed, raw: line };
    }
  }

  const parsed = parseCooldownText(bodyText);
  return parsed ? { milliseconds: parsed, raw: bodyText.slice(0, 160) } : null;
}

async function closePossibleModal(page) {
  const closeButtons = [
    page.getByRole('button', { name: /知道了|确定|关闭|OK/i }),
    page.locator('.ant-modal-close, .ant-notification-notice-close, .ant-message-custom-content').first()
  ];

  for (const button of closeButtons) {
    if (await clickFirstVisible(button, 700).catch(() => false)) {
      await page.waitForTimeout(500);
      return true;
    }
  }

  await page.keyboard.press('Escape').catch(() => {});
  return false;
}

async function runDraws(page) {
  await expandSection(page, '试试手气');

  const status = await readDrawStatus(page);
  if (status.remaining === 0) {
    const cooldown = await readDrawCooldownMs(page);
    if (cooldown) {
      log(`试试手气：抽奖次数已用完（${status.raw}），页面倒计时：${cooldown.raw}`);
    } else {
      log(`试试手气：抽奖次数已用完（${status.raw}），跳过。`);
    }
    return { attempts: 0, status: 'no-chance', drawStatus: status, cooldownMs: cooldown?.milliseconds ?? null };
  }

  const maxAttempts = Number.isFinite(drawLimit) ? Math.max(drawLimit, 0) : 3;
  const targetAttempts = status.remaining == null ? maxAttempts : Math.min(status.remaining, maxAttempts);
  if (targetAttempts <= 0) {
    log('试试手气：本次配置不抽奖，跳过。');
    return { attempts: 0, status: 'disabled', drawStatus: status, cooldownMs: null };
  }

  log(`试试手气：准备最多尝试 ${targetAttempts} 次。`);

  let attempts = 0;
  for (let index = 0; index < targetAttempts; index += 1) {
    const card = page.getByText('翻一张看运气', { exact: true }).first();
    if (!(await card.isVisible({ timeout: 3000 }).catch(() => false))) {
      log('试试手气：没有找到可翻的卡片。');
      break;
    }

    await card.click();
    attempts += 1;
    log(`试试手气：已尝试第 ${attempts} 次。`);
    await page.waitForTimeout(2200);
    await closePossibleModal(page);
  }

  const afterStatus = await readDrawStatus(page);
  const cooldown = await readDrawCooldownMs(page);
  return {
    attempts,
    status: attempts > 0 ? 'clicked' : 'not-found',
    drawStatus: afterStatus,
    cooldownMs: cooldown?.milliseconds ?? null
  };
}

async function waitForLoggedInPage(context, timeoutMs = 10 * 60 * 1000) {
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    for (const candidate of context.pages()) {
      if (candidate.isClosed()) {
        continue;
      }

      if (await hasPersonalPageHints(candidate).catch(() => false)) {
        return candidate;
      }
    }

    await pageWait(context, 2500);
  }

  return null;
}

async function pageWait(context, timeoutMs) {
  const page = context.pages().find((candidate) => !candidate.isClosed());
  if (page) {
    await page.waitForTimeout(timeoutMs);
    return;
  }
  await new Promise((resolve) => setTimeout(resolve, timeoutMs));
}

async function loginMode(page, context) {
  await page.goto(targetUrl, { waitUntil: 'domcontentloaded', timeout: 60000 });

  if (isLoginAutoMode) {
    log('已打开登录页面。请在弹出的独立浏览器窗口里完成登录。');
    log('检测到个人中心内容后会自动保存登录态并关闭窗口，最长等待 10 分钟。');

    const loggedInPage = await waitForLoggedInPage(context);
    if (!loggedInPage) {
      log('等待超时，未检测到登录成功。请重新点击“首次登录”。');
      process.exitCode = 1;
      return;
    }

    await loggedInPage.goto(targetUrl, { waitUntil: 'domcontentloaded', timeout: 60000 }).catch(() => {});
    log('登录态已保存到 .auth/vsllm-profile。以后可直接后台运行。');
    return;
  }

  log('已打开登录页面。请在弹出的独立浏览器窗口里完成登录。');
  log('登录成功并能看到个人中心后，回到这个终端按 Enter 保存会话。');

  await new Promise((resolve) => {
    process.stdin.resume();
    process.stdin.once('data', resolve);
  });

  await page.goto(targetUrl, { waitUntil: 'domcontentloaded', timeout: 60000 }).catch(() => {});
  if (!(await isProbablyLoggedIn(page))) {
    log('看起来还没有登录成功。请重新运行 npm run login。');
    process.exitCode = 1;
    return;
  }

  log('登录态已保存到 .auth/vsllm-profile。以后可直接运行 npm run run。');
}

async function openPersonalPage(page) {
  await page.goto(targetUrl, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => {});

  if (!(await isProbablyLoggedIn(page))) {
    log('未检测到已登录状态。请先运行：npm run login');
    process.exitCode = 2;
    return false;
  }

  return true;
}

async function runCycle(page, debugLabel = 'last-run') {
  if (!(await openPersonalPage(page))) {
    return null;
  }

  await page.waitForTimeout(1500);
  const checkIn = await runCheckIn(page);
  const draws = await runDraws(page);

  log(`完成：签到=${checkIn.status}，抽奖=${draws.status}，抽奖尝试=${draws.attempts}`);
  await saveDebug(page, debugLabel);
  return { checkIn, draws };
}

async function runNormal(page) {
  await runCycle(page, 'last-run');
}

function getNextWatchDelay(result) {
  const fallbackMs = watchIntervalMinutes * 60 * 1000;
  const bufferMs = watchBufferMinutes * 60 * 1000;
  const cooldownMs = result?.draws?.cooldownMs;

  if (Number.isFinite(cooldownMs) && cooldownMs > 0) {
    return Math.max(cooldownMs + bufferMs, 60 * 1000);
  }

  return fallbackMs + bufferMs;
}

async function runWatch(page) {
  log(`守候模式：启动后立即检查一次；读不到倒计时时，每 ${watchIntervalMinutes} 分钟检查一次。`);
  log(`守候模式：每次会在预计刷新后额外等待 ${watchBufferMinutes} 分钟，避免刚刷新时页面还没更新。`);

  let round = 1;
  while (true) {
    log(`守候模式：第 ${round} 轮检查开始。`);
    const result = await runCycle(page, 'watch-run');

    if (!result) {
      log('守候模式：未登录或页面不可用，已停止。');
      return;
    }

    const delay = getNextWatchDelay(result);
    const nextTime = new Date(Date.now() + delay);
    log(`守候模式：下一轮约 ${formatTime(nextTime)} 检查，等待 ${formatDuration(delay)}。`);
    await sleep(delay);
    round += 1;
  }
}

async function main() {
  await ensureDirs();

  if (isManualBrowserLoginMode) {
    await loginWithNormalBrowser();
    return;
  }

  let context;
  let page;

  try {
    const browserLaunchOptions = await getBrowserLaunchOptions();
    context = await chromium.launchPersistentContext(authDir, {
      ...browserLaunchOptions,
      headless: !headed,
      slowMo,
      viewport: { width: 1440, height: 960 },
      locale: 'zh-CN',
      ignoreDefaultArgs: ['--enable-automation'],
      args: [
        '--disable-notifications',
        '--disable-dev-shm-usage',
        '--disable-blink-features=AutomationControlled',
        '--disable-infobars'
      ]
    });

    page = context.pages()[0] || await context.newPage();

    if (isLoginMode) {
      await loginMode(page, context);
    } else if (isWatchMode) {
      await runWatch(page);
    } else {
      await runNormal(page);
    }
  } catch (error) {
    log(`运行失败：${error?.message || error}`);
    if (String(error?.message || error).includes('playwright install')) {
      log('请先运行：npx playwright install chromium');
    }
    if (page) {
      await saveDebug(page, 'error');
    }
    process.exitCode = 1;
  } finally {
    if (keepOpen) {
      log('已按 --keep-open 保持浏览器打开。关闭窗口后脚本结束。');
      await page?.waitForEvent('close').catch(() => {});
    }
    await context?.close().catch(() => {});
  }
}

main();
