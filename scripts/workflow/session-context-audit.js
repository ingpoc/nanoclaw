#!/usr/bin/env node

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import YAML from 'yaml';

const DEFAULT_DIR =
  process.env.SESSION_EXPORT_DIR ||
  path.join(os.homedir(), 'Documents/remote-claude', 'Obsidian', 'Claude-Sessions');
const DEFAULT_TOP = 8;
const DEFAULT_SHOW_BLOCKS = 2;
const APPROX_CHARS_PER_TOKEN = 4;
const DEFAULT_SUMMARY_KEEP_RATIO = 0.1;
const MIN_MEANINGFUL_STDOUT_TOKENS = 100;
const MIN_MEANINGFUL_STDOUT_LINES = 20;
const SNAPSHOT_CATEGORIES = [
  'System prompt',
  'System tools',
  'Custom agents',
  'Memory files',
  'Skills',
  'Messages',
  'Autocompact buffer',
];

function usage() {
  console.log(`Usage: node scripts/workflow/session-context-audit.js [options]

Audit exported Claude/Codex session markdown files for:
- highest recorded /context snapshots
- stdout-heavy transcripts
- estimated tokens that were likely compressible

Options:
  --dir PATH              Export directory (default: ${DEFAULT_DIR})
  --top N                 Number of sessions to show per section (default: ${DEFAULT_TOP})
  --show-blocks N         Largest stdout blocks to show per session (default: ${DEFAULT_SHOW_BLOCKS})
  --min-used-tokens N     Minimum recorded context tokens for snapshot ranking (default: 0)
  --json                  Emit JSON instead of human-readable text
  -h, --help              Show this help
`);
}

function parseArgs(argv) {
  const options = {
    dir: DEFAULT_DIR,
    top: DEFAULT_TOP,
    showBlocks: DEFAULT_SHOW_BLOCKS,
    minUsedTokens: 0,
    json: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    switch (token) {
      case '--dir':
        options.dir = argv[index + 1];
        index += 1;
        break;
      case '--top':
        options.top = Number.parseInt(argv[index + 1] || '', 10);
        index += 1;
        break;
      case '--show-blocks':
        options.showBlocks = Number.parseInt(argv[index + 1] || '', 10);
        index += 1;
        break;
      case '--min-used-tokens':
        options.minUsedTokens = Number.parseInt(argv[index + 1] || '', 10);
        index += 1;
        break;
      case '--json':
        options.json = true;
        break;
      case '-h':
      case '--help':
        usage();
        process.exit(0);
        break;
      default:
        throw new Error(`Unknown option: ${token}`);
    }
  }

  for (const key of ['top', 'showBlocks', 'minUsedTokens']) {
    if (!Number.isFinite(options[key]) || options[key] < 0) {
      throw new Error(`Invalid numeric value for ${key}`);
    }
  }

  return options;
}

function stripAnsi(value) {
  return value.replace(/\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07/g, '');
}

function parseFrontmatter(raw) {
  if (!raw.startsWith('---\n')) return {};
  const end = raw.indexOf('\n---\n', 4);
  if (end === -1) return {};
  const frontmatter = raw.slice(4, end);
  try {
    return YAML.parse(frontmatter) || {};
  } catch {
    return {};
  }
}

function parseTokenNumber(value, suffix = '') {
  const base = Number.parseFloat(value);
  if (!Number.isFinite(base)) return 0;
  if (suffix.toLowerCase() === 'k') return Math.round(base * 1000);
  if (suffix.toLowerCase() === 'm') return Math.round(base * 1000000);
  return Math.round(base);
}

function formatTokenNumber(value) {
  if (value >= 1000) {
    const rounded = Math.round((value / 1000) * 10) / 10;
    return `${rounded}k`;
  }
  return `${value}`;
}

function cleanPreview(value, maxLength = 88) {
  const compact = value.replace(/\s+/g, ' ').trim();
  if (compact.length <= maxLength) return compact;
  return `${compact.slice(0, maxLength - 3)}...`;
}

