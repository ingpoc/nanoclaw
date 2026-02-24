import fs from 'fs';
import path from 'path';

import {
  ASSISTANT_NAME,
  DATA_DIR,
  IDLE_TIMEOUT,
  MAIN_GROUP_FOLDER,
  POLL_INTERVAL,
  TRIGGER_PATTERN,
} from './config.js';
import { WhatsAppChannel } from './channels/whatsapp.js';
import {
  ContainerOutput,
  runContainerAgent,
  writeGroupsSnapshot,
  writeTasksSnapshot,
} from './container-runner.js';
import { cleanupOrphans, ensureContainerRuntimeRunning } from './container-runtime.js';
import {
  getAllChats,
  getAllRegisteredGroups,
  getAllSessions,
  getAllTasks,
  getChatIngestSeqAtOrBeforeTimestamp,
  getIngestSeqAtOrBeforeTimestamp,
  getMessagesSince,
  getNewMessages,
  getTasksForGroup,
  getRouterState,
  initDatabase,
  setRegisteredGroup,
  setRouterState,
  setSession,
  storeChatMetadata,
  storeMessage,
  storeMessageDirect,
  insertWorkerRun,
  updateWorkerRunStatus,
  updateWorkerRunCompletion,
} from './db.js';
import {
  type DispatchPayload,
  requiresBrowserEvidence,
  parseDispatchPayload,
  validateDispatchPayload,
  parseCompletionContract,
  validateCompletionContract,
} from './dispatch-validator.js';
import { GroupQueue } from './group-queue.js';
import { startIpcWatcher } from './ipc.js';
import { findChannel, formatMessages, formatOutbound } from './router.js';
import { startSchedulerLoop } from './task-scheduler.js';
import { Channel, NewMessage, RegisteredGroup } from './types.js';
import { logger } from './logger.js';

// Re-export for backwards compatibility during refactor
export { escapeXml, formatMessages } from './router.js';

let lastIngestSeq = 0;
let sessions: Record<string, string> = {};
let registeredGroups: Record<string, RegisteredGroup> = {};
let lastAgentIngestSeq: Record<string, number> = {};
let messageLoopRunning = false;

let whatsapp: WhatsAppChannel;
const channels: Channel[] = [];
const queue = new GroupQueue();

function isInternalGroupJid(jid: string): boolean {
  return jid.endsWith('@nanoclaw');
}

function getGroupJidByFolder(folder: string): string | undefined {
  for (const [jid, group] of Object.entries(registeredGroups)) {
    if (group.folder === folder) return jid;
  }
  return undefined;
}

function resolveWorkerReplyJid(messages: NewMessage[]): string | undefined {
  const lastSender = messages[messages.length - 1]?.sender || '';
  const match = lastSender.match(/^([A-Za-z0-9._-]+)@nanoclaw$/);
  if (match) {
    const sourceJid = getGroupJidByFolder(match[1]);
    if (sourceJid) return sourceJid;
  }
  return getGroupJidByFolder('andy-developer');
}

