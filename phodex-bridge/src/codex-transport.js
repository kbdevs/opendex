// FILE: codex-transport.js
// Purpose: Abstracts the runtime transport so the bridge can talk to either OpenCode's HTTP API or a legacy WebSocket/stdin endpoint.
// Layer: CLI helper
// Exports: createCodexTransport
// Depends on: child_process, fs, path, ws

const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const WebSocket = require("ws");

const DEFAULT_OPENCODE_ENDPOINT = "http://127.0.0.1:4096";
const DEFAULT_OPENCODE_AGENT = "build";
const DEFAULT_REQUEST_TIMEOUT_MS = 10 * 60_000;

function createCodexTransport({
  endpoint = "",
  env = process.env,
  WebSocketImpl = WebSocket,
  fetchImpl = globalThis.fetch,
  spawnImpl = spawn,
} = {}) {
  const normalizedEndpoint =
    normalizeEndpoint(endpoint) || readOpenCodeEndpoint(env);
  if (isWebSocketEndpoint(normalizedEndpoint)) {
    return createWebSocketTransport({
      endpoint: normalizedEndpoint,
      WebSocketImpl,
    });
  }

  if (shouldUseOpenCodeTransport(normalizedEndpoint, env, fetchImpl)) {
    return createOpenCodeTransport({
      endpoint: normalizedEndpoint || DEFAULT_OPENCODE_ENDPOINT,
      env,
      fetchImpl,
    });
  }

  return createSpawnTransport({ env, spawnImpl });
}

function createOpenCodeTransport({ endpoint, env, fetchImpl }) {
  if (typeof fetchImpl !== "function") {
    throw new Error("OpenCode transport requires a fetch implementation.");
  }

  const listeners = createListenerBag();
  const sessionByThreadId = new Map();
  let isShutdown = false;

  return {
    mode: "opencode",
    describe() {
      return endpoint;
    },
    send(message) {
      void handleOpenCodeMessage({
        rawMessage: message,
        endpoint,
        env,
        fetchImpl,
        listeners,
        sessionByThreadId,
        isShutdown: () => isShutdown,
      });
    },
    onMessage(handler) {
      listeners.onMessage = handler;
    },
    onClose(handler) {
      listeners.onClose = handler;
    },
    onError(handler) {
      listeners.onError = handler;
    },
    shutdown() {
      if (isShutdown) {
        return;
      }

      isShutdown = true;
      listeners.emitClose(1000, "shutdown");
    },
  };
}

async function handleOpenCodeMessage({
  rawMessage,
  endpoint,
  env,
  fetchImpl,
  listeners,
  sessionByThreadId,
  isShutdown,
}) {
  const message = safeParseJSON(rawMessage);
  if (!message || typeof message !== "object") {
    return;
  }

  const requestId = message.id;
  const method =
    typeof message.method === "string" ? message.method.trim() : "";
  const params =
    message.params && typeof message.params === "object" ? message.params : {};
  if (!method) {
    return;
  }

  try {
    const context = {
      endpoint,
      env,
      fetchImpl,
      listeners,
      sessionByThreadId,
      isShutdown,
    };

    switch (method) {
      case "initialize":
        emitJsonRpcResult(listeners, requestId, {
          serverInfo: {
            name: "Opendex",
            runtime: "OpenCode",
          },
          capabilities: {
            experimentalApi: true,
          },
        });
        return;
      case "initialized":
        return;
      case "collaborationMode/list":
        emitJsonRpcResult(listeners, requestId, {
          modes: [],
          items: [],
        });
        return;
      case "account/read":
        emitJsonRpcResult(listeners, requestId, {
          account: null,
          requiresOpenaiAuth: false,
        });
        return;
      case "getAuthStatus":
        emitJsonRpcResult(listeners, requestId, {
          authenticated: false,
          authMethod: "none",
          account: null,
          requiresOpenaiAuth: false,
          token: null,
        });
        return;
      case "account/login/start":
      case "account/login/cancel":
      case "account/logout":
        emitJsonRpcResult(listeners, requestId, {
          success: true,
          supported: false,
        });
        return;
      case "model/list":
        await handleModelList({ requestId, context });
        return;
      case "thread/start":
        await handleThreadStart({ requestId, params, context });
        return;
      case "thread/list":
        await handleThreadList({ requestId, context });
        return;
      case "thread/read":
      case "thread/resume":
        await handleThreadRead({ requestId, params, method, context });
        return;
      case "thread/archive":
      case "thread/unarchive":
        emitJsonRpcResult(listeners, requestId, {
          success: true,
          supported: false,
        });
        return;
      case "thread/fork":
        emitJsonRpcError(listeners, requestId, {
          code: -32000,
          message: "OpenCode thread forking is not available in Opendex yet.",
          data: { errorCode: "unsupported_method" },
        });
        return;
      case "turn/start":
        await handleTurnStart({ requestId, params, context });
        return;
      case "turn/interrupt":
        emitJsonRpcResult(listeners, requestId, {
          success: true,
          supported: false,
        });
        return;
      case "turn/steer":
        await handleTurnSteer({ requestId, params, context });
        return;
      default:
        emitJsonRpcError(listeners, requestId, {
          code: -32601,
          message: `Unsupported OpenCode bridge method: ${method}`,
          data: { errorCode: "unsupported_method" },
        });
    }
  } catch (error) {
    listeners.emitError(error);
    emitJsonRpcError(listeners, requestId, {
      code: -32000,
      message: error?.message || "OpenCode transport request failed.",
      data: {
        errorCode: error?.errorCode || "transport_failed",
      },
    });
  }
}

