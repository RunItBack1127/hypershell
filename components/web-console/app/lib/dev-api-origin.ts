export const resolveDevApiOrigin = (
  configuredOrigin: string,
  allowInClusterService = false,
): string => {
  const origin = new URL(configuredOrigin);
  const isLoopback = ["127.0.0.1", "::1", "localhost"].includes(
    origin.hostname,
  );
  const isApprovedInClusterService =
    allowInClusterService &&
    origin.protocol === "http:" &&
    origin.hostname === "hypershell-api-server" &&
    origin.port === "8000";

  if (
    !["http:", "https:"].includes(origin.protocol) ||
    origin.username ||
    origin.password ||
    origin.pathname !== "/" ||
    origin.search ||
    origin.hash
  ) {
    throw new Error(
      "WEB_CONSOLE_API_ORIGIN must be an HTTP(S) origin without credentials",
    );
  }
  if (!isLoopback && !isApprovedInClusterService) {
    throw new Error(
      "WEB_CONSOLE_API_ORIGIN must use a loopback host or the explicitly enabled in-cluster API service",
    );
  }

  return origin.origin;
};
