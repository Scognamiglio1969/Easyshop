import assert from "node:assert/strict";
import test from "node:test";

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request("http://localhost/", { headers: { accept: "text/html" } }),
    { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } },
    { waitUntil() {}, passThroughOnException() {} },
  );
}

test("renders the complete Easyshop release page", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /Easyshop — Create at the speed of seeing/i);
  assert.match(html, /Download Easyshop/i);
  assert.match(html, /Massimo Scognamiglio/i);
  assert.match(html, /Honest on-device ML/i);
  assert.match(html, /Easyshop-0\.1\.0-alpha\.dmg/i);
  assert.doesNotMatch(html, /Make the subject warmer|Italian shortcuts|Local assistance/i);
});
