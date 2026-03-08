import { describe, expect, it } from 'vitest';

import {
  deriveIssueStatus,
  derivePullRequestStatus,
  extractIssueNumbers,
  extractPullRequestLinkedIssueNumbers,
} from '../scripts/workflow/github-project-sync.js';

describe('extractIssueNumbers', () => {
  it('deduplicates issue references from PR bodies', () => {
    expect(extractIssueNumbers('Fixes #12\nRelated to #12 and #19')).toEqual([12, 19]);
  });

  it('uses the Linked Work Item section as the authoritative PR sync source', () => {
    const body = `## Linked Work Item

- Fixes #12

## Summary

References PR #48 and issue #19 for background only.
`;

    expect(extractPullRequestLinkedIssueNumbers(body)).toEqual([12]);
  });

  it('treats No issue: maintenance as a PR sync no-op', () => {
    const body = `## Linked Work Item

- No issue: maintenance

## Summary

References PR #48 for context.
`;

    expect(extractPullRequestLinkedIssueNumbers(body)).toEqual([]);
  });
});

describe('deriveIssueStatus', () => {
  it('puts new issues into Backlog', () => {
    expect(
      deriveIssueStatus({
        action: 'opened',
        currentStatus: null,
        issueState: 'OPEN',
        labels: [],
        assigneeCount: 0,
      }),
    ).toBe('Backlog');
  });

  it('marks blocked issues as Blocked', () => {
    expect(
      deriveIssueStatus({
        action: 'labeled',
        currentStatus: 'In Progress',
        issueState: 'OPEN',
        labels: ['status:blocked'],
        assigneeCount: 1,
      }),
    ).toBe('Blocked');
  });

  it('moves unassigned active issues back to Ready', () => {
    expect(
      deriveIssueStatus({
        action: 'unassigned',
        currentStatus: 'In Progress',
        issueState: 'OPEN',
        labels: [],
        assigneeCount: 0,
      }),
    ).toBe('Ready');
  });
});

describe('derivePullRequestStatus', () => {
  it('moves linked issues into Review for open PRs', () => {
    expect(
      derivePullRequestStatus({
        issueState: 'OPEN',
        labels: [],
        assigneeCount: 1,
        pullRequestState: 'OPEN',
        isDraft: false,
        merged: false,
        currentStatus: 'In Progress',
      }),
    ).toBe('Review');
  });

  it('returns merged work to Done', () => {
    expect(
      derivePullRequestStatus({
        issueState: 'OPEN',
        labels: [],
        assigneeCount: 1,
        pullRequestState: 'CLOSED',
        isDraft: false,
        merged: true,
        currentStatus: 'Review',
      }),
    ).toBe('Done');
  });

  it('returns closed unmerged work to Ready when no owner remains', () => {
    expect(
      derivePullRequestStatus({
        issueState: 'OPEN',
        labels: [],
        assigneeCount: 0,
        pullRequestState: 'CLOSED',
        isDraft: false,
        merged: false,
        currentStatus: 'Review',
      }),
    ).toBe('Ready');
  });
});
