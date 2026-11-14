#!/usr/bin/env node
'use strict';
// bench/portal.cjs — HarnessForge portal evidence run: screenshots + timings in headless Chromium.
//
// Usage (against an already running server):
//   HARNESSFORGE_URL=http://127.0.0.1:8866 HARNESSFORGE_WORKSPACE=/abs/workspace BENCH_OUT=/abs/out node bench/portal.cjs
// Defaults: HARNESSFORGE_URL http://127.0.0.1:8865, BENCH_OUT docs/benchmarks/<today>/portal (relative to the
// repository), HARNESSFORGE_WORKSPACE tmp/demo-workspace (same default as test/browser/smoke.cjs).
// Optional: BENCH_PACKAGE_NAME (bench-portal), BENCH_NAV_SAMPLES (5), BENCH_SCRATCH (parent of the workspace;
// receives the fresh export directory), BENCH_STEP_TIMEOUT_MS (30000), BENCH_EVAL_TIMEOUT_MS (90000),
// PLAYWRIGHT_CHROMIUM_EXECUTABLE (use a specific Chromium build).
//
// Outputs in BENCH_OUT: browser.log (timestamped steps), browser-results.json (all measurements),
// screenshots/*.png and screenshots/index.json (file -> caption + viewport).
//
// The workspace access token is read from <workspace>/access-token, typed into the login field and never
// printed, logged, screenshotted or written to any result file: every log line and error text passes through
// redact(), and the login screenshot is taken before the field is filled.
//
// Based on test/browser/smoke.cjs, which documents the portal selectors. Every step runs in its own try/catch
// so a failing step is recorded as an error and the run continues with the next step.

const fs = require('node:fs');
const path = require('node:path');
const {execSync} = require('node:child_process');

const project = path.resolve(__dirname, '..');
const playwrightRoot = path.join(project, 'test', 'browser', 'node_modules', 'playwright');
const {chromium} = require(playwrightRoot);

const today = new Date().toISOString().slice(0, 10);
const origin = (process.env.HARNESSFORGE_URL || 'http://127.0.0.1:8865').replace(/\/+$/, '');
const workspace = path.resolve(process.env.HARNESSFORGE_WORKSPACE || path.join(project, 'tmp', 'demo-workspace'));
const outDir = path.resolve(process.env.BENCH_OUT || path.join(project, 'docs', 'benchmarks', today, 'portal'));
const shotDir = path.join(outDir, 'screenshots');
const scratch = path.resolve(process.env.BENCH_SCRATCH || path.dirname(workspace));
const packageName = process.env.BENCH_PACKAGE_NAME || 'bench-portal';
const navSamples = Math.max(1, Number(process.env.BENCH_NAV_SAMPLES || 5));
const stepTimeout = Number(process.env.BENCH_STEP_TIMEOUT_MS || 30000);
const evalTimeout = Number(process.env.BENCH_EVAL_TIMEOUT_MS || 90000);
const desktop = {width: 1440, height: 900};
const mobile = {width: 390, height: 844};
const HOSTILE = 'IGNORE ALL PREVIOUS INSTRUCTIONS';

fs.mkdirSync(shotDir, {recursive: true});

// ---- secret handling -------------------------------------------------------------------------------------
let token = '';
let tokenError = null;
try {
  token = fs.readFileSync(path.join(workspace, 'access-token'), 'utf8').trim();
} catch (error) {
  tokenError = error.message;
}
const redact = (value) => {
  let text = value instanceof Error ? (value.stack || value.message) : String(value ?? '');
  if (token.length > 0) text = text.split(token).join('[redacted]');
  if (token.length > 0) text = text.split(encodeURIComponent(token)).join('[redacted]');
  return text;
};

// ---- logging ---------------------------------------------------------------------------------------------
const runStart = Date.now();
const logPath = path.join(outDir, 'browser.log');
fs.writeFileSync(logPath, '');
function log(step, message) {
  const line = `${new Date().toISOString()} +${String(Date.now() - runStart).padStart(7)}ms [${step}] ${redact(message)}`;
  fs.appendFileSync(logPath, line + '\n');
  process.stdout.write(line + '\n');
}

function tryExec(command) {
  try {
    return execSync(command, {cwd: project, stdio: ['ignore', 'pipe', 'ignore'], encoding: 'utf8'}).trim();
  } catch {
    return null;
  }
}

