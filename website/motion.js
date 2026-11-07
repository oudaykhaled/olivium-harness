(() => {
  'use strict';

  const canvas = document.getElementById('signal-canvas');
  if (!canvas) return;
  const context = canvas.getContext('2d');
  if (!context) return;

  const field = canvas.closest('.signal-field') || canvas;
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const colors = {
    live: '#bbff62',
    accent: '#a894ff',
    inactive: '#45513f',
    trace: '#273120',
    frame: '#35412d',
    grid: '#253020',
  };
  let width = 540;
  let height = 230;
  let pixelRatio = 1;
  let elapsed = 0;
  let lastFrame = 0;
  let animationFrame = 0;
  let paused = false;
  let inView = true;
  let stage = 0;

  // All routes use straight, orthogonal segments. Positions are in diagram space.
  const inputRoutes = [
    [[24, 35], [108, 35], [108, 72], [176, 72], [176, 110], [218, 110]],
    [[24, 72], [144, 72], [144, 94], [202, 94], [202, 110], [218, 110]],
    [[24, 110], [218, 110]],
    [[24, 148], [144, 148], [144, 126], [202, 126], [202, 110], [218, 110]],
    [[24, 185], [108, 185], [108, 148], [176, 148], [176, 110], [218, 110]],
  ];
  const outputRoutes = [
    [[322, 110], [370, 110], [370, 56], [506, 56]],
    [[322, 110], [506, 110]],
    [[322, 110], [370, 110], [370, 164], [506, 164]],
  ];

  function routeLength(points) {
    return points.slice(1).reduce((length, point, index) => (
      length + Math.hypot(point[0] - points[index][0], point[1] - points[index][1])
    ), 0);
  }

  const routes = [...inputRoutes, ...outputRoutes].map((points, index) => ({
    points,
    length: routeLength(points),
    offset: (index * 0.173 + 0.11) % 1,
    output: index >= inputRoutes.length,
  }));

  function pointOnRoute(route, progress) {
    let remaining = route.length * progress;
    for (let index = 1; index < route.points.length; index += 1) {
      const start = route.points[index - 1];
      const end = route.points[index];
      const length = Math.hypot(end[0] - start[0], end[1] - start[1]);
      if (remaining <= length) {
        const ratio = remaining / length;
        return [start[0] + (end[0] - start[0]) * ratio, start[1] + (end[1] - start[1]) * ratio];
      }
      remaining -= length;
    }
    return route.points[route.points.length - 1];
  }

  function trace(points, color, opacity = 1, lineWidth = 1) {
    context.beginPath();
    context.moveTo(points[0][0], points[0][1]);
    for (let index = 1; index < points.length; index += 1) {
      context.lineTo(points[index][0], points[index][1]);
    }
    context.strokeStyle = color;
    context.globalAlpha = opacity;
    context.lineWidth = lineWidth;
    context.stroke();
    context.globalAlpha = 1;
  }

  function square(x, y, size, color, opacity = 1) {
    context.fillStyle = color;
    context.globalAlpha = opacity;
    context.fillRect(x - size / 2, y - size / 2, size, size);
    context.globalAlpha = 1;
  }

  function draw() {
    context.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0);
    context.clearRect(0, 0, width, height);

    // The light dot lattice remains fixed while packets move through the circuit.
    context.fillStyle = colors.grid;
    context.globalAlpha = 0.62;
    for (let x = 10; x < width; x += 18) {
      for (let y = 10; y < height; y += 18) {
        context.beginPath();
        context.arc(x, y, 0.65, 0, Math.PI * 2);
        context.fill();
      }
    }
    context.globalAlpha = 1;

    const scale = Math.min((width - 8) / 540, (height - 12) / 220);
    context.translate((width - 540 * scale) / 2, (height - 220 * scale) / 2);
    context.scale(scale, scale);
    context.lineCap = 'butt';
    context.lineJoin = 'miter';

    routes.forEach((route, index) => {
      trace(route.points, colors.trace, 1, 1.25);
      const progress = (elapsed / (route.output ? 6500 : 8200) + route.offset) % 1;
      const packet = pointOnRoute(route, progress);
      const active = route.output ? stage >= 2 : stage < 3;
      const packetColor = index === 7 ? colors.accent : colors.live;
      // Two small, separated packets form a precise direction cue without a glow.
      const trail = pointOnRoute(route, Math.max(0, progress - 0.026));
      square(trail[0], trail[1], 2.4, packetColor, active ? 0.38 : 0.18);
      square(packet[0], packet[1], 3.6, packetColor, active ? 0.95 : 0.45);
    });

    inputRoutes.forEach((points, index) => {
      const start = points[0];
      square(start[0], start[1], 6, colors.inactive);
      square(start[0], start[1], 2, index === stage ? colors.live : '#7d8b70');
      trace([[start[0] + 12, start[1] - 5], [start[0] + 12, start[1] + 5]], colors.frame);
    });

    outputRoutes.forEach((points, index) => {
      const endpoint = points[points.length - 1];
      const color = index === 2 ? colors.accent : colors.live;
      context.strokeStyle = stage >= 2 ? color : colors.inactive;
      context.lineWidth = 1.25;
      context.strokeRect(endpoint[0] - 5, endpoint[1] - 5, 10, 10);
      square(endpoint[0], endpoint[1], 3, color, stage >= 2 ? 0.9 : 0.45);
      trace([[endpoint[0] + 14, endpoint[1] - 3], [endpoint[0] + 17, endpoint[1]], [endpoint[0] + 14, endpoint[1] + 3]], colors.inactive);
    });

    // A hollow O with a rightward shear keeps the italic monogram legible.
    const scan = (elapsed / 5200) % 1;
    for (let row = 0; row < 9; row += 1) {
      for (let column = 0; column < 7; column += 1) {
        const isCap = row === 0 || row === 8;
        const isO = isCap ? column > 0 && column < 6 : column < 2 || column > 4;
        if (!isO) continue;
        const x = 270 + (column - 3) * 10 + (4 - row) * 2.5;
        const y = 110 + (row - 4) * 10;
        const distance = Math.abs(column / 6 - scan);
        const highlight = Math.max(0, 1 - distance * 4);
        const opacity = reducedMotion.matches ? 0.92 : 0.72 + highlight * 0.28;
        square(x, y, 5.5, colors.live, opacity);
      }
    }

    const left = 218;
    const right = 322;
    const top = 52;
    const bottom = 168;
    const cornerSize = 9;
    [
      [[left, top + cornerSize], [left, top], [left + cornerSize, top]],
      [[right - cornerSize, top], [right, top], [right, top + cornerSize]],
      [[left, bottom - cornerSize], [left, bottom], [left + cornerSize, bottom]],
      [[right - cornerSize, bottom], [right, bottom], [right, bottom - cornerSize]],
    ].forEach((points) => trace(points, colors.inactive, 1, 1.2));

    for (let index = 0; index < 4; index += 1) {
      square(258 + index * 8, 187, index === stage ? 4 : 2, index === stage ? colors.live : colors.inactive);
    }
    trace([[244, 33], [296, 33]], colors.frame, 0.8);
    square(270, 33, 3, colors.accent, 0.75);
  }

  function shouldAnimate() {
    return !paused && !reducedMotion.matches && !document.hidden && inView;
  }

  function frame(timestamp) {
    animationFrame = 0;
    if (!shouldAnimate()) {
      lastFrame = 0;
      return;
    }
    if (lastFrame) elapsed += Math.min(timestamp - lastFrame, 64);
    lastFrame = timestamp;
    draw();
    animationFrame = window.requestAnimationFrame(frame);
  }

  function syncAnimation() {
    if (animationFrame) window.cancelAnimationFrame(animationFrame);
    animationFrame = 0;
    lastFrame = 0;
    draw();
    if (shouldAnimate()) animationFrame = window.requestAnimationFrame(frame);
  }

  function resize() {
    const bounds = canvas.getBoundingClientRect();
    if (bounds.width < 1 || bounds.height < 1) return;
    width = bounds.width;
    height = bounds.height;
    pixelRatio = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width = Math.round(width * pixelRatio);
    canvas.height = Math.round(height * pixelRatio);
    draw();
  }

  const resizeObserver = new ResizeObserver(resize);
  resizeObserver.observe(field);
  if ('IntersectionObserver' in window) {
    const intersectionObserver = new IntersectionObserver((entries) => {
      inView = entries[0].isIntersecting;
      syncAnimation();
    }, { threshold: 0.01 });
    intersectionObserver.observe(canvas);
  }

  document.addEventListener('visibilitychange', syncAnimation);
  reducedMotion.addEventListener('change', syncAnimation);
  window.addEventListener('resize', resize, { passive: true });
  document.addEventListener('harness:motion', (event) => {
    if (typeof event.detail?.paused !== 'boolean') return;
    paused = event.detail.paused;
    syncAnimation();
  });
  document.addEventListener('harness:stage', (event) => {
    const nextStage = Number(event.detail?.stage);
    if (!Number.isFinite(nextStage)) return;
    stage = Math.min(3, Math.max(0, Math.floor(nextStage)));
    draw();
  });
  window.addEventListener('pagehide', () => {
    if (animationFrame) window.cancelAnimationFrame(animationFrame);
    animationFrame = 0;
    lastFrame = 0;
  });
  window.addEventListener('pageshow', syncAnimation);

  resize();
  syncAnimation();
})();