async function handleThreadStart({ requestId, params, context }) {
  const preferredDirectory = readRequestedDirectory(params, context.env);
  const session = await createOpenCodeSession({
    title: readThreadTitle(params) || "Opendex Thread",
    directory: preferredDirectory,
    context,
  });
  registerThreadSession(
    context.sessionByThreadId,
    session.id,
    withSessionDirectory(session, preferredDirectory),
  );
  emitJsonRpcResult(context.listeners, requestId, {
    threadId: session.id,
    thread: createThreadSummary(session),
    result: {
      threadId: session.id,
    },
  });
  emitNotification(context.listeners, "thread/started", {
    threadId: session.id,
    thread: createThreadSummary(session),
  });
}

async function handleModelList({ requestId, context }) {
  const models = await listOpenCodeModels(context);
  emitJsonRpcResult(context.listeners, requestId, {
    items: models,
    data: models,
    models,
  });
}

async function handleThreadList({ requestId, context }) {
  const sessions = await listOpenCodeSessions(context);
  const threads = sessions.map((session) => createThreadSummary(session));
  for (const thread of threads) {
    registerThreadSession(context.sessionByThreadId, thread.id, thread);
  }
  emitJsonRpcResult(context.listeners, requestId, {
    threads,
    items: threads,
    data: threads,
  });
}

async function handleThreadRead({ requestId, params, method, context }) {
  const threadId = readThreadId(params);
  if (!threadId) {
    throw withErrorCode(
      new Error("A thread id is required."),
      "missing_thread_id",
    );
  }

  const session = await readOpenCodeSession(threadId, context);
  const transcript = await readOpenCodeSessionMessages(threadId, context);
  registerThreadSession(context.sessionByThreadId, threadId, session);
  const result = createThreadReadResult(session, transcript);
  emitJsonRpcResult(context.listeners, requestId, result);
  if (method === "thread/resume") {
    emitNotification(context.listeners, "thread/started", {
      threadId,
      thread: createThreadSummary(session),
    });
  }
}

async function handleTurnStart({ requestId, params, context }) {
  let threadId = readThreadId(params);
  let session = null;
  let createdThread = false;
  if (threadId) {
    session = await readOpenCodeSession(threadId, context);
  } else {
    const preferredDirectory = readRequestedDirectory(params, context.env);
    session = await createOpenCodeSession({
      title: readThreadTitle(params) || "Opendex Thread",
      directory: preferredDirectory,
      context,
    });
    threadId = session.id;
    createdThread = true;
    registerThreadSession(
      context.sessionByThreadId,
      threadId,
      withSessionDirectory(session, preferredDirectory),
    );
  }

  const turnId = createSyntheticTurnId(threadId);
  emitJsonRpcResult(context.listeners, requestId, {
    threadId,
    turnId,
    turn: { id: turnId, threadId },
  });
  if (createdThread) {
    emitNotification(context.listeners, "thread/started", {
      threadId,
      thread: createThreadSummary(session),
    });
  }
  emitNotification(context.listeners, "turn/started", {
    threadId,
    turnId,
    turn: { id: turnId, threadId, status: "running" },
  });

  const userText = extractTurnPrompt(params);
  const response = await postOpenCodeMessage({
    sessionId: threadId,
    prompt: userText,
    model: readRequestedModel(params),
    context,
  });
  emitAssistantParts({
    listeners: context.listeners,
    threadId,
    turnId,
    response,
  });
  emitNotification(context.listeners, "turn/completed", {
    threadId,
    turnId,
    turn: {
      id: turnId,
      threadId,
      status: "completed",
    },
    usage: buildTokenUsage(response?.info?.tokens),
  });
  if (response?.info?.tokens) {
    emitNotification(context.listeners, "thread/tokenUsage/updated", {
      threadId,
      usage: buildTokenUsage(response.info.tokens),
    });
  }
}

