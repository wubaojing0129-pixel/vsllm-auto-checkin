import { chromium } from 'playwright';
import { execFileSync } from 'node:child_process';
import { access, appendFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, '..');
const authDir = path.join(rootDir, '.auth', 'vsllm-profile');
const logDir = path.join(rootDir, 'logs');
const drawHistoryPath = path.join(logDir, 'draw-history.log');
const drawStatePath = path.join(logDir, 'draw-state.json');
const checkInHistoryPath = path.join(logDir, 'checkin-history.log');
const browserExecutableCandidates = [
  process.env.VSLLM_BROWSER_EXECUTABLE,
  process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, 'Google', 'Chrome', 'Application', 'chrome.exe'),
  process.env.PROGRAMFILES && path.join(process.env.PROGRAMFILES, 'Google', 'Chrome', 'Application', 'chrome.exe'),
  process.env['PROGRAMFILES(X86)'] && path.join(process.env['PROGRAMFILES(X86)'], 'Google', 'Chrome', 'Application', 'chrome.exe'),
  process.env.PROGRAMFILES && path.join(process.env.PROGRAMFILES, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
  process.env['PROGRAMFILES(X86)'] && path.join(process.env['PROGRAMFILES(X86)'], 'Microsoft', 'Edge', 'Application', 'msedge.exe')
].filter(Boolean);

const baseUrl = 'https://vsllm.com';
const targetUrl = process.env.VSLLM_URL || `${baseUrl}/console/personal`;
const drawLimit = readPositiveInteger(process.env.VSLLM_DRAW_LIMIT, 3);
const watchIntervalMinutes = readPositiveInteger(process.env.VSLLM_WATCH_INTERVAL_MINUTES, 180);
const watchBufferSeconds = readBufferSeconds();
const explicitUserId = process.env.VSLLM_USER_ID || process.env.NEW_API_USER || '';
const args = new Set(process.argv.slice(2));

const isWatchMode = args.has('--watch');
const isBalanceMode = args.has('--balance');
const headed = args.has('--headed') || process.env.VSLLM_HEADLESS === 'false';
const summaryOnly = process.env.VSLLM_SUMMARY_ONLY === '1';

