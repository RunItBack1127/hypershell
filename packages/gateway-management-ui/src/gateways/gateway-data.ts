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
// Upper bound on how long a settled routed gateway is polled for its console
// address. A routed gateway is not proof of console eligibility: its console
// provisioning can be disabled, misconfigured, or stuck, in which case
// console_address never arrives. Without a bound the UI would poll that gateway
// every gatewayStatusPollMilliseconds forever. Once this window (measured from
// the gateway's createdAt) elapses, polling stops and the UI surfaces a terminal
// "console unavailable" state (gatewayConsoleUnavailable).
export const gatewayConsoleReadyDeadlineMilliseconds = 600_000;

const gatewayPollingStates = new Set([
  "pending",
  "provisioning",
  "reconciling",
  "updating",
  "degraded",
]);
const gatewayFailedLifecycleStates = new Set(["error", "failed"]);

type GatewayConsoleRecord = Pick<
  GatewayRecord,
  "phase" | "status" | "externalDns" | "consoleUrl" | "createdAt"
>;

export function gatewayNeedsStatusPolling(
  gateway: GatewayConsoleRecord,
  now: number = Date.now(),
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

  return gatewayAwaitingConsole(gateway, states, now);
}

// A routed gateway reaches Running before its per-gateway console pod can serve;
// the control plane publishes console_address only once that pod is Ready. Keep
// polling a settled routed gateway (one with an external endpoint) until its
// console URL arrives so the console button appears without a manual page
// refresh. A failed gateway will not gain a console, so it never keeps polling,
// and polling is bounded by gatewayConsoleReadyDeadlineMilliseconds so a gateway
// that is routed but never console-eligible does not poll forever.
function gatewayAwaitingConsole(
  gateway: Pick<GatewayRecord, "externalDns" | "consoleUrl" | "createdAt">,
  states: readonly string[],
  now: number,
): boolean {
  const routed = Boolean(gateway.externalDns?.trim());
  const consolePublished = Boolean(gateway.consoleUrl?.trim());
  const failed = states.some((value) =>
    gatewayFailedLifecycleStates.has(value),
  );
  return (
    routed &&
    !consolePublished &&
    !failed &&
    withinConsoleReadyDeadline(gateway.createdAt, now)
  );
}

// Reports whether the console-ready polling window is still open. A gateway with
// no parseable createdAt cannot be bounded, so it is treated as past the
// deadline (do not poll) rather than polled indefinitely.
function withinConsoleReadyDeadline(
  createdAt: string | undefined,
  now: number,
): boolean {
  if (!createdAt) {
    return false;
  }
  const created = Date.parse(createdAt);
  if (Number.isNaN(created)) {
    return false;
  }
  return now - created < gatewayConsoleReadyDeadlineMilliseconds;
}

// Shared deadline primitive for views that already know a gateway is routed and
// settled (e.g. the detail header, gated by isGatewayReadyToConnect) and only
// need to distinguish "console still provisioning" from "console unavailable".
export function isGatewayConsolePastDeadline(
  createdAt: string | undefined,
  now: number = Date.now(),
): boolean {
  return !withinConsoleReadyDeadline(createdAt, now);
}

// True when a routed gateway has settled (not transitional, not failed) without
// a console URL and the console-ready polling window has elapsed, so the UI can
// surface a terminal "console unavailable" state instead of an indefinite
// "provisioning" spinner.
export function gatewayConsoleUnavailable(
  gateway: GatewayConsoleRecord,
  now: number = Date.now(),
): boolean {
  const routed = Boolean(gateway.externalDns?.trim());
  const consolePublished = Boolean(gateway.consoleUrl?.trim());
  if (!routed || consolePublished) {
    return false;
  }

  const states = [gateway.phase, gateway.status]
    .map((value) => value?.trim().toLocaleLowerCase() ?? "")
    .filter(Boolean);
  const transitional =
    states.length === 0 ||
    states.some((value) => gatewayPollingStates.has(value));
  const failed = states.some((value) =>
    gatewayFailedLifecycleStates.has(value),
  );
  if (transitional || failed) {
    return false;
  }

  return !withinConsoleReadyDeadline(gateway.createdAt, now);
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
