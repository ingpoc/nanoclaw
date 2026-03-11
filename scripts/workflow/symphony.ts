#!/usr/bin/env -S npx tsx

import fs from 'node:fs';
import path from 'node:path';

import {
  ProjectRegistry,
  SymphonyIssueRouting,
  findProjectRegistryEntry,
  resolveSymphonyBackend,
  validateProjectRegistry,
} from '../../src/symphony-routing.js';

const ROOT_DIR = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..', '..');
const DEFAULT_REGISTRY_PATH =
  process.env.NANOCLAW_SYMPHONY_REGISTRY_PATH ||
  path.join(ROOT_DIR, '.nanoclaw', 'symphony', 'project-registry.cache.json');
const EXAMPLE_REGISTRY_PATH = path.join(
  ROOT_DIR,
  '.claude',
  'examples',
  'symphony-project-registry.example.json',
);

function usage(): never {
  console.error(`Usage:
  npx tsx scripts/workflow/symphony.ts validate-registry [--file <path>]
  npx tsx scripts/workflow/symphony.ts show-projects [--file <path>]
  npx tsx scripts/workflow/symphony.ts resolve-issue --issue-file <path> [--file <path>]
  npx tsx scripts/workflow/symphony.ts print-example
`);
  process.exit(1);
}

function optionValue(args: string[], name: string): string | null {
  const idx = args.indexOf(name);
  if (idx === -1) return null;
  return args[idx + 1] || null;
}

function readJsonFile<T>(filePath: string): T {
  return JSON.parse(fs.readFileSync(filePath, 'utf8')) as T;
}

function loadRegistry(filePath: string): ProjectRegistry {
  if (!fs.existsSync(filePath)) {
    throw new Error(
      `Missing Symphony registry cache: ${filePath}. Copy the example from ${EXAMPLE_REGISTRY_PATH} and replace it with your Notion-backed runtime cache.`,
    );
  }
  return validateProjectRegistry(readJsonFile(filePath));
}

function main() {
  const [, , command, ...rest] = process.argv;
  if (!command) usage();

  const filePath = optionValue(rest, '--file') || DEFAULT_REGISTRY_PATH;

  switch (command) {
    case 'validate-registry': {
      const registry = loadRegistry(filePath);
      console.log(
        JSON.stringify(
          {
            status: 'ok',
            file: filePath,
            projectCount: registry.projects.length,
            projectKeys: registry.projects.map((project) => project.projectKey),
          },
          null,
          2,
        ),
      );
      return;
    }
    case 'show-projects': {
      const registry = loadRegistry(filePath);
      console.log(
        JSON.stringify(
          registry.projects.map((project) => ({
            projectKey: project.projectKey,
            linearProject: project.linearProject,
            notionRoot: project.notionRoot,
            githubRepo: project.githubRepo,
            symphonyEnabled: project.symphonyEnabled,
            allowedBackends: project.allowedBackends,
            defaultBackend: project.defaultBackend,
            secretScope: project.secretScope,
            workspaceRoot: project.workspaceRoot,
            readyPolicy: project.readyPolicy,
          })),
          null,
          2,
        ),
      );
      return;
    }
    case 'resolve-issue': {
      const issueFile = optionValue(rest, '--issue-file');
      if (!issueFile) usage();
      const registry = loadRegistry(filePath);
      const issue = readJsonFile<SymphonyIssueRouting>(issueFile);
      const resolved = resolveSymphonyBackend(registry, issue);
      console.log(JSON.stringify(resolved, null, 2));
      return;
    }
    case 'print-example': {
      console.log(fs.readFileSync(EXAMPLE_REGISTRY_PATH, 'utf8'));
      return;
    }
    default:
      usage();
  }
}

main();