function parseUsageSnapshot(clean) {
  const header = clean.match(
    /([A-Za-z0-9_.-]+)\s+·\s+([0-9.]+)([kKmM]?)\/([0-9.]+)([kKmM]?)\s+tokens/,
  );
  if (!header) return null;

  const categories = [];
  for (const category of SNAPSHOT_CATEGORIES) {
    const match = clean.match(
      new RegExp(`${category}:\\s+([0-9.]+)([kKmM]?) tokens(?: \\(([0-9.]+)%\\))?`),
    );
    if (!match) continue;
    categories.push({
      name: category,
      tokens: parseTokenNumber(match[1], match[2]),
      pct: match[3] ? Number.parseFloat(match[3]) : null,
    });
  }

  categories.sort((left, right) => right.tokens - left.tokens);

  return {
    model: header[1],
    usedTokens: parseTokenNumber(header[2], header[3]),
    limitTokens: parseTokenNumber(header[4], header[5]),
    categories,
  };
}

function parseStdoutBlocks(raw) {
  const blocks = [];
  const regex = /<local-command-stdout>([\s\S]*?)<\/local-command-stdout>/g;
  let match;
  while ((match = regex.exec(raw))) {
    const stripped = stripAnsi(match[1]);
    const trimmed = stripped.trim();
    const lineCount = trimmed ? trimmed.split('\n').length : 0;
    const charCount = trimmed.length;
    const approxTokens = Math.round(charCount / APPROX_CHARS_PER_TOKEN);
    const previewLine =
      trimmed
        .split('\n')
        .map((line) => line.trim())
        .find((line) => line.length > 0) || '(empty stdout block)';
    const kind = /Context Usage/.test(trimmed)
      ? 'context-usage'
      : /(error|fail|warning)/i.test(trimmed)
        ? 'diagnostic'
        : 'generic';

    blocks.push({
      kind,
      lines: lineCount,
      chars: charCount,
      approxTokens,
      preview: cleanPreview(previewLine),
    });
  }

  blocks.sort((left, right) => right.approxTokens - left.approxTokens);
  return blocks;
}

