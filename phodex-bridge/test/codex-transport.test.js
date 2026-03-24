// FILE: codex-transport.test.js
// Purpose: Verifies endpoint-backed Codex transport only sends after the websocket is open.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/codex-transport

const test = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");

const { createCodexTransport } = require("../src/codex-transport");

class FakeWebSocket {
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSED = 3;
  static latestInstance = null;

  constructor(endpoint) {
    this.endpoint = endpoint;
    this.readyState = FakeWebSocket.CONNECTING;
    this.handlers = {};
    this.sentMessages = [];
    FakeWebSocket.latestInstance = this;
  }

  on(eventName, handler) {
    this.handlers[eventName] = handler;
  }

  send(message) {
    this.sentMessages.push(message);
  }

  close() {
    this.readyState = FakeWebSocket.CLOSED;
  }

  emit(eventName, ...args) {
    this.handlers[eventName]?.(...args);
  }
}

test("endpoint transport only sends outbound messages after the websocket opens", () => {
  const transport = createCodexTransport({
    endpoint: "ws://127.0.0.1:4321/codex",
    WebSocketImpl: FakeWebSocket,
  });

  const socket = FakeWebSocket.latestInstance;
  assert.ok(socket);
  assert.equal(socket.endpoint, "ws://127.0.0.1:4321/codex");

  transport.send('{"id":"init-1","method":"initialize"}');
  transport.send('{"id":"list-1","method":"thread/list"}');
  assert.deepEqual(socket.sentMessages, []);

  socket.readyState = FakeWebSocket.OPEN;
  socket.emit("open");

  assert.deepEqual(socket.sentMessages, []);

  transport.send('{"id":"list-2","method":"thread/list"}');
  assert.deepEqual(socket.sentMessages, [
    '{"id":"list-2","method":"thread/list"}',
  ]);
});

test("OpenCode HTTP transport creates a thread and completes a turn", async () => {
  const calls = [];
  let messageReads = 0;
  const selectedDirectory = "/tmp/opendex-selected";
  const transport = createCodexTransport({
    endpoint: "http://127.0.0.1:4096",
    env: {
      PWD: "/tmp/opendex-test",
    },
    fetchImpl: async (url, options = {}) => {
      const parsedUrl = new URL(String(url));
      calls.push({
        pathname: parsedUrl.pathname,
        search: parsedUrl.search,
        searchParams: parsedUrl.searchParams,
        method: options.method || "GET",
        body: options.body ? JSON.parse(options.body) : null,
      });

      if (
        parsedUrl.pathname === "/session" &&
        (options.method || "GET") === "POST"
      ) {
        return createJsonResponse({
          id: "ses_test_1",
          title: "Opendex Thread",
          status: "ready",
          directory: selectedDirectory,
        });
      }

      if (
        parsedUrl.pathname === "/session/ses_test_1/message" &&
        (options.method || "GET") === "GET"
      ) {
        messageReads += 1;
        if (messageReads === 1) {
          return createJsonResponse([]);
        }

        return createJsonResponse([
          {
            info: {
              id: "msg_assistant_1",
              role: "assistant",
              tokens: {
                total: 42,
                input: 21,
                output: 21,
              },
            },
            parts: [{ type: "text", text: "Hello from OpenCode" }],
          },
        ]);
      }

      if (
        parsedUrl.pathname === "/session/ses_test_1/message" &&
        (options.method || "GET") === "POST"
      ) {
        return createJsonResponse({
          info: {
            id: "msg_user_1",
            role: "user",
          },
          parts: [{ type: "text", text: "Say hello" }],
        });
      }

      throw new Error(
        `Unexpected request: ${options.method || "GET"} ${parsedUrl.pathname}`,
      );
    },
  });

  const messages = [];
  transport.onMessage((message) => messages.push(JSON.parse(message)));

  transport.send(
      JSON.stringify({
        id: "thread-start-1",
        method: "thread/start",
        params: {
          title: "Opendex Thread",
          cwd: selectedDirectory,
        },
      }),
    );
    await flushAsync();

  transport.send(
    JSON.stringify({
      id: "turn-start-1",
      method: "turn/start",
      params: {
        threadId: "ses_test_1",
        prompt: "Say hello",
      },
    }),
  );
  await waitForCondition(() =>
    messages.some(
      (message) =>
        message.method === "item/agentMessage/delta" &&
        message.params?.textDelta === "Hello from OpenCode",
    ),
  );

  assert.equal(calls[0].pathname, "/session");
  assert.equal(calls[0].searchParams.get("directory"), selectedDirectory);
  assert.equal(calls[1].pathname, "/session/ses_test_1/message");
  assert.equal(calls[1].method, "GET");
  assert.equal(calls[1].searchParams.get("directory"), selectedDirectory);
  assert.equal(calls[2].pathname, "/session/ses_test_1/message");
  assert.equal(calls[2].method, "POST");
  assert.equal(calls[2].searchParams.get("directory"), selectedDirectory);
  assert.equal(calls[2].body.parts[0].text, "Say hello");
  assert.equal(messages[0].id, "thread-start-1");
  assert.equal(messages[1].method, "thread/started");
  assert.equal(messages[2].id, "turn-start-1");
  assert.equal(messages[3].method, "turn/started");
  const agentDelta = messages.find(
    (message) =>
      message.method === "item/agentMessage/delta" &&
      message.params?.textDelta === "Hello from OpenCode",
  );
  assert.ok(agentDelta);
  assert.ok(messages.some((message) => message.method === "turn/completed"));
  assert.ok(
    messages.some((message) => message.method === "thread/tokenUsage/updated"),
  );
});

