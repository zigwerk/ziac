import { createSignal, onCleanup, onMount } from "solid-js";
import * as THREE from "three";
import { RoundedBoxGeometry } from "three/addons/geometries/RoundedBoxGeometry.js";
import { heroResources, heroRoutes, heroSlabs } from "./heroTopologyModel";

interface TooltipState {
  readonly x: number;
  readonly y: number;
  readonly name: string;
  readonly type: string;
  readonly status: string;
}

interface AnimatedObject {
  readonly object: THREE.Object3D;
  readonly targetY: number;
  readonly delay: number;
}

const palette = {
  ink: 0x172033,
  grid: 0xdfe6ef,
  slab: 0xf0f4f8,
  slabEdge: 0xc7d2df,
  account: 0xeaf1f8,
  external: 0xf1eef9,
  blue: 0x4b8fe8,
  amber: 0xf2a62b,
  mint: 0x6bc5ad,
  violet: 0x8c73de,
  route: 0x7eb5ed,
  data: 0xa28bdc,
  binding: 0xe3a13a,
} as const;

function makeTextTexture(
  title: string,
  detail: string,
  options: { readonly width?: number; readonly height?: number; readonly accent?: string } = {},
): THREE.CanvasTexture {
  const canvas = document.createElement("canvas");
  canvas.width = options.width ?? 640;
  canvas.height = options.height ?? 180;
  const context = canvas.getContext("2d")!;
  context.clearRect(0, 0, canvas.width, canvas.height);
  context.fillStyle = options.accent ?? "#172033";
  context.font = "700 38px Inter, Arial, sans-serif";
  context.fillText(title, 18, 62);
  context.fillStyle = "#6b7484";
  context.font = "600 22px Inter, Arial, sans-serif";
  context.fillText(detail, 18, 102);
  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  texture.anisotropy = 4;
  texture.needsUpdate = true;
  return texture;
}

function makeLabelPlane(
  title: string,
  detail: string,
  width: number,
  height: number,
  accent?: string,
): THREE.Mesh {
  const texture = makeTextTexture(title, detail, { accent });
  const material = new THREE.MeshBasicMaterial({
    map: texture,
    transparent: true,
    depthWrite: false,
    side: THREE.DoubleSide,
  });
  const plane = new THREE.Mesh(new THREE.PlaneGeometry(width, height), material);
  plane.rotation.x = -Math.PI / 2;
  return plane;
}

function expandRoute(points: readonly (readonly [number, number, number])[]): THREE.Vector3[] {
  const expanded: THREE.Vector3[] = [];
  for (let segment = 0; segment < points.length - 1; segment += 1) {
    const start = points[segment]!;
    const end = points[segment + 1]!;
    for (let step = 0; step < 14; step += 1) {
      const t = step / 14;
      expanded.push(
        new THREE.Vector3(
          THREE.MathUtils.lerp(start[0], end[0], t),
          THREE.MathUtils.lerp(start[1], end[1], t),
          THREE.MathUtils.lerp(start[2], end[2], t),
        ),
      );
    }
  }
  const last = points.at(-1)!;
  expanded.push(new THREE.Vector3(last[0], last[1], last[2]));
  return expanded;
}

