import { expect, test, type APIRequestContext, type Locator, type Page } from "@playwright/test";
import type { GraphEditorState, GraphNodeData } from "../src/types";
import { startGraphEditorServer, type GraphEditorServer } from "./graphEditorServer";

test.describe.serial("PlantSimEngine graph editor", () => {
  let server: GraphEditorServer;

  test.beforeAll(async () => {
    server = await startGraphEditorServer();
  });

  test.afterAll(async () => {
    await server?.stop();
  });

  test("starts a real Julia editor session", async ({ page, request }) => {
    await page.goto(server.url);

    await expect(page.getByText("Dependency Graph")).toBeVisible();

    const state = await getState(request, server.url);
    expect(state.ok).toBe(true);
    expect(state.graph.cyclic).toBe(false);
    expect(state.graph.nodes.some((node) => node.modelType.includes("ToyLAIModel"))).toBe(true);
    expect(state.graph.nodes.some((node) => node.modelType.includes("Beer"))).toBe(true);
  });

  test("updates, adds, maps, removes, creates a cycle, and breaks it", async ({ page, request }) => {
    await page.goto(server.url);

    const beer = await findNode(request, server.url, (node) => node.modelType.includes("Beer"));
    await openInspectorPanel(page);
    await page.getByTestId(`model-node-${beer.scale}-${beer.process}`).click();
    await expect(page.getByTestId("existing-model-editor")).toBeVisible();
    await page.getByTestId("edit-param-k").fill("0.8");
    await page.getByTestId("update-model-submit").click();
    await waitForState(request, server.url, (state) => {
      const updated = state.graph.nodes.find((node) => node.process === beer.process && node.scale === beer.scale);
      return updated?.modelParameters?.k?.value === "0.8";
    });

    await openAddModelPanel(page);
    await page.getByTestId("add-model-scale").selectOption("Default");
    await selectOptionContaining(page.getByTestId("add-model-type"), "ToyDegreeDaysCumulModel");
    await page.getByTestId("add-model-submit").click();
    const degreeDays = await waitForNode(request, server.url, (node) => node.modelType.includes("ToyDegreeDaysCumulModel"));

    await openInspectorPanel(page);
    await page.getByTestId(`model-node-${degreeDays.scale}-${degreeDays.process}`).click();
    await page.getByTestId("remove-model-submit").click();
    await waitForState(request, server.url, (state) =>
      !state.graph.nodes.some((node) => node.modelType.includes("ToyDegreeDaysCumulModel"))
    );

    await openAddModelPanel(page);
    await page.getByTestId("add-model-scale").selectOption("Default");
    await selectOptionContaining(page.getByTestId("add-model-type"), "ToyDegreeDaysCumulModel");
    await page.getByTestId("add-model-submit").click();
    const mappedDegreeDays = await waitForNode(request, server.url, (node) => node.modelType.includes("ToyDegreeDaysCumulModel"));

    const lai = await findNode(request, server.url, (node) => node.modelType.includes("ToyLAIModel"));
    await openInspectorPanel(page);
    await page.getByTestId(`port-input-${lai.scale}-${lai.process}-TT_cu`).click();
    await expect(page.getByTestId("mapping-source-output")).toBeVisible();
    await selectOptionContaining(page.getByTestId("mapping-source-output"), `${mappedDegreeDays.scale}.${mappedDegreeDays.process}.TT_cu`);
    await page.getByTestId("mapping-apply").click();
    await waitForState(request, server.url, (state) => state.ok && !state.graph.cyclic);

    await openAddModelPanel(page);
    await page.getByTestId("add-model-scale").selectOption("Default");
    await selectOptionContaining(page.getByTestId("add-model-type"), "ReebE2E");
    await page.getByTestId("add-param-k").fill("0.6");
    await page.getByTestId("add-model-submit").click();

    await waitForState(request, server.url, (state) => state.graph.cyclic === true);
    await expect(page.getByTestId("cycle-break-prompt")).toBeVisible();
    await expect(page.locator(".react-flow__edge.cycle_edge")).toHaveCount(2);

    await page.getByTestId("cycle-break-choose").click();
    await expect(page.locator(".port-cycle-break-button")).not.toHaveCount(0);
    await page.locator(".port-cycle-break-button").first().click();

    await waitForState(request, server.url, (state) =>
      state.graph.cyclic === false && state.mappingCode.includes("PreviousTimeStep(:")
    );
    await expect(page.getByTestId("cycle-break-prompt")).toHaveCount(0);

    await page.getByTestId("toolbar-mapping-code").click();
    await expect(page.getByTestId("mapping-code")).toHaveValue(/PreviousTimeStep\(:/);
  });
});

async function openInspectorPanel(page: Page) {
  await page.getByTestId("toolbar-add-model").click();
  await page.getByTestId("toolbar-inspector").click();
}

async function openAddModelPanel(page: Page) {
  await page.getByTestId("toolbar-add-model").click();
  await expect(page.getByTestId("add-model-panel")).toBeVisible();
}

async function getState(request: APIRequestContext, baseURL: string): Promise<GraphEditorState> {
  const response = await request.get(stateURL(baseURL));
  if (!response.ok()) {
    throw new Error(`Expected /state to return 2xx, got ${response.status()}:\n${await response.text()}`);
  }
  return await response.json() as GraphEditorState;
}

function stateURL(baseURL: string): string {
  const url = new URL(baseURL);
  const token = url.searchParams.get("token");
  url.pathname = "/state";
  url.search = "";
  if (token) url.searchParams.set("token", token);
  return url.toString();
}

async function waitForState(
  request: APIRequestContext,
  baseURL: string,
  predicate: (state: GraphEditorState) => boolean,
  timeoutMs = 15_000,
): Promise<GraphEditorState> {
  const deadline = Date.now() + timeoutMs;
  let latest = await getState(request, baseURL);
  while (Date.now() < deadline) {
    if (predicate(latest)) return latest;
    await new Promise((resolve) => setTimeout(resolve, 250));
    latest = await getState(request, baseURL);
  }
  throw new Error(`Timed out waiting for editor state. Latest state:\n${JSON.stringify(latest, null, 2)}`);
}

async function findNode(
  request: APIRequestContext,
  baseURL: string,
  predicate: (node: GraphNodeData) => boolean,
): Promise<GraphNodeData> {
  const state = await getState(request, baseURL);
  const node = state.graph.nodes.find(predicate);
  expect(node, `Expected graph node in ${state.graph.nodes.map((item) => item.modelType).join(", ")}`).toBeTruthy();
  return node!;
}

async function waitForNode(
  request: APIRequestContext,
  baseURL: string,
  predicate: (node: GraphNodeData) => boolean,
): Promise<GraphNodeData> {
  const state = await waitForState(request, baseURL, (candidate) => candidate.graph.nodes.some(predicate));
  return state.graph.nodes.find(predicate)!;
}

async function selectOptionContaining(select: Locator, text: string) {
  const value = await select.evaluate((element, needle) => {
    const selectElement = element as HTMLSelectElement;
    const option = [...selectElement.options].find((item) => item.textContent?.includes(needle));
    return option?.value ?? null;
  }, text);
  expect(value, `Expected select option containing ${text}`).toBeTruthy();
  await select.selectOption(value!);
}
