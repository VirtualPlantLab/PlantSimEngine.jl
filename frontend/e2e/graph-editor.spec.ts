import { expect, test, type APIRequestContext, type Locator, type Page } from "@playwright/test";
import type { ApplicationGraphNode, EditorState } from "../src/types";
import { startGraphEditorServer, type GraphEditorServer } from "./graphEditorServer";

test.describe.serial("PlantSimEngine model graph editor", () => {
  let server: GraphEditorServer;

  test.beforeAll(async () => {
    server = await startGraphEditorServer();
  });

  test.afterAll(async () => {
    await server?.stop();
  });

  test("starts empty and adds an object", async ({ page, request }) => {
    await page.goto(server.url);
    await expect(page.getByText("Model Graph")).toBeVisible();

    let state = await getState(request, server.url);
    expect(state.ok).toBe(true);
    expect(state.graph.metadata.objectCount).toBe(0);
    expect(state.graph.metadata.applicationCount).toBe(0);

    await page.getByTestId("add-object").click();
    await page.getByTestId("object-id").fill("leaf");
    await page.locator(".object-form label", { hasText: "Scale" }).getByRole("textbox").fill("Leaf");
    await page.locator(".object-form label", { hasText: "Kind" }).getByRole("textbox").fill("organ");
    await page.locator(".object-form label", { hasText: "Name" }).getByRole("textbox").fill("leaf");
    await page.getByTestId("object-submit").click();

    state = await waitForState(request, server.url, (value) => value.graph.metadata.objectCount === 1);
    expect(state.graph.objects[0].scale).toBe("Leaf");
  });

  test("adds and updates an application", async ({ page, request }) => {
    await page.goto(server.url);
    await openAddApplication(page, "Beer");
    await page.getByTestId("application-name").fill("light");
    await page.getByTestId("application-param-k").fill("0.5");
    await page.getByTestId("application-target-preview").click();
    await expect(page.getByTestId("application-target-preview-result")).toContainText("1 target object");
    await page.getByTestId("application-submit").click();

    let state = await waitForState(request, server.url, (value) => value.graph.metadata.applicationCount === 1);
    let light = findApplication(state, "light");
    expect(light.modelName).toContain("Beer");

    await page.getByTestId("application-node-light").click();
    await page.getByRole("button", { name: "Edit application" }).click();
    await page.getByTestId("application-param-k").fill("0.8");
    await page.getByTestId("application-cadence-mode").selectOption("period");
    await page.getByTestId("application-cadence-value").fill("2");
    await page.getByTestId("application-cadence-unit").selectOption("Hour");
    await page.getByTestId("application-submit").click();

    state = await waitForState(request, server.url, (value) => findApplication(value, "light").modelParameters.k?.value === 0.8);
    light = findApplication(state, "light");
    expect(light.targetIds).toEqual(["leaf"]);
    expect(light.cadence).toMatchObject({ mode: "period", value: 2, unit: "Hour" });
  });

  test("static viewer opens the inspector without an editor connection", async ({ page }) => {
    const url = new URL(server.url);
    url.pathname = "/static";
    await page.goto(url.toString());
    await expect(page.getByTestId("application-node-light")).toBeVisible();
    await page.getByTestId("application-node-light").click();
    await expect(page.locator(".model-inspector")).toContainText("light");
    await expect(page.getByText("Edit application")).toHaveCount(0);
  });

  test("creates and breaks a cycle directly in the graph", async ({ page, request }) => {
    await page.goto(server.url);
    await page.getByTestId("port-input-LAI").getByRole("button").click();
    await page.locator(".candidate-card", { hasText: "ReebE2E" }).click();
    await expect(page.getByTestId("application-form")).toBeVisible();
    await page.getByTestId("application-name").fill("reeb");
    await page.getByTestId("application-submit").click();

    let state = await waitForState(request, server.url, (value) => value.graph.metadata.cyclic === true);
    expect(state.graph.edges.filter((edge) => edge.cycle && edge.projection === "applications")).toHaveLength(2);
    await expect(page.getByTestId("cycle-callout")).toBeVisible();

    await page.getByTestId("choose-cycle-break").click();
    const scissors = page.locator("[data-testid^='cycle-break-']").first();
    await expect(scissors).toBeVisible();
    await scissors.click();
    await expect(page.getByTestId("cycle-break-dialog")).toBeVisible();
    const initialization = page.getByTestId("cycle-break-dialog").getByRole("textbox");
    if (await initialization.count()) await initialization.fill("0.0");
    await page.getByTestId("confirm-cycle-break").click();

    state = await waitForState(request, server.url, (value) => value.graph.metadata.cyclic === false);
    expect(state.graph.edges.some((edge) => edge.kind === "previous_timestep")).toBe(true);
    expect(state.modelCode).toContain("PreviousTimeStep");
  });

  test("connects another consumer and supports undo, redo, remove, and save", async ({ page, request }, testInfo) => {
    await page.goto(server.url);
    await page.getByTestId("configure-environment").click();
    await page.getByTestId("scene-environment").selectOption("environment:weather");
    await page.getByTestId("environment-submit").click();
    await waitForState(request, server.url, (value) => value.graph.metadata.sceneEnvironmentId === "environment:weather");
    await openAddApplication(page, "E2EConsumer");
    await page.getByTestId("application-name").fill("consumer");
    await page.getByTestId("application-submit").click();
    await waitForState(request, server.url, (value) => value.graph.applications.some((application) => application.applicationId === "consumer"));

    await page.getByTestId("application-node-light").click();
    await page.getByTestId("configure-application").click();
    await page.getByTestId("call-name").fill("consumer_call");
    await page.getByTestId("call-target").selectOption("consumer");
    await page.getByTestId("add-call-binding").click();
    await waitForState(request, server.url, (value) => value.graph.metadata.callCount === 1);
    await page.getByTestId("environment-provider").fill("model");
    await page.getByTestId("environment-backend").selectOption("scene");
    await page.getByTestId("apply-environment").click();
    let state = await waitForState(request, server.url, (value) => findApplication(value, "light").environment?.provider === "model");
    expect(state.graph.edges.some((edge) => edge.kind === "manual_call" && edge.call === "consumer_call")).toBe(true);
    await page.getByRole("button", { name: "Done" }).click();

    await page.getByTestId("port-output-aPPFD").first().getByRole("button").click();
    await page.locator(".candidate-card.existing", { hasText: "consumer" }).click();
    await expect(page.getByTestId("binding-form")).toBeVisible();
    await page.getByTestId("binding-preview-button").click();
    await expect(page.getByTestId("binding-preview")).toContainText("resolved binding");
    await page.getByTestId("binding-submit").click();
    state = await waitForState(request, server.url, (value) => value.graph.edges.some((edge) => edge.targetApplicationId === "consumer" && edge.targetVariable === "aPPFD"));
    expect(state.graph.metadata.applicationCount).toBe(3);

    await page.getByTestId("application-node-light").click();
    await page.getByTestId("configure-application").click();
    await page.getByTitle("Remove consumer_call call").click();
    await waitForState(request, server.url, (value) => value.graph.metadata.callCount === 0);
    await page.getByRole("button", { name: "Done" }).click();

    await page.getByTestId("application-node-consumer").click();
    await page.getByRole("button", { name: "Remove application" }).click();
    await waitForState(request, server.url, (value) => !value.graph.applications.some((application) => application.applicationId === "consumer"));
    await page.getByRole("button", { name: "Undo" }).click();
    await waitForState(request, server.url, (value) => value.graph.applications.some((application) => application.applicationId === "consumer"));
    await page.getByRole("button", { name: "Redo" }).click();
    await waitForState(request, server.url, (value) => !value.graph.applications.some((application) => application.applicationId === "consumer"));

    const savePath = testInfo.outputPath("model.jl");
    await page.getByTestId("save-model").click();
    await page.getByPlaceholder("/absolute/path/to/model.jl").fill(savePath);
    await page.locator(".model-file-dialog").getByRole("button", { name: "Save", exact: true }).click();
    state = await waitForState(request, server.url, (value) => value.savePath === savePath);
    expect(state.recentPaths).toContain(savePath);
  });

  test("mounts one template twice, configures an override and environment, then reopens with undo and redo", async ({ page, request }, testInfo) => {
    await page.goto(server.url);
    await addObject(page, "plant_a", "Plant", "plant", "plant_a");
    await addObject(page, "plant_b", "Plant", "plant", "plant_b");
    await waitForState(request, server.url, (value) => value.graph.objects.some((object) => object.objectId === "plant_b"));

    for (const plant of ["plant_a", "plant_b"]) {
      await page.getByTestId("add-instance").click();
      await page.getByTestId("instance-template").selectOption("catalog:plant");
      await page.getByTestId("instance-name").fill(plant);
      await page.getByTestId("instance-root").selectOption(plant);
      await page.getByTestId("instance-preview-button").click();
      await expect(page.getByTestId("instance-preview")).toContainText("1 claimed object");
      await page.getByTestId("instance-submit").click();
      await waitForState(request, server.url, (value) => value.graph.instances.some((instance) => instance.name === plant));
    }

    let state = await getState(request, server.url);
    expect(findApplication(state, "plant_a__template_source").targetIds).toEqual(["plant_a"]);
    expect(findApplication(state, "plant_b__template_source").targetIds).toEqual(["plant_b"]);

    await page.getByTestId("application-node-plant_b__template_source").click();
    await page.getByRole("button", { name: "Create override" }).click();
    await page.getByTestId("application-param-coefficient").fill("2.0");
    await page.getByRole("button", { name: "Apply override" }).click();
    state = await waitForState(request, server.url, (value) => findApplication(value, "plant_b__template_source").modelParameters.coefficient?.value === 2);
    expect(findApplication(state, "plant_a__template_source").modelParameters.coefficient?.value).toBe(1);

    await page.getByTestId("configure-environment").click();
    await page.getByTestId("scene-environment").selectOption("environment:weather");
    await page.getByTestId("environment-submit").click();
    await waitForState(request, server.url, (value) => value.graph.metadata.sceneEnvironmentId === "environment:weather");

    await page.getByTestId("application-node-plant_a__template_source").click();
    await page.getByTestId("configure-application").click();
    await page.getByTestId("environment-backend").selectOption("environment:canopy");
    await page.getByTestId("environment-provider").fill("canopy_cells");
    await page.getByTestId("environment-source-T").fill("air_temperature");
    await page.getByTestId("environment-sink").fill("canopy_state");
    await page.getByTestId("apply-environment").click();
    state = await waitForState(request, server.url, (value) => findApplication(value, "plant_a__template_source").environment?.sources.T === "air_temperature");
    expect(findApplication(state, "plant_b__template_source").environment?.backendId).toBe("environment:canopy");
    await page.getByRole("button", { name: "Done" }).click();

    const savePath = testInfo.outputPath("multi-plant-model.jl");
    await page.getByTestId("save-model").click();
    await page.getByPlaceholder("/absolute/path/to/model.jl").fill(savePath);
    await page.locator(".model-file-dialog").getByRole("button", { name: "Save", exact: true }).click();
    await waitForState(request, server.url, (value) => value.savePath === savePath);

    await page.getByRole("button", { name: "Objects" }).click();
    await page.locator(".entity-node.instance", { hasText: "plant_b" }).click();
    await page.getByRole("button", { name: "Unmount instance" }).click();
    await waitForState(request, server.url, (value) => value.graph.instances.length === 1);

    await page.getByTestId("open-model").click();
    await page.getByPlaceholder("/absolute/path/to/model.jl").fill(savePath);
    await page.locator(".model-file-dialog").getByRole("button", { name: "Open", exact: true }).click();
    await waitForState(request, server.url, (value) => value.graph.instances.length === 2);
    await page.getByRole("button", { name: "Undo" }).click();
    await waitForState(request, server.url, (value) => value.graph.instances.length === 1);
    await page.getByRole("button", { name: "Redo" }).click();
    await waitForState(request, server.url, (value) => value.graph.instances.length === 2);
  });
});

