import { loadConfig } from "../src/config.js";

describe("loadConfig", () => {
  it("validates and normalizes trusted runtime configuration", () => {
    const config = loadConfig({
      HOST: "127.0.0.1",
      HYPERSHELL_API_ORIGIN: "https://api.example.test/",
      HYPERSHELL_API_TIMEOUT_MS: "5000",
      HYPERSHELL_GATEWAY_OIDC_AUDIENCE: "openshell-cli",
      HYPERSHELL_GATEWAY_OIDC_CLIENT_ID: "openshell-cli",
      HYPERSHELL_GATEWAY_OIDC_ISSUER:
        "https://issuer.example.test/realms/hypershell/",
      HYPERSHELL_GATEWAY_OIDC_SCOPES: "openid profile email openshell:all",
      LOG_LEVEL: "warn",
      NODE_ENV: "production",
      PORT: "8081",
      STATIC_ROOT: "./public",
    });

    expect(config.apiOrigin).toBe("https://api.example.test");
    expect(config.apiTimeoutMs).toBe(5000);
    expect(config.gatewayConnection).toEqual({
      oidcAudience: "openshell-cli",
      oidcClientId: "openshell-cli",
      oidcIssuer: "https://issuer.example.test/realms/hypershell",
      oidcScopes: "openid profile email openshell:all",
    });
    expect(config.host).toBe("127.0.0.1");
    expect(config.port).toBe(8081);
    expect(pathIsAbsolute(config.staticRoot)).toBe(true);
  });

  it("fails closed without echoing invalid values", () => {
    expect(() => loadConfig({ PORT: "secret-invalid-port" })).toThrow(
      /Invalid web-console BFF configuration/,
    );
    expect(() => loadConfig({ PORT: "secret-invalid-port" })).not.toThrow(
      /secret-invalid-port/,
    );
  });

  it("rejects an API URL that is not an origin", () => {
    expect(() =>
      loadConfig({ HYPERSHELL_API_ORIGIN: "https://api.example.test/v1" }),
    ).toThrow(/HYPERSHELL_API_ORIGIN/u);
  });

  it("rejects partial gateway OIDC settings without echoing values", () => {
    const loadPartial = () =>
      loadConfig({
        HYPERSHELL_GATEWAY_OIDC_ISSUER:
          "https://secret-issuer.example.test/realms/hypershell",
      });

    expect(loadPartial).toThrow(/gateway OIDC connection settings/u);
    expect(loadPartial).not.toThrow(/secret-issuer/u);
  });
});

function pathIsAbsolute(value: string): boolean {
  return value.startsWith("/");
}
