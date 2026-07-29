type CloudPoint = {
  label: string;
  x: number;
  y: number;
  z: number;
};

type ProjectedPoint = {
  label: string;
  x: number;
  y: number;
  z: number;
  depth: number;
  scale: number;
};

const clamp = (value: number, minimum: number, maximum: number): number =>
  Math.min(maximum, Math.max(minimum, value));

const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
const fontStack =
  '"SFMono-Regular", "Cascadia Mono", "Liberation Mono", monospace';

document.querySelectorAll<HTMLElement>('[data-feature-cloud]').forEach((cloud) => {
  const canvas = cloud.querySelector<HTMLCanvasElement>('[data-tag-cloud]');
  const landing = cloud.closest<HTMLElement>('.landing');
  const labels = Array.from(cloud.querySelectorAll<HTMLElement>('.feature-tag'))
    .map((tag) => tag.textContent?.trim())
    .filter((label): label is string => Boolean(label));

  if (!canvas || !landing || canvas.dataset.cloudReady || labels.length === 0) {
    return;
  }

  const context = canvas.getContext('2d');
  if (!context) return;

  canvas.dataset.cloudReady = 'true';

  const goldenAngle = Math.PI * (3 - Math.sqrt(5));
  const points: CloudPoint[] = labels.map((label, index) => {
    const y = 1 - ((index + 0.5) / labels.length) * 2;
    const radius = Math.sqrt(1 - y * y);
    const angle = index * goldenAngle;

    return {
      label,
      x: Math.cos(angle) * radius,
      y,
      z: Math.sin(angle) * radius,
    };
  });

  let width = 1;
  let height = 1;
  let rotationX = -0.12;
  let rotationY = 0;
  let velocityX = 0;
  let velocityY = 0.00008;
  let targetVelocityX = 0;
  let targetVelocityY = 0.00008;
  let frame: number | null = null;
  let previousTime = 0;

  const draw = (): void => {
    context.clearRect(0, 0, width, height);

    const cosX = Math.cos(rotationX);
    const sinX = Math.sin(rotationX);
    const cosY = Math.cos(rotationY);
    const sinY = Math.sin(rotationY);
    const sphereRadius = Math.max(width, height) * 0.46;
    const perspectiveDistance = 3.2;

    const projected: ProjectedPoint[] = points.map((point) => {
      const rotatedX = point.x * cosY + point.z * sinY;
      const firstZ = -point.x * sinY + point.z * cosY;
      const rotatedY = point.y * cosX - firstZ * sinX;
      const rotatedZ = point.y * sinX + firstZ * cosX;
      const scale = perspectiveDistance / (perspectiveDistance - rotatedZ);

      return {
        label: point.label,
        x: width / 2 + rotatedX * sphereRadius * scale,
        y: height / 2 + rotatedY * sphereRadius * scale,
        z: rotatedZ,
        depth: (rotatedZ + 1) / 2,
        scale,
      };
    });

    projected.sort((first, second) => first.z - second.z);

    for (const point of projected) {
      const responsiveScale = clamp(width / 960, 0.78, 1.12);
      const fontSize =
        (9 + point.depth * 4.5) * point.scale * responsiveScale;
      const alpha = 0.12 + point.depth * 0.34;

      context.font = `600 ${fontSize}px ${fontStack}`;
      context.textAlign = 'center';
      context.textBaseline = 'middle';
      context.fillStyle = `rgba(190, 225, 248, ${alpha})`;
      context.shadowColor = `rgba(83, 167, 255, ${alpha * 0.6})`;
      context.shadowBlur = 8 * point.depth;
      context.fillText(point.label.toUpperCase(), point.x, point.y);
    }

    context.shadowBlur = 0;
  };

  const resize = (): void => {
    const bounds = cloud.getBoundingClientRect();
    const pixelRatio = Math.min(window.devicePixelRatio || 1, 2);

    width = Math.max(1, bounds.width);
    height = Math.max(1, bounds.height);
    canvas.width = Math.round(width * pixelRatio);
    canvas.height = Math.round(height * pixelRatio);
    context.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0);
    draw();
  };

  const tick = (time: number): void => {
    const elapsed = previousTime === 0 ? 16 : Math.min(time - previousTime, 32);
    previousTime = time;
    const easing = Math.min(1, elapsed * 0.006);

    velocityX += (targetVelocityX - velocityX) * easing;
    velocityY += (targetVelocityY - velocityY) * easing;
    rotationX += velocityX * elapsed;
    rotationY += velocityY * elapsed;

    draw();
    frame = window.requestAnimationFrame(tick);
  };

  const start = (): void => {
    if (frame !== null || reducedMotion.matches || document.hidden) return;
    previousTime = 0;
    frame = window.requestAnimationFrame(tick);
  };

  const stop = (): void => {
    if (frame === null) return;
    window.cancelAnimationFrame(frame);
    frame = null;
  };

  const resetVelocity = (): void => {
    targetVelocityX = 0;
    targetVelocityY = 0.00008;
  };

  landing.addEventListener(
    'pointermove',
    (event) => {
      if (event.pointerType === 'touch' || reducedMotion.matches) return;

      const bounds = landing.getBoundingClientRect();
      const pointerX = clamp(
        ((event.clientX - bounds.left) / bounds.width - 0.5) * 2,
        -1,
        1,
      );
      const pointerY = clamp(
        ((event.clientY - bounds.top) / bounds.height - 0.5) * 2,
        -1,
        1,
      );

      targetVelocityX = -pointerY * 0.00042;
      targetVelocityY = 0.00008 + pointerX * 0.00062;
    },
    { passive: true },
  );
  landing.addEventListener('pointerleave', resetVelocity, { passive: true });

  document.addEventListener('visibilitychange', () => {
    if (document.hidden) {
      stop();
    } else {
      start();
    }
  });

  reducedMotion.addEventListener('change', () => {
    resetVelocity();
    if (reducedMotion.matches) {
      stop();
      draw();
    } else {
      start();
    }
  });

  if (typeof ResizeObserver !== 'undefined') {
    const resizeObserver = new ResizeObserver(resize);
    resizeObserver.observe(cloud);
  } else {
    window.addEventListener('resize', resize, { passive: true });
  }

  resize();
  cloud.classList.add('is-enhanced');
  start();
});

/* Module scope keeps top-level names out of the global script namespace. */
export {};