async function handleTurnSteer({ requestId, params, context }) {
  const threadId = readThreadId(params);
  if (!threadId) {
    throw withErrorCode(
      new Error("A thread id is required."),
      "missing_thread_id",
    );
  }

  const turnId = createSyntheticTurnId(threadId);
  emitJsonRpcResult(context.listeners, requestId, {
    threadId,
    turnId,
    turn: { id: turnId, threadId },
  });
  emitNotification(context.listeners, "turn/started", {
    threadId,
    turnId,
    turn: { id: turnId, threadId, status: "running" },
  });
  const response = await postOpenCodeMessage({
    sessionId: threadId,
    prompt: extractTurnPrompt(params),
    model: readRequestedModel(params),
    context,
  });
  emitAssistantParts({
    listeners: context.listeners,
    threadId,
    turnId,
    response,
  });
  emitNotification(context.listeners, "turn/completed", {
    threadId,
    turnId,
    turn: { id: turnId, threadId, status: "completed" },
    usage: buildTokenUsage(response?.info?.tokens),
  });
}

async function createOpenCodeSession({ title, directory, context }) {
  const resolvedDirectory = normalizeOpenCodeDirectory(directory || resolveOpenCodeDirectory(context.env));
  const body = { title };
  const session = await httpJson({
    endpoint: context.endpoint,
    pathname: "/session",
    method: "POST",
    query: {
      directory: resolvedDirectory,
    },
    body,
    fetchImpl: context.fetchImpl,
    timeoutMs: DEFAULT_REQUEST_TIMEOUT_MS,
  });
  return withSessionDirectory(session, resolvedDirectory);
}

async function listOpenCodeSessions(context) {
  const response = await httpJson({
    endpoint: context.endpoint,
    pathname: "/session",
    method: "GET",
    fetchImpl: context.fetchImpl,
    timeoutMs: 30_000,
  });
  return Array.isArray(response) ? response : [];
}

async function listOpenCodeModels(context) {
  const forcedModel = "gpt-5.4";

  try {
    const config = await httpJson({
      endpoint: context.endpoint,
      pathname: "/global/config",
      method: "GET",
      fetchImpl: context.fetchImpl,
      timeoutMs: 5_000,
    });
    const models = extractOpenCodeModels(config);
    const matchingModels = models.filter(
      (model) => model.id === forcedModel || model.model === forcedModel,
    );
    if (matchingModels.length) {
      return matchingModels.map((model, index) => ({
        ...model,
        id: forcedModel,
        model: forcedModel,
        displayName: "GPT-5.4",
        isDefault: index === 0,
      }));
    }
  } catch {
    // Ignore config lookup failures and fall back to a forced GPT-5.4 entry.
  }

  return [
    createModelOption({
      id: forcedModel,
      model: forcedModel,
      displayName: "GPT-5.4",
      description: "Use GPT-5.4 through the configured OpenCode runtime.",
      isDefault: true,
      supportedReasoningEfforts: ["low", "medium", "high"],
      defaultReasoningEffort: "medium",
    }),
  ];
}

async function readOpenCodeSession(sessionId, context) {
  if (context.sessionByThreadId.has(sessionId)) {
    const cached = context.sessionByThreadId.get(sessionId);
    if (cached?.directory || cached?.path) {
      return cached;
    }
  }

  const session = await httpJson({
    endpoint: context.endpoint,
    pathname: `/session/${encodeURIComponent(sessionId)}`,
    method: "GET",
    query: {
      directory: resolveOpenCodeSessionDirectory(sessionId, context),
    },
    fetchImpl: context.fetchImpl,
    timeoutMs: 30_000,
  });
  const normalizedSession = withSessionDirectory(
    session,
    resolveOpenCodeSessionDirectory(sessionId, context),
  );
  registerThreadSession(context.sessionByThreadId, sessionId, normalizedSession);
  return normalizedSession;
}

async function readOpenCodeSessionMessages(sessionId, context) {
  const response = await httpJson({
    endpoint: context.endpoint,
    pathname: `/session/${encodeURIComponent(sessionId)}/message`,
    method: "GET",
    query: {
      directory: resolveOpenCodeSessionDirectory(sessionId, context),
      limit: "200",
    },
    fetchImpl: context.fetchImpl,
    timeoutMs: DEFAULT_REQUEST_TIMEOUT_MS,
  });
  return Array.isArray(response) ? response : [];
}

