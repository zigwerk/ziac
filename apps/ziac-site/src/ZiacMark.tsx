import { onCleanup, onMount } from "solid-js";
import * as THREE from "three";

const faceLetters = ["Z", "I", "A", "C"] as const;
const orientationSequence = [0, 2, 1, 3, 1, 0, 3, 2] as const;
const segmentDuration = 3200;

export function orientationStep(elapsed: number) {
  const safeElapsed = Math.max(0, Number.isFinite(elapsed) ? elapsed : 0);
  const segment = Math.floor(safeElapsed / segmentDuration);
  const local = (safeElapsed % segmentDuration) / segmentDuration;
  return {
    from: orientationSequence[segment % orientationSequence.length]!,
    to: orientationSequence[(segment + 1) % orientationSequence.length]!,
    progress: local < 0.76 ? 0.5 - Math.cos((local / 0.76) * Math.PI) / 2 : 1,
  };
}

function makeFaceTexture(letter: string, background = "#f7faff", accent = "#2264d8") {
  const canvas = document.createElement("canvas");
  canvas.width = 192;
  canvas.height = 192;
  const context = canvas.getContext("2d")!;
  context.fillStyle = background;
  context.fillRect(0, 0, canvas.width, canvas.height);
  context.strokeStyle = accent;
  context.lineWidth = 10;
  context.strokeRect(8, 8, 176, 176);
  if (letter) {
    context.fillStyle = accent;
    context.font = "800 112px Inter, Arial, sans-serif";
    context.textAlign = "center";
    context.textBaseline = "middle";
    context.fillText(letter, 96, 103);
  }
  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  texture.anisotropy = 4;
  texture.needsUpdate = true;
  return texture;
}

export function ZiacMark() {
  let host!: HTMLSpanElement;

  onMount(() => {
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const scene = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(32, 1, 0.1, 20);
    camera.position.set(0, 0.15, 4.2);

    const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    renderer.setClearColor(0xffffff, 0);
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    host.append(renderer.domElement);

    scene.add(new THREE.HemisphereLight(0xffffff, 0xc9d8ec, 2.7));
    const keyLight = new THREE.DirectionalLight(0xffffff, 3.2);
    keyLight.position.set(-3, 4, 5);
    scene.add(keyLight);

    const textures = {
      Z: makeFaceTexture(faceLetters[0]),
      I: makeFaceTexture(faceLetters[1]),
      A: makeFaceTexture(faceLetters[2]),
      C: makeFaceTexture(faceLetters[3]),
      top: makeFaceTexture("", "#f5a623", "#b96808"),
      bottom: makeFaceTexture("", "#edf3fb", "#8ba8cf"),
    };
    const materials = [textures.I, textures.C, textures.top, textures.bottom, textures.Z, textures.A].map(
      (map) => new THREE.MeshStandardMaterial({ map, roughness: 0.56, metalness: 0 }),
    );
    const geometry = new THREE.BoxGeometry(1.35, 1.35, 1.35);
    const cube = new THREE.Mesh(geometry, materials);
    scene.add(cube);

    const edges = new THREE.LineSegments(
      new THREE.EdgesGeometry(geometry),
      new THREE.LineBasicMaterial({ color: 0x6f8eb8, transparent: true, opacity: 0.78 }),
    );
    cube.add(edges);

    const orientations = [
      new THREE.Quaternion().setFromEuler(new THREE.Euler(-0.24, 0, -0.06)),
      new THREE.Quaternion().setFromEuler(new THREE.Euler(0.2, -Math.PI / 2, 0.08)),
      new THREE.Quaternion().setFromEuler(new THREE.Euler(-0.18, Math.PI, -0.08)),
      new THREE.Quaternion().setFromEuler(new THREE.Euler(0.24, Math.PI / 2, 0.06)),
    ];
    cube.quaternion.copy(orientations[0]!);

    const resize = () => {
      const { width, height } = host.getBoundingClientRect();
      if (width === 0 || height === 0) return;
      renderer.setSize(width, height, false);
      camera.aspect = width / height;
      camera.updateProjectionMatrix();
    };
    const resizeObserver = new ResizeObserver(resize);
    resizeObserver.observe(host);
    resize();

    const startedAt = performance.now();
    let frame = 0;
    const render = (now: number) => {
      if (!reducedMotion) {
        const step = orientationStep(now - startedAt);
        cube.quaternion.slerpQuaternions(orientations[step.from]!, orientations[step.to]!, step.progress);
      }
      renderer.render(scene, camera);
      frame = requestAnimationFrame(render);
    };
    frame = requestAnimationFrame(render);

    onCleanup(() => {
      cancelAnimationFrame(frame);
      resizeObserver.disconnect();
      edges.geometry.dispose();
      (edges.material as THREE.Material).dispose();
      geometry.dispose();
      materials.forEach((material) => {
        material.map?.dispose();
        material.dispose();
      });
      renderer.dispose();
      renderer.domElement.remove();
    });
  });

  return <span class="ziac-mark-canvas" ref={host} aria-hidden="true" />;
}
