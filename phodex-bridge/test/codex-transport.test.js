// FILE: codex-transport.test.js
// Purpose: Verifies endpoint-backed Codex transport only sends after the websocket is open.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/codex-transport

const test = require("node:test");
const assert = require("node:assert/strict");

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
        });
      }

      if (
        parsedUrl.pathname === "/session/ses_test_1" &&
        (options.method || "GET") === "GET"
      ) {
        return createJsonResponse({
          id: "ses_test_1",
          title: "Opendex Thread",
          status: "ready",
        });
      }

      if (
        parsedUrl.pathname === "/session/ses_test_1/message" &&
        (options.method || "GET") === "POST"
      ) {
        return createJsonResponse({
          info: {
            id: "msg_assistant_1",
            tokens: {
              total: 42,
              input: 21,
              output: 21,
            },
          },
          parts: [{ type: "text", text: "Hello from OpenCode" }],
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
      params: { title: "Opendex Thread" },
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
  await flushAsync();

  assert.equal(calls[0].pathname, "/session");
  assert.equal(calls[1].pathname, "/session/ses_test_1");
  assert.equal(calls[2].pathname, "/session/ses_test_1/message");
  assert.equal(calls[2].body.parts[0].text, "Say hello");
  assert.equal(messages[0].id, "thread-start-1");
  assert.equal(messages[1].method, "thread/started");
  assert.equal(messages[2].id, "turn-start-1");
  assert.equal(messages[3].method, "turn/started");
  assert.equal(messages[4].method, "item/agentMessage/delta");
  assert.equal(messages[4].params.textDelta, "Hello from OpenCode");
  assert.equal(messages[5].method, "turn/completed");
  assert.equal(messages[6].method, "thread/tokenUsage/updated");
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
