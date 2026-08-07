import { reactRouter } from "@react-router/dev/vite";
import { defineConfig, type Plugin } from "vite";

import { resolveDevApiOrigin } from "./app/lib/dev-api-origin";

const getApiOrigin = (): string => {
  const configuredOrigin =
    process.env.WEB_CONSOLE_API_ORIGIN ?? "http://127.0.0.1:8000";
  return resolveDevApiOrigin(
    configuredOrigin,
    process.env.WEB_CONSOLE_DEV_CLUSTER === "true",
  );
};

const runtimeConfigPlugin = (): Plugin => ({
  name: "hypershell-runtime-config",
  configureServer(server) {
    const oidcAudience = process.env.HYPERSHELL_GATEWAY_OIDC_AUDIENCE?.trim();
    const oidcClientId = process.env.HYPERSHELL_GATEWAY_OIDC_CLIENT_ID?.trim();
    const oidcIssuer = process.env.HYPERSHELL_GATEWAY_OIDC_ISSUER?.trim();
    const oidcScopes = process.env.HYPERSHELL_GATEWAY_OIDC_SCOPES?.trim();
    const values = [oidcAudience, oidcClientId, oidcIssuer, oidcScopes];
    const configuredCount = values.filter(Boolean).length;
    if (configuredCount !== 0 && configuredCount !== values.length) {
      throw new Error(
        "Gateway OIDC connection settings must be configured together",
      );
    }
    const gatewayConnection =
      oidcAudience && oidcClientId && oidcIssuer && oidcScopes
        ? { oidcAudience, oidcClientId, oidcIssuer, oidcScopes }
        : null;

    server.middlewares.use((request, response, next) => {
      const pathname = new URL(request.url ?? "/", "http://localhost").pathname;
      if (request.method !== "GET" || pathname !== "/api/console/v1/config") {
        next();
        return;
      }
      response.statusCode = 200;
      response.setHeader("cache-control", "no-store");
      response.setHeader("content-type", "application/json; charset=utf-8");
      response.end(JSON.stringify({ gatewayConnection }));
    });
  },
});

export default defineConfig({
  cacheDir: process.env.WEB_CONSOLE_CACHE_DIR,
  envDir: false,
  plugins:
    process.env.STORYBOOK === "true"
      ? []
      : [runtimeConfigPlugin(), reactRouter()],
  build: {
    sourcemap: false,
    target: "es2022",
  },
  server: {
    host: "127.0.0.1",
    port: 5173,
    strictPort: true,
    proxy: {
      "/api": {
        target: getApiOrigin(),
        changeOrigin: false,
      },
    },
  },
  ssr: {
    noExternal: [/^@patternfly\//],
  },
});
