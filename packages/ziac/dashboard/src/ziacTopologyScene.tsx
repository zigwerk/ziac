// Ziac dashboard-owned Three.js topology scene.
import { For, Show, createEffect, createSignal, onCleanup, onMount } from "solid-js";
import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { RoundedBoxGeometry } from "three/addons/geometries/RoundedBoxGeometry.js";
import { Line2 } from "three/addons/lines/Line2.js";
import { LineGeometry } from "three/addons/lines/LineGeometry.js";
import { LineMaterial } from "three/addons/lines/LineMaterial.js";
import {
  Box,
  Focus,
  Grid3X3,
  Layers3,
  Minus,
  MousePointer2,
  Move3D,
  Plus,
} from "lucide-solid";
import {
  deriveZiacSceneModel,
  fitOrthographicSceneZoom,
  type ZiacSceneBoundary,
  type ZiacSceneGroup,
  type ZiacSceneLocality,
  type ZiacSceneModel,
  type ZiacSceneNode,
  type ZiacScenePlane,
  type ZiacSceneRoute,
  type ZiacSceneTooltip,
  type ZiacTopologyMode,
} from "./ziacTopologySceneModel";
import type { FilteredZiacVisualModel } from "./ziacVisualArtifact";

type SceneHover = { x: number; y: number; data: ZiacSceneTooltip };
const providerTextureCache = new Map<string, THREE.Texture>();
const providerTextureLoader = new THREE.TextureLoader();

export function ZiacTopologyScene(props: {
  model: FilteredZiacVisualModel;
  mode: ZiacTopologyMode;
  selectedId: string | null;
  onSelect: (id: string) => void;
}) {
  let host!: HTMLDivElement;
  let runtime: SceneRuntime | null = null;
  const [ready, setReady] = createSignal(false);
  const [gridVisible, setGridVisible] = createSignal(true);
  const [layersVisible, setLayersVisible] = createSignal(true);
  const [projection, setProjection] = createSignal<"2d" | "3d">("3d");
  const [tooltip, setTooltip] = createSignal<SceneHover | null>(null);

  onMount(() => {
    runtime = createRuntime(host, props.onSelect, (next) => setTooltip(next));
    setReady(true);
  });

  createEffect(() => {
    if (!ready() || !runtime) return;
    const model = deriveZiacSceneModel(props.model, props.mode);
    runtime.renderModel(model, props.selectedId, gridVisible(), layersVisible());
  });

  onCleanup(() => {
    runtime?.dispose();
    runtime = null;
  });

  const setCameraProjection = (next: "2d" | "3d") => {
    setProjection(next);
    runtime?.setProjection(next);
  };

  return (
    <section class="ziac-scene-shell" aria-label="3D infrastructure topology">
      <div ref={host} class="ziac-scene-host" />
      <div class="ziac-scene-tools" aria-label="Canvas controls">
        <ToolButton label="Select resources"><MousePointer2 size={15} /></ToolButton>
        <ToolButton label="Pan and orbit"><Move3D size={15} /></ToolButton>
        <span />
        <ToolButton label="Fit topology" onClick={() => runtime?.fit()}><Focus size={15} /></ToolButton>
        <ToolButton label="Zoom in" onClick={() => runtime?.zoom(0.84)}><Plus size={15} /></ToolButton>
        <ToolButton label="Zoom out" onClick={() => runtime?.zoom(1.18)}><Minus size={15} /></ToolButton>
        <span />
        <button type="button" classList={{ active: projection() === "2d" }} onClick={() => setCameraProjection("2d")} title="Top-down view">2D</button>
        <button type="button" classList={{ active: projection() === "3d" }} onClick={() => setCameraProjection("3d")} title="Isometric view">3D</button>
        <ToolButton label="Toggle topology planes" active={layersVisible()} onClick={() => setLayersVisible(!layersVisible())}><Layers3 size={15} /></ToolButton>
        <ToolButton label="Toggle grid" active={gridVisible()} onClick={() => setGridVisible(!gridVisible())}><Grid3X3 size={15} /></ToolButton>
      </div>
      <div class="ziac-scene-legend">
        <span><i class="public" />Public request</span>
        <span><i class="private" />Private path</span>
        <span><i class="output" />Output wiring</span>
        <span><i class="identity" />IAM / access</span>
        <span><i class="dependency" />Dependency</span>
      </div>
      <div class="ziac-scene-summary">
        <Box size={14} />
        <span>{props.model.resources.length} resources</span>
        <strong>{props.model.edges.length} connections</strong>
      </div>
      <Show when={tooltip()}>
        {(hover) => (
          <aside
            class="ziac-scene-tooltip"
            classList={{ slab: hover().data.kind !== "resource" }}
            style={{ left: `${hover().x}px`, top: `${hover().y}px` }}
            aria-live="polite"
          >
            <header>
              <div><small>{hover().data.subtitle}</small><strong>{hover().data.title}</strong></div>
              <span class={`health-${hover().data.health}`}>{hover().data.health}</span>
            </header>
            <dl>
              <div><dt>Monthly estimate</dt><dd>{hover().data.forecastMonthly}</dd></div>
              <div><dt>Uptime</dt><dd>{hover().data.uptime}</dd></div>
              <div><dt>Scope</dt><dd>{hover().data.scope}</dd></div>
              <div><dt>Operation</dt><dd>{hover().data.operation}</dd></div>
              <div><dt>{hover().data.kind === "resource" ? "Connections" : "Resources"}</dt><dd>{hover().data.kind === "resource" ? hover().data.connectionCount : hover().data.resourceCount}</dd></div>
              <div><dt>Provider</dt><dd>{hover().data.provider}</dd></div>
            </dl>
            <code>{hover().data.canonicalId}</code>
            <p>Cost is estimated from configured capacity. Connect billing telemetry for observed spend.</p>
          </aside>
        )}
      </Show>
      <div class="sr-only" aria-label="Infrastructure resources">
        <For each={props.model.resources}>
          {(resource) => <button type="button" onClick={() => props.onSelect(resource.id)}>{resource.logical_id}</button>}
        </For>
      </div>
      <Show when={props.model.resources.length === 0}>
        <div class="ziac-scene-empty">No resources match these filters.</div>
      </Show>
    </section>
  );
}

