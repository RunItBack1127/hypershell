import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { IntlProvider } from "react-intl";
import { vi } from "vitest";

import { GatewayUiProvider } from "../gateway-ui-provider";
import { GatewayCreatePage } from "./gateway-create";

const { createGatewayMock, listGatewayReleasesMock, navigateMock } = vi.hoisted(
  () => ({
    createGatewayMock: vi.fn(),
    listGatewayReleasesMock: vi.fn(),
    navigateMock: vi.fn(),
  }),
);

const releaseOptions = [
  {
    id: "release-1",
    image: "ghcr.io/nvidia/openshell/gateway:0.0.92@sha256:1234",
    name: "OpenShell 0.0.92",
  },
  {
    id: "release-2",
    image: "ghcr.io/nvidia/openshell/gateway:0.0.91@sha256:5678",
    name: "OpenShell 0.0.91",
  },
];

const gatewayOperations = {
  getGateway: vi.fn(),
  listGateways: vi.fn(),
  listGatewayReleases: listGatewayReleasesMock,
  provisionGateway: createGatewayMock,
  removeGateway: vi.fn(),
  renameGateway: vi.fn(),
};

const navigation = {
  collectionHref: "/",
  createHref: "/gateways/new",
  detailHref: (gatewayId: string) => `/gateways/${gatewayId}`,
  navigate: navigateMock,
};

const createdGateway = {
  clusterId: "",
  databaseId: "",
  externalDns: "",
  id: "gateway-1",
  name: "team-gateway",
  namespace: "openshell",
  phase: "",
  releaseId: "release-1",
  status: "",
};

function renderPage() {
  const queryClient = new QueryClient({
    defaultOptions: { mutations: { retry: false }, queries: { retry: false } },
  });

  return render(
    <IntlProvider locale="en">
      <QueryClientProvider client={queryClient}>
        <GatewayUiProvider gateways={gatewayOperations} navigation={navigation}>
          <GatewayCreatePage />
        </GatewayUiProvider>
      </QueryClientProvider>
    </IntlProvider>,
  );
}

describe("GatewayCreatePage", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    listGatewayReleasesMock.mockReset();
    listGatewayReleasesMock.mockResolvedValue(releaseOptions);
    navigateMock.mockResolvedValue(undefined);
  });

  it("searches releases by human-facing content and provisions with the selected ID", async () => {
    const user = userEvent.setup();
    createGatewayMock.mockResolvedValue(createdGateway);
    renderPage();

    expect(screen.queryByLabelText("Cluster")).toBeNull();
    const releaseSelect = await screen.findByRole("combobox", {
      name: "Gateway release",
    });
    expect(screen.queryByLabelText("Managed database")).toBeNull();

    await user.type(releaseSelect, "0.0.92");
    expect(await screen.findByText("OpenShell 0.0.92")).toBeTruthy();
    expect(
      screen.getByText("ghcr.io/nvidia/openshell/gateway:0.0.92@sha256:1234"),
    ).toBeTruthy();
    expect(screen.queryByText("OpenShell 0.0.91")).toBeNull();
    await user.click(screen.getByText("OpenShell 0.0.92"));

    await user.type(
      screen.getByRole("textbox", { name: "Gateway name" }),
      "team-gateway",
    );
    await user.click(screen.getByRole("button", { name: "Provision gateway" }));

    await waitFor(() => {
      expect(createGatewayMock).toHaveBeenCalledWith({
        name: "team-gateway",
        namespace: "openshell",
        releaseId: "release-1",
      });
    });
    await waitFor(() => {
      expect(navigateMock).toHaveBeenCalledWith("/gateways/gateway-1");
    });
  });

  it("validates required values before sending a request", async () => {
    const user = userEvent.setup();
    renderPage();

    await screen.findByRole("combobox", { name: "Gateway release" });

    await user.click(screen.getByRole("button", { name: "Provision gateway" }));

    expect(await screen.findAllByText("This field is required.")).toHaveLength(
      2,
    );
    expect(createGatewayMock).not.toHaveBeenCalled();
  });

  it("shows progress only while the create request is pending", async () => {
    const user = userEvent.setup();
    let resolveRequest: ((gateway: typeof createdGateway) => void) | undefined;
    createGatewayMock.mockImplementation(
      () =>
        new Promise((resolve) => {
          resolveRequest = resolve;
        }),
    );
    renderPage();

    const releaseSelect = await screen.findByRole("combobox", {
      name: "Gateway release",
    });
    await user.click(releaseSelect);
    await user.click(screen.getByText("OpenShell 0.0.92"));

    await user.type(
      screen.getByRole("textbox", { name: "Gateway name" }),
      "team-gateway",
    );
    const submitButton = screen.getByRole("button", {
      name: "Provision gateway",
    });
    expect(submitButton.classList.contains("pf-m-progress")).toBe(false);

    await user.click(submitButton);

    await waitFor(() => {
      expect(submitButton.classList.contains("pf-m-progress")).toBe(true);
    });
    resolveRequest?.(createdGateway);
    await waitFor(() => {
      expect(navigateMock).toHaveBeenCalledWith("/gateways/gateway-1");
    });
  });

  it("supports keyboard selection and reports an unmatched search", async () => {
    const user = userEvent.setup();
    renderPage();

    const releaseSelect = await screen.findByRole("combobox", {
      name: "Gateway release",
    });
    await user.type(releaseSelect, "not-a-release");
    expect(screen.getByText("No matching gateway releases")).toBeTruthy();
    await user.keyboard("{ArrowDown}");

    await user.clear(releaseSelect);
    await user.keyboard("{ArrowUp}{Enter}");
    expect((releaseSelect as HTMLInputElement).value).toBe("OpenShell 0.0.91");
  });

  it("blocks provisioning when no releases are available", async () => {
    listGatewayReleasesMock.mockResolvedValueOnce([]);
    renderPage();

    expect(
      await screen.findByText("No gateway releases are available"),
    ).toBeTruthy();
    expect(
      screen
        .getByRole("button", { name: "Provision gateway" })
        .hasAttribute("disabled"),
    ).toBe(true);
  });

  it("allows release loading to be retried", async () => {
    const user = userEvent.setup();
    listGatewayReleasesMock
      .mockRejectedValueOnce(new Error("unavailable"))
      .mockResolvedValueOnce(releaseOptions);
    renderPage();

    expect(
      await screen.findByText("Gateway releases could not be loaded"),
    ).toBeTruthy();
    await user.click(screen.getByRole("button", { name: "Try again" }));
    expect(
      (
        await screen.findByRole("combobox", { name: "Gateway release" })
      ).hasAttribute("disabled"),
    ).toBe(false);
    expect(listGatewayReleasesMock).toHaveBeenCalledTimes(2);
  });
});
