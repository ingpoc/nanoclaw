/**
 * NAN-54 live acceptance:
 * Andy bootstrap skill -> AND Linear issue -> Jarvis worker -> Linear comment + Notion memory.
 *
 * Run with:
 *   node --experimental-transform-types scripts/test-andy-aadharchain-pipeline-e2e.ts
 */
import Database from 'better-sqlite3';

import {
  parseDispatchPayload,
  validateCompletionContract,
  validateDispatchPayload,
} from '../dist/dispatch-validator.js';
import { readEnvFile } from '../dist/env.js';
import { linearGraphql } from '../dist/symphony-linear.js';
import { notionRequest, notionSearch } from '../dist/symphony-notion.js';

type MessageRow = {
  id: string;
  content: string;
  timestamp: string;
};

type AndyRequestRow = {
  request_id: string;
  state: string;
  worker_run_id: string | null;
  updated_at: string;
};

type WorkerRunRow = {
  run_id: string;
  request_id: string | null;
  status: string;
  phase: string | null;
  dispatch_payload: string | null;
  branch_name: string | null;
  commit_sha: string | null;
  files_changed: string | null;
  test_summary: string | null;
  risk_summary: string | null;
  completed_at: string | null;
};

type LinearIssueVerification = {
  id: string;
  identifier: string;
  title: string;
  team: { key: string } | null;
  project: { name: string; url: string } | null;
  comments: { nodes: Array<{ body: string }> } | null;
};

const DEFAULT_DB_PATH = 'store/messages.db';
const PROJECT_NAME = 'Aadharchain';
const PROJECT_KEY = 'AND-aadharchain';
const GITHUB_REPO = 'openclaw-gurusharan/aadhaar-chain';
const NOTION_HTTP_PORT = 7802;
const LINEAR_HTTP_PORT = 7803;
const POLL_MS = 500;
const REQUEST_ACK_TIMEOUT_MS = 30_000;
const REQUEST_LINK_TIMEOUT_MS = 180_000;
const RUN_TERMINAL_TIMEOUT_MS = 20 * 60_000;
const TIMESTAMP_FLOOR_TOLERANCE_MS = 1_000;
const RUN_TERMINAL_OK = new Set(['review_requested', 'done']);
const RUN_TERMINAL_FAIL = new Set(['failed', 'failed_contract']);

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function nowIso(): string {
  return new Date().toISOString();
}

function getRequiredEnv(name: string): string {
  return process.env[name] || readEnvFile([name])[name] || '';
}

function getAndyChatJid(db: Database.Database): string {
  const row = db.prepare(
    `SELECT jid
     FROM registered_groups
     WHERE folder = 'andy-developer'
     LIMIT 1`,
  ).get() as { jid: string } | undefined;
  if (!row?.jid) {
    throw new Error('andy-developer is not registered in registered_groups');
  }
  return row.jid;
}

function upsertChat(db: Database.Database, chatJid: string): void {
  db.prepare(
    `INSERT INTO chats (jid, name, last_message_time, channel, is_group)
     VALUES (?, ?, ?, ?, ?)
     ON CONFLICT(jid) DO UPDATE SET
       name = excluded.name,
       last_message_time = excluded.last_message_time,
       channel = excluded.channel,
       is_group = excluded.is_group`,
  ).run(chatJid, 'Andy-Developer', nowIso(), 'whatsapp', 1);
}

function getBotIds(db: Database.Database, chatJid: string): Set<string> {
  const rows = db.prepare(
    `SELECT id FROM messages WHERE chat_jid = ? AND is_bot_message = 1`,
  ).all(chatJid) as Array<{ id: string }>;
  return new Set(rows.map((row) => row.id));
}

function insertUserMessage(
  db: Database.Database,
  chatJid: string,
  messageId: string,
  content: string,
): string {
  const timestamp = nowIso();
  db.prepare(
    `INSERT OR REPLACE INTO messages (
      id, chat_jid, sender, sender_name, content, timestamp, is_from_me, is_bot_message
    ) VALUES (?, ?, ?, ?, ?, ?, 1, 0)`,
  ).run(messageId, chatJid, 'uat-user@nanoclaw', 'UAT User', content, timestamp);
  db.prepare(`UPDATE chats SET last_message_time = ? WHERE jid = ?`).run(timestamp, chatJid);
  return timestamp;
}