function ToolButton(props: { label: string; active?: boolean; onClick?: () => void; children: unknown }) {
  return <button type="button" classList={{ active: props.active }} onClick={props.onClick} title={props.label} aria-label={props.label}>{props.children as never}</button>;
}

type SceneRuntime = {
  renderModel: (model: ZiacSceneModel, selectedId: string | null, showGrid: boolean, showLayers: boolean) => void;
  setProjection: (projection: "2d" | "3d") => void;
  fit: () => void;
  zoom: (factor: number) => void;
  dispose: () => void;
};

function createRuntime(
  host: HTMLDivElement,
  onSelect: (id: string) => void,
  onHover: (hover: SceneHover | null) => void,
): SceneRuntime {
  const scene = new THREE.Scene();
  const camera = new THREE.OrthographicCamera(-12, 12, 8, -8, 0.1, 200);
  camera.position.set(20, 23, 26);
  camera.lookAt(0, 0, 0);

  const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, powerPreference: "high-performance" });
  renderer.setClearColor(0xf8fafc, 0);
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFShadowMap;
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.08;
  renderer.domElement.className = "ziac-three-canvas";
  renderer.domElement.setAttribute("aria-label", "Interactive infrastructure canvas");
  host.appendChild(renderer.domElement);

  const controls = new OrbitControls(camera, renderer.domElement);
  controls.enableDamping = true;
  controls.dampingFactor = 0.08;
  controls.maxPolarAngle = Math.PI / 2.15;
  controls.minZoom = 0.1;
  controls.maxZoom = 2.8;
  controls.target.set(0, 0, 0);

  scene.add(new THREE.HemisphereLight(0xffffff, 0xaeb9c4, 1.25));
  const key = new THREE.DirectionalLight(0xffffff, 3.6);
  key.position.set(-10, 22, 12);
  key.castShadow = true;
  key.shadow.mapSize.set(2048, 2048);
  key.shadow.camera.left = -42;
  key.shadow.camera.right = 42;
  key.shadow.camera.top = 34;
  key.shadow.camera.bottom = -34;
  key.shadow.bias = -0.0004;
  key.shadow.normalBias = 0.025;
  scene.add(key);

  const content = new THREE.Group();
  scene.add(content);
  let grid: THREE.GridHelper | null = null;
  let currentModel: ZiacSceneModel | null = null;
  let currentProjection: "2d" | "3d" = "3d";
  const raycaster = new THREE.Raycaster();
  const pointer = new THREE.Vector2();
  const hoverables: THREE.Object3D[] = [];
  let hovered: THREE.Object3D | null = null;
  let frame = 0;

  const resize = () => {
    const width = Math.max(1, host.clientWidth);
    const height = Math.max(1, host.clientHeight);
    const aspect = width / height;
    const viewHeight = 17;
    camera.left = -viewHeight * aspect / 2;
    camera.right = viewHeight * aspect / 2;
    camera.top = viewHeight / 2;
    camera.bottom = -viewHeight / 2;
    camera.updateProjectionMatrix();
    renderer.setSize(width, height, false);
    if (currentModel) fitModel(camera, controls, currentModel, false, currentProjection);
  };
  const observer = new ResizeObserver(resize);
  observer.observe(host);
  resize();

  const render = () => {
    frame = requestAnimationFrame(render);
    if (currentProjection === "3d") controls.update();
    renderer.render(scene, camera);
  };
  render();

  const clearHover = () => {
    if (hovered) setMeshHover(hovered, false);
    hovered = null;
    renderer.domElement.style.cursor = "grab";
    onHover(null);
  };
  const updatePointer = (event: PointerEvent) => {
    const rect = renderer.domElement.getBoundingClientRect();
    pointer.x = ((event.clientX - rect.left) / rect.width) * 2 - 1;
    pointer.y = -((event.clientY - rect.top) / rect.height) * 2 + 1;
    raycaster.setFromCamera(pointer, camera);
    const hit = raycaster.intersectObjects(hoverables, false)[0]?.object ?? null;
    if (hovered !== hit) {
      if (hovered) setMeshHover(hovered, false);
      hovered = hit;
      if (hovered) setMeshHover(hovered, true);
    }
    renderer.domElement.style.cursor = hovered?.userData.resourceId ? "pointer" : hovered ? "help" : "grab";
    const data = hovered?.userData.tooltip as ZiacSceneTooltip | undefined;
    if (!data) return onHover(null);
    const width = 270;
    const height = 250;
    onHover({
      x: THREE.MathUtils.clamp(event.clientX - rect.left + 14, 8, Math.max(8, rect.width - width - 8)),
      y: THREE.MathUtils.clamp(event.clientY - rect.top + 14, 8, Math.max(8, rect.height - height - 8)),
      data,
    });
  };
  const selectPointer = () => {
    const id = hovered?.userData.resourceId;
    if (typeof id === "string") onSelect(id);
  };
  renderer.domElement.addEventListener("pointermove", updatePointer);
  renderer.domElement.addEventListener("pointerleave", clearHover);
  renderer.domElement.addEventListener("click", selectPointer);

  const renderModel = (model: ZiacSceneModel, selectedId: string | null, showGrid: boolean, showLayers: boolean) => {
    currentModel = model;
    clearHover();
    clearGroup(content);
    hoverables.length = 0;
    if (grid) {
      scene.remove(grid);
      grid.geometry.dispose();
      disposeMaterial(grid.material);
      grid = null;
    }
    if (showGrid) {
      const gridSize = Math.max(44, Math.ceil(Math.max(model.bounds.width, model.bounds.depth) + 10));
      grid = new THREE.GridHelper(gridSize, gridSize, 0xcbd3dc, 0xe6eaee);
      grid.position.set(model.bounds.center[0], -0.5, model.bounds.center[2]);
      const materials = Array.isArray(grid.material) ? grid.material : [grid.material];
      for (const material of materials) {
        material.transparent = true;
        material.opacity = 0.7;
      }
      scene.add(grid);
    }
    if (showLayers) {
      for (const boundary of model.boundaries) hoverables.push(addEstateMoat(content, boundary));
      for (const locality of model.localities) hoverables.push(addCockroachLocality(content, locality));
      for (const plane of model.planes) hoverables.push(addPlane(content, plane));
      for (const group of model.groups) addGroupZone(content, group);
    }
    for (const route of model.routes) addRoute(content, route, selectedId);
    for (const node of model.nodes) hoverables.push(addNode(content, node, node.id === selectedId));
    fitModel(camera, controls, model, false, currentProjection);
  };

  return {
    renderModel,
    setProjection: (projection) => {
      const center = currentModel?.bounds.center ?? [0, 0, 0];
      currentProjection = projection;
      controls.enabled = projection === "3d";
      controls.maxPolarAngle = projection === "2d" ? Math.PI : Math.PI / 2.15;
      camera.up.set(0, projection === "2d" ? 0 : 1, projection === "2d" ? -1 : 0);
      camera.position.set(center[0] + (projection === "2d" ? 0.01 : 20), projection === "2d" ? 34 : 23, center[2] + (projection === "2d" ? 0.01 : 26));
      controls.target.set(center[0], 0, center[2]);
      camera.lookAt(controls.target);
      camera.updateProjectionMatrix();
      if (projection === "3d") controls.update();
      if (currentModel) fitModel(camera, controls, currentModel, true, projection);
    },
    fit: () => currentModel && fitModel(camera, controls, currentModel, true, currentProjection),
    zoom: (factor) => {
      camera.zoom = THREE.MathUtils.clamp(camera.zoom / factor, controls.minZoom, controls.maxZoom);
      camera.updateProjectionMatrix();
    },
    dispose: () => {
      cancelAnimationFrame(frame);
      observer.disconnect();
      renderer.domElement.removeEventListener("pointermove", updatePointer);
      renderer.domElement.removeEventListener("pointerleave", clearHover);
      renderer.domElement.removeEventListener("click", selectPointer);
      controls.dispose();
      clearGroup(content);
      if (grid) {
        grid.geometry.dispose();
        disposeMaterial(grid.material);
      }
      renderer.dispose();
      renderer.domElement.remove();
    },
  };
}

