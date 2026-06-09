import { test, expect } from "@playwright/test";

test("home page renders title", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("#title")).toHaveText("ADZA e2e fixture");
});

test("health reports sha", async ({ request }) => {
  const res = await request.get("/health");
  expect(res.ok()).toBeTruthy();
  const body = await res.json();
  expect(body.sha).toBeTruthy();
});