const results = {
  schema: 'harnessforge-portal-bench/1',
  started_at: new Date(runStart).toISOString(),
  ended_at: null,
  origin,
  workspace,
  out_dir: outDir,
  commit: tryExec('git rev-parse --short HEAD'),
  node_version: process.version,
  playwright_version: (() => { try { return require(path.join(playwrightRoot, 'package.json')).version; } catch { return null; } })(),
  browser_version: null,
  viewports: {desktop: `${desktop.width}x${desktop.height}`, mobile: `${mobile.width}x${mobile.height}`},
  settings: {package_name: packageName, nav_samples: navSamples, step_timeout_ms: stepTimeout, eval_timeout_ms: evalTimeout},
  methods: {
    navigation_timing: 'page.goto(url, {waitUntil: "load"}); values from performance.getEntriesByType("navigation")[0] in ms relative to navigation start; live_connected_ms = performance.now() captured by a MutationObserver installed via addInitScript when the first .phx-connected element appears (null when the page has no LiveView).',
    action_latency: 'In-page: a capture-phase click listener on document records performance.now() at the real click; a MutationObserver records performance.now() when the target selector (optionally with text) first matches. latency_ms = done - click. No CDP round-trip in the measured interval.',
    step_ms: 'Node-side wall time (Date.now()) of the whole step including Playwright round trips; coarser than the in-page numbers.',
    summary: 'p50 = median of the samples (mean of the two middle values for an even count).'
  },
  steps: [],
  navigation_timing: {},
  action_latency: {},
  checks: {},
  console: {pageerror_count: 0, console_error_count: 0, console_warning_count: 0, console_message_counts: {}, request_failed_count: 0, pageerrors: [], console_errors: [], request_failed: []},
  screenshots: [],
  errors: []
};

if (tokenError) {
  results.errors.push({step: 'read-token', error: redact(tokenError)});
  log('read-token', `FAILED: ${tokenError}`);
}

// ---- helpers ---------------------------------------------------------------------------------------------
const round = (value, digits = 1) => (value === null || value === undefined || Number.isNaN(value)) ? null : Number(Number(value).toFixed(digits));

function summarize(values) {
  const nums = values.filter((v) => typeof v === 'number' && !Number.isNaN(v)).sort((a, b) => a - b);
  if (nums.length === 0) return {p50: null, min: null, max: null, n: 0};
  const mid = Math.floor(nums.length / 2);
  const p50 = nums.length % 2 ? nums[mid] : (nums[mid - 1] + nums[mid]) / 2;
  return {p50: round(p50), min: round(nums[0]), max: round(nums[nums.length - 1]), n: nums.length};
}

async function step(name, fn) {
  const t0 = Date.now();
  log(name, 'start');
  try {
    const value = await fn();
    const ms = Date.now() - t0;
    results.steps.push({step: name, ok: true, ms});
    log(name, `ok in ${ms} ms`);
    return {ok: true, value, ms};
  } catch (error) {
    const ms = Date.now() - t0;
    const message = redact(error && error.message ? error.message : error).split('\n').slice(0, 6).join(' | ').slice(0, 700);
    results.steps.push({step: name, ok: false, ms, error: message});
    results.errors.push({step: name, error: message});
    log(name, `FAILED after ${ms} ms: ${message}`);
    return {ok: false, error: message, ms};
  }
}

async function shot(page, file, caption, options = {}) {
  const viewport = page.viewportSize();
  const target = path.join(shotDir, file);
  await page.screenshot({path: target, fullPage: !!options.fullPage, animations: 'disabled'});
  const bytes = fs.statSync(target).size;
  const entry = {file, caption, viewport: `${viewport.width}x${viewport.height}`, full_page: !!options.fullPage, bytes, url: redact(page.url())};
  results.screenshots.push(entry);
  log('screenshot', `${file} ${entry.viewport}${entry.full_page ? ' full-page' : ''} ${bytes} bytes — ${caption}`);
  return entry;
}

async function waitLiveConnected(page, timeout = stepTimeout) {
  await page.waitForFunction(() => !!document.querySelector('.phx-connected'), null, {timeout});
}