function addEstateMoat(parent: THREE.Group, boundary: ZiacSceneBoundary): THREE.Mesh {
  const geometry = new RoundedBoxGeometry(boundary.size[0], boundary.thickness, boundary.size[1], 4, 0.22);
  const material = new THREE.MeshStandardMaterial({
    color: estateColor(boundary),
    roughness: 0.72,
    metalness: 0.01,
    transparent: true,
    opacity: boundary.kind === "network" ? 0.58 : 0.72,
    emissive: boundary.kind === "network" ? 0x188038 : boundary.provider === "cockroach" ? 0x6f5bd3 : 0x1a73e8,
    emissiveIntensity: 0,
  });
  const mesh = new THREE.Mesh(geometry, material);
  mesh.position.set(...boundary.position);
  mesh.receiveShadow = true;
  mesh.userData.tooltip = boundary.tooltip;
  mesh.userData.hoverKind = "boundary";
  parent.add(mesh);

  const border = new THREE.LineSegments(
    new THREE.EdgesGeometry(geometry, 24),
    new THREE.LineBasicMaterial({ color: estateBorder(boundary), transparent: true, opacity: 0.92 }),
  );
  mesh.add(border);

  const label = new THREE.Mesh(
    new THREE.PlaneGeometry(boundary.surface.size[0], boundary.surface.size[1]),
    new THREE.MeshBasicMaterial({ map: createEstateSurfaceTexture(boundary), transparent: true, depthWrite: false, toneMapped: false }),
  );
  label.rotation.x = -Math.PI / 2;
  label.position.set(
    boundary.surface.position[0] - boundary.position[0],
    boundary.surface.position[1] - boundary.position[1],
    boundary.surface.position[2] - boundary.position[2],
  );
  label.renderOrder = 1;
  mesh.add(label);
  return mesh;
}

