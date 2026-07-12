// Ziac dashboard-owned global infrastructure map.
import { For, Show, createEffect, createMemo, onCleanup, onMount } from "solid-js";
import maplibregl from "maplibre-gl";
import "maplibre-gl/dist/maplibre-gl.css";
import { MapboxOverlay } from "@deck.gl/mapbox";
import { ArcLayer, ScatterplotLayer, TextLayer } from "@deck.gl/layers";
import type { Layer, PickingInfo } from "@deck.gl/core";
import { Cloud, Database, Globe2, MapPin } from "lucide-solid";
import { deriveZiacGlobalMapModel, type ZiacGlobalMapModel, type ZiacMapRegionMarker, type ZiacMapRoute } from "./ziacGlobalMapModel";
import type { FilteredZiacVisualModel } from "./ziacVisualArtifact";

const MONOCHROME_ROUTE: [number, number, number, number] = [91, 101, 111, 150];
const MONOCHROME_MARKER: [number, number, number, number] = [76, 86, 96, 230];

export function ZiacGlobalMap(props: {
  model: FilteredZiacVisualModel;
  selectedId: string | null;
  onSelect: (id: string) => void;
}) {
  let container!: HTMLDivElement;
  let map: maplibregl.Map | null = null;
  let overlay: MapboxOverlay | null = null;
  const mapModel = createMemo(() => deriveZiacGlobalMapModel(props.model, props.selectedId));

  onMount(() => {
    map = new maplibregl.Map({
      container,
      style: "https://basemaps.cartocdn.com/gl/positron-gl-style/style.json",
      center: [18, 24],
      zoom: 0.8,
      minZoom: 0.6,
      maxZoom: 8,
      attributionControl: false,
      dragRotate: false,
      canvasContextAttributes: { antialias: true },
    });
    map.addControl(new maplibregl.NavigationControl({ showCompass: false }), "top-right");
    map.addControl(new maplibregl.AttributionControl({ compact: true }), "bottom-right");
    overlay = new MapboxOverlay({ interleaved: false, layers: deckLayers(mapModel(), props.onSelect) });
    map.addControl(overlay as unknown as maplibregl.IControl);
    map.once("load", () => {
      map?.resize();
    });
  });

  createEffect(() => {
    const current = mapModel();
    overlay?.setProps({ layers: deckLayers(current, props.onSelect) });
  });

  onCleanup(() => {
    overlay = null;
    map?.remove();
    map = null;
  });

  return (
    <div class="ziac-map-shell">
      <div ref={container} class="ziac-map-canvas" aria-label="Global deployment map" />
      <Show when={mapModel().frontDoor}>
        {(frontDoor) => (
          <button type="button" class="ziac-map-front-door" onClick={() => props.onSelect(frontDoor().id)}>
            <Globe2 size={17} />
            <span><small>Global front door</small><strong>{frontDoor().logical_id}</strong></span>
            <em>{mapModel().routes.length} inferred routes</em>
          </button>
        )}
      </Show>
      <div class="ziac-map-provenance">
        <span><i />inferred</span>
        <span><b />Cloud Run</span>
        <span><u />CockroachDB locality</span>
      </div>
      <div class="ziac-map-region-strip" aria-label="Global deployment regions">
        <For each={mapModel().regionMarkers}>
          {(marker) => (
            <button type="button" classList={{ selected: marker.selected }} onClick={() => marker.primaryResourceId && props.onSelect(marker.primaryResourceId)}>
              <MapPin size={14} />
              <span><strong>{marker.region}</strong><small>{marker.label}</small></span>
              <em>{marker.resourceCount}</em>
              <span class="ziac-region-providers">
                <Show when={marker.cloudRunResources.length > 0}><Cloud size={13} /></Show>
                <Show when={marker.cockroachResources.length > 0}><Database size={13} /></Show>
              </span>
            </button>
          )}
        </For>
        <For each={mapModel().unmappedRegions}>
          {(region) => <span class="ziac-unmapped-region"><MapPin size={13} />{region}<em>unmapped</em></span>}
        </For>
      </div>
    </div>
  );
}