async function postOpenCodeMessage({ sessionId, prompt, model, context }) {
  const baselineMessages = await readOpenCodeSessionMessages(
    sessionId,
    context,
  ).catch(() => []);
  const baselineCount = Array.isArray(baselineMessages)
    ? baselineMessages.length
    : 0;
  const body = {
    agent: readFirstDefinedValue([
      context.env.OPENDEX_OPENCODE_AGENT,
      context.env.REMODEX_OPENCODE_AGENT,
      context.env.PHODEX_OPENCODE_AGENT,
      DEFAULT_OPENCODE_AGENT,
    ]),
    model:
      model ||
      readFirstDefinedValue([
        context.env.OPENDEX_OPENCODE_MODEL,
        context.env.REMODEX_OPENCODE_MODEL,
        context.env.PHODEX_OPENCODE_MODEL,
        "",
      ]) ||
      undefined,
    messageID: createSyntheticMessageId(sessionId),
    parts: [
      {
        type: "text",
        text: prompt,
      },
    ],
  };

  const response = await httpJson({
    endpoint: context.endpoint,
    pathname: `/session/${encodeURIComponent(sessionId)}/message`,
    method: "POST",
    query: {
      directory: resolveOpenCodeSessionDirectory(sessionId, context),
    },
    body,
    fetchImpl: context.fetchImpl,
    timeoutMs: DEFAULT_REQUEST_TIMEOUT_MS,
  });

  if (hasRenderableAssistantContent(response)) {
    return response;
  }

  return waitForAssistantResponse({
    sessionId,
    baselineCount,
    context,
    fallbackResponse: response,
  });
}

async function waitForAssistantResponse({
  sessionId,
  baselineCount,
  context,
  fallbackResponse,
}) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const transcript = await readOpenCodeSessionMessages(
      sessionId,
      context,
    ).catch(() => []);
    const recentMessages = Array.isArray(transcript)
      ? transcript.slice(Math.max(0, baselineCount - 1))
      : [];
    const assistantMessage = [...recentMessages].reverse().find((message) => {
      if (message?.info?.role !== "assistant") {
        return false;
      }
      return hasRenderableAssistantContent(message);
    });
    if (assistantMessage) {
      return assistantMessage;
    }

    if (attempt < 19) {
      await sleep(500);
    }
  }

  return fallbackResponse;
}

