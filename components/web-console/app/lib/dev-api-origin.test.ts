import { describe, expect, it } from "vitest";

import { resolveDevApiOrigin } from "./dev-api-origin";

describe("resolveDevApiOrigin", () => {
  it("allows loopback development origins", () => {
    expect(resolveDevApiOrigin("http://127.0.0.1:8000")).toBe(
      "http://127.0.0.1:8000",
    );
  });

  it("allows only the explicit Kind API service when enabled", () => {
    expect(resolveDevApiOrigin("http://hypershell-api-server:8000", true)).toBe(
      "http://hypershell-api-server:8000",
    );
    expect(() =>
      resolveDevApiOrigin("http://hypershell-api-server:8000"),
    ).toThrow(/loopback host/u);
  });

  it.each([
    "http://api.example.test:8000",
    "https://hypershell-api-server:8000",
    "http://hypershell-api-server:9000",
    "http://hypershell-api-server:8000/api",
  ])("rejects unapproved origins even in cluster mode: %s", (origin) => {
    expect(() => resolveDevApiOrigin(origin, true)).toThrow();
  });
});
