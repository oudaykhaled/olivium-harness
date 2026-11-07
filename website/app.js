'use strict';

(() => {
  const panel = document.querySelector('#demo-panel');
  const stepButtons = [...document.querySelectorAll('[data-step]')];
  const nextButton = document.querySelector('#next-step');
  let currentStep = 0;
  let currentTarget = 'Codex CLI';
  const guidance = '# Team engineering guidance\n\nKeep each change focused.\nExplain the reason for it.\nInclude checks for changed behavior.';
  const targets = {'Codex CLI': 'AGENTS.md', 'Claude Code': 'CLAUDE.md', 'OpenCode': 'AGENTS.md'};
  const stages = [
    `<p class="panel-kicker">INPUT / SELECTED EVIDENCE</p><h3 class="panel-title">LOAD THE CONTEXT.</h3><p class="panel-intro">Start with the knowledge your team wants the agent to use.</p>
     <div class="context-files"><div class="context-file"><span class="file-type">MD</span><div><b>engineering-principles.md</b><small>Small changes. Clear intent. Useful checks.</small></div><span class="file-check" aria-hidden="true">✓</span></div><div class="context-file"><span class="file-type">MD</span><div><b>review-notes.md</b><small>What makes a change easier to review.</small></div><span class="file-check" aria-hidden="true">✓</span></div></div>
     <div class="goal-line"><span>GOAL</span><p>Make changes easier to review.</p></div>`,
    `<p class="panel-kicker">SYNTHESIS / GROUNDED RECOMMENDATION</p><h3 class="panel-title">MAKE KNOWLEDGE ACTIONABLE.</h3><p class="panel-intro">Connect selected evidence to the goal. Keep the source visible.</p>
     <blockquote class="guidance-block">Keep changes focused, explain the reason for each change, and include checks for changed behavior.</blockquote>
     <div class="citation-list"><span>↳ engineering-principles.md</span><span>↳ review-notes.md</span></div><p class="panel-note">These example documents value small changes and clear review context. The recommendation connects those practices to the team’s goal.</p>`,
    `<p class="panel-kicker">CONTROL / HUMAN DECISION</p><h3 class="panel-title">YOU HAVE THE FINAL SAY.</h3><p class="panel-intro">Inspect. Edit. Reject. Resolve conflicts. Approve what belongs.</p>
     <div class="review-check"><span aria-hidden="true">[✓]</span> Supporting evidence inspected</div><div class="review-check"><span aria-hidden="true">[✓]</span> Exact guidance revision approved</div><div class="review-check"><span aria-hidden="true">[✓]</span> Package plan separately approved</div><div class="approval-stamp"><span aria-hidden="true">◆</span><div><b>APPROVED BY YOUR TEAM</b><small>Illustrative review / revision 01</small></div></div>`,
    `<p class="panel-kicker">OUTPUT / AGENT-NATIVE GUIDANCE</p><h3 class="panel-title">EXPORT YOUR WAY OF WORKING.</h3><div class="target-tabs" role="group" aria-label="Example export target">${Object.keys(targets).map(t => `<button type="button" data-target="${t}" aria-pressed="${t === currentTarget}">${t}</button>`).join('')}</div><div class="export-code"><div class="export-code-head"><span id="export-filename">AGENTS.md</span><button type="button" class="copy-button" id="copy-guidance" aria-label="Copy example guidance">COPY ↗</button></div><pre id="guidance-text">${guidance}</pre></div><p class="panel-note">Simplified instruction excerpt. Full native packages carry approved guidance and provenance; their structure depends on the target.</p>`
  ];

  function renderStage(index) {
    currentStep = index;
    stepButtons.forEach((button, i) => {
      button.classList.toggle('active', i === index);
      button.setAttribute('aria-pressed', String(i === index));
    });
    panel.innerHTML = stages[index];
    document.querySelector('#stage-count').textContent = `0${index + 1} OF 04`;
    const labels = ['Next: synthesize', 'Next: review', 'Next: export', 'Restart the pipeline'];
    nextButton.innerHTML = `${labels[index]} <span aria-hidden="true">${index === 3 ? '↺' : '→'}</span>`;
    document.dispatchEvent(new CustomEvent('harness:stage', {detail: {stage: index}}));
    if (index === 3) {
      setTarget(currentTarget);
      panel.querySelectorAll('[data-target]').forEach(button => button.addEventListener('click', () => setTarget(button.dataset.target)));
      document.querySelector('#copy-guidance').addEventListener('click', copyGuidance);
    }
  }

  function setTarget(target) {
    if (!Object.hasOwn(targets, target)) return;
    currentTarget = target;
    document.querySelector('#export-filename').textContent = targets[target];
    document.querySelector('#tree-output').innerHTML = `<span>└─</span> ${targets[target]}`;
    panel.querySelectorAll('[data-target]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.target === target)));
  }

  async function copyGuidance() {
    const button = document.querySelector('#copy-guidance');
    try {
      await navigator.clipboard.writeText(guidance);
      button.textContent = 'COPIED ✓';
      button.setAttribute('aria-label', 'Example guidance copied');
    } catch {
      const range = document.createRange();
      range.selectNodeContents(document.querySelector('#guidance-text'));
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      button.textContent = 'TEXT SELECTED';
      button.setAttribute('aria-label', 'Text selected. Use your device’s copy command.');
    }
  }

  stepButtons.forEach((button, index) => {
    button.addEventListener('click', () => renderStage(index));
    button.addEventListener('keydown', event => {
      if (!['ArrowRight','ArrowLeft','Home','End'].includes(event.key)) return;
      event.preventDefault();
      const target = event.key === 'Home' ? 0 : event.key === 'End' ? 3 : (index + (event.key === 'ArrowRight' ? 1 : 3)) % 4;
      stepButtons[target].focus();
      renderStage(target);
    });
  });
  nextButton.addEventListener('click', () => renderStage((currentStep + 1) % stages.length));
  document.querySelector('#restart-example').addEventListener('click', () => renderStage(0));
  renderStage(0);

  // Presentation-only shell session. These commands are never executed.
  const terminal = document.querySelector('#hero-log');
  const motionButton = document.querySelector('#motion-toggle');
  const replayButton = document.querySelector('#replay-terminal');
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const transcript = [
    {kind:'command', prefix:'$ ', text:'cat team-context/*.md'},
    {kind:'muted', prefix:'[read] ', text:'principles.md + review-notes.md'},
    {kind:'command', prefix:'$ ', text:'cat goals/review-quality.md'},
    {kind:'output', prefix:'  → ', text:'make changes easier to review'},
    {kind:'success', prefix:'[review] ', text:'guidance + package plan approved'},
    {kind:'command', prefix:'$ ', text:'cat exports/AGENTS.md'},
    {kind:'success', prefix:'[ready] ', text:'focused changes. clear intent. checks.'}
  ];
  terminal.setAttribute('aria-label','Illustrative Linux shell session: selected team documents and a goal become human-approved guidance in AGENTS.md. No commands are executed.');
  let paused = reducedMotion.matches;
  let timer = null;
  let row = 0;
  let position = 0;
  let lineText = null;
  let inView = true;

  function createLine(item) {
    const line = document.createElement('div');
    line.className = `log-line log-${item.kind}`;
    const prefix = document.createElement('span');
    prefix.className = item.kind === 'command' ? 'prompt' : 'log-prefix';
    prefix.textContent = item.prefix;
    const content = document.createElement('span');
    content.className = item.kind === 'command' ? 'command' : 'log-text';
    line.append(prefix, content);
    terminal.appendChild(line);
    return content;
  }

  function stop() { if (timer !== null) clearTimeout(timer); timer = null; }
  function schedule(delay = 35) {
    stop();
    if (!paused && !reducedMotion.matches && !document.hidden && inView) timer = setTimeout(tick, delay);
  }
  function tick() {
    timer = null;
    if (paused || reducedMotion.matches || document.hidden || !inView) return;
    if (row >= transcript.length) {
      resetTranscript();
      schedule(600);
      return;
    }
    const item = transcript[row];
    if (!lineText) lineText = createLine(item);
    position++;
    lineText.textContent = item.text.slice(0,position);
    terminal.scrollTop = terminal.scrollHeight;
    if (position >= item.text.length) {
      row++; position = 0; lineText = null;
      schedule(row === transcript.length ? 5500 : 330);
    } else schedule(item.kind === 'command' ? 30 : 12);
  }
  function resetTranscript() {
    stop(); terminal.replaceChildren(); row = 0; position = 0; lineText = null;
  }
  function showStaticTranscript() {
    resetTranscript();
    transcript.forEach(item => { createLine(item).textContent = item.text; });
    row = transcript.length;
  }
  function applyMotion() {
    const isPaused = paused || reducedMotion.matches;
    document.body.dataset.motion = isPaused ? 'paused' : 'running';
    motionButton.setAttribute('aria-pressed', String(isPaused));
    motionButton.innerHTML = isPaused ? 'Resume motion <span aria-hidden="true">▶</span>' : 'Pause motion <span aria-hidden="true">Ⅱ</span>';
    if (reducedMotion.matches) {
      motionButton.innerHTML = 'Reduced motion <span aria-hidden="true">✓</span>';
      motionButton.disabled = true;
      motionButton.title = 'Following your device’s reduced-motion preference';
      showStaticTranscript();
    } else {
      motionButton.disabled = false; motionButton.removeAttribute('title');
      if (isPaused) stop(); else schedule();
    }
    document.dispatchEvent(new CustomEvent('harness:motion', {detail: {paused:isPaused}}));
  }
  motionButton.addEventListener('click', () => { paused = !paused; applyMotion(); });
  replayButton.addEventListener('click', () => {
    if (reducedMotion.matches) { showStaticTranscript(); return; }
    resetTranscript(); paused = false; applyMotion();
  });
  reducedMotion.addEventListener('change', () => { paused = reducedMotion.matches; applyMotion(); });
  document.addEventListener('visibilitychange', () => { if (document.hidden) stop(); else schedule(); });
  if ('IntersectionObserver' in window) {
    const observer = new IntersectionObserver(entries => {
      inView = entries[0].isIntersecting;
      if (inView) schedule(); else stop();
    }, {rootMargin:'80px'});
    observer.observe(terminal);
  }
  applyMotion();
})();