async function dispatchMessageToJid(
  jid: string,
  text: string,
  sourceGroup: string,
): Promise<void> {
  if (isInternalGroupJid(jid)) {
    const targetGroup = registeredGroups[jid];
    if (!targetGroup) {
      throw new Error(`Unknown internal group JID: ${jid}`);
    }
    const timestamp = new Date().toISOString();
    const id = `ipc-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    storeChatMetadata(jid, timestamp, targetGroup.name, 'nanoclaw', true);
    storeMessageDirect({
      id,
      chat_jid: jid,
      sender: `${sourceGroup}@nanoclaw`,
      sender_name: sourceGroup,
      content: text,
      timestamp,
      is_from_me: false,
      is_bot_message: false,
    });
    logger.info({ jid, sourceGroup }, 'Internal message queued');
    return;
  }

  const channel = findChannel(channels, jid);
  if (!channel) {
    throw new Error(`No channel for JID: ${jid}`);
  }
  await channel.sendMessage(jid, text);
}

function loadState(): void {
  const lastIngest = parseInt(getRouterState('last_ingest_seq') || '0', 10);
  if (Number.isFinite(lastIngest) && lastIngest > 0) {
    lastIngestSeq = lastIngest;
  } else {
    const lastTimestamp = getRouterState('last_timestamp') || '';
    lastIngestSeq = getIngestSeqAtOrBeforeTimestamp(lastTimestamp);
  }

  const agentSeq = getRouterState('last_agent_ingest_seq');
  try {
    if (agentSeq) {
      const parsed = JSON.parse(agentSeq) as Record<string, unknown>;
      const normalized: Record<string, number> = {};
      for (const [chatJid, value] of Object.entries(parsed)) {
        const seq = typeof value === 'number' ? value : parseInt(String(value), 10);
        if (Number.isFinite(seq) && seq > 0) normalized[chatJid] = seq;
      }
      lastAgentIngestSeq = normalized;
    } else {
      const legacyAgentTs = getRouterState('last_agent_timestamp');
      const parsedLegacy = legacyAgentTs
        ? (JSON.parse(legacyAgentTs) as Record<string, string>)
        : {};
      const migrated: Record<string, number> = {};
      for (const [chatJid, timestamp] of Object.entries(parsedLegacy)) {
        migrated[chatJid] = getChatIngestSeqAtOrBeforeTimestamp(chatJid, timestamp);
      }
      lastAgentIngestSeq = migrated;
    }
  } catch {
    logger.warn('Corrupted last_agent_ingest_seq in DB, resetting');
    lastAgentIngestSeq = {};
  }
  sessions = getAllSessions();
  registeredGroups = getAllRegisteredGroups();
  saveState();
  logger.info(
    { groupCount: Object.keys(registeredGroups).length },
    'State loaded',
  );
}

function saveState(): void {
  setRouterState('last_ingest_seq', String(lastIngestSeq));
  setRouterState(
    'last_agent_ingest_seq',
    JSON.stringify(lastAgentIngestSeq),
  );
}

function registerGroup(jid: string, group: RegisteredGroup): void {
  registeredGroups[jid] = group;
  setRegisteredGroup(jid, group);

  // Create group folder
  const groupDir = path.join(DATA_DIR, '..', 'groups', group.folder);
  fs.mkdirSync(path.join(groupDir, 'logs'), { recursive: true });

  logger.info(
    { jid, name: group.name, folder: group.folder },
    'Group registered',
  );
}

/**
 * Get available groups list for the agent.
 * Returns groups ordered by most recent activity.
 */
export function getAvailableGroups(): import('./container-runner.js').AvailableGroup[] {
  const chats = getAllChats();
  const registeredJids = new Set(Object.keys(registeredGroups));
  const groups = chats
    .filter((c) => c.jid !== '__group_sync__' && c.is_group)
    .map((c) => ({
      jid: c.jid,
      name: c.name,
      lastActivity: c.last_message_time,
      isRegistered: registeredJids.has(c.jid),
    }));

  const seen = new Set(groups.map((g) => g.jid));
  for (const [jid, group] of Object.entries(registeredGroups)) {
    if (jid === '__group_sync__' || seen.has(jid)) continue;
    groups.push({
      jid,
      name: group.name,
      lastActivity: group.added_at,
      isRegistered: true,
    });
    seen.add(jid);
  }

  groups.sort((a, b) => b.lastActivity.localeCompare(a.lastActivity));
  return groups;
}

/** @internal - exported for testing */
export function _setRegisteredGroups(groups: Record<string, RegisteredGroup>): void {
  registeredGroups = groups;
}

function formatWorkerPrompt(payload: DispatchPayload): string {
  const acceptance = payload.acceptance_tests
    .map((item) => `- ${item}`)
    .join('\n');
  const required = payload.output_contract.required_fields
    .map((item) => `- ${item}`)
    .join('\n');

  return [
    `Run ID: ${payload.run_id}`,
    `Task Type: ${payload.task_type}`,
    `Repository: ${payload.repo}`,
    `Branch: ${payload.branch}`,
    'Task:',
    payload.input,
    'Acceptance Tests (all must pass):',
    acceptance,
    'Output Contract (MUST be wrapped in <completion> JSON):',
    required,
  ].join('\n\n');
}

/**
 * Process all pending messages for a group.
 * Called by the GroupQueue when it's this group's turn.
 */
async function processGroupMessages(chatJid: string): Promise<boolean> {
  const group = registeredGroups[chatJid];
  if (!group) return true;

  const isMainGroup = group.folder === MAIN_GROUP_FOLDER;

  const sinceIngestSeq = lastAgentIngestSeq[chatJid] || 0;
  const missedMessages = getMessagesSince(chatJid, sinceIngestSeq, ASSISTANT_NAME);

  if (missedMessages.length === 0) return true;

  // For non-main groups, check if trigger is required and present
  if (!isMainGroup && group.requiresTrigger !== false) {
    const hasTrigger = missedMessages.some((m) =>
      TRIGGER_PATTERN.test(m.content.trim()),
    );
    if (!hasTrigger) return true;
  }

  let prompt = formatMessages(missedMessages);

  // Advance cursor so the piping path in startMessageLoop won't re-fetch
  // these messages. Save the old cursor so we can roll back on error.
  const previousCursor = lastAgentIngestSeq[chatJid] || 0;
  lastAgentIngestSeq[chatJid] =
    missedMessages[missedMessages.length - 1].ingest_seq || previousCursor;
  saveState();

  logger.info(
    { group: group.name, messageCount: missedMessages.length },
    'Processing messages',
  );

  // For jarvis-worker groups: require a strict JSON dispatch payload.
  const isWorkerGroup = group.folder.startsWith('jarvis-worker');
  const replyJid = isWorkerGroup ? resolveWorkerReplyJid(missedMessages) : chatJid;

  const sendReply = async (text: string): Promise<boolean> => {
    if (!replyJid) {
      logger.warn({ group: group.name }, 'No reply JID available for message delivery');
      return false;
    }
    const replyChannel = findChannel(channels, replyJid);
    if (!replyChannel) {
      logger.warn({ group: group.name, replyJid }, 'No channel owns reply JID');
      return false;
    }
    await replyChannel.sendMessage(replyJid, text);
    return true;
  };

  if (!isWorkerGroup) {
    const replyChannel = replyJid ? findChannel(channels, replyJid) : undefined;
    if (!replyChannel || !replyJid) {
      logger.warn({ group: group.name, chatJid }, 'No channel owns JID, skipping messages');
      return true;
    }
  } else if (!replyJid) {
    logger.warn({ group: group.name, chatJid }, 'Worker group has no reply target; continuing without user notifications');
  }

  let runId: string | undefined;
  let dispatchPayload: DispatchPayload | null = null;
  if (isWorkerGroup) {
    const last = missedMessages[missedMessages.length - 1];

    dispatchPayload = parseDispatchPayload(last.content);
    if (!dispatchPayload) {
      logger.warn({ group: group.name }, 'Worker dispatch missing JSON payload');
      await sendReply(
        '⚠ Invalid dispatch payload: worker tasks must be a JSON object with run_id, task_type, input, repo, branch, acceptance_tests, output_contract',
      );
      return true;
    }

    const { valid, errors } = validateDispatchPayload(dispatchPayload);
    if (!valid) {
      logger.warn({ group: group.name, errors }, 'Invalid dispatch payload, rejecting');
      await sendReply(`⚠ Invalid dispatch payload: ${errors.join('; ')}`);
      return true;
    }

    runId = dispatchPayload.run_id;
    prompt = formatWorkerPrompt(dispatchPayload);

    const insertResult = insertWorkerRun(runId, group.folder);
    if (insertResult === 'duplicate') {
      logger.warn({ group: group.name, runId }, 'Duplicate run_id, skipping execution');
      return true;
    }
    logger.info({ group: group.name, runId, insertResult }, 'Worker run accepted');

    // Mark running before container starts
    updateWorkerRunStatus(runId, 'running');
  }

  // Track idle timer for closing stdin when agent is idle
  let idleTimer: ReturnType<typeof setTimeout> | null = null;

  const resetIdleTimer = () => {
    if (idleTimer) clearTimeout(idleTimer);
    idleTimer = setTimeout(() => {
      logger.debug({ group: group.name }, 'Idle timeout, closing container stdin');
      queue.closeStdin(chatJid);
    }, IDLE_TIMEOUT);
  };

  if (replyJid) {
    const replyChannel = findChannel(channels, replyJid);
    await replyChannel?.setTyping?.(replyJid, true);
  }
  let hadError = false;
  let outputSentToUser = false;
  let lastWorkerOutput = '';

  const output = await runAgent(group, prompt, chatJid, runId, async (result) => {
    // Streaming output callback — called for each agent result
    if (result.result) {
      const raw = typeof result.result === 'string' ? result.result : JSON.stringify(result.result);
      if (isWorkerGroup) lastWorkerOutput = raw;
      // Strip <internal>...</internal> blocks — agent uses these for internal reasoning
      const text = raw.replace(/<internal>[\s\S]*?<\/internal>/g, '').trim();
      logger.info({ group: group.name }, `Agent output: ${raw.slice(0, 200)}`);
      if (text) {
        // For worker groups, append usage stats to final response so Andy can see cost
        let finalText = text;
        if (isWorkerGroup && result.usage) {
          const u = result.usage;
          finalText += `\n\n<internal>run_id=${runId} tokens=${u.input_tokens}in/${u.output_tokens}out duration=${Math.round(u.duration_ms / 1000)}s rss=${u.peak_rss_mb}MB</internal>`;
        }
        if (await sendReply(finalText)) {
          outputSentToUser = true;
        }
      }
      // Only reset idle timer on actual results, not session-update markers (result: null)
      resetIdleTimer();
    }

    if (result.status === 'success') {
      queue.notifyIdle(chatJid);
    }

    if (result.status === 'error') {
      hadError = true;
    }
  });

  if (replyJid) {
    const replyChannel = findChannel(channels, replyJid);
    await replyChannel?.setTyping?.(replyJid, false);
  }
  if (idleTimer) clearTimeout(idleTimer);

  if (isWorkerGroup && runId) {
    if (output === 'error' || hadError) {
      updateWorkerRunStatus(runId, 'failed');
    } else {
      // Check completion contract from final worker output
      const contract = parseCompletionContract(lastWorkerOutput);
      const { valid, missing } = validateCompletionContract(contract, {
        expectedRunId: runId,
        requiredFields: dispatchPayload?.output_contract?.required_fields,
        browserEvidenceRequired: dispatchPayload
          ? requiresBrowserEvidence(dispatchPayload)
          : false,
      });
      if (valid && contract) {
        updateWorkerRunCompletion(runId, {
          branch_name: contract.branch,
          pr_url: contract.pr_url,
          commit_sha: contract.commit_sha,
          files_changed: contract.files_changed,
          test_summary: contract.test_result,
          risk_summary: contract.risk,
        });
        updateWorkerRunStatus(runId, 'review_requested');
        logger.info({ group: group.name, runId }, 'Contract satisfied → review_requested');
      } else {
        updateWorkerRunStatus(runId, 'failed_contract');
        logger.warn({ group: group.name, runId, missing }, 'Completion contract missing fields');
        await sendReply(`⚠ Completion contract missing: ${missing.join(', ')}`);
      }
    }
  }

  if (output === 'error' || hadError) {
    // If we already sent output to the user, don't roll back the cursor —
    // the user got their response and re-processing would send duplicates.
    if (outputSentToUser) {
      logger.warn({ group: group.name }, 'Agent error after output was sent, skipping cursor rollback to prevent duplicates');
      return true;
    }
    // Roll back cursor so retries can re-process these messages
    lastAgentIngestSeq[chatJid] = previousCursor;
    saveState();
    logger.warn({ group: group.name }, 'Agent error, rolled back message cursor for retry');
    return false;
  }

  return true;
}

async function runAgent(
  group: RegisteredGroup,
  prompt: string,
  chatJid: string,
  runId: string | undefined,
  onOutput?: (output: ContainerOutput) => Promise<void>,
): Promise<'success' | 'error'> {
  const isMain = group.folder === MAIN_GROUP_FOLDER;
  const sessionId = sessions[group.folder];

  // Update tasks snapshot for container to read (filtered by group)
  const tasks = isMain ? getAllTasks() : getTasksForGroup(group.folder);
  writeTasksSnapshot(
    group.folder,
    isMain,
    tasks.map((t) => ({
      id: t.id,
      groupFolder: t.group_folder,
      prompt: t.prompt,
      schedule_type: t.schedule_type,
      schedule_value: t.schedule_value,
      status: t.status,
      next_run: t.next_run,
    })),
  );

  // Update available groups snapshot (main group only can see all groups)
  const availableGroups = getAvailableGroups();
  writeGroupsSnapshot(
    group.folder,
    isMain,
    availableGroups,
    new Set(Object.keys(registeredGroups)),
  );

  // Wrap onOutput to track session ID from streamed results
  const wrappedOnOutput = onOutput
    ? async (output: ContainerOutput) => {
        if (output.newSessionId) {
          sessions[group.folder] = output.newSessionId;
          setSession(group.folder, output.newSessionId);
        }
        await onOutput(output);
      }
    : undefined;

  try {
    const output = await runContainerAgent(
      group,
      {
        prompt,
        sessionId,
        groupFolder: group.folder,
        chatJid,
        isMain,
        model: group.containerConfig?.model,
        runId,
      },
      (proc, containerName) => queue.registerProcess(chatJid, proc, containerName, group.folder),
      wrappedOnOutput,
    );

    if (output.newSessionId) {
      sessions[group.folder] = output.newSessionId;
      setSession(group.folder, output.newSessionId);
    }

    if (output.status === 'error') {
      logger.error(
        { group: group.name, error: output.error },
        'Container agent error',
      );
      return 'error';
    }

    return 'success';
  } catch (err) {
    logger.error({ group: group.name, err }, 'Agent error');
    return 'error';
  }
}

async function startMessageLoop(): Promise<void> {
  if (messageLoopRunning) {
    logger.debug('Message loop already running, skipping duplicate start');
    return;
  }
  messageLoopRunning = true;

  logger.info(`NanoClaw running (trigger: @${ASSISTANT_NAME})`);

  while (true) {
    try {
      const jids = Object.keys(registeredGroups);
      const { messages, newIngestSeq } = getNewMessages(jids, lastIngestSeq, ASSISTANT_NAME);

      if (messages.length > 0) {
        logger.info({ count: messages.length }, 'New messages');

        // Advance the "seen" cursor for all messages immediately
        lastIngestSeq = newIngestSeq;
        saveState();

        // Deduplicate by group
        const messagesByGroup = new Map<string, NewMessage[]>();
        for (const msg of messages) {
          const existing = messagesByGroup.get(msg.chat_jid);
          if (existing) {
            existing.push(msg);
          } else {
            messagesByGroup.set(msg.chat_jid, [msg]);
          }
        }

        for (const [chatJid, groupMessages] of messagesByGroup) {
          const group = registeredGroups[chatJid];
          if (!group) continue;

          const channel = findChannel(channels, chatJid);
          const isInternalChat = isInternalGroupJid(chatJid);
          if (!channel && !isInternalChat) {
            console.log(`Warning: no channel owns JID ${chatJid}, skipping messages`);
            continue;
          }

          const isMainGroup = group.folder === MAIN_GROUP_FOLDER;
          const needsTrigger = !isMainGroup && group.requiresTrigger !== false;

          // For non-main groups, only act on trigger messages.
          // Non-trigger messages accumulate in DB and get pulled as
          // context when a trigger eventually arrives.
          if (needsTrigger) {
            const hasTrigger = groupMessages.some((m) =>
              TRIGGER_PATTERN.test(m.content.trim()),
            );
            if (!hasTrigger) continue;
          }

          // Pull all messages since the per-chat ingest cursor so non-trigger
          // context that accumulated between triggers is included.
          const allPending = getMessagesSince(
            chatJid,
            lastAgentIngestSeq[chatJid] || 0,
            ASSISTANT_NAME,
          );
          const messagesToSend =
            allPending.length > 0 ? allPending : groupMessages;
          const formatted = formatMessages(messagesToSend);

          if (queue.sendMessage(chatJid, formatted)) {
            logger.debug(
              { chatJid, count: messagesToSend.length },
              'Piped messages to active container',
            );
            const lastSeq = messagesToSend[messagesToSend.length - 1].ingest_seq;
            lastAgentIngestSeq[chatJid] = lastSeq || (lastAgentIngestSeq[chatJid] || 0);
            saveState();
            // Show typing indicator while the container processes the piped message
            channel?.setTyping?.(chatJid, true)?.catch((err) =>
              logger.warn({ chatJid, err }, 'Failed to set typing indicator'),
            );
          } else {
            // No active container — enqueue for a new one
            queue.enqueueMessageCheck(chatJid);
          }
        }
      }
    } catch (err) {
      logger.error({ err }, 'Error in message loop');
    }
    await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL));
  }
}

/**
 * Startup recovery: check for unprocessed messages in registered groups.
 * Handles crash between advancing global ingest cursor and processing messages.
 */
function recoverPendingMessages(): void {
  for (const [chatJid, group] of Object.entries(registeredGroups)) {
    const sinceIngestSeq = lastAgentIngestSeq[chatJid] || 0;
    const pending = getMessagesSince(chatJid, sinceIngestSeq, ASSISTANT_NAME);
    if (pending.length > 0) {
      logger.info(
        { group: group.name, pendingCount: pending.length },
        'Recovery: found unprocessed messages',
      );
      queue.enqueueMessageCheck(chatJid);
    }
  }
}

function ensureContainerSystemRunning(): void {
  ensureContainerRuntimeRunning();
  cleanupOrphans();
}

async function main(): Promise<void> {
  ensureContainerSystemRunning();
  initDatabase();
  logger.info('Database initialized');
  loadState();

  // Graceful shutdown handlers
  const shutdown = async (signal: string) => {
    logger.info({ signal }, 'Shutdown signal received');
    await queue.shutdown(10000);
    for (const ch of channels) await ch.disconnect();
    process.exit(0);
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));

  // Channel callbacks (shared by all channels)
  const channelOpts = {
    onMessage: (_chatJid: string, msg: NewMessage) => storeMessage(msg),
    onChatMetadata: (chatJid: string, timestamp: string, name?: string, channel?: string, isGroup?: boolean) =>
      storeChatMetadata(chatJid, timestamp, name, channel, isGroup),
    registeredGroups: () => registeredGroups,
  };

  // Create and connect channels
  whatsapp = new WhatsAppChannel(channelOpts);
  channels.push(whatsapp);
  await whatsapp.connect();

  // Start subsystems (independently of connection handler)
  startSchedulerLoop({
    registeredGroups: () => registeredGroups,
    getSessions: () => sessions,
    queue,
    onProcess: (groupJid, proc, containerName, groupFolder) => queue.registerProcess(groupJid, proc, containerName, groupFolder),
    sendMessage: async (jid, rawText) => {
      const text = formatOutbound(rawText);
      if (!text) return;
      try {
        await dispatchMessageToJid(jid, text, 'scheduler');
      } catch (err) {
        logger.warn({ jid, err }, 'Failed to deliver scheduled-task message');
      }
    },
  });
  startIpcWatcher({
    sendMessage: async (jid, rawText, sourceGroup) => {
      const text = formatOutbound(rawText);
      if (!text) return;
      await dispatchMessageToJid(jid, text, sourceGroup);
    },
    registeredGroups: () => registeredGroups,
    registerGroup,
    syncGroupMetadata: (force) => whatsapp?.syncGroupMetadata(force) ?? Promise.resolve(),
    getAvailableGroups,
    writeGroupsSnapshot: (gf, im, ag, rj) => writeGroupsSnapshot(gf, im, ag, rj),
  });
  queue.setProcessMessagesFn(processGroupMessages);
  recoverPendingMessages();
  startMessageLoop().catch((err) => {
    logger.fatal({ err }, 'Message loop crashed unexpectedly');
    process.exit(1);
  });
}

// Guard: only run when executed directly, not when imported by tests
const isDirectRun =
  process.argv[1] &&
  new URL(import.meta.url).pathname === new URL(`file://${process.argv[1]}`).pathname;

if (isDirectRun) {
  main().catch((err) => {
    logger.error({ err }, 'Failed to start NanoClaw');
    process.exit(1);
  });
}
