export interface GatewayConnectionDefaults {
  oidcAudience: string;
  oidcClientId: string;
  oidcIssuer: string;
  oidcScopes: string;
}

interface RuntimeConfigPayload {
  gatewayConnection?: unknown;
}

function isConnectionDefaults(
  value: unknown,
): value is GatewayConnectionDefaults {
  if (typeof value !== "object" || value === null) {
    return false;
  }
  const candidate = value as Record<string, unknown>;
  return ["oidcAudience", "oidcClientId", "oidcIssuer", "oidcScopes"].every(
    (field) =>
      typeof candidate[field] === "string" &&
      candidate[field].trim().length > 0,
  );
}

export async function loadGatewayConnectionDefaults(
  signal?: AbortSignal,
): Promise<GatewayConnectionDefaults | undefined> {
  try {
    const response = await fetch("/api/console/v1/config", {
      credentials: "same-origin",
      headers: { accept: "application/json" },
      signal,
    });
    if (!response.ok) {
      return undefined;
    }
    const payload = (await response.json()) as RuntimeConfigPayload;
    return isConnectionDefaults(payload.gatewayConnection)
      ? payload.gatewayConnection
      : undefined;
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError") {
      throw error;
    }
    return undefined;
  }
}
