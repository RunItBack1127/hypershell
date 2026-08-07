import { createGatewayOperations } from "@openshift-online/hypershell-gateway-ui";

import { createApiClient } from "../adapters/api/api.client";
import { createGatewayControlPlaneAdapter } from "../adapters/api/gateway-operations";
import { loadGatewayConnectionDefaults } from "../adapters/config/gateway-connection-config";
import { gatewayObservability } from "../adapters/observability/gateway-observability";

const gatewayControlPlane = createGatewayControlPlaneAdapter(
  (correlationId) => createApiClient(correlationId),
  loadGatewayConnectionDefaults,
);

export const gatewayOperations = createGatewayOperations({
  controlPlane: gatewayControlPlane,
  probes: gatewayObservability.probes,
  runtime: gatewayObservability.runtime,
});
