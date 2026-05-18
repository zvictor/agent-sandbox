#!/usr/bin/env bun

import { randomUUID } from "node:crypto";

const BASE_URL = process.env.DEEPWIKI_API_URL ?? "https://api.devin.ai";
const POLL_INTERVAL_MS = 2000;
const HEARTBEAT_INTERVAL_MS = 15000;
const API_TIMEOUT_MS = 30000;

const ENGINE_MAP = {
  fast: "multihop_faster",
  deep: "agent",
  codemap: "codemap",
} as const;

type Mode = keyof typeof ENGINE_MAP;
type ProgressMode = "auto" | "plain" | "quiet";

interface QueryRequest {
  engine_id: string;
  user_query: string;
  keywords: string[];
  repo_names: string[];
  additional_context: string;
  query_id: string;
  use_notes: boolean;
  attached_context: unknown[];
  generate_summary: boolean;
}

interface QueryEvent {
  type?: string;
  data?: unknown;
}

interface QueryState {
  message_id?: string;
  user_query?: string;
  repo_names?: string[];
  response?: QueryEvent[];
  error?: string | null;
  state?: string;
  redis_stream?: string;
}

interface QueryResult {
  title?: string;
  queries?: QueryState[];
  org_id?: string;
}

interface QueryOptions {
  repos: string[];
  mode: Mode;
  context?: string;
  queryId?: string;
  summary: boolean;
  mermaid: boolean;
  rawJson: boolean;
  sourcesOnly: boolean;
}

interface StatusOptions {
  repo: string;
  warm: boolean;
}

interface CodemapLocation {
  id: string;
  lineContent: string;
  path: string;
  lineNumber: number;
  title: string;
  description: string;
}

interface CodemapTrace {
  id: string;
  title: string;
  description: string;
  locations: CodemapLocation[];
}

interface Codemap {
  title: string;
  traces: CodemapTrace[];
  description: string;
  metadata: Record<string, unknown>;
  workspaceInfo: Record<string, unknown>;
}

class DeepWikiError extends Error {
  details?: Record<string, unknown>;
  retryable: boolean;

  constructor(message: string, details?: Record<string, unknown>, retryable = false) {
    super(message);
    this.name = "DeepWikiError";
    this.details = details;
    this.retryable = retryable;
  }
}

function fail(message: string, details?: Record<string, unknown>): never {
  process.stderr.write(`${JSON.stringify({ error: message, ...details })}\n`);
  process.exit(1);
}

function usage(code = 1): never {
  process.stderr.write(
    [
      "Usage:",
      "  deepwiki.ts query \"question\" owner/repo [owner/repo2 ...] [--mode deep|fast|codemap] [--context TEXT] [--id QUERY_ID] [--mermaid] [--sources-only] [--json]",
      "  deepwiki.ts start \"question\" owner/repo [owner/repo2 ...] [--mode deep|fast|codemap] [--context TEXT] [--id QUERY_ID] [--no-summary]",
      "  deepwiki.ts wait QUERY_ID [--mode codemap] [--mermaid] [--sources-only] [--json]",
      "  deepwiki.ts status owner/repo [--warm]",
      "  deepwiki.ts warm owner/repo",
      "  deepwiki.ts get QUERY_ID",
      "  deepwiki.ts list SEARCH",
    ].join("\n") + "\n",
  );
  process.exit(code);
}

function printJson(data: unknown): void {
  process.stdout.write(`${JSON.stringify(data, null, 2)}\n`);
}