function addCockroachLocality(parent: THREE.Group, locality: ZiacSceneLocality): THREE.Mesh {
  const geometry = new RoundedBoxGeometry(locality.size[0], locality.thickness, locality.size[1], 3, 0.1);
  const material = new THREE.MeshStandardMaterial({
    color: locality.primary ? 0xe8e2fa : 0xf3f0fa,
    roughness: 0.68,
    metalness: 0.01,
    emissive: 0x6f5bd3,
    emissiveIntensity: 0,
  });
  const mesh = new THREE.Mesh(geometry, material);
  mesh.position.set(...locality.position);
  mesh.receiveShadow = true;
  mesh.userData.tooltip = locality.tooltip;
  mesh.userData.hoverKind = "locality";
  parent.add(mesh);

  const label = new THREE.Mesh(
    new THREE.PlaneGeometry(locality.size[0] - 0.16, locality.size[1] - 0.14),
    new THREE.MeshBasicMaterial({ map: createLocalitySurfaceTexture(locality), transparent: true, depthWrite: false, toneMapped: false }),
  );
  label.rotation.x = -Math.PI / 2;
  label.position.y = locality.thickness / 2 + 0.012;
  label.renderOrder = 2;
  mesh.add(label);
  return mesh;
}

function addPlane(group: THREE.Group, plane: ZiacScenePlane): THREE.Mesh {
  const geometry = new RoundedBoxGeometry(plane.size[0], plane.thickness, plane.size[1], 4, 0.16);
  const material = new THREE.MeshStandardMaterial({
    color: planeColor(plane.kind),
    roughness: 0.64,
    metalness: 0.02,
    transparent: true,
    opacity: plane.emphasized ? 0.96 : 0.58,
    emissive: 0x0b57d0,
    emissiveIntensity: 0,
  });
  const mesh = new THREE.Mesh(geometry, material);
  mesh.position.set(...plane.position);
  mesh.receiveShadow = true;
  mesh.userData.tooltip = plane.tooltip;
  mesh.userData.hoverKind = "slab";
  group.add(mesh);

  const edges = new THREE.LineSegments(
    new THREE.EdgesGeometry(geometry, 25),
    new THREE.LineBasicMaterial({ color: plane.emphasized ? 0xaab7c4 : 0xd4dae0, transparent: true, opacity: 0.88 }),
  );
  mesh.add(edges);

  const decalWidth = Math.min(7.2, Math.max(4.2, plane.size[0] - 0.8));
  const decalDepth = Math.min(1.05, Math.max(0.72, plane.size[1] * 0.2));
  const slabTexture = createSlabSurfaceTexture(plane);
  const decal = new THREE.Mesh(
    new THREE.PlaneGeometry(decalWidth, decalDepth),
    new THREE.MeshBasicMaterial({
      map: slabTexture,
      transparent: true,
      depthWrite: false,
      toneMapped: false,
    }),
  );
  decal.rotation.x = -Math.PI / 2;
  decal.position.set(
    -plane.size[0] / 2 + decalWidth / 2 + 0.38,
    plane.thickness / 2 + 0.012,
    plane.size[1] / 2 - decalDepth / 2 - 0.28,
  );
  decal.renderOrder = 2;
  mesh.add(decal);
  return mesh;
}

