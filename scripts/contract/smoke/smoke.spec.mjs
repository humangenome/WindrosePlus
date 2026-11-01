// Opens the dashboard, the Sea Chart as the dashboard embeds it, and the public map at five widths, twice, on
// the made-up game folder. Each page must show the folder's data, keep inside the window (no sideways scroll),
// log no script error and load nothing that fails, apart from the answers the folder makes on purpose.
import { test, expect } from '@playwright/test';
import fs from 'node:fs';

const PASSWORD = 'contract-pass-123';
const TOKEN = 'contract-map-token';
const WIDTHS = [390, 768, 1024, 1440, 1920];
const ROUNDS = 2;
// the made-up folder has no runtime overlay, on purpose
const EXPECTED_FAILURES = [/\/api\/(public\/)?runtime-overlay(\?|$)/, /\/favicon\.ico$/];

const pages = [
  {
    name: 'dashboard', path: '/', login: true,
    ready: async (page) => {
      await expect(page.locator('#server-name')).toContainText('Contract Test Server', { timeout: 20000 });
      await expect(page.locator('#player-count')).toHaveText('2', { timeout: 20000 });
    },
  },
  {
    name: 'sea-chart-embedded', path: '/livemap?embed=1', login: true,
    ready: async (page) => {
      await expect(page.locator('#map.leaflet-container')).toBeVisible({ timeout: 20000 });
      await expect(page.locator('#loading')).toBeHidden({ timeout: 20000 });
    },
  },
  {
    name: 'public-map', path: `/public-map?token=${TOKEN}`, login: false,
    ready: async (page) => {
      await expect(page.locator('#map.leaflet-container')).toBeVisible({ timeout: 20000 });
      await expect(page.locator('#loading')).toBeHidden({ timeout: 20000 });
    },
  },
];

async function logIn(context, baseURL) {
  const answer = await context.request.post(`${baseURL}/login`, {
    form: { password: PASSWORD }, maxRedirects: 0,
  });
  expect(answer.status(), 'login answers with a redirect').toBe(302);
}

for (let round = 1; round <= ROUNDS; round++) {
  for (const width of WIDTHS) {
    for (const p of pages) {
      test(`round ${round}: ${p.name} at ${width}px`, async ({ browser, baseURL }) => {
        const context = await browser.newContext({ viewport: { width, height: width < 768 ? 844 : 900 } });
        if (p.login) await logIn(context, baseURL);
        const page = await context.newPage();
        const problems = [];
        page.on('pageerror', (e) => problems.push(`script error: ${e.message}`));
        page.on('console', (m) => {
          if (m.type() !== 'error') return;
          const url = (m.location() && m.location().url) || '';
          if (/Failed to load resource/.test(m.text()) && EXPECTED_FAILURES.some((r) => r.test(url))) return;
          problems.push(`console error: ${m.text()} ${url}`);
        });
        page.on('response', (r) => {
          if (r.status() >= 400 && !EXPECTED_FAILURES.some((x) => x.test(r.url()))) problems.push(`${r.status()} ${r.url()}`);
        });
        page.on('requestfailed', (r) => {
          const why = (r.failure() && r.failure().errorText) || '';
          if (!/ERR_ABORTED/.test(why)) problems.push(`request failed: ${r.url()} ${why}`);
        });

        await page.goto(p.path, { waitUntil: 'load' });
        await p.ready(page);
        await page.waitForTimeout(1500);

        const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
        fs.mkdirSync('test-results/shots', { recursive: true });
        await page.screenshot({ path: `test-results/shots/r${round}-${p.name}-${width}.png`, fullPage: false });
        expect(overflow, 'the page scrolls sideways by this many pixels').toBeLessThanOrEqual(1);
        expect(problems, 'errors and failed loads').toEqual([]);
        await context.close();
      });
    }
  }
}

// Every stat key in a real catalog (scripts/contract/stat-labels.json) gets its listed label from the page's own
// rules too (readableStatName, used for catalogs built before the builder wrote labels). No browser needed.
test('items panel: every stat key in a real catalog gets its listed label', async () => {
  const repo = new URL('../../../', import.meta.url);
  const html = fs.readFileSync(new URL('server/web/livemap/index.html', repo), 'utf8');
  const start = html.indexOf('var STAT_NAMES'), end = html.indexOf('function formatStatEntry');
  expect(start, 'STAT_NAMES found').toBeGreaterThan(0);
  expect(end, 'formatStatEntry found').toBeGreaterThan(start);
  const mod = { exports: null };
  new Function('module', html.slice(start, end) + '\nmodule.exports = readableStatName;')(mod);
  const list = JSON.parse(fs.readFileSync(new URL('scripts/contract/stat-labels.json', repo), 'utf8'));
  expect(list.keys.length).toBeGreaterThan(250);
  const wrong = list.keys.filter((k) => mod.exports(k.stat, k.row) !== k.label)
    .map((k) => `${k.stat} ${k.row} -> ${mod.exports(k.stat, k.row)} (listed ${k.label})`);
  expect(wrong).toEqual([]);
});

// The Items panel names stats in player words: by the label the catalog builder writes, and by the same rules for a
// catalog built before labels (item 1 carries only the game's code names).
test('items panel: readable stat names', async ({ browser, baseURL }) => {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  await logIn(context, baseURL);
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.goto('/livemap?embed=1', { waitUntil: 'load' });
  await expect(page.locator('#map.leaflet-container')).toBeVisible({ timeout: 20000 });
  const detail = page.locator('#wpitems-detail');
  await page.evaluate(() => window.WindroseItems.open('Contract_Item_1'));
  await expect(detail).toContainText('Ship range', { timeout: 20000 });
  await expect(detail).toContainText('Ability cooldown');
  await expect(detail).toContainText('2 min');
  await expect(detail).not.toContainText('ShipFireRangeRANK');
  await expect(detail).not.toContainText('Cutlass_Contract_AbilityCooldown');
  await page.evaluate(() => window.WindroseItems.open('Contract_Item_2'));
  await expect(detail).toContainText('Attack power', { timeout: 20000 });
  await expect(detail).toContainText('Critical chance');
  await expect(detail).toContainText('15%');
  fs.mkdirSync('test-results/shots', { recursive: true });
  await page.screenshot({ path: 'test-results/shots/items-panel-1440.png' });
  expect(errors, 'script errors').toEqual([]);
  await context.close();
});