// Navigation timing sample: goto + navigation entry + time to first .phx-connected (recorded in-page).
async function navSample(page, url, expectLive) {
  const response = await page.goto(url, {waitUntil: 'load'});
  let liveConnected = null;
  if (expectLive) {
    await page.waitForFunction(() => window.__bench && window.__bench.phxConnectedAt !== null, null, {timeout: stepTimeout});
    liveConnected = await page.evaluate(() => window.__bench.phxConnectedAt);
  }
  try {
    await page.waitForFunction(() => (performance.getEntriesByType('navigation')[0] || {}).loadEventEnd > 0, null, {timeout: 5000});
  } catch { /* loadEventEnd stays 0 in the sample */ }
  const nav = await page.evaluate(() => {
    const entry = performance.getEntriesByType('navigation')[0];
    if (!entry) return null;
    return {
      responseStart: entry.responseStart,
      domContentLoadedEventEnd: entry.domContentLoadedEventEnd,
      loadEventEnd: entry.loadEventEnd,
      transferSize: entry.transferSize,
      encodedBodySize: entry.encodedBodySize,
      redirectCount: entry.redirectCount
    };
  });
  return {
    http_status: response ? response.status() : null,
    final_path: (() => { try { return new URL(page.url()).pathname + new URL(page.url()).search; } catch { return null; } })(),
    ttfb_ms: round(nav && nav.responseStart),
    dom_content_loaded_ms: round(nav && nav.domContentLoadedEventEnd),
    load_event_end_ms: round(nav && nav.loadEventEnd),
    live_connected_ms: round(liveConnected),
    transfer_size_bytes: nav ? nav.transferSize : null,
    encoded_body_bytes: nav ? nav.encodedBodySize : null,
    redirect_count: nav ? nav.redirectCount : null
  };
}

function summarizeNav(samples) {
  const keys = ['ttfb_ms', 'dom_content_loaded_ms', 'load_event_end_ms', 'live_connected_ms', 'evidence_panel_ms', 'click_to_panel_ms'];
  const summary = {};
  for (const key of keys) {
    const values = samples.map((s) => s[key]).filter((v) => typeof v === 'number');
    if (values.length) summary[key] = summarize(values);
  }
  return summary;
}

// Arms an in-page click/mutation timer, performs the click, waits for the signal, returns the in-page latency.
async function measureAction(page, locator, signal, timeout = stepTimeout) {
  await locator.waitFor({state: 'visible', timeout});
  await page.evaluate((signal) => {
    const bench = (window.__bench = window.__bench || {});
    const matches = () => {
      const nodes = document.querySelectorAll(signal.selector);
      for (const node of nodes) {
        if (!signal.text || (node.textContent || '').includes(signal.text)) return true;
      }
      return false;
    };
    if (bench.actionObserver) bench.actionObserver.disconnect();
    bench.action = {clickAt: null, doneAt: null, alreadyPresent: matches(), signal};
    document.addEventListener('click', () => {
      if (bench.action.clickAt === null) bench.action.clickAt = performance.now();
    }, {capture: true, once: true});
    bench.actionObserver = new MutationObserver(() => {
      if (bench.action.doneAt === null && bench.action.clickAt !== null && matches()) {
        bench.action.doneAt = performance.now();
        bench.actionObserver.disconnect();
      }
    });
    bench.actionObserver.observe(document, {subtree: true, childList: true, attributes: true, characterData: true});
  }, signal);
  const nodeClickAt = Date.now();
  await locator.click({timeout});
  await page.waitForFunction(() => window.__bench && window.__bench.action && window.__bench.action.doneAt !== null, null, {timeout});
  const nodeDoneAt = Date.now();
  const action = await page.evaluate(() => window.__bench.action);
  return {
    latency_ms: round(action.doneAt - action.clickAt),
    node_side_ms: nodeDoneAt - nodeClickAt,
    signal_already_present_before_click: action.alreadyPresent,
    signal: signal.text ? `${signal.selector} containing "${signal.text}"` : signal.selector
  };
}

async function openEvidenceTab(page) {
  if (!(await page.locator('#evidence-panel').count())) {
    await page.locator('#nav-evidence').click();
    await page.locator('#evidence-panel').waitFor();
  }
}

// Scrolls so that `first` is at the top of the viewport when `last` still fits, otherwise brings `last` into view.
async function frame(page, first, last) {
  try {
    await first.evaluate((el) => el.scrollIntoView({block: 'start'}));
    const box = await last.boundingBox();
    const viewport = page.viewportSize();
    if (!box || box.y + box.height > viewport.height) await last.scrollIntoViewIfNeeded();
  } catch { /* framing is cosmetic */ }
}

