#!/usr/bin/env node

import fs from 'node:fs';

const LINEAR_API_URL = process.env.LINEAR_API_URL || 'https://api.linear.app/graphql';

function usage() {
  console.error(
    'Usage: node scripts/workflow/migrate-github-project-to-linear.js --input <gh-project-items.json> [--dry-run] [--allow-existing]',
  );
}

function parseArgs(argv) {
  const options = new Map();
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith('--')) continue;
    const next = argv[index + 1];
    if (!next || next.startsWith('--')) {
      options.set(token.slice(2), 'true');
      continue;
    }
    options.set(token.slice(2), next);
    index += 1;
  }
  return options;
}

function requiredEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function readInput(inputPath) {
  const raw = JSON.parse(fs.readFileSync(inputPath, 'utf8'));
  if (!Array.isArray(raw.items)) {
    throw new Error(`Expected ${inputPath} to contain an .items array from gh project item-list.`);
  }
  return raw.items;
}

async function linearGraphql(query, variables = {}) {
  const token = requiredEnv('LINEAR_API_KEY');
  const response = await fetch(LINEAR_API_URL, {
    method: 'POST',
    headers: {
      Authorization: token,
      'Content-Type': 'application/json',
      'User-Agent': 'nanoclaw-github-project-migration',
    },
    body: JSON.stringify({ query, variables }),
  });

  const payload = await response.json();
  if (!response.ok || payload.errors?.length) {
    throw new Error(
      `Linear GraphQL request failed: ${response.status} ${response.statusText}\n${JSON.stringify(
        payload.errors || payload,
        null,
        2,
      )}`,
    );
  }

  return payload.data;
}

async function loadContext(projectId, teamId) {
  const data = await linearGraphql(
    `query($projectId:String!,$teamId:String!){
      project(id:$projectId){
        id
        name
        issues(first:100){
          nodes { id identifier title }
        }
      }
      team(id:$teamId){
        id
        name
        states{
          nodes { id name type }
        }
      }
    }`,
    { projectId, teamId },
  );

  if (!data.project) {
    throw new Error(`Linear project not found: ${projectId}`);
  }
  if (!data.team) {
    throw new Error(`Linear team not found: ${teamId}`);
  }
  return data;
}

function buildStateMap(states) {
  const byName = new Map(states.map((state) => [String(state.name || '').toLowerCase(), state]));

  const mappings = {
    Backlog: byName.get('backlog'),
    Done: byName.get('done'),
    Ready: byName.get('todo') || byName.get('backlog'),
    Review: byName.get('in review'),
    'In Progress': byName.get('in progress'),
    Blocked: byName.get('canceled'),
  };

  for (const [status, state] of Object.entries(mappings)) {
    if (!state) {
      throw new Error(`Missing Linear state mapping for legacy status "${status}".`);
    }
  }

  return mappings;
}

function legacyStatusToLinearStateId(status, stateMap) {
  const normalized = String(status || '').trim();
  const state = stateMap[normalized];
  if (!state) {
    throw new Error(`No Linear state mapping for legacy status: ${normalized}`);
  }
  return state.id;
}

function buildDescription(item) {
  const body = String(item?.content?.body || '').trim();
  const issueUrl = item?.content?.url || '';
  const issueNumber = item?.content?.number || '';
  const legacyStatus = item?.status || '';
  const legacySource = item?.source || '';

  const header = [
    '## Migration Metadata',
    `- Legacy GitHub Issue: ${issueNumber ? `#${issueNumber}` : 'unknown'}`,
    `- Legacy GitHub URL: ${issueUrl || 'unknown'}`,
    `- Legacy Project Status: ${legacyStatus || 'unknown'}`,
    `- Legacy Source: ${legacySource || 'unknown'}`,
    '',
    '---',
    '',
  ].join('\n');

  return body ? `${header}${body}` : header.trim();
}

async function createIssue({ teamId, projectId, stateId, item, dryRun }) {
  const input = {
    teamId,
    projectId,
    stateId,
    title: item.title || item.content?.title || `Migrated issue ${item.content?.number || ''}`.trim(),
    description: buildDescription(item),
  };

  if (dryRun) {
    return {
      dryRun: true,
      title: input.title,
      stateId,
      githubIssue: item.content?.url || null,
    };
  }

  const data = await linearGraphql(
    `mutation($input:IssueCreateInput!){
      issueCreate(input:$input){
        success
        issue{
          id
          identifier
          title
          url
          state { name }
          project { name }
        }
      }
    }`,
    { input },
  );

  if (!data.issueCreate?.success || !data.issueCreate?.issue) {
    throw new Error(`Linear issue creation failed for "${input.title}".`);
  }
  return data.issueCreate.issue;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const inputPath = options.get('input');
  const dryRun = options.has('dry-run');
  const allowExisting = options.has('allow-existing');

  if (!inputPath) {
    usage();
    process.exit(1);
  }

  const teamId = requiredEnv('NANOCLAW_LINEAR_TEAM_ID');
  const projectId = requiredEnv('NANOCLAW_LINEAR_PROJECT_ID');
  const items = readInput(inputPath);
  const context = await loadContext(projectId, teamId);

  if (!allowExisting && context.project.issues.nodes.length > 0) {
    throw new Error(
      `Linear project ${context.project.name} is not empty (${context.project.issues.nodes.length} issues). Refusing to import.`,
    );
  }

  const stateMap = buildStateMap(context.team.states.nodes);
  const summary = [];

  for (const item of items) {
    const stateId = legacyStatusToLinearStateId(item.status, stateMap);
    const created = await createIssue({
      teamId,
      projectId,
      stateId,
      item,
      dryRun,
    });

    summary.push({
      githubIssue: item.content?.number || null,
      title: item.title,
      legacyStatus: item.status,
      linear: created,
    });
  }

  process.stdout.write(`${JSON.stringify({ dryRun, imported: summary.length, items: summary }, null, 2)}\n`);
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