function isPlainProgressEnabled(mode: ProgressMode): boolean {
  switch (mode) {
    case "plain":
      return true;
    case "quiet":
      return false;
    case "auto":
    default:
      return process.stderr.isTTY === true;
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function latestQuery(result: QueryResult): QueryState | null {
  const queries = result.queries ?? [];
  return queries.length > 0 ? (queries[queries.length - 1] ?? null) : null;
}

function isBlankText(text: string): boolean {
  return /^\s*$/.test(text);
}

function isProgressLine(line: string): boolean {
  return /^(?:progress:|status:|step:|eta:)/i.test(line)
    || /\bETA\b/i.test(line)
    || /\bPROGRESS\b/i.test(line)
    || /\b\d+\s*\/\s*\d+\b/.test(line)
    || /\b\d{1,3}%\b/.test(line);
}

function extractProgressLines(text: string): string[] {
  const lines = text
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
  if (lines.length === 0) return [];
  if (!lines.every((line) => line.startsWith("> "))) return [];
  const stripped = lines.map((line) => line.slice(2).trim()).filter(Boolean);
  if (stripped.length === 0) return [];
  if (!stripped.every((line) => isProgressLine(line))) return [];
  return stripped;
}

function cleanReferencePath(rawPath: string): string {
  return rawPath.replace(/^Repo [^:]+: /, "");
}

function extractQueryError(result: QueryResult): string | null {
  const query = latestQuery(result);
  if (typeof query?.error === "string" && query.error.length > 0) {
    return query.error;
  }
  return null;
}

async function api<T>(path: string, options?: RequestInit): Promise<T> {
  const url = `${BASE_URL}${path}`;
  const timeoutController = new AbortController();
  const externalSignal = options?.signal;
  const timer = setTimeout(() => timeoutController.abort("deepwiki-api-timeout"), API_TIMEOUT_MS);
  const abortController = new AbortController();

  const abortFromExternal = () => abortController.abort(externalSignal?.reason);
  const abortFromTimeout = () => abortController.abort("deepwiki-api-timeout");

  try {
    if (externalSignal) {
      if (externalSignal.aborted) {
        abortFromExternal();
      } else {
        externalSignal.addEventListener("abort", abortFromExternal, { once: true });
      }
    }
    timeoutController.signal.addEventListener("abort", abortFromTimeout, { once: true });

    const response = await fetch(url, {
      ...options,
      signal: abortController.signal,
      headers: {
        "Content-Type": "application/json",
        ...(options?.headers ?? {}),
      },
    });
    if (!response.ok) {
      const body = await response.text().catch(() => "");
      throw new DeepWikiError(`HTTP ${response.status}: ${response.statusText}`, {
        url,
        body,
        status: response.status,
      }, response.status === 502 || response.status === 503 || response.status === 504);
    }
    return (await response.json()) as T;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const isAbort = error instanceof DOMException && error.name === "AbortError";
    const timedOut = abortController.signal.aborted && timeoutController.signal.aborted;
    if (isAbort || timedOut) {
      throw new DeepWikiError("DeepWiki API request timed out", {
        url,
        timeout_ms: API_TIMEOUT_MS,
      }, true);
    }
    if (error instanceof DeepWikiError) {
      throw error;
    }
    throw new DeepWikiError(message, { url });
  } finally {
    clearTimeout(timer);
    timeoutController.signal.removeEventListener("abort", abortFromTimeout);
    externalSignal?.removeEventListener("abort", abortFromExternal);
  }
}

class ProgressTracker {
  private readonly enabled: boolean;
  private readonly startedAt = Date.now();
  private readonly timer: Timer | null;
  private lastActivityAt = Date.now();
  private lastMessage = "";
  private seenResponseEvents = 0;
  private searchedSources = 0;
  private groundedReferences = 0;
  private answerStarted = false;

  constructor(mode: ProgressMode) {
    this.enabled = isPlainProgressEnabled(mode);
    if (this.enabled) {
      this.timer = setInterval(() => this.emitHeartbeat(), HEARTBEAT_INTERVAL_MS);
    } else {
      this.timer = null;
    }
  }

  stop(): void {
    if (this.timer) {
      clearInterval(this.timer);
    }
  }

  processQueryState(query: QueryState): void {
    const response = query.response ?? [];
    if (response.length <= this.seenResponseEvents) return;

    for (const event of response.slice(this.seenResponseEvents)) {
      this.processEvent(event);
    }
    this.seenResponseEvents = response.length;
  }

  markDone(): void {
    this.log("Response complete.");
  }

  startQuery(queryId: string): void {
    this.log(`Started query ${queryId}`);
  }

  private touch(): void {
    this.lastActivityAt = Date.now();
  }

  private log(message: string): void {
    if (!this.enabled) return;
    if (message === this.lastMessage) return;
    this.lastMessage = message;
    process.stderr.write(`> ${message}\n`);
  }

  private emitHeartbeat(): void {
    if (!this.enabled) return;
    if (Date.now() - this.lastActivityAt < HEARTBEAT_INTERVAL_MS) return;
    const elapsed = Math.floor((Date.now() - this.startedAt) / 1000);
    this.log(`Still working... ${elapsed}s elapsed`);
  }

  private processEvent(event: QueryEvent): void {
    this.touch();
    const eventType = event.type ?? "";

    if (eventType === "loading_indexes") {
      const allDone = Boolean((event.data as { all_done?: boolean } | undefined)?.all_done);
      this.log(allDone ? "Indexes ready." : "Loading repo indexes...");
      return;
    }

    if (eventType === "file_contents") {
      this.searchedSources += 1;
      if (this.searchedSources === 1) {
        this.log("Searching codebase...");
      } else if (this.searchedSources % 25 === 0) {
        this.log(`Searching codebase... (${this.searchedSources} source files inspected)`);
      }
      return;
    }

    if (eventType === "reference") {
      this.groundedReferences += 1;
      if (this.groundedReferences === 1) {
        this.log("Grounding answer...");
      } else if (this.groundedReferences % 10 === 0) {
        this.log(`Grounding answer... (${this.groundedReferences} references)`);
      }
      return;
    }

    if (eventType === "summary_done") {
      this.log("Summary complete. Finalizing answer...");
      return;
    }

    if (eventType === "done") {
      this.markDone();
      return;
    }

    if (eventType !== "chunk" && eventType !== "summary_chunk") {
      return;
    }

    const text = typeof event.data === "string" ? event.data : "";
    if (isBlankText(text)) return;

    const progressLines = extractProgressLines(text);
    if (progressLines.length > 0) {
      for (const line of progressLines) {
        this.log(line);
      }
      return;
    }

    if (!this.answerStarted) {
      this.answerStarted = true;
      this.log("Synthesizing answer...");
    }
  }
}

function extractEvents(result: QueryResult): QueryEvent[] {
  return latestQuery(result)?.response ?? [];
}

function extractAnswerText(result: QueryResult): string {
  const events = extractEvents(result);
  const chunks = events
    .filter((event) => event.type === "chunk")
    .map((event) => (typeof event.data === "string" ? event.data : ""))
    .filter((text) => !isBlankText(text))
    .filter((text) => extractProgressLines(text).length === 0)
    .join("");
  if (chunks !== "") return chunks;

  return events
    .filter((event) => event.type === "summary_chunk")
    .map((event) => (typeof event.data === "string" ? event.data : ""))
    .filter((text) => !isBlankText(text))
    .join("");
}

function extractSourcePaths(result: QueryResult): string[] {
  const events = extractEvents(result);
  const references = events
    .filter((event) => event.type === "reference")
    .map((event) => {
      const data = event.data as { file_path?: string } | undefined;
      return typeof data?.file_path === "string" ? cleanReferencePath(data.file_path) : null;
    })
    .filter((value): value is string => typeof value === "string" && value.length > 0);
  if (references.length > 0) {
    return [...new Set(references)];
  }

  return [
    ...new Set(
      events
        .filter((event) => event.type === "file_contents")
        .map((event) => (Array.isArray(event.data) ? event.data[1] : null))
        .filter((value): value is string => typeof value === "string" && value.length > 0),
    ),
  ];
}

function extractThreadId(result: QueryResult): string {
  return latestQuery(result)?.message_id ?? "";
}

function extractCodemap(result: QueryResult): Codemap | null {
  for (const event of extractEvents(result)) {
    if (event.type !== "chunk" || typeof event.data !== "string") continue;
    try {
      const parsed = JSON.parse(event.data) as Partial<Codemap>;
      if (Array.isArray(parsed.traces)) {
        return parsed as Codemap;
      }
    } catch {
      continue;
    }
  }
  return null;
}

async function submitQuery(question: string, options: QueryOptions, queryId: string): Promise<string> {
  const request: QueryRequest = {
    engine_id: ENGINE_MAP[options.mode],
    user_query: question,
    keywords: [],
    repo_names: options.repos,
    additional_context: options.context ?? "",
    query_id: queryId,
    use_notes: false,
    attached_context: [],
    generate_summary: options.summary,
  };

  try {
    await api("/ada/query", {
      method: "POST",
      body: JSON.stringify(request),
    });
    return queryId;
  } catch (error) {
    if (error instanceof DeepWikiError) {
      throw new DeepWikiError(error.message, {
        ...(error.details ?? {}),
        query_id: queryId,
      }, error.retryable);
    }
    throw error;
  }
}

async function getQuery(queryId: string): Promise<QueryResult> {
  return api<QueryResult>(`/ada/query/${queryId}`);
}

async function waitForQuery(queryId: string, tracker: ProgressTracker): Promise<QueryResult> {
  while (true) {
    let result: QueryResult;
    try {
      result = await getQuery(queryId);
    } catch (error) {
      if (error instanceof DeepWikiError && error.retryable) {
        await sleep(POLL_INTERVAL_MS);
        continue;
      }
      throw error;
    }
    const query = latestQuery(result);
    if (!query) {
      await sleep(POLL_INTERVAL_MS);
      continue;
    }

    tracker.processQueryState(query);

    const error = extractQueryError(result);
    if (error) {
      throw new DeepWikiError(error, { query_id: queryId });
    }

    if (query.state === "done") {
      tracker.markDone();
      return result;
    }

    await sleep(POLL_INTERVAL_MS);
  }
}

async function warmRepo(repo: string): Promise<Record<string, unknown>> {
  return api<Record<string, unknown>>(
    `/ada/warm_public_repo?repo_name=${encodeURIComponent(repo)}`,
    { method: "POST" },
  );
}

async function statusRepo(repo: string): Promise<Record<string, unknown>> {
  return api<Record<string, unknown>>(
    `/ada/public_repo_indexing_status?repo_name=${encodeURIComponent(repo)}`,
  );
}

function renderAnswer(result: QueryResult, queryId: string): void {
  const answer = extractAnswerText(result);
  if (answer !== "") {
    process.stdout.write(`${answer}\n`);
  }

  const sources = extractSourcePaths(result);
  if (sources.length > 0) {
    process.stdout.write("Sources:\n");
    for (const source of sources) {
      process.stdout.write(`- ${source}\n`);
    }
    process.stdout.write("\n");
  }

  if (queryId !== "") {
    process.stdout.write(`Query-ID: ${queryId}\n`);
  }

  const threadId = extractThreadId(result);
  if (threadId !== "") {
    process.stdout.write(`Message-ID: ${threadId}\n`);
  }
}

const TRACE_COLORS = [
  ["#e8f5e9", "#4caf50"],
  ["#e3f2fd", "#2196f3"],
  ["#fff3e0", "#ff9800"],
  ["#f3e5f5", "#9c27b0"],
  ["#fff8e1", "#ffc107"],
  ["#fce4ec", "#e91e63"],
  ["#e0f2f1", "#009688"],
  ["#fbe9e7", "#ff5722"],
] as const;

function sanitizeId(text: string): string {
  return text.replace(/[^a-zA-Z0-9]/g, "_");
}

function escapeLabel(text: string): string {
  return text.replace(/"/g, "&quot;").replace(/\n/g, " ");
}

function shortPath(path: string): string {
  const index = path.lastIndexOf("/");
  return index >= 0 ? path.slice(index + 1) : path;
}

function codemapToMermaid(codemap: Codemap): string {
  const lines: string[] = ["flowchart TB"];
  const { traces } = codemap;

  for (let i = 0; i < traces.length; i += 1) {
    const trace = traces[i];
    const subgroupId = sanitizeId(`trace_${trace.id}`);
    lines.push("");
    lines.push(`    subgraph ${subgroupId}["${trace.id}. ${escapeLabel(trace.title)}"]`);

    for (const location of trace.locations) {
      const locationId = sanitizeId(`loc_${location.id}`);
      const label = `${escapeLabel(location.title)}\\n${shortPath(location.path)}:${location.lineNumber}`;
      lines.push(`        ${locationId}["${label}"]`);
    }

    lines.push("    end");

    for (let index = 0; index < trace.locations.length - 1; index += 1) {
      const from = sanitizeId(`loc_${trace.locations[index].id}`);
      const to = sanitizeId(`loc_${trace.locations[index + 1].id}`);
      lines.push(`    ${from} --> ${to}`);
    }
  }

  for (let index = 0; index < traces.length - 1; index += 1) {
    const current = traces[index].locations;
    const next = traces[index + 1].locations;
    if (current.length === 0 || next.length === 0) continue;
    const from = sanitizeId(`loc_${current[current.length - 1].id}`);
    const to = sanitizeId(`loc_${next[0].id}`);
    lines.push(`    ${from} -.-> ${to}`);
  }

  lines.push("");
  for (let index = 0; index < traces.length; index += 1) {
    const subgroupId = sanitizeId(`trace_${traces[index].id}`);
    const [fill, stroke] = TRACE_COLORS[index % TRACE_COLORS.length];
    lines.push(`    style ${subgroupId} fill:${fill},stroke:${stroke},stroke-width:2px`);
  }

  return lines.join("\n");
}

function parseProgressMode(): ProgressMode {
  const mode = (process.env.DEEPWIKI_PROGRESS_MODE ?? "auto").toLowerCase();
  if (mode === "plain" || mode === "quiet" || mode === "auto") return mode;
  if (mode === "always") return "plain";
  if (mode === "never") return "quiet";
  return "auto";
}

function takeValue(args: string[], index: number, flag: string): string {
  const value = args[index + 1];
  if (!value || value.startsWith("-")) {
    fail(`${flag} requires a value`);
  }
  return value;
}

function buildQueryOptions(): QueryOptions {
  return {
    repos: [],
    mode: "deep",
    context: "",
    queryId: "",
    summary: true,
    mermaid: false,
    rawJson: false,
    sourcesOnly: false,
  };
}

function parseQueryArgs(args: string[]): { question: string; options: QueryOptions } {
  if (args.length === 0 || args[0] === "--help" || args[0] === "-h") usage(0);

  const question = args[0];
  const options = buildQueryOptions();

  for (let index = 1; index < args.length; index += 1) {
    const arg = args[index];
    switch (arg) {
      case "--mode":
      case "-m":
        options.mode = takeValue(args, index, arg) as Mode;
        index += 1;
        break;
      case "--context":
      case "-c":
        options.context = takeValue(args, index, arg);
        index += 1;
        break;
      case "--id":
        options.queryId = takeValue(args, index, arg);
        index += 1;
        break;
      case "--mermaid":
        options.mermaid = true;
        break;
      case "--sources-only":
        options.sourcesOnly = true;
        break;
      case "--json":
        options.rawJson = true;
        break;
      case "--no-summary":
        options.summary = false;
        break;
      case "--help":
      case "-h":
        usage(0);
        break;
      default:
        if (arg.startsWith("-")) {
          fail(`Unknown flag: ${arg}`);
        }
        options.repos.push(arg);
    }
  }

  if (options.repos.length === 0) {
    fail("At least one owner/repo is required.");
  }

  if (!(options.mode in ENGINE_MAP)) {
    fail(`Unsupported mode: ${options.mode}`);
  }

  return { question, options };
}

function parseStartArgs(args: string[]): { question: string; options: QueryOptions } {
  if (args.length === 0 || args[0] === "--help" || args[0] === "-h") usage(0);

  const question = args[0];
  const options = buildQueryOptions();
  options.rawJson = true;

  for (let index = 1; index < args.length; index += 1) {
    const arg = args[index];
    switch (arg) {
      case "--mode":
      case "-m":
        options.mode = takeValue(args, index, arg) as Mode;
        index += 1;
        break;
      case "--context":
      case "-c":
        options.context = takeValue(args, index, arg);
        index += 1;
        break;
      case "--id":
        options.queryId = takeValue(args, index, arg);
        index += 1;
        break;
      case "--no-summary":
        options.summary = false;
        break;
      case "--help":
      case "-h":
        usage(0);
        break;
      default:
        if (arg.startsWith("-")) {
          fail(`Unknown flag: ${arg}`);
        }
        options.repos.push(arg);
    }
  }

  if (options.repos.length === 0) {
    fail("At least one owner/repo is required.");
  }

  if (!(options.mode in ENGINE_MAP)) {
    fail(`Unsupported mode: ${options.mode}`);
  }

  return { question, options };
}

function parseWaitArgs(args: string[]): { queryId: string; options: QueryOptions } {
  if (args.length === 0 || args[0] === "--help" || args[0] === "-h") usage(0);

  const queryId = args[0];
  const options = buildQueryOptions();
  options.queryId = queryId;

  for (let index = 1; index < args.length; index += 1) {
    const arg = args[index];
    switch (arg) {
      case "--mode":
      case "-m":
        options.mode = takeValue(args, index, arg) as Mode;
        index += 1;
        break;
      case "--mermaid":
        options.mermaid = true;
        break;
      case "--sources-only":
        options.sourcesOnly = true;
        break;
      case "--json":
        options.rawJson = true;
        break;
      case "--help":
      case "-h":
        usage(0);
        break;
      default:
        fail(`Unknown flag: ${arg}`);
    }
  }

  if (!(options.mode in ENGINE_MAP)) {
    fail(`Unsupported mode: ${options.mode}`);
  }

  return { queryId, options };
}

function parseStatusArgs(args: string[]): StatusOptions {
  if (args.length === 0 || args[0] === "--help" || args[0] === "-h") usage(0);

  let repo = "";
  let warm = false;

  for (const arg of args) {
    if (arg === "--warm") {
      warm = true;
      continue;
    }
    if (arg === "--help" || arg === "-h") usage(0);
    if (arg.startsWith("-")) fail(`Unknown flag: ${arg}`);
    if (repo !== "") fail("status accepts exactly one owner/repo.");
    repo = arg;
  }

  if (repo === "") fail("owner/repo is required.");
  return { repo, warm };
}

async function startQuery(question: string, options: QueryOptions): Promise<string> {
  const queryId = options.queryId || randomUUID();
  return submitQuery(question, options, queryId);
}

function renderCompletedQuery(result: QueryResult, options: QueryOptions): void {
  if (options.rawJson) {
    printJson(result);
    return;
  }

  if (options.mermaid && options.mode === "codemap") {
    const codemap = extractCodemap(result);
    if (!codemap) {
      throw new DeepWikiError("Codemap response was missing from completed query.", {
        query_id: options.queryId ?? "",
      });
    }
    process.stdout.write(`${codemapToMermaid(codemap)}\n`);
    return;
  }

  if (options.sourcesOnly) {
    for (const source of extractSourcePaths(result)) {
      process.stdout.write(`${source}\n`);
    }
    return;
  }

  renderAnswer(result, options.queryId ?? "");
}

async function runQuery(question: string, options: QueryOptions): Promise<void> {
  const queryId = options.queryId || randomUUID();
  const tracker = new ProgressTracker(parseProgressMode());

  try {
    tracker.startQuery(queryId);
    options.queryId = await submitQuery(question, options, queryId);
    const result = await waitForQuery(queryId, tracker);
    renderCompletedQuery(result, options);
  } finally {
    tracker.stop();
  }
}

async function runStart(question: string, options: QueryOptions): Promise<void> {
  const queryId = await startQuery(question, options);
  printJson({
    query_id: queryId,
    mode: options.mode,
    repo_names: options.repos,
    additional_context: options.context ?? "",
    generate_summary: options.summary,
  });
}

async function runWait(queryId: string, options: QueryOptions): Promise<void> {
  const tracker = new ProgressTracker(parseProgressMode());
  try {
    tracker.startQuery(queryId);
    const result = await waitForQuery(queryId, tracker);
    options.queryId = queryId;
    renderCompletedQuery(result, options);
  } finally {
    tracker.stop();
  }
}

async function runStatus(options: StatusOptions): Promise<void> {
  if (options.warm) {
    process.stderr.write(`Warming ${options.repo}...\n`);
    await warmRepo(options.repo);
  }

  const result = await statusRepo(options.repo);
  const payload = { repo_name: options.repo, ...(result as object) };
  printJson(payload);

  const status = result as { indexed?: boolean; status?: string };
  if (!(status.indexed === true || status.status === "completed" || status.status === "indexed")) {
    process.exit(1);
  }
}

async function runWarm(repo: string): Promise<void> {
  const result = await warmRepo(repo);
  printJson({ repo_name: repo, ...(result as object) });
}

async function runGet(queryId: string): Promise<void> {
  printJson(await getQuery(queryId));
}

async function runList(search: string): Promise<void> {
  printJson(await api(`/ada/list_public_indexes?search_repo=${encodeURIComponent(search)}`));
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const command = args[0];
  if (!command || command === "--help" || command === "-h") usage(0);

  try {
    switch (command) {
      case "query": {
        const { question, options } = parseQueryArgs(args.slice(1));
        await runQuery(question, options);
        break;
      }
      case "start": {
        const { question, options } = parseStartArgs(args.slice(1));
        await runStart(question, options);
        break;
      }
      case "wait": {
        const { queryId, options } = parseWaitArgs(args.slice(1));
        await runWait(queryId, options);
        break;
      }
      case "status": {
        await runStatus(parseStatusArgs(args.slice(1)));
        break;
      }
      case "warm": {
        const repo = args[1];
        if (!repo) fail("owner/repo is required.");
        await runWarm(repo);
        break;
      }
      case "get": {
        const queryId = args[1];
        if (!queryId) fail("query id is required.");
        await runGet(queryId);
        break;
      }
      case "list": {
        const search = args[1];
        if (!search) fail("search term is required.");
        await runList(search);
        break;
      }
      default:
        usage();
    }
  } catch (error) {
    if (error instanceof DeepWikiError) {
      fail(error.message, error.details);
    }
    const message = error instanceof Error ? error.message : String(error);
    fail(message);
  }
}

await main();