async function httpJson({
  endpoint,
  pathname,
  method,
  query = {},
  body,
  fetchImpl,
  timeoutMs,
}) {
  const url = new URL(pathname, ensureTrailingSlash(endpoint));
  for (const [key, value] of Object.entries(query)) {
    if (value == null || value === "") {
      continue;
    }
    url.searchParams.set(key, String(value));
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  timer.unref?.();
  let response;
  try {
    response = await fetchImpl(url, {
      method,
      headers: body ? { "content-type": "application/json" } : undefined,
      body: body ? JSON.stringify(body) : undefined,
      signal: controller.signal,
    });
  } catch (error) {
    throw withErrorCode(
      new Error(
        `OpenCode request failed for ${method} ${url.pathname}: ${error.message}`,
      ),
      "opencode_unreachable",
    );
  } finally {
    clearTimeout(timer);
  }

  const text = await response.text();
  if (!response.ok) {
    throw withErrorCode(
      new Error(
        `OpenCode request failed for ${method} ${url.pathname}: ${response.status} ${text || response.statusText}`,
      ),
      "opencode_request_failed",
    );
  }

  return text ? JSON.parse(text) : null;
}

function emitAssistantParts({ listeners, threadId, turnId, response }) {
  const parts = Array.isArray(response?.parts) ? response.parts : [];
  let emittedText = false;
  for (const part of parts) {
    if (!part || typeof part !== "object") {
      continue;
    }

    if (part.type === "text" && typeof part.text === "string" && part.text) {
      emittedText = true;
      emitNotification(listeners, "item/agentMessage/delta", {
        threadId,
        turnId,
        textDelta: part.text,
        item: {
          id: part.id || createSyntheticItemId(threadId, "assistant"),
          type: "agent_message",
        },
      });
      continue;
    }

    const reasoningText = extractReasoningText(part);
    if (reasoningText) {
      emitNotification(listeners, "item/reasoning/textDelta", {
        threadId,
        turnId,
        textDelta: reasoningText,
        item: {
          id: part.id || createSyntheticItemId(threadId, "reasoning"),
          type: "reasoning",
        },
      });
      continue;
    }
  }

  if (!emittedText) {
    emitNotification(listeners, "item/agentMessage/delta", {
      threadId,
      turnId,
      textDelta: "",
      item: {
        id: createSyntheticItemId(threadId, "assistant"),
        type: "agent_message",
      },
    });
  }
}

function createThreadReadResult(session, transcript) {
  const turns = buildHistoryTurnsFromTranscript(transcript, session.id);
  const thread = {
    ...createThreadSummary(session),
    turns,
    preview: extractThreadPreviewText(transcript),
  };
  return {
    thread,
    turns,
    messages: transcript,
    items: turns,
  };
}

function createThreadSummary(session) {
  const title = session.title || session.name || session.slug || session.id;
  return {
    id: session.id,
    threadId: session.id,
    title,
    name: title,
    preview: session.summary || session.preview || title,
    status: session.status || "ready",
    createdAt: session.created || session.time?.created || null,
    updatedAt: session.updated || session.time?.updated || null,
    cwd: session.directory || session.path || null,
    current_working_directory: session.directory || session.path || null,
    model: session.model || null,
    modelProvider: session.providerID || session.provider || null,
    source: "opencode",
  };
}

function extractOpenCodeModels(config) {
  const entries = [];
  const seen = new Set();

  const addModel = (entry, providerName = "") => {
    const option = normalizeOpenCodeModel(entry, providerName);
    if (!option) {
      return;
    }
    const key = `${option.id}::${option.model}`;
    if (seen.has(key)) {
      return;
    }
    seen.add(key);
    entries.push(option);
  };

  if (config?.providers && typeof config.providers === "object") {
    for (const [providerName, providerConfig] of Object.entries(
      config.providers,
    )) {
      if (Array.isArray(providerConfig?.models)) {
        for (const model of providerConfig.models) {
          addModel(model, providerName);
        }
      }
    }
  }

  if (Array.isArray(config?.models)) {
    for (const model of config.models) {
      addModel(model);
    }
  }

  return entries;
}

function normalizeOpenCodeModel(entry, providerName = "") {
  if (typeof entry === "string") {
    return createModelOption({
      id: entry,
      model: entry,
      displayName: entry,
      description: providerName ? `Available via ${providerName}.` : undefined,
      isDefault: false,
    });
  }

  if (!entry || typeof entry !== "object") {
    return null;
  }

  const model = readFirstDefinedValue([
    entry.model,
    entry.id,
    entry.name,
    entry.slug,
  ]);
  if (!model) {
    return null;
  }

  const displayName =
    readFirstDefinedValue([
      entry.displayName,
      entry.display_name,
      entry.label,
      entry.name,
      model,
    ]) || model;

  return createModelOption({
    id: model,
    model,
    displayName,
    description:
      readFirstDefinedValue([entry.description, entry.summary]) ||
      (providerName ? `Available via ${providerName}.` : undefined),
    isDefault: Boolean(entry.isDefault || entry.is_default),
    supportedReasoningEfforts: extractStringArray(
      entry.supportedReasoningEfforts || entry.supported_reasoning_efforts,
    ),
    defaultReasoningEffort:
      readFirstDefinedValue([
        entry.defaultReasoningEffort,
        entry.default_reasoning_effort,
      ]) || undefined,
  });
}

function createModelOption({
  id,
  model,
  displayName,
  description,
  isDefault,
  supportedReasoningEfforts = [],
  defaultReasoningEffort,
}) {
  return {
    id,
    model,
    displayName,
    description: description || "",
    isDefault: Boolean(isDefault),
    supportedReasoningEfforts,
    defaultReasoningEffort: defaultReasoningEffort || null,
  };
}

function extractStringArray(value) {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.filter((entry) => typeof entry === "string" && entry.trim());
}

function buildHistoryTurnsFromTranscript(transcript, threadId) {
  return transcript
    .map((message, index) =>
      buildHistoryTurnFromMessage(message, threadId, index),
    )
    .filter(Boolean);
}

function buildHistoryTurnFromMessage(message, threadId, index) {
  const role = message?.info?.role;
  if (role !== "user" && role !== "assistant") {
    return null;
  }

  const turnId =
    message?.info?.id || createSyntheticTurnId(`${threadId}_${index}`);
  const createdAt = message?.info?.time?.created || null;
  const completedAt = message?.info?.time?.completed || createdAt;
  const items = buildHistoryItemsFromMessage(message, threadId, turnId);
  if (!items.length) {
    return null;
  }

  return {
    id: turnId,
    threadId,
    status: completedAt ? "completed" : "running",
    createdAt,
    updatedAt: completedAt || createdAt,
    completedAt,
    items,
    output:
      role === "assistant"
        ? extractAssistantTextFromMessage(message)
        : undefined,
    usage: buildTokenUsage(message?.info?.tokens),
  };
}

function buildHistoryItemsFromMessage(message, threadId, turnId) {
  const role = message?.info?.role;
  const createdAt = message?.info?.time?.created || null;
  const parts = Array.isArray(message?.parts) ? message.parts : [];
  const items = [];

  if (role === "user") {
    const text = extractMessageText(message);
    if (text) {
      items.push(
        createHistoryTextItem({
          id: createSyntheticItemId(threadId, "user"),
          type: "user_message",
          text,
          createdAt,
        }),
      );
    }
    return items;
  }

  const reasoningText = parts
    .map(extractReasoningText)
    .filter(Boolean)
    .join("\n\n");
  if (reasoningText) {
    items.push({
      id: createSyntheticItemId(threadId, "reasoning"),
      type: "reasoning",
      text: reasoningText,
      createdAt,
    });
  }

  const assistantText = extractAssistantTextFromMessage(message);
  if (assistantText) {
    items.push(
      createHistoryTextItem({
        id: createSyntheticItemId(threadId, "assistant"),
        type: "assistant_message",
        text: assistantText,
        createdAt,
      }),
    );
  }

  return items;
}

function createHistoryTextItem({ id, type, text, createdAt }) {
  return {
    id,
    type,
    createdAt,
    content: [
      {
        type: "text",
        text,
      },
    ],
    text,
  };
}

function extractThreadPreviewText(transcript) {
  const latest = [...transcript].reverse().find((message) => {
    const role = message?.info?.role;
    return role === "assistant" || role === "user";
  });
  return latest ? extractMessageText(latest) : "";
}

function extractMessageText(message) {
  const role = message?.info?.role;
  if (role === "assistant") {
    return extractAssistantTextFromMessage(message);
  }

  const parts = Array.isArray(message?.parts) ? message.parts : [];
  const text = parts
    .map((part) => {
      if (part?.type === "text" && typeof part.text === "string") {
        return part.text;
      }
      return "";
    })
    .filter(Boolean)
    .join("\n\n");
  return text.trim();
}

function hasRenderableAssistantContent(message) {
  if (message?.info?.role !== "assistant") {
    return false;
  }
  return Boolean(extractAssistantTextFromMessage(message).trim());
}

function readRequestedModel(params) {
  return readFirstDefinedValue([
    params.model,
    params.modelId,
    params.modelID,
    params.runtime?.model,
    params.runtimeConfiguration?.model,
  ]);
}

function extractAssistantTextFromMessage(message) {
  const parts = Array.isArray(message?.parts) ? message.parts : [];
  return parts
    .map((part) => {
      if (part?.type === "text" && typeof part.text === "string") {
        return part.text;
      }
      const reasoningText = extractReasoningText(part);
      return reasoningText || "";
    })
    .filter(Boolean)
    .join("\n");
}

function extractReasoningText(part) {
  if (!part || typeof part !== "object") {
    return "";
  }
  if (part.type === "reasoning" && typeof part.text === "string" && part.text) {
    return part.text;
  }
  if (typeof part.reasoning === "string" && part.reasoning) {
    return part.reasoning;
  }
  if (
    part.type === "tool" &&
    typeof part.state?.output === "string" &&
    part.state.output
  ) {
    return part.state.output;
  }
  return "";
}

function buildTokenUsage(tokens) {
  if (!tokens || typeof tokens !== "object") {
    return null;
  }
  return {
    total: tokens.total ?? null,
    input: tokens.input ?? null,
    output: tokens.output ?? null,
    reasoning: tokens.reasoning ?? null,
    cache: tokens.cache || null,
  };
}

function resolveOpenCodeDirectory(env) {
  const explicitDirectory = readFirstDefinedValue([
    env.OPENDEX_OPENCODE_DIRECTORY,
    env.REMODEX_OPENCODE_DIRECTORY,
    env.PHODEX_OPENCODE_DIRECTORY,
    env.PWD,
    process.cwd(),
  ]);
  if (!explicitDirectory) {
    return process.cwd();
  }

  const resolved = path.resolve(explicitDirectory);
  if (path.basename(resolved) === "phodex-bridge") {
    const repoRoot = path.resolve(resolved, "..");
    if (fs.existsSync(path.join(repoRoot, ".git"))) {
      return repoRoot;
    }
  }
  return resolved;
}

function normalizeOpenCodeDirectory(candidate) {
  return path.resolve(candidate || process.cwd());
}

function readRequestedDirectory(params, env) {
  const requestedDirectory = readFirstDefinedValue([
    params.cwd,
    params.current_working_directory,
    params.currentWorkingDirectory,
    params.directory,
  ]);
  return normalizeOpenCodeDirectory(requestedDirectory || resolveOpenCodeDirectory(env));
}

function resolveOpenCodeSessionDirectory(sessionId, context) {
  const cached = context.sessionByThreadId.get(sessionId);
  const cachedDirectory = readFirstDefinedValue([
    cached?.directory,
    cached?.path,
  ]);
  return normalizeOpenCodeDirectory(cachedDirectory || resolveOpenCodeDirectory(context.env));
}

function withSessionDirectory(session, fallbackDirectory) {
  if (!session || typeof session !== "object") {
    return session;
  }

  if (session.directory || session.path || !fallbackDirectory) {
    return session;
  }

  return {
    ...session,
    directory: fallbackDirectory,
  };
}

function readOpenCodeEndpoint(env) {
  return normalizeEndpoint(
    readFirstDefinedValue([
      env.OPENDEX_OPENCODE_ENDPOINT,
      env.REMODEX_OPENCODE_ENDPOINT,
      env.PHODEX_OPENCODE_ENDPOINT,
      env.OPENCODE_ENDPOINT,
      "",
    ]),
  );
}

function shouldUseOpenCodeTransport(endpoint, env, fetchImpl) {
  if (isHttpEndpoint(endpoint)) {
    return true;
  }
  return Boolean(
    env.OPENDEX_OPENCODE_ENDPOINT ||
    env.REMODEX_OPENCODE_ENDPOINT ||
    env.PHODEX_OPENCODE_ENDPOINT ||
    env.OPENCODE_ENDPOINT,
  );
}

function normalizeEndpoint(endpoint) {
  return typeof endpoint === "string" && endpoint.trim() ? endpoint.trim() : "";
}

function isWebSocketEndpoint(endpoint) {
  return /^wss?:\/\//i.test(endpoint);
}

function isHttpEndpoint(endpoint) {
  return /^https?:\/\//i.test(endpoint);
}

function ensureTrailingSlash(value) {
  return value.endsWith("/") ? value : `${value}/`;
}

function registerThreadSession(sessionByThreadId, threadId, session) {
  if (!threadId || !session || typeof session !== "object") {
    return;
  }
  sessionByThreadId.set(threadId, {
    ...session,
    id: threadId,
  });
}

function readThreadId(params) {
  const candidates = [
    params.threadId,
    params.thread?.id,
    params.thread?.threadId,
    params.conversationId,
  ];
  return readFirstDefinedValue(candidates);
}

function readThreadTitle(params) {
  return readFirstDefinedValue([
    params.title,
    params.thread?.title,
    params.thread?.name,
  ]);
}

function extractTurnPrompt(params) {
  if (Array.isArray(params.input)) {
    const inputPrompt = extractPromptFromInputItems(params.input);
    if (inputPrompt) {
      return inputPrompt;
    }
  }

  const directPrompt = readFirstDefinedValue([
    params.prompt,
    params.text,
    params.message,
    params.content,
  ]);
  if (directPrompt) {
    return directPrompt;
  }

  if (Array.isArray(params.messages)) {
    const joined = params.messages
      .map((entry) => {
        if (typeof entry === "string") {
          return entry;
        }
        if (entry && typeof entry === "object") {
          return readFirstDefinedValue([
            entry.text,
            entry.content,
            entry.message,
          ]);
        }
        return "";
      })
      .filter(Boolean)
      .join("\n\n");
    if (joined) {
      return joined;
    }
  }

  return "Continue.";
}

function extractPromptFromInputItems(inputItems) {
  return inputItems
    .map((item) => {
      if (typeof item === "string") {
        return item;
      }
      if (!item || typeof item !== "object") {
        return "";
      }
      if (item.type === "text" && typeof item.text === "string") {
        return item.text;
      }
      if (item.type === "skill") {
        return readFirstDefinedValue([item.name, item.id]);
      }
      return readFirstDefinedValue([item.text, item.content, item.message]);
    })
    .filter(Boolean)
    .join("\n\n")
    .trim();
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function createSyntheticTurnId(threadId) {
  return `turn_${threadId}_${Date.now().toString(36)}`;
}

function createSyntheticMessageId(threadId) {
  return `msg_${threadId}_${Date.now().toString(36)}`;
}

function createSyntheticItemId(threadId, kind) {
  return `item_${kind}_${threadId}_${Date.now().toString(36)}`;
}

function emitJsonRpcResult(listeners, id, result) {
  if (id == null) {
    return;
  }
  listeners.emitMessage(JSON.stringify({ id, result }));
}

function emitJsonRpcError(listeners, id, error) {
  if (id == null) {
    return;
  }
  listeners.emitMessage(JSON.stringify({ id, error }));
}

function emitNotification(listeners, method, params) {
  listeners.emitMessage(JSON.stringify({ method, params }));
}

function readFirstDefinedValue(values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) {
      return value.trim();
    }
  }
  return "";
}