async function waitForAndyRequestByMessageId(
  db: Database.Database,
  messageId: string,
  timeoutMs: number,
): Promise<AndyRequestRow | null> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const row = db.prepare(
      `SELECT request_id, state, worker_run_id, updated_at
       FROM andy_requests
       WHERE user_message_id = ?`,
    ).get(messageId) as AndyRequestRow | undefined;
    if (row) return row;
    await sleep(POLL_MS);
  }
  return null;
}

function getAndyRequestById(db: Database.Database, requestId: string): AndyRequestRow | null {
  const row = db.prepare(
    `SELECT request_id, state, worker_run_id, updated_at
     FROM andy_requests
     WHERE request_id = ?`,
  ).get(requestId) as AndyRequestRow | undefined;
  return row || null;
}

async function waitForBotMessage(
  db: Database.Database,
  chatJid: string,
  baselineBotIds: Set<string>,
  minTsMs: number,
  timeoutMs: number,
): Promise<MessageRow | null> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const rows = db.prepare(
      `SELECT id, content, timestamp
       FROM messages
       WHERE chat_jid = ? AND is_bot_message = 1
       ORDER BY timestamp ASC, id ASC`,
    ).all(chatJid) as MessageRow[];

    for (const row of rows) {
      if (baselineBotIds.has(row.id)) continue;
      const rowMs = Date.parse(row.timestamp);
      if (!Number.isFinite(rowMs) || rowMs + TIMESTAMP_FLOOR_TOLERANCE_MS < minTsMs) continue;
      baselineBotIds.add(row.id);
      return row;
    }

    await sleep(POLL_MS);
  }
  return null;
}

async function waitForRunLinkOrDispatchBlock(
  db: Database.Database,
  chatJid: string,
  requestId: string,
  baselineBotIds: Set<string>,
  minTsMs: number,
  timeoutMs: number,
): Promise<{ kind: 'linked'; runId: string } | { kind: 'dispatch_blocked'; detail: string } | { kind: 'timeout' }> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const request = getAndyRequestById(db, requestId);
    if (request?.worker_run_id) {
      return { kind: 'linked', runId: request.worker_run_id };
    }

    const reply = await waitForBotMessage(db, chatJid, baselineBotIds, minTsMs, POLL_MS);
    if (reply && /dispatch blocked by validator/i.test(reply.content)) {
      return {
        kind: 'dispatch_blocked',
        detail: reply.content.replace(/\s+/g, ' ').slice(0, 260),
      };
    }
  }
  return { kind: 'timeout' };
}

function getWorkerRun(db: Database.Database, runId: string): WorkerRunRow | null {
  const row = db.prepare(
    `SELECT run_id, request_id, status, phase, dispatch_payload, branch_name, commit_sha, files_changed,
            test_summary, risk_summary, completed_at
     FROM worker_runs
     WHERE run_id = ?`,
  ).get(runId) as WorkerRunRow | undefined;
  return row || null;
}

async function waitForWorkerRunTerminal(
  db: Database.Database,
  runId: string,
  timeoutMs: number,
): Promise<WorkerRunRow | null> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const row = getWorkerRun(db, runId);
    if (row && (RUN_TERMINAL_OK.has(row.status) || RUN_TERMINAL_FAIL.has(row.status))) {
      return row;
    }
    await sleep(POLL_MS);
  }
  return null;
}

function cleanupRequest(db: Database.Database, messageId: string, requestId: string | null): void {
  if (!requestId) return;
  db.prepare(
    `UPDATE andy_requests
     SET state = 'cancelled',
         last_status_text = ?,
         updated_at = ?,
         closed_at = COALESCE(closed_at, ?)
     WHERE request_id = ?
       AND user_message_id = ?
       AND state NOT IN ('completed', 'failed', 'cancelled')`,
  ).run(
    `Closed after NAN-54 Aadharchain pipeline E2E cleanup (${messageId})`,
    nowIso(),
    nowIso(),
    requestId,
    messageId,
  );
}

async function assertHealth(port: number, label: string): Promise<void> {
  const response = await fetch(`http://127.0.0.1:${port}/health`);
  if (!response.ok) {
    throw new Error(`${label} not reachable on port ${port}: HTTP ${response.status}`);
  }
  const payload = (await response.json()) as { status?: string };
  if (payload.status !== 'ok') {
    throw new Error(`${label} health check returned ${JSON.stringify(payload)}`);
  }
  console.log(`[preflight] ${label} (port ${port}): PASS`);
}