test("OpenCode HTTP transport returns runtime models from global config", async () => {
  const transport = createCodexTransport({
    endpoint: "http://127.0.0.1:4096",
    env: {
      PWD: "/tmp/opendex-test",
    },
    fetchImpl: async (url, options = {}) => {
      const parsedUrl = new URL(String(url));
      if (
        parsedUrl.pathname === "/global/config" &&
        (options.method || "GET") === "GET"
      ) {
        return createJsonResponse({
          providers: {
            openai: {
              models: [
                {
                  id: "gpt-5",
                  model: "gpt-5",
                  displayName: "GPT-5",
                  description: "General purpose model",
                  isDefault: true,
                  supportedReasoningEfforts: ["low", "medium", "high"],
                  defaultReasoningEffort: "medium",
                },
              ],
            },
          },
        });
      }

      throw new Error(
        `Unexpected request: ${options.method || "GET"} ${parsedUrl.pathname}`,
      );
    },
  });

  const messages = [];
  transport.onMessage((message) => messages.push(JSON.parse(message)));

  transport.send(
    JSON.stringify({
      id: "model-list-1",
      method: "model/list",
      params: { limit: 50, includeHidden: false },
    }),
  );
  await flushAsync();

  assert.equal(messages[0].id, "model-list-1");
  assert.equal(messages[0].result.items[0].id, "gpt-5.4");
  assert.equal(messages[0].result.items[0].displayName, "GPT-5.4");
  assert.equal(messages[0].result.items[0].isDefault, true);
});

test("transport falls back to spawned codex app-server when no HTTP endpoint is configured", () => {
  const spawnCalls = [];
  const fakeSpawn = (command, args, options) => {
    spawnCalls.push({ command, args, options });

    const child = new EventEmitter();
    child.stdin = {
      writable: true,
      destroyed: false,
      writableEnded: false,
      write() {},
      on() {},
    };
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    child.killed = false;
    child.exitCode = null;
    child.kill = () => {
      child.killed = true;
    };
    return child;
  };

  const transport = createCodexTransport({
    env: {
      PWD: "/tmp/opendex-test",
    },
    fetchImpl: async () => {
      throw new Error("fetch should not be used without an explicit OpenCode endpoint");
    },
    spawnImpl: fakeSpawn,
  });

  assert.equal(transport.mode, "spawn");
  assert.equal(transport.describe(), "`codex app-server`");
  assert.deepEqual(spawnCalls, [
    {
      command: "codex",
      args: ["app-server"],
      options: {
        stdio: ["pipe", "pipe", "pipe"],
        env: {
          PWD: "/tmp/opendex-test",
        },
      },
    },
  ]);
});

function createJsonResponse(payload) {
  return {
    ok: true,
    status: 200,
    text: async () => JSON.stringify(payload),
  };
}

function flushAsync() {
  return new Promise((resolve) => setImmediate(resolve));
}

async function waitForCondition(predicate, timeoutMs = 2_000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (predicate()) {
      return;
    }
    await flushAsync();
  }
  throw new Error("Timed out waiting for condition");
}