function parseUserContentSize(raw) {
  const clean = stripAnsi(raw);
  let total = 0;
  const sections = clean.split(/\n### User\n\n/).slice(1);
  for (const section of sections) {
    const nextHeading = section.search(/\n### (?:User|Assistant)\n\n/);
    total += (nextHeading === -1 ? section : section.slice(0, nextHeading)).length;
  }
  return total;
}

function estimateSavings(stdoutTokens) {
  return Math.round(stdoutTokens * (1 - DEFAULT_SUMMARY_KEEP_RATIO));
}

function parseSessionFile(filePath) {
  const raw = fs.readFileSync(filePath, 'utf8');
  const clean = stripAnsi(raw);
  const frontmatter = parseFrontmatter(raw);
  const usage = parseUsageSnapshot(clean);
  const stdoutBlocks = parseStdoutBlocks(raw);
  const totalStdoutTokens = stdoutBlocks.reduce((sum, block) => sum + block.approxTokens, 0);
  const totalStdoutChars = stdoutBlocks.reduce((sum, block) => sum + block.chars, 0);
  const totalStdoutLines = stdoutBlocks.reduce((sum, block) => sum + block.lines, 0);
  const userChars = parseUserContentSize(raw);
  const reducibleStdoutTokens = estimateSavings(totalStdoutTokens);

  return {
    file: path.basename(filePath),
    path: filePath,
    title: String(frontmatter.title || path.basename(filePath)),
    date: frontmatter.date || null,
    messages: Number.isFinite(frontmatter.messages) ? frontmatter.messages : null,
    usage,
    stdout: {
      blockCount: stdoutBlocks.length,
      totalChars: totalStdoutChars,
      totalLines: totalStdoutLines,
      approxTokens: totalStdoutTokens,
      reducibleTokensAt90Pct: reducibleStdoutTokens,
      shareOfUserContentPct:
        userChars > 0 ? Math.round((totalStdoutChars / userChars) * 1000) / 10 : 0,
      blocks: stdoutBlocks,
    },
  };
}

function renderTopCategories(categories, limit = 4) {
  return categories
    .slice(0, limit)
    .map((category) => `${category.name} ${formatTokenNumber(category.tokens)}`)
    .join(', ');
}

function renderHumanReport(report, options) {
  const lines = [];
  lines.push('Session Context Audit');
  lines.push(`Source: ${report.sourceDir}`);
  lines.push(`Sessions scanned: ${report.scannedFiles}`);
  lines.push(`Recorded /context snapshots: ${report.snapshotSessions.length}`);
  lines.push('');

  lines.push('Highest recorded context snapshots');
  if (report.snapshotSessions.length === 0) {
    lines.push('  (none)');
  } else {
    for (const [index, session] of report.snapshotSessions.slice(0, options.top).entries()) {
      lines.push(
        `${index + 1}. ${formatTokenNumber(session.usage.usedTokens)}/${formatTokenNumber(session.usage.limitTokens)} tokens  ${session.file}`,
      );
      lines.push(`   ${cleanPreview(session.title, 110)}`);
      lines.push(`   Top categories: ${renderTopCategories(session.usage.categories)}`);
      if (session.stdout.blockCount > 0) {
        lines.push(
          `   Stdout payload: ${session.stdout.totalLines} lines, ~${formatTokenNumber(session.stdout.approxTokens)} tokens, ${session.stdout.shareOfUserContentPct}% of user content, est save if summarized: ~${formatTokenNumber(session.stdout.reducibleTokensAt90Pct)} tokens`,
        );
      }
    }
  }

  lines.push('');
  lines.push('Stdout-heavy sessions (likely compressible)');
  if (report.stdoutHeavySessions.length === 0) {
    lines.push('  (none)');
  } else {
    for (const [index, session] of report.stdoutHeavySessions.slice(0, options.top).entries()) {
      lines.push(
        `${index + 1}. ~${formatTokenNumber(session.stdout.approxTokens)} stdout tokens  ${session.file}`,
      );
      lines.push(`   ${cleanPreview(session.title, 110)}`);
      lines.push(
        `   ${session.stdout.blockCount} block(s), ${session.stdout.totalLines} lines, ${session.stdout.shareOfUserContentPct}% of user content, est save if summarized: ~${formatTokenNumber(session.stdout.reducibleTokensAt90Pct)} tokens`,
      );
      if (session.usage) {
        lines.push(
          `   Snapshot context at capture: ${formatTokenNumber(session.usage.usedTokens)} total tokens; messages bucket ${formatTokenNumber(
            session.usage.categories.find((category) => category.name === 'Messages')?.tokens || 0,
          )}`,
        );
      }
      for (const block of session.stdout.blocks.slice(0, options.showBlocks)) {
        lines.push(
          `   - ${block.kind}: ${block.lines} lines, ~${formatTokenNumber(block.approxTokens)} tokens, ${block.preview}`,
        );
      }
    }
  }

  lines.push('');
  lines.push('Notes');
  lines.push(
    `- Stdout token counts are approximate, using ${APPROX_CHARS_PER_TOKEN} chars/token for local transcript payload.`,
  );
  lines.push(
    `- Reducible-token estimates assume a tool could return a summary in roughly ${Math.round(
      DEFAULT_SUMMARY_KEEP_RATIO * 100,
    )}% of the original payload.`,
  );
  lines.push(
    '- Fixed overhead like autocompact buffer, system tools, memory files, and long user prompts is not reducible by stdout-focused tooling.',
  );

  return lines.join('\n');
}

function buildReport(files, options) {
  const sessions = files.map(parseSessionFile);
  const snapshotSessions = sessions
    .filter((session) => session.usage && session.usage.usedTokens >= options.minUsedTokens)
    .sort((left, right) => right.usage.usedTokens - left.usage.usedTokens);
  const stdoutHeavySessions = sessions
    .filter(
      (session) =>
        session.stdout.approxTokens >= MIN_MEANINGFUL_STDOUT_TOKENS ||
        session.stdout.totalLines >= MIN_MEANINGFUL_STDOUT_LINES,
    )
    .sort((left, right) => right.stdout.approxTokens - left.stdout.approxTokens);

  return {
    generatedAt: new Date().toISOString(),
    sourceDir: options.dir,
    scannedFiles: sessions.length,
    snapshotSessions,
    stdoutHeavySessions,
  };
}

function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
  } catch (error) {
    console.error(error.message);
    usage();
    process.exit(2);
  }

  if (!fs.existsSync(options.dir)) {
    console.error(`Session export directory not found: ${options.dir}`);
    process.exit(2);
  }

  const files = fs
    .readdirSync(options.dir)
    .filter((name) => name.endsWith('.md'))
    .map((name) => path.join(options.dir, name))
    .sort();

  const report = buildReport(files, options);
  if (options.json) {
    console.log(JSON.stringify(report, null, 2));
    return;
  }

  console.log(renderHumanReport(report, options));
}

main();
