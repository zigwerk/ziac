import { fileURLToPath } from "node:url";
import type { Plugin } from "vite";
import { defineConfig } from "vite";
import solid from "vite-plugin-solid";

const root = fileURLToPath(new URL(".", import.meta.url));

function ziacWebuiDevShim(): Plugin {
  return {
    name: "ziac-webui-dev-shim",
    configureServer(server) {
      server.middlewares.use((request, response, next) => {
        if (request.url?.split("?")[0] !== "/webui.js") {
          next();
          return;
        }
        response.statusCode = 200;
        response.setHeader("Content-Type", "application/javascript");
        response.end("window.__ziacWebuiDevShim = true;");
      });
    },
  };
}

export default defineConfig({
  root,
  base: "./",
  plugins: [ziacWebuiDevShim(), solid()],
  build: {
    outDir: "dist",
    emptyOutDir: true,
    target: "es2022",
    chunkSizeWarningLimit: 1800,
  },
});

