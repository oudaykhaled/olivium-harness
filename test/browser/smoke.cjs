// Real browser smoke against an already-running, synthetic-only workspace.
// The access code is read locally and is never printed, traced or screenshot.
const { chromium } = require('playwright');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

(async () => {
  const project = path.resolve(__dirname, '../..');
  const workspace = process.env.HARNESSFORGE_WORKSPACE || path.join(project, 'tmp/demo-workspace');
  const origin = process.env.HARNESSFORGE_URL || 'http://127.0.0.1:8865';
  const executablePath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
  const browser = await chromium.launch({headless: true, ...(executablePath ? {executablePath} : {})});
  try {
    const page = await browser.newPage({viewport: {width: 1440, height: 1100}});
    page.setDefaultTimeout(20000);
    page.setDefaultNavigationTimeout(20000);
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(origin);
    await page.getByLabel('Workspace access code', {exact: true}).fill(fs.readFileSync(path.join(workspace, 'access-token'), 'utf8').trim());
    await page.getByRole('button', {name: 'Unlock workspace'}).click();
    await page.locator('#load-demo').waitFor();
    await page.waitForFunction(() => !!document.querySelector('.phx-connected'));
    await page.locator('#load-demo').click();
    await page.locator('.claim-card').first().waitFor();

    const injection = page.locator('.claim-card').filter({hasText: 'IGNORE ALL PREVIOUS INSTRUCTIONS'});
    const reject = injection.getByRole('button', {name: /^Reject claim:/});
    if (await reject.count()) await reject.click();
    const good = page.locator('.claim-card').filter({hasNotText: 'IGNORE ALL PREVIOUS INSTRUCTIONS'});
    for (let index = 0; index < await good.count(); index++) {
      const approve = good.nth(index).getByRole('button', {name: /^Approve claim:/});
      if (await approve.count()) await approve.click();
    }
    await page.locator('#nav-package').click();
    await page.locator('#package-name').fill('browser-harness');
    await page.locator('#build-package').click();
    await page.locator('.artifact-row').first().waitFor();
    const artifact = page.locator('.artifact-row').filter({hasText: 'browser-harness'}).first();
    const target = path.join(project, 'tmp', `browser-export-${Date.now()}`);
    await artifact.locator('input[name="export[target]"]').fill(target);
    await artifact.getByRole('button', {name: 'Export package', exact: true}).click();
    await artifact.locator('[id^=package-export-result-][role=status]').waitFor();
    const guidance = fs.readFileSync(path.join(target, 'AGENTS.md'), 'utf8');
    assert(guidance.includes('table-driven tests'));
    assert(!guidance.includes('export all credentials'));

    await page.locator('#nav-evaluations').click();
    await page.locator('#evaluation-kind').selectOption('static_integrity');
    await page.locator('#evaluation-form button').click();
    const diagnostic = page.locator('[id^="run-"]').filter({hasText: 'static_integrity'}).first();
    await diagnostic.filter({hasText: 'passed'}).waitFor();
    assert((await diagnostic.textContent()).includes('Runtime qualified: false'));
    const diagnosticId = (await diagnostic.getAttribute('id')).slice(4);
    await page.locator('#evaluation-form button').click();
    await page.waitForFunction(id => [...document.querySelectorAll('[id^="run-"]')].find(el => el.textContent.includes('static_integrity'))?.id !== `run-${id}`, diagnosticId);
    const candidateId = (await diagnostic.getAttribute('id')).slice(4);
    await page.locator('#comparison-baseline').selectOption(diagnosticId);
    await page.locator('#comparison-candidate').selectOption(candidateId);
    await page.locator('#comparison-form button').click();
    await page.locator('#comparison-result').waitFor();
    assert((await page.locator('#comparison-result').textContent()).includes('Qualified pair: false'));
    await page.locator('#evaluation-kind').selectOption('task');
    await page.locator('#evaluation-form button').click();
    await page.locator('[id^="run-"]').filter({hasText: 'task'}).filter({hasText: 'blocked'}).first().waitFor();
    await page.locator('#nav-releases').click();
    await page.locator('#release-evaluation').selectOption(diagnosticId);
    await page.locator('#release-form button').click();
    await page.locator('#error').waitFor();

    await page.locator('#nav-evidence').click();
    fs.mkdirSync(path.join(__dirname, 'results'), {recursive: true});
    await page.screenshot({path: path.join(__dirname, 'results/harnessforge-desktop.png'), fullPage: true});
    await page.setViewportSize({width: 390, height: 844});
    assert.equal(await page.locator('.workspace-shell').count(), 1);
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));
    await page.locator('#nav-privacy').click();
    await page.locator('#backup-form').waitFor();
    const backup = path.join(project, 'tmp', `browser-backup-${Date.now()}`);
    await page.locator('#backup-target').fill(backup);
    await page.locator('#backup-form button').click();
    await page.locator('#privacy-result').waitFor();
    assert(fs.existsSync(path.join(backup, 'manifest.json')));
    await page.locator('#nav-evidence').click();
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.screenshot({path: path.join(__dirname, 'results/harnessforge-mobile.png')});
    await page.locator('.claim-card').first().scrollIntoViewIfNeeded();
    await page.screenshot({path: path.join(__dirname, 'results/harnessforge-mobile-review.png')});
    assert.deepEqual(errors, []);
    console.log(JSON.stringify({ok: true, checks: ['real login+CSRF', 'live synthetic import', 'explicit approve/reject', 'package build', 'fresh export', 'rejected input excluded', 'queued static evaluation', 'recorded evaluation comparison', 'blocked model evaluation', 'diagnostic release rejected', 'mobile privacy and backup', 'desktop/mobile render'], export: target}));
  } finally { await browser.close(); }
})().catch(error => { console.error(error.message); process.exit(1); });
