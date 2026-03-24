// FILE: workspace-handler.test.js
// Purpose: Verifies workspace RPCs can browse Mac directories safely.
// Layer: Unit test
// Exports: node:test suite

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const { handleWorkspaceRequest } = require("../src/workspace-handler");

test("workspace/listDirectory defaults to most recently modified folders first", async () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "opendex-workspace-"));
  const olderChild = path.join(tempRoot, "Alpha");
  const newerHiddenChild = path.join(tempRoot, ".secret");
  const fileChild = path.join(tempRoot, "notes.txt");
  fs.mkdirSync(olderChild);
  fs.mkdirSync(newerHiddenChild);
  fs.writeFileSync(fileChild, "hello", "utf8");

  const olderDate = new Date("2024-01-01T00:00:00.000Z");
  const newerDate = new Date("2024-06-01T00:00:00.000Z");
  fs.utimesSync(olderChild, olderDate, olderDate);
  fs.utimesSync(newerHiddenChild, newerDate, newerDate);

  try {
    const response = await invokeWorkspaceRequest({
      id: "list-1",
      method: "workspace/listDirectory",
      params: { path: tempRoot },
    });

    assert.equal(response.id, "list-1");
    assert.equal(response.result.currentPath, tempRoot);
    assert.equal(response.result.parentPath, path.dirname(tempRoot));
    assert.equal(response.result.displayName, path.basename(tempRoot));
    assert.deepEqual(
      response.result.directories.map((entry) => entry.path),
      [newerHiddenChild, olderChild],
    );
    assert.deepEqual(
      response.result.directories.map((entry) => entry.isHidden),
      [true, false],
    );
    assert.equal(response.result.directories[0].modifiedAt, newerDate.toISOString());
    assert.equal(response.result.directories[1].modifiedAt, olderDate.toISOString());
  } finally {
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("workspace/listDirectory returns a workspace error for missing folders", async () => {
  const missingPath = path.join(os.tmpdir(), `opendex-missing-${Date.now()}`);
  const response = await invokeWorkspaceRequest({
    id: "list-missing",
    method: "workspace/listDirectory",
    params: { path: missingPath },
  });

  assert.equal(response.id, "list-missing");
  assert.equal(response.error.code, -32000);
  assert.equal(response.error.data.errorCode, "missing_working_directory");
});

function invokeWorkspaceRequest(message) {
  return new Promise((resolve, reject) => {
    const handled = handleWorkspaceRequest(JSON.stringify(message), (rawResponse) => {
      try {
        resolve(JSON.parse(rawResponse));
      } catch (error) {
        reject(error);
      }
    });

    if (!handled) {
      reject(new Error("Workspace request was not handled."));
    }
  });
}
