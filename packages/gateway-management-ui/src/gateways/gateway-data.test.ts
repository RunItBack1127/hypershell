import { describe, expect, it } from "vitest";

import { normalizeGatewayPlacementClusterIds } from "../application/gateway-placement";
import type { GatewayRecord } from "../application/gateway-types";
import {
  gatewayNeedsStatusPolling,
  gatewayPlacementBatchQueryKey,
  gatewayStatusPollMilliseconds,
  toGatewayConnection,
} from "./gateway-data";

function gateway(overrides: Partial<GatewayRecord> = {}): GatewayRecord {
  return {
    clusterId: "",
    createdAt: "2026-08-10T14:30:00Z",
    databaseId: "database-1",
    externalDns: "gateway.example.com",
    id: "gateway-1",
    name: "Team gateway",
    namespace: "openshell",
    phase: "",
    releaseId: "release-1",
    status: "Ready",
    ...overrides,
  };
}

describe("gateway presentation data", () => {
  it("uses one canonical cluster identifier normalization for batch keys", () => {
    const clusterIds = [" cluster-west ", "", "cluster-east", "cluster-west"];

    expect(normalizeGatewayPlacementClusterIds(clusterIds)).toEqual([
      "cluster-east",
      "cluster-west",
    ]);
    expect(gatewayPlacementBatchQueryKey(clusterIds)).toEqual([
      "gateways",
      "placements",
      "batch",
      "cluster-east",
      "cluster-west",
    ]);
  });

  it("maps gateway values into the connection view", () => {
    expect(
      toGatewayConnection(
        gateway({ phase: "Running" }),
        "Localized hub cluster",
      ),
    ).toMatchObject({
      clusterName: "Localized hub cluster",
      createdAt: "2026-08-10T14:30:00Z",
      endpoint: "https://gateway.example.com:443",
      id: "gateway-1",
      name: "Team gateway",
      phase: "Running",
      status: "Ready",
    });
  });

  it("omits phase when the gateway has not reported one", () => {
    expect(
      toGatewayConnection(gateway({ phase: "" }), "Hub cluster").phase,
    ).toBe(undefined);
  });

  it("polls transitional gateway lifecycle states at a bounded interval", () => {
    expect(gatewayStatusPollMilliseconds).toBe(5_000);
    expect(gatewayNeedsStatusPolling(gateway({ phase: "", status: "" }))).toBe(
      true,
    );
    expect(gatewayNeedsStatusPolling(gateway({ phase: "Pending" }))).toBe(true);
    expect(gatewayNeedsStatusPolling(gateway({ phase: "Provisioning" }))).toBe(
      true,
    );
    expect(gatewayNeedsStatusPolling(gateway({ status: "Updating" }))).toBe(
      true,
    );
    expect(gatewayNeedsStatusPolling(gateway({ phase: "Degraded" }))).toBe(
      true,
    );
  });

  it("stops lifecycle polling for terminal gateway states", () => {
    expect(
      gatewayNeedsStatusPolling(
        gateway({
          consoleUrl: "https://console.example.com",
          phase: "Running",
        }),
      ),
    ).toBe(false);
    expect(gatewayNeedsStatusPolling(gateway({ phase: "Failed" }))).toBe(false);
  });

  it("keeps polling a running routed gateway until its console address arrives", () => {
    // A routed gateway reaches Running before its console pod can serve; the
    // control plane publishes console_address only once the pod is Ready. Keep
    // polling so the console button appears without a manual page refresh.
    expect(gatewayNeedsStatusPolling(gateway({ phase: "Running" }))).toBe(true);

    // Once the console URL is published, the button can render and polling stops.
    expect(
      gatewayNeedsStatusPolling(
        gateway({
          consoleUrl: "https://console.example.com",
          phase: "Running",
        }),
      ),
    ).toBe(false);

    // A non-routed gateway never gains a console, so a settled one does not poll.
    expect(
      gatewayNeedsStatusPolling(
        gateway({ externalDns: undefined, phase: "Running" }),
      ),
    ).toBe(false);
  });

  it("presents transitional and failed lifecycle phases before health", () => {
    expect(
      toGatewayConnection(
        gateway({ phase: "Provisioning", status: "Ready" }),
        "Hub cluster",
      ).status,
    ).toBe("Provisioning");
    expect(
      toGatewayConnection(
        gateway({ phase: "Failed", status: "Ready" }),
        "Hub cluster",
      ).status,
    ).toBe("Failed");
    expect(
      toGatewayConnection(
        gateway({ phase: "Running", status: "Degraded" }),
        "Hub cluster",
      ).status,
    ).toBe("Degraded");
  });

  it("keeps a returned cluster identifier for name resolution only", () => {
    expect(
      toGatewayConnection(
        gateway({ clusterId: "  cluster-east  " }),
        "Hub cluster",
      ),
    ).toMatchObject({
      clusterId: "cluster-east",
      clusterName: "",
    });
  });

  it("keeps API-owned connection values unavailable when they are absent", () => {
    const connection = toGatewayConnection(
      gateway({ externalDns: undefined, status: undefined }),
      "Hub cluster",
    );

    expect(connection.endpoint).toBeUndefined();
    expect(connection.consoleUrl).toBeUndefined();
    expect(connection.oidcIssuer).toBeUndefined();
    expect(connection.status).toBe("Unknown");
  });
});
