import { afterEach, describe, expect, it, vi } from "vitest";

import { loadGatewayConnectionDefaults } from "./gateway-connection-config";

describe("gateway connection runtime configuration", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("loads complete same-origin connection defaults", async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({
          gatewayConnection: {
            oidcAudience: "openshell-cli",
            oidcClientId: "openshell-cli",
            oidcIssuer: "https://issuer.example.test/realms/openshell",
            oidcScopes: "openid profile email openshell:all",
          },
        }),
        { headers: { "content-type": "application/json" }, status: 200 },
      ),
    );
    vi.stubGlobal("fetch", fetchMock);
    const controller = new AbortController();

    await expect(
      loadGatewayConnectionDefaults(controller.signal),
    ).resolves.toEqual({
      oidcAudience: "openshell-cli",
      oidcClientId: "openshell-cli",
      oidcIssuer: "https://issuer.example.test/realms/openshell",
      oidcScopes: "openid profile email openshell:all",
    });
    expect(fetchMock).toHaveBeenCalledWith("/api/console/v1/config", {
      credentials: "same-origin",
      headers: { accept: "application/json" },
      signal: controller.signal,
    });
  });

  it("keeps commands unavailable for absent or malformed configuration", async () => {
    vi.stubGlobal(
      "fetch",
      vi
        .fn()
        .mockResolvedValueOnce(
          new Response(JSON.stringify({ gatewayConnection: null }), {
            status: 200,
          }),
        )
        .mockResolvedValueOnce(
          new Response(
            JSON.stringify({ gatewayConnection: { oidcIssuer: "issuer" } }),
            { status: 200 },
          ),
        ),
    );

    await expect(loadGatewayConnectionDefaults()).resolves.toBeUndefined();
    await expect(loadGatewayConnectionDefaults()).resolves.toBeUndefined();
  });
});
