export interface DispatchOutputContract {
  required_fields: string[];
}

export type DispatchTaskType =
  | 'analyze'
  | 'implement'
  | 'fix'
  | 'refactor'
  | 'test'
  | 'release'
  | 'research'
  | 'code';

export interface DispatchPayload {
  run_id: string;
  task_type: DispatchTaskType;
  input: string;
  repo: string;
  branch: string;
  acceptance_tests: string[];
  output_contract: DispatchOutputContract;
  priority?: 'low' | 'normal' | 'high';
}

export interface CompletionContract {
  run_id?: string;
  branch: string;
  commit_sha: string;
  files_changed: string[];
  test_result: string;
  risk: string;
  pr_url?: string;
  pr_skipped_reason?: string;
}

const RUN_ID_MAX_LENGTH = 64;
const REPO_PATTERN = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const BRANCH_PATTERN = /^jarvis-[A-Za-z0-9._/-]+$/;
const COMMIT_SHA_PATTERN = /^[0-9a-f]{7,40}$/i;
const ALLOWED_TASK_TYPES: Set<DispatchTaskType> = new Set([
  'analyze',
  'implement',
  'fix',
  'refactor',
  'test',
  'release',
  'research',
  'code',
]);
const COMPLETION_REQUIRED_FIELDS = [
  'run_id',
  'branch',
  'commit_sha',
  'files_changed',
  'test_result',
  'risk',
];

function parseJsonObject(raw: string): Record<string, unknown> | null {
  try {
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      return parsed as Record<string, unknown>;
    }
  } catch {
    // ignore parse errors
  }
  return null;
}

/**
 * Parse worker dispatch payload from message content.
 * Accepts either a raw JSON object string or text wrapping a JSON object.
 */
export function parseDispatchPayload(content: string): DispatchPayload | null {
  const trimmed = content.trim();
  const direct = parseJsonObject(trimmed);
  if (direct && typeof direct.run_id === 'string') {
    return direct as unknown as DispatchPayload;
  }

  const firstBrace = content.indexOf('{');
  const lastBrace = content.lastIndexOf('}');
  if (firstBrace === -1 || lastBrace <= firstBrace) return null;

  const wrapped = parseJsonObject(content.slice(firstBrace, lastBrace + 1));
  if (wrapped && typeof wrapped.run_id === 'string') {
    return wrapped as unknown as DispatchPayload;
  }

  return null;
}

export function validateDispatchPayload(payload: DispatchPayload): { valid: boolean; errors: string[] } {
  const errors: string[] = [];

  if (!payload.run_id || /\s/.test(payload.run_id)) {
    errors.push('run_id must be a non-empty string with no whitespace');
  } else if (payload.run_id.length > RUN_ID_MAX_LENGTH) {
    errors.push(`run_id must be ${RUN_ID_MAX_LENGTH} characters or fewer`);
  }

  if (!payload.task_type || !ALLOWED_TASK_TYPES.has(payload.task_type)) {
    errors.push(`task_type must be one of: ${Array.from(ALLOWED_TASK_TYPES).join(', ')}`);
  }

  if (!payload.input || !payload.input.trim()) {
    errors.push('input is required');
  }

  if (!payload.repo || !REPO_PATTERN.test(payload.repo)) {
    errors.push('repo must be in owner/repo format');
  }

  if (!payload.branch || !BRANCH_PATTERN.test(payload.branch)) {
    errors.push('branch must match jarvis-<feature>');
  }

  if (!Array.isArray(payload.acceptance_tests) || payload.acceptance_tests.length === 0) {
    errors.push('acceptance_tests must be a non-empty array');
  } else if (payload.acceptance_tests.some((test) => typeof test !== 'string' || !test.trim())) {
    errors.push('acceptance_tests entries must be non-empty strings');
  }

  if (!payload.output_contract || typeof payload.output_contract !== 'object') {
    errors.push('output_contract is required');
  } else {
    const fields = payload.output_contract.required_fields;
    if (!Array.isArray(fields) || fields.length === 0) {
      errors.push('output_contract.required_fields must be a non-empty array');
    } else {
      for (const required of COMPLETION_REQUIRED_FIELDS) {
        if (!fields.includes(required)) {
          errors.push(`output_contract.required_fields missing ${required}`);
        }
      }
      const hasPrUrl = fields.includes('pr_url');
      const hasPrSkipped = fields.includes('pr_skipped_reason');
      if (!hasPrUrl && !hasPrSkipped) {
        errors.push('output_contract.required_fields must include pr_url or pr_skipped_reason');
      }
    }
  }

  return { valid: errors.length === 0, errors };
}

/**
 * Scan worker output for a <completion>...</completion> block and parse the JSON inside.
 * Returns typed contract or null if no valid block found.
 */
export function parseCompletionContract(output: string): CompletionContract | null {
  const match = output.match(/<completion>([\s\S]*?)<\/completion>/);
  if (!match) return null;
  try {
    const obj = JSON.parse(match[1].trim());
    if (obj && typeof obj === 'object') {
      return obj as CompletionContract;
    }
  } catch {
    // invalid JSON inside completion block
  }
  return null;
}

export function validateCompletionContract(
  contract: CompletionContract | null,
  options?: { expectedRunId?: string },
): { valid: boolean; missing: string[] } {
  if (!contract) return { valid: false, missing: ['completion block'] };

  const missing: string[] = [];

  if (!contract.run_id) {
    missing.push('run_id');
  } else if (/\s/.test(contract.run_id) || contract.run_id.length > RUN_ID_MAX_LENGTH) {
    missing.push('run_id format');
  } else if (options?.expectedRunId && contract.run_id !== options.expectedRunId) {
    missing.push('run_id mismatch');
  }

  if (!contract.branch || !BRANCH_PATTERN.test(contract.branch)) missing.push('branch');
  if (!contract.commit_sha || !COMMIT_SHA_PATTERN.test(contract.commit_sha)) missing.push('commit_sha');

  if (!Array.isArray(contract.files_changed) || contract.files_changed.length === 0) {
    missing.push('files_changed');
  } else if (
    contract.files_changed.some(
      (item) => typeof item !== 'string' || !item.trim(),
    )
  ) {
    missing.push('files_changed format');
  }

  if (!contract.test_result || !contract.test_result.trim()) missing.push('test_result');
  if (!contract.risk || !contract.risk.trim()) missing.push('risk');
  if (!contract.pr_url && !contract.pr_skipped_reason) missing.push('pr_url or pr_skipped_reason');

  return { valid: missing.length === 0, missing };
}