function addGroupZone(parent: THREE.Group, group: ZiacSceneGroup) {
  const zone = new THREE.Mesh(
    new THREE.PlaneGeometry(group.size[0], group.size[1]),
    new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0.34, depthWrite: false, toneMapped: false }),
  );
  zone.rotation.x = -Math.PI / 2;
  zone.position.set(group.position[0], group.position[1] + 0.008, group.position[2]);
  zone.renderOrder = 1;
  parent.add(zone);

  const halfWidth = group.size[0] / 2;
  const halfDepth = group.size[1] / 2;
  const borderGeometry = new THREE.BufferGeometry().setFromPoints([
    new THREE.Vector3(group.position[0] - halfWidth, group.position[1] + 0.018, group.position[2] - halfDepth),
    new THREE.Vector3(group.position[0] + halfWidth, group.position[1] + 0.018, group.position[2] - halfDepth),
    new THREE.Vector3(group.position[0] + halfWidth, group.position[1] + 0.018, group.position[2] + halfDepth),
    new THREE.Vector3(group.position[0] - halfWidth, group.position[1] + 0.018, group.position[2] + halfDepth),
  ]);
  const border = new THREE.LineLoop(borderGeometry, new THREE.LineBasicMaterial({ color: 0x9eabb6, transparent: true, opacity: 0.72 }));
  parent.add(border);

  const labelWidth = Math.min(5.4, group.size[0] - 0.3);
  const label = new THREE.Mesh(
    new THREE.PlaneGeometry(labelWidth, 0.48),
    new THREE.MeshBasicMaterial({ map: createGroupSurfaceTexture(group), transparent: true, depthWrite: false, toneMapped: false }),
  );
  label.rotation.x = -Math.PI / 2;
  label.position.set(
    group.position[0] - group.size[0] / 2 + labelWidth / 2 + 0.14,
    group.position[1] + 0.022,
    group.position[2] + group.size[1] / 2 - 0.34,
  );
  label.renderOrder = 2;
  parent.add(label);
}

function addNode(group: THREE.Group, node: ZiacSceneNode, selected: boolean): THREE.Mesh {
  const container = new THREE.Group();
  container.position.set(...node.position);
  container.userData.baseScale = 1;
  group.add(container);

  const geometry = new RoundedBoxGeometry(node.size[0], node.size[1], node.size[2], 5, 0.15);
  const material = new THREE.MeshStandardMaterial({
    color: selected ? 0xeaf2ff : node.ownership === "observed" ? 0xf0f6f5 : node.emphasized ? 0xf6f8fa : 0xe9edf1,
    roughness: 0.42,
    metalness: 0.06,
    emissive: selected ? new THREE.Color(0x0b57d0) : new THREE.Color(0x000000),
    emissiveIntensity: selected ? 0.1 : 0,
  });
  const mesh = new THREE.Mesh(geometry, material);
  mesh.castShadow = true;
  mesh.receiveShadow = true;
  mesh.userData.resourceId = node.id;
  mesh.userData.tooltip = node.tooltip;
  mesh.userData.hoverKind = "resource";
  mesh.userData.hoverTarget = container;
  container.add(mesh);

  const accent = new THREE.Mesh(
    new RoundedBoxGeometry(node.size[0] - 0.18, 0.08, node.size[2] - 0.18, 3, 0.06),
    new THREE.MeshStandardMaterial({ color: node.accent, roughness: 0.44, metalness: 0.06 }),
  );
  accent.position.y = node.size[1] / 2 + 0.04;
  accent.castShadow = true;
  container.add(accent);
  addResourceTopIcon(container, node);

  const face = new THREE.Mesh(
    new THREE.PlaneGeometry(node.size[0] - 0.18, node.size[1] - 0.18),
    new THREE.MeshBasicMaterial({ map: createResourceFaceTexture(node, selected), toneMapped: false }),
  );
  face.position.z = node.size[2] / 2 + 0.011;
  face.renderOrder = 3;
  container.add(face);

  const health = new THREE.Mesh(
    new RoundedBoxGeometry(0.58, 0.08, 0.08, 2, 0.02),
    new THREE.MeshStandardMaterial({ color: healthColor(node.health), emissive: healthColor(node.health), emissiveIntensity: 0.16 }),
  );
  health.position.set(node.size[0] / 2 - 0.46, -node.size[1] / 2 + 0.12, node.size[2] / 2 + 0.045);
  container.add(health);
  return mesh;
}

function addResourceTopIcon(container: THREE.Group, node: ZiacSceneNode) {
  if (!node.iconPath) return;
  const icon = new THREE.Mesh(
    new THREE.PlaneGeometry(1.02, 1.02),
    new THREE.MeshBasicMaterial({ map: providerTexture(node.iconPath), transparent: true, depthWrite: false, toneMapped: false }),
  );
  icon.rotation.x = -Math.PI / 2;
  icon.position.set(-node.size[0] / 2 + 0.7, node.size[1] / 2 + 0.115, 0.16);
  icon.renderOrder = 5;
  container.add(icon);
}

function providerTexture(path: string): THREE.Texture {
  const cached = providerTextureCache.get(path);
  if (cached) return cached;
  const texture = providerTextureLoader.load(path);
  texture.colorSpace = THREE.SRGBColorSpace;
  texture.anisotropy = 4;
  texture.userData.sharedProviderTexture = true;
  providerTextureCache.set(path, texture);
  return texture;
}