function deckLayers(model: ZiacGlobalMapModel, onSelect: (id: string) => void): Layer[] {
  return [
    new ArcLayer<ZiacMapRoute>({
      id: "ziac-global-routes",
      data: model.routes,
      getSourcePosition: (route) => route.sourcePosition,
      getTargetPosition: (route) => route.targetPosition,
      getSourceColor: (route) => route.selected ? provenanceColor(route.provenance, 230) : MONOCHROME_ROUTE,
      getTargetColor: (route) => route.selected ? [26, 115, 232, 245] : MONOCHROME_ROUTE,
      getWidth: (route) => route.selected ? 4 : 2,
      widthMinPixels: 1.5,
      greatCircle: true,
      pickable: true,
      onClick: ({ object }: PickingInfo<ZiacMapRoute>) => object && onSelect(object.targetResourceId),
      updateTriggers: { getTargetColor: model.routes.map((route) => route.selected), getWidth: model.routes.map((route) => route.selected) },
    }),
    new ScatterplotLayer<ZiacMapRoute>({
      id: "ziac-ingress-points",
      data: model.routes,
      getPosition: (route) => route.sourcePosition,
      getRadius: 4,
      radiusUnits: "pixels",
      filled: false,
      stroked: true,
      getLineColor: [91, 101, 111, 145],
      lineWidthMinPixels: 1,
    }),
    new ScatterplotLayer<ZiacMapRegionMarker>({
      id: "ziac-region-markers",
      data: model.regionMarkers,
      getPosition: (marker) => marker.position,
      getRadius: (marker) => marker.selected ? 13 : 9,
      radiusUnits: "pixels",
      filled: true,
      stroked: true,
      getFillColor: (marker) => markerFill(marker),
      getLineColor: (marker) => marker.selected ? [11, 87, 208, 255] : [255, 255, 255, 245],
      getLineWidth: (marker) => marker.selected ? 3 : 2,
      lineWidthUnits: "pixels",
      pickable: true,
      onClick: ({ object }: PickingInfo<ZiacMapRegionMarker>) => {
        if (object?.primaryResourceId) onSelect(object.primaryResourceId);
      },
      updateTriggers: { getRadius: model.regionMarkers.map((marker) => marker.selected), getFillColor: model.regionMarkers.map((marker) => marker.operation) },
    }),
    new TextLayer<ZiacMapRegionMarker>({
      id: "ziac-region-labels",
      data: model.regionMarkers,
      getPosition: (marker) => marker.position,
      getText: (marker) => `${marker.region}\n${marker.resourceCount} resources`,
      getSize: 11,
      sizeUnits: "pixels",
      getColor: [22, 33, 30, 245],
      getPixelOffset: [0, -25],
      getTextAnchor: "middle",
      getAlignmentBaseline: "bottom",
      fontFamily: "Inter, system-ui, sans-serif",
      fontWeight: 700,
    }),
  ];
}

function provenanceColor(provenance: ZiacMapRoute["provenance"], alpha: number): [number, number, number, number] {
  if (provenance === "observed") return [25, 128, 56, alpha];
  if (provenance === "planned") return [176, 96, 0, alpha];
  return [8, 127, 140, alpha];
}

function markerFill(marker: ZiacMapRegionMarker): [number, number, number, number] {
  if (marker.selected) return [26, 115, 232, 242];
  if (marker.operation === "delete" || marker.operation === "replace") return [197, 34, 31, 235];
  if (marker.operation === "update") return [176, 96, 0, 235];
  if (marker.health === "unhealthy") return [197, 34, 31, 235];
  if (marker.health === "degraded" || marker.health === "reconciling") return [176, 96, 0, 235];
  if (marker.health === "healthy") return [38, 130, 66, 235];
  return MONOCHROME_MARKER;
}