function readPositiveInteger(value, fallback) {
  const parsed = Number.parseInt(value || '', 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function readBufferSeconds() {
  const seconds = Number.parseInt(process.env.VSLLM_WATCH_BUFFER_SECONDS || '', 10);
  if (Number.isFinite(seconds) && seconds >= 0) {
    return seconds;
  }

  return 10;
}

function nowText() {
  return new Date().toLocaleString('zh-CN', { hour12: false });
}

function log(message) {
  if (summaryOnly && !/签到日志|抽奖日志|余额日志|API运行失败|失败|错误|未检测到|检测到首次登录|请先|没有/.test(message)) {
    return;
  }
  console.log(`[${nowText()}] ${message}`);
}

async function readDrawState() {
  try {
    const raw = await readFile(drawStatePath, 'utf8');
    const parsed = JSON.parse(raw);
    return {
      ...parsed,
      totalAttempts: Number.parseInt(parsed.totalAttempts || '0', 10) || 0
    };
  } catch {
    return { totalAttempts: 0 };
  }
}

async function writeDrawState(state) {
  await writeFile(drawStatePath, JSON.stringify(state, null, 2), 'utf8').catch(() => {});
}

async function countSuccessfulDrawHistory() {
  try {
    const raw = await readFile(drawHistoryPath, 'utf8');
    return raw
      .split(/\r?\n/)
      .filter((line) => /抽奖日志：本轮第/.test(line))
      .length;
  } catch {
    return 0;
  }
}

async function recordDrawHistory(message) {
  const line = `[${nowText()}] ${message}`;
  console.log(line);
  await appendFile(drawHistoryPath, `${line}\n`, 'utf8').catch(() => {});
}

async function recordCheckInHistory(message) {
  const line = `[${nowText()}] ${message}`;
  console.log(line);
  await appendFile(checkInHistoryPath, `${line}\n`, 'utf8').catch(() => {});
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
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

function isoTime(date) {
  return date.toISOString();
}

async function ensureDirs() {
  await mkdir(authDir, { recursive: true });
  await mkdir(logDir, { recursive: true });
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
  for (const candidate of browserExecutableCandidates) {
    if (await fileExists(candidate)) {
      log(`浏览器内核：使用本机浏览器 ${candidate}`);
      return { executablePath: candidate };
    }
  }

  log('浏览器内核：未找到本机 Chrome/Edge，将尝试 Playwright 自带 Chromium。');
  return {};
}

function normalizeForMatch(text) {
  return String(text || '').toLowerCase().replace(/\//g, '\\');
}

function isProfileBrowserRunning() {
  if (process.platform !== 'win32') {
    return false;
  }

  try {
    const command = [
      '$ErrorActionPreference="SilentlyContinue";',
      'Get-CimInstance Win32_Process |',
      'Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match "vsllm-profile|vsllm-auto\\.js --login-browser|login:browser" } |',
      'Select-Object -ExpandProperty CommandLine'
    ].join(' ');
    const output = execFileSync('powershell.exe', ['-NoProfile', '-Command', command], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: 5000
    });
    const normalizedOutput = normalizeForMatch(output);
    return normalizedOutput.includes('vsllm-profile') || normalizedOutput.includes('--login-browser') || normalizedOutput.includes('login:browser');
  } catch {
    return false;
  }
}

function parseCooldownText(text) {
  if (!text || !/(后可再抽|可再抽|冷却|cooldown|wait|later)/i.test(text)) {
    return null;
  }

  const compactText = text.replace(/\s+/g, '');
  const hour = compactText.match(/(\d+)小时|(\d+)h/i);
  const minute = compactText.match(/(\d+)分(?:钟)?|(\d+)m/i);
  const second = compactText.match(/(\d+)秒|(\d+)s/i);

  const hours = hour ? Number.parseInt(hour[1] || hour[2], 10) : 0;
  const minutes = minute ? Number.parseInt(minute[1] || minute[2], 10) : 0;
  const seconds = second ? Number.parseInt(second[1] || second[2], 10) : 0;
  const totalSeconds = hours * 3600 + minutes * 60 + seconds;

  return totalSeconds > 0 ? totalSeconds * 1000 : null;
}

function maskValue(value) {
  const text = String(value || '');
  if (text.length <= 6) {
    return text ? '***' : '';
  }
  return `${text.slice(0, 3)}***${text.slice(-3)}`;
}

function summarize(text, maxLength = 500) {
  const compact = String(text || '').replace(/\s+/g, ' ').trim();
  return compact.length > maxLength ? `${compact.slice(0, maxLength)}...` : compact;
}

function stringifyPayload(result) {
  if (result.json != null) {
    return JSON.stringify(result.json);
  }
  return result.text || '';
}

function formatNumber(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) {
    return String(value || '').trim();
  }
  return new Intl.NumberFormat('zh-CN', {
    maximumFractionDigits: Number.isInteger(number) ? 0 : 4
  }).format(number);
}

function normalizeBalanceValue(value) {
  if (typeof value === 'number') {
    return Number.isFinite(value) ? value : null;
  }
  if (typeof value === 'string') {
    if (/^(custom|default|auto|true|false|null|undefined)$/i.test(value.trim())) {
      return null;
    }
    const cleaned = value.replace(/[,，\s]/g, '').replace(/[¥￥$元]/g, '');
    const parsed = Number(cleaned);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function isIgnoredBalanceCandidate(label, raw = '') {
  const text = `${label || ''} ${raw || ''}`;
  return /display[_-]?type|quota[_-]?display|quota[_-]?per[_-]?unit|per[_-]?unit|unit[_-]?price|price|ratio|rate|type|mode|status|enabled/i.test(text);
}

function makeBalanceCandidate({ label, value, unit = '', source = '', raw = '', priority = 20 }) {
  if (isIgnoredBalanceCandidate(label, raw)) {
    return null;
  }
  const normalized = normalizeBalanceValue(value);
  if (normalized == null) {
    return null;
  }
  const valueText = formatNumber(normalized);
  if (!valueText) {
    return null;
  }

  const cleanLabel = label || '账户余额';
  const displayText = `${cleanLabel}：${valueText}${unit ? ` ${unit}` : ''}`;
  return {
    label: cleanLabel,
    value: normalized,
    valueText,
    unit,
    source,
    raw: raw || displayText,
    displayText,
    updatedAt: isoTime(new Date()),
    priority
  };
}

function collectBalanceCandidatesFromJson(value, source = 'json') {
  const candidates = [];
  const seen = new WeakSet();
  const keyLabels = new Map([
    ['balance', '账户余额'],
    ['wallet_balance', '钱包余额'],
    ['walletBalance', '钱包余额'],
    ['available_balance', '可用余额'],
    ['availableBalance', '可用余额'],
    ['credit', '账户余额'],
    ['credits', '账户余额'],
    ['money', '账户余额'],
    ['amount', '账户余额'],
    ['quota', '账号额度'],
    ['remaining_quota', '剩余额度'],
    ['remainingQuota', '剩余额度'],
    ['available_quota', '可用额度'],
    ['availableQuota', '可用额度']
  ]);

  function visit(node, pathName, depth = 0) {
    if (depth > 6 || node == null) return;
    if (typeof node !== 'object') return;
    if (seen.has(node)) return;
    seen.add(node);

    if (Array.isArray(node)) {
      node.slice(0, 30).forEach((item, index) => visit(item, `${pathName}[${index}]`, depth + 1));
      return;
    }

    const keys = Object.keys(node);
    for (const key of keys) {
      const candidateLabel = keyLabels.get(key);
      if (candidateLabel) {
        const candidate = makeBalanceCandidate({
          label: candidateLabel,
          value: node[key],
          unit: /quota/i.test(key) ? 'quota' : '',
          source,
          raw: `${pathName}.${key}`,
          priority: /remaining|available|balance|credit|money/i.test(key) ? 2 : 8
        });
        if (candidate) candidates.push(candidate);
      }
      visit(node[key], `${pathName}.${key}`, depth + 1);
    }
  }

  visit(value, source);
  return candidates;
}

function extractBalanceFromText(text, source = 'page') {
  const body = String(text || '').replace(/\s+/g, ' ');
  const patterns = [
    /(账户余额|钱包余额|可用余额|余额|剩余额度|可用额度|额度余额|剩余能量|能量余额)\s*[：: ]\s*([¥￥$]?\s*-?[\d,，]+(?:\.\d+)?\s*(?:元|额度|能量|quota|点)?)/i,
    /(剩余|可用)\s*([¥￥$]?\s*-?[\d,，]+(?:\.\d+)?\s*(?:元|额度|能量|quota|点))/i
  ];

  for (const pattern of patterns) {
    const match = body.match(pattern);
    if (!match) continue;
    const label = match[1].replace(/\s+/g, '') || '账户余额';
    const rawValue = match[2];
    const unitMatch = String(rawValue).match(/(元|额度|能量|quota|点)$/i);
    const candidate = makeBalanceCandidate({
      label,
      value: rawValue,
      unit: unitMatch ? unitMatch[1] : '',
      source,
      raw: match[0],
      priority: 3
    });
    if (candidate) return candidate;
  }

  return null;
}

function pickBestBalance(candidates) {
  const clean = candidates.filter(Boolean);
  if (!clean.length) {
    return null;
  }
  clean.sort((left, right) => (left.priority ?? 20) - (right.priority ?? 20));
  return clean[0];
}

function getDrawPrize(result) {
  return result?.json?.data?.prize || null;
}

function describePrize(prize) {
  if (!prize) {
    return '';
  }

  const name = prize.name || '未知奖励';
  const quota = Number(prize.quota || 0);
  const quotaText = quota > 0 ? ` +${quota}` : '';
  const rarity = prize.rarity ? `（${prize.rarity}）` : '';
  return `${name}${quotaText}${rarity}`;
}

function getDrawSummary(result) {
  const prize = getDrawPrize(result);
  if (!prize) {
    return '';
  }

  const selectedIndex = result?.json?.data?.selected_index;
  const indexText = Number.isFinite(selectedIndex) ? `第 ${selectedIndex + 1} 张` : '已翻牌';
  return `${indexText}：${describePrize(prize)}`;
}

function responseMeansStop(result) {
  const text = stringifyPayload(result);
  return /次数.*(不足|用完|没有)|没有.*次数|没有.*机会|机会.*不足|已用完|后可再抽|冷却|cooldown|too\s*many|too\s*frequent|wait|later/i.test(text);
}

function responseCooldownMs(result) {
  return parseCooldownText(stringifyPayload(result));
}

function responseMeansAuthExpired(result) {
  const text = stringifyPayload(result);
  return result?.status === 401 || /unauthorized|not logged in|access token|未登录|登录.*失效|请.*登录/i.test(text);
}

function errorMeansAuthExpired(error) {
  const text = String(error?.message || error || '');
  return /未检测到登录态|没有读取到.*Cookie|没有自动识别到 new-api-user|登录状态.*失效|Unauthorized|未登录|请先运行.*首次登录|请.*登录/i.test(text);
}

async function updateDrawStatePatch(patch) {
  const current = await readDrawState();
  current.totalAttempts = Math.max(current.totalAttempts, await countSuccessfulDrawHistory());
  await writeDrawState({
    ...current,
    ...patch,
    updatedAt: isoTime(new Date())
  });
}

function findBestUserId(candidates) {
  const clean = candidates
    .map((candidate) => String(candidate || '').trim())
    .filter((candidate) => /^[A-Za-z0-9_-]{1,80}$/.test(candidate));

  return [...new Set(clean)][0] || '';
}

async function findUserIdFromStorage(page) {
  const candidates = await page.evaluate(() => {
    const found = [];
    const preferredKeys = new Set([
      'new-api-user',
      'new_api_user',
      'newApiUser',
      'userId',
      'user_id',
      'uid',
      'id'
    ]);

    function push(value, path) {
      if (value == null) return;
      if (typeof value !== 'string' && typeof value !== 'number') return;
      const text = String(value).trim();
      if (!/^[A-Za-z0-9_-]{1,80}$/.test(text)) return;
      found.push({ value: text, path });
    }

    function visit(value, path, depth = 0) {
      if (depth > 5 || value == null) return;
      if (Array.isArray(value)) {
        value.slice(0, 20).forEach((item, index) => visit(item, `${path}[${index}]`, depth + 1));
        return;
      }
      if (typeof value !== 'object') return;

      const keys = Object.keys(value);
      const looksLikeUser = keys.some((key) => /user|name|email|avatar|balance|quota/i.test(key));
      for (const key of keys) {
        const nextPath = `${path}.${key}`;
        if (preferredKeys.has(key) && (looksLikeUser || /user|account|profile|auth|new[-_]?api/i.test(path))) {
          push(value[key], nextPath);
        }
        visit(value[key], nextPath, depth + 1);
      }
    }

    for (const storeName of ['localStorage', 'sessionStorage']) {
      const store = window[storeName];
      for (let index = 0; index < store.length; index += 1) {
        const key = store.key(index);
        const raw = store.getItem(key) || '';
        if (/new[-_]?api[-_]?user|user[-_]?id|uid/i.test(key)) {
          push(raw, `${storeName}.${key}`);
        }

        const headerMatch = raw.match(/new-api-user["']?\s*[:=]\s*["']?([A-Za-z0-9_-]{1,80})/i);
        if (headerMatch) {
          push(headerMatch[1], `${storeName}.${key}.new-api-user`);
        }

        try {
          visit(JSON.parse(raw), `${storeName}.${key}`);
        } catch {
        }
      }
    }

    return found;
  });

  const ranked = candidates.sort((left, right) => {
    const score = (item) => {
      if (/new[-_]?api[-_]?user/i.test(item.path)) return 0;
      if (/userId|user_id|uid/i.test(item.path)) return 1;
      if (/user|profile|account/i.test(item.path)) return 2;
      return 3;
    };
    return score(left) - score(right);
  });

  return findBestUserId(ranked.map((item) => item.value));
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
  const expanded = await expandSection(page, '每日签到');
  if (!expanded) {
    await recordCheckInHistory('签到日志：未找到每日签到入口，跳过。');
    return { changed: false, status: 'not-found' };
  }

  if (!(await hasVisibleCheckInButton(page)) && await hasConfirmedCheckIn(page)) {
    await recordCheckInHistory('签到日志：今天已经签到，跳过。');
    return { changed: false, status: 'already-signed' };
  }

  if (await clickCheckInButton(page)) {
    await page.waitForLoadState('networkidle', { timeout: 5000 }).catch(() => {});
    await page.waitForTimeout(1200);
    if (await waitForCheckInConfirmed(page)) {
      await recordCheckInHistory('签到日志：已确认签到成功。');
      return { changed: true, status: 'confirmed' };
    }

    await recordCheckInHistory('签到日志：已点击签到按钮，但页面仍显示可签到，未确认成功。');
    return { changed: false, status: 'unconfirmed' };
  }

  await recordCheckInHistory('签到日志：没有找到“立即签到”按钮，可能页面结构变化或今天已签到。');
  return { changed: false, status: 'not-clickable' };
}

async function readPageDrawStatus(page) {
  await expandSection(page, '试试手气').catch(() => false);
  const bodyText = await page.locator('body').innerText({ timeout: 4000 }).catch(() => '');
  const match = bodyText.match(/(\d+)\s*\/\s*(\d+)\s*次/);
  if (!match) {
    return { used: null, total: null, remaining: null, raw: '' };
  }

  const used = Number.parseInt(match[1], 10);
  const total = Number.parseInt(match[2], 10);
  const available = Math.max(used, 0);
  return {
    used,
    available,
    total,
    remaining: available,
    raw: `${used}/${total} 次`
  };
}

async function readPageDrawCooldown(page) {
  await expandSection(page, '试试手气').catch(() => false);
  const bodyText = await page.locator('body').innerText({ timeout: 4000 }).catch(() => '');
  const lines = bodyText
    .split(/\r?\n/)
    .map((line) => line.replace(/\s+/g, ' ').trim())
    .filter(Boolean);

  for (const line of lines) {
    if (!/(后可再抽|可再抽|冷却|cooldown|wait|later)/i.test(line)) {
      continue;
    }
    const parsed = parseCooldownText(line);
    if (parsed) {
      return { milliseconds: parsed, raw: line };
    }
  }

  const parsed = parseCooldownText(bodyText);
  return parsed ? { milliseconds: parsed, raw: summarize(bodyText, 180) } : null;
}

async function readPageBalance(page) {
  const candidates = [];
  const bodyText = await page.locator('body').innerText({ timeout: 4000 }).catch(() => '');
  const textCandidate = extractBalanceFromText(bodyText, 'page-text');
  if (textCandidate) {
    candidates.push(textCandidate);
  }

  const storageCandidates = await page.evaluate(() => {
    const output = [];
    const seen = new WeakSet();
    const interestingKeys = /balance|wallet|quota|credit|money|amount|余额|额度|钱包|能量/i;

    function push(label, value, path) {
      if (value == null) return;
      if (typeof value !== 'string' && typeof value !== 'number') return;
      output.push({ label, value, path });
    }

    function visit(value, path, depth = 0) {
      if (depth > 5 || value == null) return;
      if (typeof value !== 'object') return;
      if (seen.has(value)) return;
      seen.add(value);

      if (Array.isArray(value)) {
        value.slice(0, 30).forEach((item, index) => visit(item, `${path}[${index}]`, depth + 1));
        return;
      }

      for (const key of Object.keys(value)) {
        const nextPath = `${path}.${key}`;
        if (interestingKeys.test(key)) {
          push(key, value[key], nextPath);
        }
        visit(value[key], nextPath, depth + 1);
      }
    }

    for (const storeName of ['localStorage', 'sessionStorage']) {
      const store = window[storeName];
      for (let index = 0; index < store.length; index += 1) {
        const key = store.key(index);
        const raw = store.getItem(key) || '';
        if (interestingKeys.test(key)) {
          push(key, raw, `${storeName}.${key}`);
        }
        try {
          visit(JSON.parse(raw), `${storeName}.${key}`);
        } catch {
        }
      }
    }

    return output;
  }).catch(() => []);

  for (const item of storageCandidates) {
    const candidate = makeBalanceCandidate({
      label: item.label,
      value: item.value,
      unit: /quota/i.test(item.label) ? 'quota' : '',
      source: 'browser-storage',
      raw: item.path,
      priority: /remaining|available|balance|余额|剩余|可用/i.test(item.label) ? 2 : 9
    });
    if (candidate) {
      candidates.push(candidate);
    }
  }

  return pickBestBalance(candidates);
}

async function prepareAuth(context) {
  return preparePageContext(context, { runCheckInBeforeRead: true });
}

async function preparePageContext(context, options = {}) {
  const runCheckInBeforeRead = options.runCheckInBeforeRead !== false;
  let observedUserId = '';
  const page = await context.newPage();

  page.on('request', (request) => {
    const header = request.headers()['new-api-user'];
    if (header && !observedUserId) {
      observedUserId = header;
    }
  });

  await page.goto(targetUrl, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => {});

  const loginVisible = await page.getByText(/登录|注册|验证码|手机号|邮箱登录/).first().isVisible({ timeout: 1500 }).catch(() => false);
  const passwordVisible = await page.locator('input[type="password"]').first().isVisible({ timeout: 1000 }).catch(() => false);
  const userAgent = await page.evaluate(() => navigator.userAgent).catch(() => 'Mozilla/5.0');
  const cookies = await context.cookies(baseUrl);
  const cookieNames = cookies.map((cookie) => cookie.name).join(', ') || '(none)';
  const hasVsllmLoginCookie = cookies.some((cookie) => ['session', 'newapi_vid'].includes(cookie.name));

  if ((loginVisible || passwordVisible) && !hasVsllmLoginCookie) {
    await page.close().catch(() => {});
    throw new Error(`未检测到登录态。当前 vsllm.com Cookie：${cookieNames}。请先运行“首次登录”，登录成功后关闭登录浏览器窗口，再按 Enter。`);
  }

  const pageBalance = await readPageBalance(page).catch((error) => {
    log(`余额日志：读取页面余额失败：${error?.message || error}`);
    return null;
  });
  if (pageBalance) {
    log(`余额日志：${pageBalance.displayText}`);
  }

  if (runCheckInBeforeRead) {
    await runCheckIn(page).catch((error) => {
      log(`签到日志：签到检查失败：${error?.message || error}`);
      return null;
    });
  }

  const pageDrawStatus = await readPageDrawStatus(page).catch((error) => {
    log(`抽奖日志：读取页面剩余次数失败：${error?.message || error}`);
    return null;
  });
  if (pageDrawStatus?.raw) {
    log(`抽奖日志：页面显示本轮次数：${pageDrawStatus.raw}`);
  }

  const pageCooldown = await readPageDrawCooldown(page).catch((error) => {
    log(`抽奖日志：读取页面冷却时间失败：${error?.message || error}`);
    return null;
  });
  if (pageCooldown?.milliseconds) {
    log(`抽奖日志：页面显示冷却中，${formatDuration(pageCooldown.milliseconds)} 后可再试：${pageCooldown.raw}`);
  }

  const storageUserId = explicitUserId ? '' : await findUserIdFromStorage(page).catch(() => '');
  const cookieUserId = cookies.find((cookie) => cookie.name === 'newapi_vid')?.value || '';
  const userId = findBestUserId([explicitUserId, observedUserId, storageUserId, cookieUserId]);
  const cookieHeader = cookies.map((cookie) => `${cookie.name}=${cookie.value}`).join('; ');

  await page.close().catch(() => {});

  if (!cookieHeader) {
    throw new Error('没有读取到 vsllm.com Cookie。请先运行“首次登录”。');
  }

  if (!userId) {
    throw new Error('没有自动识别到 new-api-user。可以在环境变量里设置 VSLLM_USER_ID，但不要把 Cookie 发到聊天里。');
  }

  log(`API鉴权：new-api-user=${maskValue(userId)}，Cookie数量=${cookies.length}`);
  log(`API鉴权：Cookie=${cookieNames}`);
  return {
    userId,
    cookieHeader,
    userAgent,
    pageBalance,
    pageDrawStatus,
    pageCooldownMs: pageCooldown?.milliseconds ?? null,
    pageCooldownText: pageCooldown?.raw || ''
  };
}

async function apiPost(context, auth, endpoint) {
  const response = await context.request.post(`${baseUrl}${endpoint}`, {
    headers: {
      Accept: 'application/json, text/plain, */*',
      Origin: baseUrl,
      Referer: targetUrl,
      'User-Agent': auth.userAgent,
      'new-api-user': auth.userId,
      Cookie: auth.cookieHeader
    },
    timeout: 30000
  });

  const text = await response.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
  }

  if (endpoint === '/api/gwent/draw') {
    const drawSummary = getDrawSummary({ json });
    if (drawSummary) {
      log(`API ${endpoint}：HTTP ${response.status()}，${drawSummary}`);
    } else {
      log(`API ${endpoint}：HTTP ${response.status()} ${summarize(text)}`);
    }
  } else {
    log(`API ${endpoint}：HTTP ${response.status()} ${summarize(text)}`);
  }
  return { ok: response.ok(), status: response.status(), text, json };
}

async function apiGet(context, auth, endpoint) {
  const response = await context.request.get(`${baseUrl}${endpoint}`, {
    headers: {
      Accept: 'application/json, text/plain, */*',
      Referer: targetUrl,
      'User-Agent': auth.userAgent,
      'new-api-user': auth.userId,
      Cookie: auth.cookieHeader
    },
    timeout: 20000
  });

  const text = await response.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
  }

  log(`API ${endpoint}：HTTP ${response.status()} ${summarize(text, 120)}`);
  return { ok: response.ok(), status: response.status(), text, json };
}

async function readApiBalance(context, auth) {
  const endpoints = [
    '/api/user/self',
    '/api/user',
    '/api/user/info',
    '/api/profile',
    '/api/dashboard/billing'
  ];

  for (const endpoint of endpoints) {
    const result = await apiGet(context, auth, endpoint).catch(() => null);
    if (!result || !result.ok) {
      continue;
    }
    const best = pickBestBalance(collectBalanceCandidatesFromJson(result.json, endpoint));
    if (best) {
      return best;
    }
  }

  return null;
}

async function readAndSaveBalance(context) {
  const auth = await preparePageContext(context, { runCheckInBeforeRead: false });
  const apiBalance = await readApiBalance(context, auth).catch((error) => {
    log(`余额日志：接口读取余额失败：${error?.message || error}`);
    return null;
  });
  const accountBalance = apiBalance || auth.pageBalance || null;
  if (!accountBalance) {
    log('余额日志：未读取到账户余额。');
    await updateDrawStatePatch({
      accountBalance: null,
      lastBalanceStatus: 'not-found'
    });
    return null;
  }

  await updateDrawStatePatch({
    accountBalance,
    lastBalanceStatus: 'ok'
  });
  log(`余额日志：当前${accountBalance.displayText}`);
  return accountBalance;
}

async function runApiCycle(context) {
  const auth = await prepareAuth(context);
  const apiBalance = await readApiBalance(context, auth).catch((error) => {
    log(`余额日志：接口读取余额失败：${error?.message || error}`);
    return null;
  });
  const accountBalance = apiBalance || auth.pageBalance || null;
  if (accountBalance) {
    log(`余额日志：当前${accountBalance.displayText}`);
  }

  await apiPost(context, auth, '/api/gwent/share_unlock').catch((error) => {
    log(`API /api/gwent/share_unlock 失败：${error.message}`);
    return null;
  });

  let attempts = 0;
  let cooldownMs = auth.pageCooldownMs ?? null;
  let cooldownText = auth.pageCooldownText || '';
  let status = 'not-run';
  const prizes = [];
  const initialDrawStatus = auth.pageDrawStatus || {};
  const maxDrawAttempts = initialDrawStatus.remaining == null
    ? drawLimit
    : Math.min(drawLimit, Math.max(initialDrawStatus.remaining, 0));
  const drawState = await readDrawState();
  drawState.totalAttempts = Math.max(drawState.totalAttempts, await countSuccessfulDrawHistory());

  if (initialDrawStatus.raw) {
    log(`抽奖日志：页面显示本轮次数 ${initialDrawStatus.raw}，本次最多尝试 ${maxDrawAttempts} 次。`);
  }

  if (maxDrawAttempts <= 0) {
    status = 'no-chance';
    if (cooldownMs) {
      const nextTime = new Date(Date.now() + getNextWatchDelay({ draws: { cooldownMs } }));
      await recordDrawHistory(`抽奖日志：本轮次数已用完，预计 ${formatTime(nextTime)} 再试：${cooldownText || initialDrawStatus.raw || '页面显示无剩余次数'}`);
    } else {
      await recordDrawHistory(`抽奖日志：本轮次数已用完：${initialDrawStatus.raw || '页面显示无剩余次数'}`);
    }
  }

  for (let index = 0; index < maxDrawAttempts; index += 1) {
    const result = await apiPost(context, auth, '/api/gwent/draw');
    attempts += 1;

    if (responseMeansAuthExpired(result)) {
      await updateDrawStatePatch({
        lastRunAt: isoTime(new Date()),
        lastCooldownMs: null,
        lastCooldownText: '',
        nextDelayMs: null,
        nextRunAt: null,
        lastStatus: 'auth-expired',
        lastPrizes: prizes
      });
      await recordDrawHistory('抽奖日志：登录状态失效，请重新点击“首次登录”。');
      throw new Error('登录状态已失效或接口返回 Unauthorized。请在控制台点击“首次登录”重新登录。');
    }

    status = result.ok ? 'requested' : 'http-error';
    const resultCooldownMs = responseCooldownMs(result);
    const resultText = summarize(stringifyPayload(result), 180);

    const prize = getDrawPrize(result);
    if (prize) {
      const prizeText = describePrize(prize);
      prizes.push(prizeText);
      drawState.totalAttempts += 1;
      await writeDrawState(drawState);
      await recordDrawHistory(`抽奖日志：本轮第 ${attempts} 次 / 累计 ${drawState.totalAttempts} 次：${prizeText}`);
    }

    if (!result.ok || (!prize && responseMeansStop(result))) {
      if (resultCooldownMs) {
        cooldownMs = resultCooldownMs;
        cooldownText = resultText;
      }
      if (!prize) {
        const attemptText = attempts > 1 ? `第 ${attempts} 次尝试` : '本轮';
        if (resultCooldownMs || cooldownMs) {
          const nextTime = new Date(Date.now() + getNextWatchDelay({ draws: { cooldownMs } }));
          await recordDrawHistory(`抽奖日志：${attemptText}被冷却挡住，预计 ${formatTime(nextTime)} 再试：${resultText || cooldownText}`);
        } else {
          await recordDrawHistory(`抽奖日志：${attemptText}未抽到新奖励：${resultText}`);
        }
      }
      break;
    }

    await sleep(1200);
  }

  if (attempts > 0 && prizes.length < attempts) {
    log(`抽奖日志：本轮请求 ${attempts} 次，成功记录 ${prizes.length} 次，请以历史记录和网页次数为准。`);
  }

  const prizeText = prizes.length ? `，结果=${prizes.join('；')}` : '';
  log(`API翻牌完成：请求次数=${attempts}，状态=${status}${prizeText}`);
  const finishedAt = new Date();
  const nextDelayMs = getNextWatchDelay({ draws: { cooldownMs } });
  await updateDrawStatePatch({
    lastRunAt: isoTime(finishedAt),
    lastCooldownMs: Number.isFinite(cooldownMs) && cooldownMs > 0 ? cooldownMs : null,
    lastCooldownText: cooldownText || '',
    nextDelayMs,
    nextRunAt: isoTime(new Date(finishedAt.getTime() + nextDelayMs)),
    lastStatus: status,
    lastPrizes: prizes,
    accountBalance
  });
  return { draws: { attempts, cooldownMs, status, prizes } };
}

function getNextWatchDelay(result) {
  const fallbackMs = watchIntervalMinutes * 60 * 1000;
  const bufferMs = watchBufferSeconds * 1000;
  const cooldownMs = result?.draws?.cooldownMs;

  if (Number.isFinite(cooldownMs) && cooldownMs > 0) {
    return Math.max(cooldownMs + bufferMs, 60 * 1000);
  }

  return fallbackMs + bufferMs;
}

async function runApiWatch(context) {
  log(`API守候：启动后立即请求一次；读不到冷却时，每 ${watchIntervalMinutes} 分钟检查一次。`);
  let round = 1;

  while (true) {
    log(`API守候：第 ${round} 轮开始。`);
    const result = await runApiCycle(context);
    const delay = getNextWatchDelay(result);
    const nextTime = new Date(Date.now() + delay);
    log(`API守候：下一轮约 ${formatTime(nextTime)}，等待 ${formatDuration(delay)}。`);
    await sleep(delay);
    round += 1;
  }
}

async function main() {
  await ensureDirs();

  let context;

  try {
    if (isProfileBrowserRunning()) {
      throw new Error('检测到首次登录浏览器或登录命令窗口仍在运行。请先关闭登录浏览器窗口，并在登录命令窗口按 Enter；如果找不到窗口，请运行 VSLLM-清理残留登录.bat。');
    }

    const browserLaunchOptions = await getBrowserLaunchOptions();
    context = await chromium.launchPersistentContext(authDir, {
      ...browserLaunchOptions,
      headless: !headed,
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

    if (isWatchMode) {
      await runApiWatch(context);
    } else if (isBalanceMode) {
      await readAndSaveBalance(context);
    } else {
      await runApiCycle(context);
    }
  } catch (error) {
    log(`API运行失败：${error?.message || error}`);
    if (errorMeansAuthExpired(error)) {
      await updateDrawStatePatch({
        lastRunAt: isoTime(new Date()),
        lastCooldownMs: null,
        lastCooldownText: '',
        nextDelayMs: null,
        nextRunAt: null,
        lastStatus: 'auth-expired',
        lastPrizes: []
      }).catch(() => {});
      await recordDrawHistory('抽奖日志：登录状态失效，请重新点击“首次登录”。').catch(() => {});
    }
    if (String(error?.message || error).includes('playwright install')) {
      log('请先运行：npx playwright install chromium');
    }
    process.exitCode = 1;
  } finally {
    await context?.close().catch(() => {});
  }
}

main();