function addRoute(group: THREE.Group, route: ZiacSceneRoute, selectedId: string | null) {
  const selected = selectedId === route.sourceId || selectedId === route.targetId;
  const geometry = new LineGeometry();
  geometry.setPositions(route.path.flatMap((point) => point));
  const material = new LineMaterial({
    color: route.accent,
    linewidth: selected ? 3.4 : route.kind === "dependency" ? 1.8 : 2.2,
    transparent: true,
    opacity: selected ? 0.96 : route.kind === "dependency" ? 0.5 : 0.68,
    depthWrite: false,
    dashed: route.kind === "dependency",
    dashSize: 0.36,
    gapSize: 0.24,
    alphaToCoverage: true,
  });
  const line = new Line2(geometry, material);
  line.computeLineDistances();
  line.renderOrder = selected ? 5 : 3;
  group.add(line);

  if (route.kind !== "dependency") addFlatArrowhead(group, route, selected);
  if (route.kind === "iam" && route.label) addFlatPermissionBadge(group, route);
}

function addFlatArrowhead(group: THREE.Group, route: ZiacSceneRoute, selected: boolean) {
  const end = new THREE.Vector3(...route.path[route.path.length - 1]!);
  const previous = new THREE.Vector3(...route.path[route.path.length - 2]!);
  const tangent = end.clone().sub(previous).setY(0).normalize();
  const length = selected ? 0.34 : 0.29;
  const width = selected ? 0.14 : 0.11;
  const base = end.clone().addScaledVector(tangent, -length);
  const perpendicular = new THREE.Vector3(-tangent.z, 0, tangent.x).multiplyScalar(width);
  const y = end.y + 0.012;
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute("position", new THREE.Float32BufferAttribute([
    end.x, y, end.z,
    base.x + perpendicular.x, y, base.z + perpendicular.z,
    base.x - perpendicular.x, y, base.z - perpendicular.z,
  ], 3));
  geometry.computeVertexNormals();
  const arrowhead = new THREE.Mesh(geometry, new THREE.MeshBasicMaterial({
    color: route.accent,
    transparent: true,
    opacity: selected ? 0.96 : 0.74,
    depthWrite: false,
    side: THREE.DoubleSide,
    toneMapped: false,
  }));
  arrowhead.renderOrder = selected ? 6 : 4;
  group.add(arrowhead);
}

function addFlatPermissionBadge(group: THREE.Group, route: ZiacSceneRoute) {
  const midpoint = flatPathMidpoint(route.path);
  const badge = new THREE.Mesh(
    new THREE.PlaneGeometry(1.65, 0.44),
    new THREE.MeshBasicMaterial({
      map: createPermissionTexture(route),
      transparent: true,
      depthWrite: false,
      toneMapped: false,
      side: THREE.DoubleSide,
    }),
  );
  badge.rotation.x = -Math.PI / 2;
  badge.position.set(midpoint.x, midpoint.y + 0.018, midpoint.z);
  badge.renderOrder = 7;
  group.add(badge);
}

function flatPathMidpoint(path: ZiacSceneRoute["path"]): THREE.Vector3 {
  const points = path.map((point) => new THREE.Vector3(...point));
  const lengths = points.slice(1).map((point, index) => point.distanceTo(points[index]!));
  const target = lengths.reduce((total, length) => total + length, 0) / 2;
  let walked = 0;
  for (let index = 1; index < points.length; index += 1) {
    const length = lengths[index - 1]!;
    if (walked + length >= target) return points[index - 1]!.clone().lerp(points[index]!, (target - walked) / Math.max(length, 0.001));
    walked += length;
  }
  return points[points.length - 1]!.clone();
}

function createResourceFaceTexture(node: ZiacSceneNode, selected: boolean): THREE.CanvasTexture {
  const canvas = document.createElement("canvas");
  canvas.width = 1024;
  canvas.height = 384;
  const context = canvas.getContext("2d");
  if (!context) return new THREE.CanvasTexture(canvas);
  context.fillStyle = selected ? "#edf4ff" : "#f8fafc";
  context.fillRect(0, 0, canvas.width, canvas.height);
  context.fillStyle = node.accent;
  context.fillRect(0, 0, 22, canvas.height);
  context.fillRect(22, 0, canvas.width - 22, 10);

  const ownershipLabel = node.ownership === "observed" ? "OBSERVED" : node.ownership === "referenced" ? "REFERENCED" : null;
  if (ownershipLabel) {
    context.fillStyle = node.ownership === "observed" ? "#dcebea" : "#e7e3ef";
    context.fillRect(774, 28, 188, 54);
    context.fillStyle = node.ownership === "observed" ? "#416f6d" : "#675f82";
    context.font = "750 30px Inter, Arial, sans-serif";
    context.textAlign = "center";
    context.fillText(ownershipLabel, 868, 65, 164);
    context.textAlign = "start";
  }

  context.fillStyle = "#5f6872";
  context.font = "750 74px Inter, Arial, sans-serif";
  fitCanvasText(context, node.face.type.toUpperCase(), 62, 88, ownershipLabel ? 680 : 880, 74);
  context.fillStyle = "#1f2933";
  context.font = "750 104px Inter, Arial, sans-serif";
  fitCanvasText(context, node.face.name, 62, 194, 880, 104);
  context.fillStyle = "#7a838c";
  context.font = "750 38px Inter, Arial, sans-serif";
  context.fillText("RESOURCE ID", 62, 250);
  context.fillStyle = "#37414a";
  context.font = "600 48px ui-monospace, SFMono-Regular, Menlo, monospace";
  wrapCanvasText(context, node.face.id, 62, 305, 880, 50, 2);

  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  texture.anisotropy = 4;
  return texture;
}