export function HeroTopology() {
  let host!: HTMLDivElement;
  const [tooltip, setTooltip] = createSignal<TooltipState | null>(null);

  onMount(() => {
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const scene = new THREE.Scene();
    const camera = new THREE.OrthographicCamera(-8.6, 8.6, 6.5, -6.5, 0.1, 100);
    camera.position.set(12, 14, 15);
    camera.lookAt(0, 0, 0.8);

    const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    renderer.setClearColor(0xffffff, 0);
    renderer.shadowMap.enabled = true;
    renderer.shadowMap.type = THREE.PCFShadowMap;
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    host.append(renderer.domElement);

    const ambient = new THREE.HemisphereLight(0xffffff, 0xdce6ef, 2.8);
    scene.add(ambient);
    const keyLight = new THREE.DirectionalLight(0xffffff, 3.5);
    keyLight.position.set(-8, 16, 9);
    keyLight.castShadow = true;
    keyLight.shadow.mapSize.set(1024, 1024);
    scene.add(keyLight);

    const grid = new THREE.GridHelper(30, 30, palette.grid, palette.grid);
    const gridMaterial = grid.material as THREE.LineBasicMaterial;
    gridMaterial.transparent = true;
    gridMaterial.opacity = 0.44;
    grid.position.y = -0.08;
    scene.add(grid);

    const animated: AnimatedObject[] = [];
    const resourceMeshes: THREE.Mesh[] = [];
    const routeLines: Array<{ readonly line: THREE.Line; readonly count: number; readonly delay: number }> = [];

    heroSlabs.forEach((slab, index) => {
      const group = new THREE.Group();
      group.position.set(slab.position[0], reducedMotion ? 0 : -0.75, slab.position[2]);
      const slabColor = slab.tone === "external" ? palette.external : slab.tone === "account" ? palette.account : palette.slab;
      const geometry = new RoundedBoxGeometry(slab.size[0], 0.24, slab.size[1], 5, 0.1);
      const material = new THREE.MeshStandardMaterial({ color: slabColor, roughness: 0.76, metalness: 0 });
      const mesh = new THREE.Mesh(geometry, material);
      mesh.castShadow = true;
      mesh.receiveShadow = true;
      group.add(mesh);

      const outline = new THREE.LineSegments(
        new THREE.EdgesGeometry(geometry, 30),
        new THREE.LineBasicMaterial({ color: palette.slabEdge, transparent: true, opacity: 0.94 }),
      );
      group.add(outline);

      const label = makeLabelPlane(slab.label, slab.detail, Math.min(3.1, slab.size[0] - 0.45), 0.86);
      label.position.set(-0.18, 0.14, slab.size[1] * 0.27);
      group.add(label);
      scene.add(group);
      animated.push({ object: group, targetY: 0.12, delay: 120 + index * 95 });
    });

    heroResources.forEach((resource, index) => {
      const group = new THREE.Group();
      group.position.set(resource.position[0], reducedMotion ? resource.position[1] : -0.5, resource.position[2]);
      const bodyGeometry = new RoundedBoxGeometry(1.42, 0.74, 0.94, 5, 0.08);
      const body = new THREE.Mesh(
        bodyGeometry,
        new THREE.MeshStandardMaterial({ color: 0xffffff, roughness: 0.64, metalness: 0 }),
      );
      body.castShadow = true;
      body.receiveShadow = true;
      body.userData.resource = resource;
      resourceMeshes.push(body);
      group.add(body);

      const accentColor = resource.tone === "run" ? palette.blue : resource.tone === "data" ? palette.mint : resource.tone === "edge" ? palette.amber : palette.violet;
      const cap = new THREE.Mesh(
        new RoundedBoxGeometry(1.42, 0.11, 0.94, 5, 0.07),
        new THREE.MeshStandardMaterial({ color: accentColor, roughness: 0.52 }),
      );
      cap.position.y = 0.39;
      cap.userData.resource = resource;
      resourceMeshes.push(cap);
      group.add(cap);

      const label = makeLabelPlane(resource.name, resource.type, 1.24, 0.45, "#172033");
      label.position.set(0, 0.46, 0);
      group.add(label);

      scene.add(group);
      animated.push({ object: group, targetY: resource.position[1], delay: 560 + index * 75 });
    });

    heroRoutes.forEach((route, index) => {
      const points = expandRoute(route.points);
      const geometry = new THREE.BufferGeometry().setFromPoints(points);
      geometry.setDrawRange(0, reducedMotion ? points.length : 0);
      const color = route.tone === "request" ? palette.route : route.tone === "data" ? palette.data : palette.binding;
      const material = new THREE.LineBasicMaterial({
        color,
        transparent: true,
        opacity: 0.62,
        depthWrite: false,
      });
      const line = new THREE.Line(geometry, material);
      scene.add(line);
      routeLines.push({ line, count: points.length, delay: 1080 + index * 100 });
    });

    const raycaster = new THREE.Raycaster();
    const pointer = new THREE.Vector2(-2, -2);
    const pointerTarget = new THREE.Vector2(0, 0);
    let frame = 0;
    let start = performance.now();
    let hovered: THREE.Mesh | null = null;

    const resize = () => {
      const { width, height } = host.getBoundingClientRect();
      if (width === 0 || height === 0) return;
      renderer.setSize(width, height, false);
      const aspect = width / height;
      const halfHeight = width < 760 ? 7.2 : 6.2;
      camera.left = -halfHeight * aspect;
      camera.right = halfHeight * aspect;
      camera.top = halfHeight;
      camera.bottom = -halfHeight;
      camera.updateProjectionMatrix();
    };

    const onPointerMove = (event: PointerEvent) => {
      const bounds = renderer.domElement.getBoundingClientRect();
      pointer.x = ((event.clientX - bounds.left) / bounds.width) * 2 - 1;
      pointer.y = -((event.clientY - bounds.top) / bounds.height) * 2 + 1;
      pointerTarget.set(pointer.x, pointer.y);
      raycaster.setFromCamera(pointer, camera);
      const hit = raycaster.intersectObjects(resourceMeshes, false)[0];

      if (hovered && hovered !== hit?.object) hovered.scale.setScalar(1);
      hovered = (hit?.object as THREE.Mesh | undefined) ?? null;
      if (!hovered) {
        setTooltip(null);
        renderer.domElement.style.cursor = "grab";
        return;
      }

      hovered.scale.setScalar(1.04);
      const resource = hovered.userData.resource as (typeof heroResources)[number];
      setTooltip({
        x: event.clientX - bounds.left + 16,
        y: event.clientY - bounds.top + 16,
        name: resource.name,
        type: resource.type,
        status: resource.status,
      });
      renderer.domElement.style.cursor = "pointer";
    };

    const onPointerLeave = () => {
      if (hovered) hovered.scale.setScalar(1);
      hovered = null;
      pointerTarget.set(0, 0);
      setTooltip(null);
    };

    const easeOutQuint = (value: number) => 1 - Math.pow(1 - value, 5);

    const render = (now: number) => {
      const elapsed = now - start;
      if (!reducedMotion) {
        for (const item of animated) {
          const progress = THREE.MathUtils.clamp((elapsed - item.delay) / 720, 0, 1);
          item.object.position.y = THREE.MathUtils.lerp(-0.6, item.targetY, easeOutQuint(progress));
        }
        for (const route of routeLines) {
          const progress = THREE.MathUtils.clamp((elapsed - route.delay) / 780, 0, 1);
          route.line.geometry.setDrawRange(0, Math.max(0, Math.floor(route.count * easeOutQuint(progress))));
        }
        const drift = Math.sin(now * 0.00022) * 0.16;
        camera.position.x = 12 + pointerTarget.x * 0.34 + drift;
        camera.position.y = 14 - pointerTarget.y * 0.26;
        camera.lookAt(0, 0.1, 0.8);
      }
      renderer.render(scene, camera);
      frame = requestAnimationFrame(render);
    };

    const resizeObserver = new ResizeObserver(resize);
    resizeObserver.observe(host);
    resize();
    renderer.domElement.addEventListener("pointermove", onPointerMove);
    renderer.domElement.addEventListener("pointerleave", onPointerLeave);
    frame = requestAnimationFrame(render);

    onCleanup(() => {
      cancelAnimationFrame(frame);
      resizeObserver.disconnect();
      renderer.domElement.removeEventListener("pointermove", onPointerMove);
      renderer.domElement.removeEventListener("pointerleave", onPointerLeave);
      scene.traverse((object) => {
        if (object instanceof THREE.Mesh || object instanceof THREE.Line || object instanceof THREE.LineSegments) {
          object.geometry.dispose();
          const materials = Array.isArray(object.material) ? object.material : [object.material];
          materials.forEach((material) => {
            if (material instanceof THREE.MeshBasicMaterial && material.map) material.map.dispose();
            material.dispose();
          });
        }
      });
      renderer.dispose();
      renderer.domElement.remove();
    });
  });

  return (
    <div
      class="topology-stage"
      ref={host}
      role="img"
      aria-label="Interactive isometric topology showing a global load balancer routing to Cloud Run services and connected data services across Google Cloud regions."
    >
      {tooltip() && (
        <div class="topology-tooltip" style={{ left: `${tooltip()!.x}px`, top: `${tooltip()!.y}px` }}>
          <strong>{tooltip()!.name}</strong>
          <span>{tooltip()!.type}</span>
          <small>{tooltip()!.status}</small>
        </div>
      )}
    </div>
  );
}