async function openAddApplication(page: Page, modelName: string) {
  await page.getByTestId("add-application").click();
  await selectOptionContaining(page.getByTestId("application-model-select"), modelName);
}

async function addObject(page: Page, id: string, scale: string, kind: string, name: string) {
  await page.getByTestId("add-object").click();
  await page.getByTestId("object-id").fill(id);
  await page.locator(".object-form label", { hasText: "Scale" }).getByRole("textbox").fill(scale);
  await page.locator(".object-form label", { hasText: "Kind" }).getByRole("textbox").fill(kind);
  await page.locator(".object-form label", { hasText: "Name" }).getByRole("textbox").fill(name);
  await page.getByTestId("object-submit").click();
}

async function getState(request: APIRequestContext, baseURL: string): Promise<EditorState> {
  const response = await request.get(stateURL(baseURL));
  expect(response.ok()).toBe(true);
  return await response.json() as EditorState;
}

function stateURL(baseURL: string): string {
  const url = new URL(baseURL);
  const token = url.searchParams.get("token");
  url.pathname = "/state";
  url.search = "";
  if (token) url.searchParams.set("token", token);
  return url.toString();
}

async function waitForState(request: APIRequestContext, baseURL: string, predicate: (state: EditorState) => boolean, timeoutMs = 20_000): Promise<EditorState> {
  const deadline = Date.now() + timeoutMs;
  let latest = await getState(request, baseURL);
  while (Date.now() < deadline) {
    if (predicate(latest)) return latest;
    await new Promise((resolve) => setTimeout(resolve, 200));
    latest = await getState(request, baseURL);
  }
  throw new Error(`Timed out waiting for editor state:\n${JSON.stringify(latest, null, 2)}`);
}

function findApplication(state: EditorState, id: string): ApplicationGraphNode {
  const application = state.graph.applications.find((item) => item.applicationId === id);
  expect(application, `Expected application ${id}`).toBeTruthy();
  return application!;
}

async function selectOptionContaining(select: Locator, text: string) {
  const value = await select.evaluate((element, needle) => {
    const selectElement = element as HTMLSelectElement;
    return [...selectElement.options].find((option) => option.textContent?.includes(needle))?.value ?? null;
  }, text);
  expect(value, `Expected option containing ${text}`).toBeTruthy();
  await select.selectOption(value!);
}