function createSlabSurfaceTexture(plane: ZiacScenePlane): THREE.CanvasTexture {
  const canvas = document.createElement("canvas");
  canvas.width = 1024;
  canvas.height = 192;
  const context = canvas.getContext("2d");
  if (!context) return new THREE.CanvasTexture(canvas);
  context.clearRect(0, 0, canvas.width, canvas.height);
  context.fillStyle = "rgba(43, 54, 64, 0.88)";
  context.font = "750 52px Inter, Arial, sans-serif";
  fitCanvasText(context, plane.surface.title, 18, 73, 970, 52);
  context.fillStyle = "rgba(85, 97, 108, 0.9)";
  context.font = "600 31px Inter, Arial, sans-serif";
  fitCanvasText(context, plane.surface.subtitle, 18, 132, 970, 31);
  context.strokeStyle = "rgba(116, 130, 143, 0.45)";
  context.lineWidth = 3;
  context.beginPath();
  context.moveTo(18, 158);
  context.lineTo(988, 158);
  context.stroke();
  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  texture.anisotropy = 4;
  return texture;
}

function createEstateSurfaceTexture(boundary: ZiacSceneBoundary): THREE.CanvasTexture {
  const canvas = document.createElement("canvas");
  canvas.width = 1280;
  canvas.height = 192;
  const context = canvas.getContext("2d");
  if (!context) return new THREE.CanvasTexture(canvas);
  context.clearRect(0, 0, canvas.width, canvas.height);
  context.fillStyle = boundary.kind === "network" ? "#256d42" : boundary.provider === "cockroach" ? "#5945aa" : "#315f8d";
  context.fillRect(0, 0, 12, canvas.height);
  context.fillStyle = "rgba(31, 41, 51, 0.94)";
  context.font = "750 62px Inter, Arial, sans-serif";
  fitCanvasText(context, boundary.label, 40, 78, 1185, 62);
  context.fillStyle = "rgba(82, 94, 105, 0.94)";
  context.font = "650 36px Inter, Arial, sans-serif";
  fitCanvasText(context, boundary.detail, 40, 139, 1185, 36);
  context.strokeStyle = boundary.kind === "network" ? "rgba(37, 109, 66, 0.5)" : boundary.provider === "cockroach" ? "rgba(89, 69, 170, 0.44)" : "rgba(49, 95, 141, 0.44)";
  context.lineWidth = 4;
  context.beginPath();
  context.moveTo(40, 166);
  context.lineTo(1225, 166);
  context.stroke();
  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  texture.anisotropy = 4;
  return texture;
}

function createLocalitySurfaceTexture(locality: ZiacSceneLocality): THREE.CanvasTexture {
  const canvas = document.createElement("canvas");
  canvas.width = 768;
  canvas.height = 320;
  const context = canvas.getContext("2d");
  if (!context) return new THREE.CanvasTexture(canvas);
  context.clearRect(0, 0, canvas.width, canvas.height);
  context.fillStyle = locality.primary ? "#5945aa" : "#7b6eb5";
  context.beginPath();
  context.arc(58, 61, 18, 0, Math.PI * 2);
  context.fill();
  context.fillStyle = "#332b55";
  context.font = "750 56px Inter, Arial, sans-serif";
  fitCanvasText(context, locality.region, 96, 80, 638, 56);
  context.fillStyle = "#6f658b";
  context.font = "700 34px Inter, Arial, sans-serif";
  context.fillText(locality.primary ? "PRIMARY LOCALITY" : "REPLICA LOCALITY", 40, 160);
  context.fillStyle = "#4f465f";
  context.font = "600 31px Inter, Arial, sans-serif";
  fitCanvasText(context, "Cockroach Cloud", 40, 218, 680, 31);
  context.strokeStyle = "rgba(111, 91, 211, 0.42)";
  context.lineWidth = 4;
  context.beginPath();
  context.moveTo(40, 258);
  context.lineTo(728, 258);
  context.stroke();
  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  texture.anisotropy = 4;
  return texture;
}

function createGroupSurfaceTexture(group: ZiacSceneGroup): THREE.CanvasTexture {
  const canvas = document.createElement("canvas");
  canvas.width = 1024;
  canvas.height = 128;
  const context = canvas.getContext("2d");
  if (!context) return new THREE.CanvasTexture(canvas);
  context.clearRect(0, 0, canvas.width, canvas.height);
  context.fillStyle = "rgba(46, 58, 69, 0.92)";
  context.font = "750 48px Inter, Arial, sans-serif";
  fitCanvasText(context, group.label, 16, 58, 760, 48);
  context.fillStyle = "rgba(92, 103, 113, 0.94)";
  context.font = "700 33px Inter, Arial, sans-serif";
  context.fillText(`${group.count} RESOURCE${group.count === 1 ? "" : "S"}`, 16, 104);
  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  texture.anisotropy = 4;
  return texture;
}

