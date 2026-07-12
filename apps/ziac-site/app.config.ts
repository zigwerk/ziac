import { defineConfig } from "@solidjs/start/config";

export default defineConfig({
  serialization: {
    mode: "json",
  },
  vite: {
    resolve: {
      conditions: ["solid"],
    },
    ssr: {
      noExternal: ["lucide-solid"],
    },
  },
  server: {
    preset: "static",
    prerender: {
      routes: ["/", "/how-it-works", "/why-zig", "/why-zigeffect", "/causal-graph", "/case-studies/yachdee-court-series"],
    },
  },
});