function safeParseJSON(value) {
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

function withErrorCode(error, errorCode) {
  error.errorCode = errorCode;
  return error;
}

function createSpawnTransport({ env, spawnImpl = spawn }) {
  const launch = createCodexLaunchPlan({ env });
  const codex = spawnImpl(launch.command, launch.args, launch.options);

  let stdoutBuffer = "";
  let stderrBuffer = "";
  let didRequestShutdown = false;
  let didReportError = false;
  const listeners = createListenerBag();

  codex.on("error", (error) => {
    didReportError = true;
    listeners.emitError(error);
  });
  codex.on("close", (code, signal) => {
    if (!didRequestShutdown && !didReportError && code !== 0) {
      didReportError = true;
      listeners.emitError(
        createCodexCloseError({
          code,
          signal,
          stderrBuffer,
          launchDescription: launch.description,
        }),
      );
      return;
    }

    listeners.emitClose(code, signal);
  });
  // Ignore broken-pipe shutdown noise once the child is already going away.
  codex.stdin.on("error", (error) => {
    if (didRequestShutdown && isIgnorableStdinShutdownError(error)) {
      return;
    }

    if (isIgnorableStdinShutdownError(error)) {
      return;
    }

    didReportError = true;
    listeners.emitError(error);
  });
  // Keep stderr muted during normal operation, but preserve enough output to
  // explain launch failures when the child exits before the bridge can use it.
  codex.stderr.on("data", (chunk) => {
    stderrBuffer = appendOutputBuffer(stderrBuffer, chunk.toString("utf8"));
  });

  codex.stdout.on("data", (chunk) => {
    stdoutBuffer += chunk.toString("utf8");
    const lines = stdoutBuffer.split("\n");
    stdoutBuffer = lines.pop() || "";

    for (const line of lines) {
      const trimmedLine = line.trim();
      if (trimmedLine) {
        listeners.emitMessage(trimmedLine);
      }
    }
  });

  return {
    mode: "spawn",
    describe() {
      return launch.description;
    },
    send(message) {
      if (
        !codex.stdin.writable ||
        codex.stdin.destroyed ||
        codex.stdin.writableEnded
      ) {
        return;
      }

      codex.stdin.write(message.endsWith("\n") ? message : `${message}\n`);
    },
    onMessage(handler) {
      listeners.onMessage = handler;
    },
    onClose(handler) {
      listeners.onClose = handler;
    },
    onError(handler) {
      listeners.onError = handler;
    },
    shutdown() {
      didRequestShutdown = true;
      shutdownCodexProcess(codex);
    },
  };
}

// Builds a single, platform-aware launch path so the bridge never "guesses"
// between multiple commands and accidentally starts duplicate runtimes.
function createCodexLaunchPlan({ env }) {
  const sharedOptions = {
    stdio: ["pipe", "pipe", "pipe"],
    env: { ...env },
  };

  if (process.platform === "win32") {
    return {
      command: env.ComSpec || "cmd.exe",
      args: ["/d", "/c", "codex app-server"],
      options: {
        ...sharedOptions,
        windowsHide: true,
      },
      description: "`cmd.exe /d /c codex app-server`",
    };
  }

  return {
    command: "codex",
    args: ["app-server"],
    options: sharedOptions,
    description: "`codex app-server`",
  };
}

// Stops the exact process tree we launched on Windows so the shell wrapper
// does not leave a child Codex process running in the background.
function shutdownCodexProcess(codex) {
  if (codex.killed || codex.exitCode !== null) {
    return;
  }

  if (process.platform === "win32" && codex.pid) {
    const killer = spawn("taskkill", ["/pid", String(codex.pid), "/t", "/f"], {
      stdio: "ignore",
      windowsHide: true,
    });
    killer.on("error", () => {
      codex.kill();
    });
    return;
  }

  codex.kill("SIGTERM");
}

function createCodexCloseError({
  code,
  signal,
  stderrBuffer,
  launchDescription,
}) {
  const details = stderrBuffer.trim();
  const reason =
    details ||
    `Process exited with code ${code}${signal ? ` (signal: ${signal})` : ""}.`;
  return new Error(`Codex launcher ${launchDescription} failed: ${reason}`);
}

function appendOutputBuffer(buffer, chunk) {
  const next = `${buffer}${chunk}`;
  return next.slice(-4_096);
}

function isIgnorableStdinShutdownError(error) {
  return error?.code === "EPIPE" || error?.code === "ERR_STREAM_DESTROYED";
}

function createWebSocketTransport({ endpoint, WebSocketImpl = WebSocket }) {
  const socket = new WebSocketImpl(endpoint);
  const listeners = createListenerBag();
  const openState = WebSocketImpl.OPEN ?? WebSocket.OPEN ?? 1;
  const connectingState = WebSocketImpl.CONNECTING ?? WebSocket.CONNECTING ?? 0;

  socket.on("message", (chunk) => {
    const message = typeof chunk === "string" ? chunk : chunk.toString("utf8");
    if (message.trim()) {
      listeners.emitMessage(message);
    }
  });

  socket.on("close", (code, reason) => {
    const safeReason = reason ? reason.toString("utf8") : "no reason";
    listeners.emitClose(code, safeReason);
  });

  socket.on("error", (error) => listeners.emitError(error));

  return {
    mode: "websocket",
    describe() {
      return endpoint;
    },
    send(message) {
      if (socket.readyState === openState) {
        socket.send(message);
      }
    },
    onMessage(handler) {
      listeners.onMessage = handler;
    },
    onClose(handler) {
      listeners.onClose = handler;
    },
    onError(handler) {
      listeners.onError = handler;
    },
    shutdown() {
      if (
        socket.readyState === openState ||
        socket.readyState === connectingState
      ) {
        socket.close();
      }
    },
  };
}

function createListenerBag() {
  return {
    onMessage: null,
    onClose: null,
    onError: null,
    emitMessage(message) {
      this.onMessage?.(message);
    },
    emitClose(...args) {
      this.onClose?.(...args);
    },
    emitError(error) {
      this.onError?.(error);
    },
  };
}

module.exports = { createCodexTransport };