function createPermissionTexture(route: ZiacSceneRoute): THREE.CanvasTexture {
  const canvas = document.createElement("canvas");
  canvas.width = 512;
  canvas.height = 128;
  const context = canvas.getContext("2d");
  if (!context) return new THREE.CanvasTexture(canvas);
  context.fillStyle = "rgba(255, 255, 255, 0.96)";
  context.fillRect(4, 4, 504, 120);
  context.strokeStyle = route.accent;
  context.lineWidth = 8;
  context.strokeRect(4, 4, 504, 120);
  context.fillStyle = "#26313a";
  context.font = "750 50px Inter, Arial, sans-serif";
  context.textAlign = "center";
  context.textBaseline = "middle";
  context.fillText(route.label ?? "IAM", 256, 64, 470);
  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  texture.anisotropy = 4;
  return texture;
}

function fitCanvasText(
  context: CanvasRenderingContext2D,
  value: string,
  x: number,
  y: number,
  maxWidth: number,
  baseSize: number,
) {
  let size = baseSize;
  while (context.measureText(value).width > maxWidth && size > 22) {
    size -= 2;
    context.font = context.font.replace(/\d+px/, `${size}px`);
  }
  context.fillText(value, x, y, maxWidth);
}

function wrapCanvasText(
  context: CanvasRenderingContext2D,
  value: string,
  x: number,
  y: number,
  maxWidth: number,
  lineHeight: number,
  maxLines: number,
) {
  const parts = value.split(/(?=[./:_-])/);
  const lines: string[] = [];
  let line = "";
  for (const part of parts) {
    const candidate = line + part;
    if (line && context.measureText(candidate).width > maxWidth) {
      lines.push(line);
      line = part;
    } else {
      line = candidate;
    }
  }
  if (line) lines.push(line);
  lines.slice(0, maxLines).forEach((valueLine, index) => {
    const truncated = index === maxLines - 1 && lines.length > maxLines ? `${valueLine.slice(0, -3)}...` : valueLine;
    context.fillText(truncated, x, y + index * lineHeight, maxWidth);
  });
}

function fitModel(
  camera: THREE.OrthographicCamera,
  controls: OrbitControls,
  model: ZiacSceneModel,
  animate: boolean,
  projection: "2d" | "3d",
) {
  const center = new THREE.Vector3(...model.bounds.center);
  const offset = camera.position.clone().sub(controls.target);
  controls.target.copy(center);
  camera.position.copy(center).add(offset);
  const desired = fitOrthographicSceneZoom(model.bounds, camera.right - camera.left, camera.top - camera.bottom, projection);
  const aspect = (camera.right - camera.left) / Math.max(1, camera.top - camera.bottom);
  camera.zoom = animate ? desired : aspect >= 0.85 ? Math.max(desired, 0.78) : desired;
  camera.updateProjectionMatrix();
  camera.lookAt(center);
  if (projection === "3d") controls.update();
}

function setMeshHover(object: THREE.Object3D, active: boolean) {
  if (object.userData.hoverKind === "resource") {
    const target = object.userData.hoverTarget as THREE.Object3D;
    target.scale.setScalar(active ? 1.035 : target.userData.baseScale ?? 1);
    return;
  }
  const material = (object as THREE.Mesh).material;
  if (material instanceof THREE.MeshStandardMaterial) material.emissiveIntensity = active ? 0.07 : 0;
}

function clearGroup(group: THREE.Group) {
  while (group.children.length > 0) {
    const child = group.children[0];
    if (!child) continue;
    group.remove(child);
    child.traverse((object) => {
      if (object instanceof THREE.Mesh || object instanceof THREE.Line || object instanceof THREE.LineSegments) {
        object.geometry.dispose();
        disposeMaterial(object.material);
      }
    });
  }
}

function disposeMaterial(material: THREE.Material | THREE.Material[]) {
  const disposeOne = (value: THREE.Material) => {
    const mapped = value as THREE.Material & { map?: THREE.Texture | null };
    if (!mapped.map?.userData.sharedProviderTexture) mapped.map?.dispose();
    value.dispose();
  };
  if (Array.isArray(material)) material.forEach(disposeOne);
  else disposeOne(material);
}

function planeColor(kind: ZiacScenePlane["kind"]): number {
  if (kind === "global") return 0xe9f0f6;
  if (kind === "region") return 0xeff4f8;
  if (kind === "data") return 0xf0edf7;
  return 0xf1f4f5;
}

function estateColor(boundary: ZiacSceneBoundary): number {
  if (boundary.kind === "network") return 0xe3f1e8;
  if (boundary.provider === "cockroach") return 0xeeeaf8;
  return 0xe6edf5;
}

function estateBorder(boundary: ZiacSceneBoundary): number {
  if (boundary.kind === "network") return 0x4f8d65;
  if (boundary.provider === "cockroach") return 0x7765bb;
  return 0x557ba2;
}

function healthColor(health: ZiacSceneNode["health"]): number {
  if (health === "healthy") return 0x34a853;
  if (health === "degraded" || health === "reconciling") return 0xf9ab00;
  if (health === "unhealthy") return 0xd93025;
  return 0x9aa0a6;
}