function buildPrompt(token: string): string {
  return [
    '@Andy Run the NAN-54 Aadharchain full pipeline probe using the real NanoClaw flow, not Symphony.',
    `GitHub repo: ${GITHUB_REPO}.`,
    `Project name: ${PROJECT_NAME}.`,
    `Project key: ${PROJECT_KEY}.`,
    '',
    `If the project is missing from the AND team or missing its Notion root page/memory scope, load /project-bootstrap and bootstrap it for the existing repo ${GITHUB_REPO}.`,
    `Then create one AND-team Linear issue titled "[Delivery] NAN-54 pipeline probe ${token}" under the ${PROJECT_NAME} project.`,
    '',
    'After the issue exists, dispatch jarvis-worker-1 with strict valid worker dispatch JSON.',
    'The worker task must stay small and local:',
    `1. Create docs/nanoclaw/pipeline-${token}.md inside the aadhaar-chain workspace`,
    `2. Add a Linear comment on the created AND issue containing the exact token ${token}`,
    `3. Write one Notion memory entry for project_key ${PROJECT_KEY} containing the exact token ${token} and the issue identifier`,
    '4. Return a valid completion contract with run_id, branch, commit_sha, files_changed, test_result, risk, pr_skipped_reason',
    '',
    'Do not open a PR or push to main. Use the normal Andy -> worker flow and report exact blockers if bootstrap or tool access fails.',
  ].join('\n');
}

function validateWorkerCompletion(row: WorkerRunRow): void {
  const filesChanged = row.files_changed ? (JSON.parse(row.files_changed) as string[]) : [];
  const completion = {
    run_id: row.run_id,
    branch: row.branch_name || '',
    commit_sha: row.commit_sha || '',
    files_changed: filesChanged,
    test_result: row.test_summary || '',
    risk: row.risk_summary || '',
    pr_skipped_reason: 'local-only NAN-54 pipeline probe',
  };
  const result = validateCompletionContract(completion, { expectedRunId: row.run_id });
  if (!result.valid) {
    throw new Error(`completion validation failed: ${result.missing.join(', ')}`);
  }
}

async function verifyLinearState(token: string): Promise<{
  viewerName: string;
  issue: LinearIssueVerification;
}> {
  const data = await linearGraphql<{
    viewer: { name: string | null };
    issues: { nodes: LinearIssueVerification[] };
  }>(
    `
      query VerifyNan54($token: String!) {
        viewer { name }
        issues(
          first: 10
          filter: {
            team: { key: { eq: "AND" } }
            title: { containsIgnoreCase: $token }
          }
        ) {
          nodes {
            id
            identifier
            title
            team { key }
            project { name url }
            comments(first: 20) {
              nodes { body }
            }
          }
        }
      }
    `,
    { token },
  );

  const issue = data.issues.nodes[0];
  if (!issue) {
    throw new Error(`no AND-team Linear issue found for token ${token}`);
  }
  if (!issue.identifier.startsWith('AND-')) {
    throw new Error(`expected AND-* issue, got ${issue.identifier}`);
  }
  if (issue.team?.key !== 'AND') {
    throw new Error(`expected AND team issue, got ${issue.team?.key || 'unknown'}`);
  }
  if (!issue.project?.name || issue.project.name.toLowerCase() !== PROJECT_NAME.toLowerCase()) {
    throw new Error(`expected project ${PROJECT_NAME}, got ${issue.project?.name || 'none'}`);
  }

  const matchingComment = issue.comments?.nodes.find((comment) => comment.body.includes(token));
  if (!matchingComment) {
    throw new Error(`no Linear comment containing token ${token} found on ${issue.identifier}`);
  }

  return {
    viewerName: data.viewer.name || 'unknown',
    issue,
  };
}

async function verifyNotionState(token: string): Promise<number> {
  const databaseId = getRequiredEnv('NOTION_AGENT_MEMORY_DATABASE_ID');
  if (!databaseId) {
    throw new Error('Missing NOTION_AGENT_MEMORY_DATABASE_ID env var.');
  }

  const data = await notionRequest<{ results: Array<{ id: string }> }>(
    'POST',
    `/databases/${databaseId}/query`,
    {
      filter: {
        and: [
          { property: 'ProjectKey', rich_text: { contains: PROJECT_KEY } },
          { property: 'Content', rich_text: { contains: token } },
        ],
      },
      page_size: 20,
    },
  );
  return data.results.length;
}

async function verifyNotionProjectPage(): Promise<void> {
  const pages = await notionSearch(PROJECT_NAME, 5);
  const page = pages.find((entry) => entry.title.toLowerCase().includes(PROJECT_NAME.toLowerCase()));
  if (!page) {
    throw new Error(`no Notion page found for project ${PROJECT_NAME}`);
  }
}

