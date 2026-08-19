import type {
  GatewayListRequest,
  GatewayRecord,
} from "../application/gateway-types";
import { normalizeGatewayPlacementClusterIds } from "../application/gateway-placement";
import type { GatewayConnection } from "./gateway-connections";

export const gatewayListQueryRoot = ["gateways", "list"] as const;
export const gatewayPlacementQueryRoot = ["gateways", "placements"] as const;
export const gatewayPlacementStaleMilliseconds = 60_000;
export const gatewaySearchDebounceMilliseconds = 250;
export const gatewayStatusPollMilliseconds = 5_000;

const gatewayPollingStates = new Set([
  "pending",
  "provisioning",
  "reconciling",
  "updating",
  "degraded",
]);
const gatewayFailedLifecycleStates = new Set(["error", "failed"]);

export function gatewayNeedsStatusPolling(
  gateway: Pick<
    GatewayRecord,
    "phase" | "status" | "externalDns" | "consoleUrl"
  >,
): boolean {
  const states = [gateway.phase, gateway.status]
    .map((value) => value?.trim().toLocaleLowerCase() ?? "")
    .filter(Boolean);

  if (
    states.length === 0 ||
    states.some((value) => gatewayPollingStates.has(value))
  ) {
    return true;
  }

  return gatewayAwaitingConsole(gateway, states);
}

// A routed gateway reaches Running before its per-gateway console pod can serve;
// the control plane publishes console_address only once that pod is Ready. Keep
// polling a settled routed gateway (one with an external endpoint) until its
// console URL arrives so the console button appears without a manual page
// refresh. A failed gateway will not gain a console, so it never keeps polling.
function gatewayAwaitingConsole(
  gateway: Pick<GatewayRecord, "externalDns" | "consoleUrl">,
  states: readonly string[],
): boolean {
  const routed = Boolean(gateway.externalDns?.trim());
  const consolePublished = Boolean(gateway.consoleUrl?.trim());
  const failed = states.some((value) =>
    gatewayFailedLifecycleStates.has(value),
  );
  return routed && !consolePublished && !failed;
}

export function gatewayListQueryKey(request: GatewayListRequest) {
  return [
    ...gatewayListQueryRoot,
    request.page,
    request.size,
    request.search,
    request.sortField,
    request.sortDirection,
  ] as const;
}

export function gatewayQueryKey(gatewayId: string) {
  return ["gateways", "detail", gatewayId] as const;
}

export function gatewayPlacementQueryKey(search: string) {
  return [...gatewayPlacementQueryRoot, "search", search.trim()] as const;
}

export function gatewayPlacementDetailQueryKey(clusterId: string) {
  return [...gatewayPlacementQueryRoot, "detail", clusterId] as const;
}

export function gatewayPlacementBatchQueryKey(clusterIds: readonly string[]) {
  const normalizedClusterIds = normalizeGatewayPlacementClusterIds(clusterIds);
  return [
    ...gatewayPlacementQueryRoot,
    "batch",
    ...normalizedClusterIds,
  ] as const;
}

type GatewayApiPayload = Omit<
  GatewayRecord,
  "externalDns" | "phase" | "status"
> &
  Partial<Pick<GatewayRecord, "externalDns" | "phase" | "status">>;

function gatewayEndpoint(gateway: GatewayApiPayload): string | undefined {
  const externalDns = gateway.externalDns?.trim() ?? "";
  if (!externalDns) {
    return undefined;
  }
  if (/^https?:\/\//iu.test(externalDns)) {
    return externalDns;
  }

  return `https://${externalDns}${externalDns.includes(":") ? "" : ":443"}`;
}

export function toGatewayConnection(
  gateway: GatewayApiPayload,
  hubClusterName: string,
): GatewayConnection {
  const clusterId = gateway.clusterId.trim();
  const phase = gateway.phase?.trim() ?? "";
  const healthStatus = gateway.status?.trim() ?? "";
  const normalizedPhase = phase.toLocaleLowerCase();
  const status =
    phase &&
    (gatewayPollingStates.has(normalizedPhase) ||
      gatewayFailedLifecycleStates.has(normalizedPhase))
      ? phase
      : healthStatus || phase;

  return {
    ...(typeof gateway.activeSandboxCount === "number"
      ? { activeSandboxCount: gateway.activeSandboxCount }
      : {}),
    ...(clusterId ? { clusterId } : {}),
    clusterName: clusterId ? "" : hubClusterName,
    ...(gateway.consoleUrl ? { consoleUrl: gateway.consoleUrl } : {}),
    ...(gateway.createdAt ? { createdAt: gateway.createdAt } : {}),
    endpoint: gatewayEndpoint(gateway),
    id: gateway.id,
    name: gateway.name,
    ...(gateway.oidcAudience ? { oidcAudience: gateway.oidcAudience } : {}),
    ...(gateway.oidcClientId ? { oidcClientId: gateway.oidcClientId } : {}),
    ...(gateway.oidcIssuer ? { oidcIssuer: gateway.oidcIssuer } : {}),
    ...(phase ? { phase } : {}),
    status: status || "Unknown",
  };
}