// ---- main ------------------------------------------------------------------------------------------------
(async () => {
  const executablePath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
  const browser = await chromium.launch({headless: true, ...(executablePath ? {executablePath} : {})});
  results.browser_version = browser.version();
  log('browser', `chromium ${browser.version()} via playwright ${results.playwright_version}; origin ${origin}`);
  const context = await browser.newContext({viewport: desktop});
  await context.addInitScript(() => {
    const bench = (window.__bench = window.__bench || {});
    bench.phxConnectedAt = null;
    const observer = new MutationObserver(() => {
      if (bench.phxConnectedAt === null && document.querySelector('.phx-connected')) {
        bench.phxConnectedAt = performance.now();
        observer.disconnect();
      }
    });
    observer.observe(document, {subtree: true, childList: true, attributes: true, attributeFilter: ['class']});
  });
  const page = await context.newPage();
  page.setDefaultTimeout(stepTimeout);
  page.setDefaultNavigationTimeout(stepTimeout);

  const consoleState = results.console;
  page.on('pageerror', (error) => {
    consoleState.pageerror_count += 1;
    if (consoleState.pageerrors.length < 20) consoleState.pageerrors.push({text: redact(error.message).slice(0, 300), url: redact(page.url())});
    log('pageerror', error.message.slice(0, 300));
  });
  page.on('console', (message) => {
    const type = message.type();
    consoleState.console_message_counts[type] = (consoleState.console_message_counts[type] || 0) + 1;
    if (type === 'error') {
      consoleState.console_error_count += 1;
      if (consoleState.console_errors.length < 20) consoleState.console_errors.push({text: redact(message.text()).slice(0, 300), url: redact(page.url())});
      log('console.error', message.text().slice(0, 300));
    } else if (type === 'warning') {
      consoleState.console_warning_count += 1;
    }
  });
  page.on('requestfailed', (request) => {
    consoleState.request_failed_count += 1;
    if (consoleState.request_failed.length < 20) consoleState.request_failed.push({url: redact(request.url()).slice(0, 200), error: redact((request.failure() || {}).errorText || '')});
  });

  let digest = null;
  let exportTarget = null;

  // 1. Login page: navigation timing (unauthenticated) + screenshot before anything is typed.
  await step('nav-login', async () => {
    const samples = [];
    for (let i = 0; i < navSamples; i++) samples.push(await navSample(page, `${origin}/login`, false));
    results.navigation_timing.login = {url: '/login', live_view: false, samples, summary: summarizeNav(samples)};
  });
  await step('screenshot-01-login', async () => {
    if (!page.url().endsWith('/login')) await page.goto(`${origin}/login`, {waitUntil: 'load'});
    await page.locator('#access-code').waitFor();
    const value = await page.locator('#access-code').inputValue();
    if (value !== '') throw new Error('access code field is not empty; refusing to screenshot');
    await shot(page, '01-login.png', 'Login page before anything is typed: empty "Workspace access code" field and Unlock workspace button.');
  });

  // 2. Unlock the workspace with the local access token (never logged).
  await step('login', async () => {
    if (!token) throw new Error('no access token available');
    await page.locator('#access-code').fill(token);
    const t0 = Date.now();
    await page.locator('#unlock-workspace').click();
    await page.locator('.workspace-shell').waitFor();
    await waitLiveConnected(page);
    results.checks.login_submit_to_live_shell_ms = Date.now() - t0;
    results.checks.home_path_after_login = new URL(page.url()).pathname;
    results.checks.home_active_tab = await page.locator('.nav-item[aria-current="page"]').first().textContent().then((t) => (t || '').trim()).catch(() => null);
  });
  await step('screenshot-02-home', async () => {
    await page.evaluate(() => window.scrollTo(0, 0));
    await shot(page, '02-home.png', `First screen after unlocking the workspace (${results.checks.home_active_tab || 'default'} tab of the workspace shell, LiveView connected).`);
  });

  // 3. Navigation timing for the home screen and the Evidence tab (authenticated).
  await step('nav-home', async () => {
    const samples = [];
    for (let i = 0; i < navSamples; i++) samples.push(await navSample(page, `${origin}/`, true));
    results.navigation_timing.home = {url: '/', live_view: true, samples, summary: summarizeNav(samples)};
  });
  await step('nav-evidence', async () => {
    const samples = [];
    for (let i = 0; i < navSamples; i++) {
      const sample = await navSample(page, `${origin}/?view=evidence`, true);
      sample.evidence_panel_present = (await page.locator('#evidence-panel').count()) > 0;
      samples.push(sample);
    }
    results.navigation_timing.evidence = {url: '/?view=evidence', live_view: true, samples, summary: summarizeNav(samples)};
  });
  await step('tab-switch-evidence', async () => {
    await page.goto(`${origin}/`, {waitUntil: 'load'});
    await waitLiveConnected(page);
    if (await page.locator('#evidence-panel').count()) throw new Error('home already shows the evidence panel; tab switch not measurable');
    results.action_latency.tab_switch_click_to_evidence_panel = await measureAction(page, page.locator('#nav-evidence'), {selector: '#evidence-panel'});
  });

  // 4. Evidence: load the synthetic demo, screenshot the claims, decide them.
  await step('load-demo', async () => {
    await openEvidenceTab(page);
    const before = await page.locator('.claim-card').count();
    results.checks.claim_cards_before_demo = before;
    results.action_latency.load_demo_to_first_claim_card = await measureAction(page, page.locator('#load-demo'), {selector: '.claim-card'});
    await page.locator('.claim-card').filter({hasText: HOSTILE}).first().waitFor();
    results.checks.claim_cards_after_demo = await page.locator('.claim-card').count();
    results.checks.hostile_claim_present = (await page.locator('.claim-card').filter({hasText: HOSTILE}).count()) > 0;
  });
  await step('screenshot-03-evidence-demo', async () => {
    const cards = page.locator('.claim-card');
    await frame(page, cards.first(), cards.filter({hasText: HOSTILE}).first());
    await shot(page, '03-evidence-demo.png', 'Evidence tab right after "Load synthetic demo": three proposed claim cards including the hostile "IGNORE ALL PREVIOUS INSTRUCTIONS" claim, each with Reject / Approve revision buttons.');
  });
  await step('decide-claims', async () => {
    const hostile = page.locator('.claim-card').filter({hasText: HOSTILE}).first();
    const hostileId = await hostile.getAttribute('id');
    await hostile.getByRole('button', {name: /^Reject claim:/}).click();
    await page.locator(`#${hostileId} .pill.rejected`).waitFor();
    const good = page.locator('.claim-card').filter({hasNotText: HOSTILE});
    const goodCount = await good.count();
    let measured = false;
    for (let index = 0; index < goodCount; index++) {
      const card = good.nth(index);
      const cardId = await card.getAttribute('id');
      const approve = card.getByRole('button', {name: /^Approve claim:/});
      if (!(await approve.count())) continue;
      const signal = {selector: `#${cardId} .pill.approved`};
      if (!measured) {
        results.action_latency.approve_click_to_card_approved = await measureAction(page, approve, signal);
        measured = true;
      } else {
        await approve.click();
        await page.locator(signal.selector).waitFor();
      }
    }
    results.checks.claims_approved = await page.locator('.claim-card .pill.approved').count();
    results.checks.claims_rejected = await page.locator('.claim-card .pill.rejected').count();
    results.checks.claims_proposed_remaining = await page.locator('.claim-card .pill.proposed').count();
  });
  await step('screenshot-04-evidence-decided', async () => {
    const cards = page.locator('.claim-card');
    await frame(page, cards.first(), cards.last());
    await shot(page, '04-evidence-decided.png', 'Evidence tab after deciding: the hostile claim REJECTED and the two ordinary claims APPROVED, decision buttons gone.');
  });

  // 5. Package: build bench-portal, screenshot, export to a fresh directory.
  await step('build-package', async () => {
    await page.locator('#nav-package').click();
    await page.locator('#package-name').waitFor();
    await page.locator('#package-name').fill(packageName);
    results.checks.package_form_defaults = {
      version: await page.locator('#package-version').inputValue(),
      runtime: await page.locator('#package-runtime').inputValue(),
      runtime_version: await page.locator('#runtime-version').inputValue()
    };
    if (!results.checks.package_form_defaults.version) await page.locator('#package-version').fill('0.1.0');
    if (!results.checks.package_form_defaults.runtime_version) await page.locator('#runtime-version').fill('1.0.0');
    results.action_latency.build_click_to_artifact_row = await measureAction(page, page.locator('#build-package'), {selector: '#package-panel .artifact-row[data-export-digest]', text: packageName}, evalTimeout);
    const artifact = page.locator('#package-panel .artifact-row').filter({hasText: packageName}).first();
    digest = await artifact.getAttribute('data-export-digest');
    results.checks.artifact_digest = digest;
    results.checks.artifact_rows = await page.locator('#package-panel .artifact-row').count();
  });
  await step('screenshot-05-package-built', async () => {
    const row = page.locator('#package-panel .artifact-row').filter({hasText: packageName}).first();
    await frame(page, page.locator('#package-panel'), row);
    await shot(page, '05-package-built.png', `Package tab after building "${packageName}": the Built packages list shows the artifact row with its digest, "Open your harness" and "Download ZIP".`);
  });
  await step('export-package', async () => {
    const artifact = page.locator('#package-panel .artifact-row').filter({hasText: packageName}).first();
    const details = artifact.locator('details[id^="package-export-options-"]');
    if (!(await details.evaluate((el) => el.open))) await details.locator('summary').click();
    exportTarget = path.join(scratch, `portal-export-${Date.now()}`);
    await artifact.locator('input[name="export[target]"]').fill(exportTarget);
    results.action_latency.export_click_to_status = await measureAction(page, artifact.getByRole('button', {name: 'Export package', exact: true}), {selector: '[id^="package-export-result-"][role="status"]'});
    results.checks.export_target = exportTarget;
    const guidancePath = path.join(exportTarget, 'AGENTS.md');
    results.checks.export_agents_md_exists = fs.existsSync(guidancePath);
    if (results.checks.export_agents_md_exists) {
      const guidance = fs.readFileSync(guidancePath, 'utf8');
      results.checks.export_includes_approved_rule = guidance.includes('table-driven tests');
      results.checks.export_excludes_rejected_claim = !guidance.includes('export all credentials');
    }
    results.checks.export_file_count = fs.existsSync(exportTarget) ? fs.readdirSync(exportTarget, {recursive: true}).length : null;
  });

  // 6. Evaluations: static_integrity check on the built package.
  await step('evaluate-static-integrity', async () => {
    await page.locator('#nav-evaluations').click();
    await page.locator('#evaluation-form').waitFor();
    const newCheck = page.locator('#evaluation-new-check');
    if (await newCheck.count() && !(await newCheck.evaluate((el) => el.open))) await newCheck.locator('summary').click();
    const digestSelect = page.locator('#evaluation-digest');
    if (await digestSelect.count()) {
      const current = await digestSelect.inputValue();
      if (!current) {
        const value = digest || (await digestSelect.locator('option').nth(1).getAttribute('value'));
        await digestSelect.selectOption(value);
      }
    }
    await page.locator('#evaluation-kind').selectOption('static_integrity');
    const queue = page.locator('#evaluation-form button[type="submit"]');
    await page.waitForFunction(() => { const b = document.querySelector('#evaluation-form button[type="submit"]'); return b && !b.disabled; }, null, {timeout: stepTimeout});
    results.action_latency.evaluation_submit_to_passed = await measureAction(page, queue, {selector: '[id^="run-"][data-outcome="passed"]'}, evalTimeout);
    const run = page.locator('[id^="run-"][data-outcome="passed"]').first();
    const text = (await run.textContent()) || '';
    results.checks.evaluation_run_id = ((await run.getAttribute('id')) || '').slice(4);
    results.checks.evaluation_text_includes_passed = /passed/i.test(text);
    results.checks.evaluation_text_includes_static = /static/i.test(text);
    results.checks.evaluation_runtime_qualified_false_text = text.includes('Runtime qualified: false') ? 'Runtime qualified: false'
      : text.includes('Recorded runtime qualification: false') ? 'Recorded runtime qualification: false' : null;
    await run.locator('details').evaluateAll((nodes) => nodes.forEach((node) => { node.open = true; }));
  });
  await step('screenshot-07-evaluations', async () => {
    const run = page.locator('[id^="run-"]').first();
    await frame(page, page.locator('#evaluations-panel'), run);
    await shot(page, '07-evaluations.png', 'Evaluations tab after queuing a static package integrity check: the recorded run shows passed, with its details opened to show "Recorded runtime qualification: false".');
  });

  // 7. Privacy tab.
  await step('screenshot-08-privacy', async () => {
    const tools = page.locator('#workspace-tools');
    if (await tools.count() && !(await tools.evaluate((el) => el.open))) await tools.locator('summary').click();
    await page.locator('#nav-privacy').click();
    await page.locator('#backup-form').waitFor();
    await page.evaluate(() => window.scrollTo(0, 0));
    await shot(page, '08-privacy.png', 'Privacy tab: local-only data controls including the workspace backup form.');
  });

  // 8. Harness detail page for the built artifact (full page).
  await step('screenshot-06-harness-detail', async () => {
    if (!digest) throw new Error('no artifact digest from the build step');
    const t0 = Date.now();
    await page.goto(`${origin}/harnesses/${digest}`, {waitUntil: 'load'});
    try { await waitLiveConnected(page, 10000); } catch { results.checks.harness_detail_live_connected = false; }
    results.checks.harness_detail_load_ms = Date.now() - t0;
    results.checks.harness_detail_title = await page.title();
    results.checks.harness_detail_path = new URL(page.url()).pathname;
    await shot(page, '06-harness-detail.png', `Harness detail page /harnesses/<digest> for "${packageName}" (full page): generated files, checks and download.`, {fullPage: true});
  });

  // 9. Company builder / setup page.
  await step('screenshot-09-setup', async () => {
    const response = await page.goto(`${origin}/setup`, {waitUntil: 'load'});
    results.checks.setup_http_status = response ? response.status() : null;
    try { await waitLiveConnected(page, 10000); } catch { results.checks.setup_live_connected = false; }
    results.checks.setup_final_path = new URL(page.url()).pathname;
    results.checks.setup_title = await page.title();
    await shot(page, '09-setup.png', `Company setup page /setup (final path ${results.checks.setup_final_path}).`);
  });

  // 10. Mobile viewport of the Evidence tab.
  await step('screenshot-10-mobile-evidence', async () => {
    await page.setViewportSize(mobile);
    await page.goto(`${origin}/`, {waitUntil: 'load'});
    await waitLiveConnected(page);
    await page.locator('#nav-evidence').click();
    await page.locator('#evidence-panel').waitFor();
    await page.evaluate(() => window.scrollTo(0, 0));
    results.checks.mobile_workspace_shell_count = await page.locator('.workspace-shell').count();
    results.checks.mobile_no_horizontal_overflow = await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
    await shot(page, '10-mobile-evidence.png', 'Evidence tab at a 390x844 phone viewport after the decisions (workspace shell, no horizontal overflow check recorded).');
  });

  await step('close', async () => {
    await context.close();
    await browser.close();
  });

  results.ended_at = new Date().toISOString();
  results.total_ms = Date.now() - runStart;
  results.screenshots_total_bytes = results.screenshots.reduce((sum, s) => sum + s.bytes, 0);
  results.ok = results.errors.length === 0;

  const index = {generated_at: results.ended_at, default_viewport: `${desktop.width}x${desktop.height}`, screenshots: {}};
  for (const entry of results.screenshots) {
    index.screenshots[entry.file] = {caption: entry.caption, viewport: entry.viewport, full_page: entry.full_page, bytes: entry.bytes};
  }
  fs.writeFileSync(path.join(shotDir, 'index.json'), JSON.stringify(index, null, 2) + '\n');
  fs.writeFileSync(path.join(outDir, 'browser-results.json'), redact(JSON.stringify(results, null, 2)) + '\n');
  log('done', `ok=${results.ok} errors=${results.errors.length} screenshots=${results.screenshots.length} total=${results.total_ms} ms`);
  process.stdout.write(JSON.stringify({ok: results.ok, errors: results.errors.length, screenshots: results.screenshots.length, pageerrors: results.console.pageerror_count, console_errors: results.console.console_error_count, out: outDir}) + '\n');
  process.exit(results.ok ? 0 : 1);
})().catch((error) => {
  log('fatal', error && error.stack ? error.stack : String(error));
  results.ended_at = new Date().toISOString();
  results.errors.push({step: 'fatal', error: redact(error && error.message ? error.message : error).slice(0, 700)});
  try { fs.writeFileSync(path.join(outDir, 'browser-results.json'), redact(JSON.stringify(results, null, 2)) + '\n'); } catch { /* best effort */ }
  process.exit(2);
});