async function main(): Promise<void> {
  const startedAt = Date.now();
  const dbPath = process.env.DB_PATH || DEFAULT_DB_PATH;
  const db = new Database(dbPath, { readonly: false });
  const token = `${Date.now()}-${Math.random().toString(36).slice(2, 7)}`;
  const messageId = `uat-nan54-${token}`;
  let requestId: string | null = null;

  try {
    console.log('=== NAN-54 Aadharchain Pipeline E2E ===');
    console.log(`db=${dbPath}`);
    console.log(`token=${token}`);

    await assertHealth(NOTION_HTTP_PORT, 'notion-mcp-http');
    await assertHealth(LINEAR_HTTP_PORT, 'linear-mcp-http');

    const chatJid = getAndyChatJid(db);
    upsertChat(db, chatJid);
    const baselineBotIds = getBotIds(db, chatJid);
    const sentAt = insertUserMessage(db, chatJid, messageId, buildPrompt(token));
    const sentMs = Date.parse(sentAt);

    const initialReply = await waitForBotMessage(
      db,
      chatJid,
      baselineBotIds,
      sentMs,
      REQUEST_ACK_TIMEOUT_MS,
    );
    if (!initialReply) {
      throw new Error(`Andy did not acknowledge the probe within ${REQUEST_ACK_TIMEOUT_MS}ms`);
    }

    const request = await waitForAndyRequestByMessageId(db, messageId, REQUEST_ACK_TIMEOUT_MS);
    if (!request) {
      throw new Error(
        `andy_request row was not created for the NAN-54 probe; initial reply was: ${initialReply.content.replace(/\s+/g, ' ').slice(0, 220)}`,
      );
    }
    requestId = request.request_id;

    const link = await waitForRunLinkOrDispatchBlock(
      db,
      chatJid,
      request.request_id,
      baselineBotIds,
      sentMs,
      REQUEST_LINK_TIMEOUT_MS,
    );
    if (link.kind === 'dispatch_blocked') {
      throw new Error(`dispatch blocked by validator: ${link.detail}`);
    }
    if (link.kind === 'timeout') {
      throw new Error(`worker run was not linked within ${REQUEST_LINK_TIMEOUT_MS}ms`);
    }

    const linkedRun = getWorkerRun(db, link.runId);
    if (!linkedRun?.dispatch_payload) {
      throw new Error(`worker run ${link.runId} is missing dispatch_payload`);
    }
    const dispatch = parseDispatchPayload(linkedRun.dispatch_payload);
    if (!dispatch) {
      throw new Error(`worker run ${link.runId} dispatch payload could not be parsed`);
    }
    const dispatchCheck = validateDispatchPayload(dispatch);
    if (!dispatchCheck.valid) {
      throw new Error(`dispatch validation failed: ${dispatchCheck.errors.join('; ')}`);
    }
    console.log('[dispatch] validation: PASS');

    const terminal = await waitForWorkerRunTerminal(db, link.runId, RUN_TERMINAL_TIMEOUT_MS);
    if (!terminal) {
      throw new Error(`worker run ${link.runId} did not reach terminal status within ${RUN_TERMINAL_TIMEOUT_MS}ms`);
    }
    if (RUN_TERMINAL_FAIL.has(terminal.status)) {
      throw new Error(`worker run ${link.runId} failed with status ${terminal.status}`);
    }

    validateWorkerCompletion(terminal);
    console.log('[worker] completion contract: PASS');

    const { viewerName, issue } = await verifyLinearState(token);
    console.log(`[andy] issue in andyworkspace team: PASS (${issue.identifier})`);
    console.log(`[andy] Aadharchain project in andyworkspace: PASS`);
    console.log(`[verify] Linear comment on ${issue.identifier}: PASS`);

    await verifyNotionProjectPage();
    const notionMemoryCount = await verifyNotionState(token);
    if (notionMemoryCount < 1) {
      throw new Error(`expected at least one Notion memory entry containing token ${token}`);
    }
    console.log('[verify] Notion memory write: PASS');
    console.log(`[result] notion_memory_count=${notionMemoryCount}`);
    console.log(`[result] linear_viewer_name=${viewerName}`);
    console.log(`PASS in ${Math.round((Date.now() - startedAt) / 1000)}s`);
  } finally {
    cleanupRequest(db, messageId, requestId);
    db.close();
  }
}

main().catch((err) => {
  console.error('FAIL');
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
});
