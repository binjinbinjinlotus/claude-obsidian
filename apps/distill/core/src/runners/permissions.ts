import type { PermissionDenial } from '../contracts.js';

const COMPOUND_MARKERS = ['&&', '||', ';', '|', '\n', '$(', '`', '<<'];

function input(d: PermissionDenial, key: string): string | undefined {
  const v = d.input[key];
  return typeof v === 'string' ? v : undefined;
}

/**
 * A rule that would allow exactly this call on resume, or undefined when no
 * exact rule can match (compound shell commands are checked per part).
 * Absolute paths become `//abs` rules; Edit rules cover every file-writing tool.
 */
export function suggestedRule(d: PermissionDenial): string | undefined {
  switch (d.toolName) {
    case 'Bash': {
      const cmd = input(d, 'command');
      if (cmd === undefined) return undefined;
      const compound = COMPOUND_MARKERS.some((m) => cmd.includes(m)) || cmd.startsWith('cd ');
      return compound ? undefined : `Bash(${cmd})`;
    }
    case 'Read': {
      const p = input(d, 'file_path');
      if (p !== undefined) return `Read(/${p})`;
      break;
    }
    case 'Write':
    case 'Edit':
    case 'MultiEdit':
    case 'NotebookEdit': {
      // Write(...) rules do not match; Edit rules govern all file writes.
      const p = input(d, 'file_path');
      if (p !== undefined) return `Edit(/${p})`;
      break;
    }
    case 'WebFetch': {
      const u = input(d, 'url');
      if (u === undefined) return undefined;
      try {
        const host = new URL(u).hostname;
        return host ? `WebFetch(domain:${host})` : undefined;
      } catch {
        return undefined;
      }
    }
    default:
      break;
  }
  return d.toolName;
}

/** Granting this lets the agent change files outside the approval gate. */
export function bypassesApproval(d: PermissionDenial): boolean {
  const rule = suggestedRule(d) ?? '';
  return d.toolName === 'Bash' || (rule.startsWith('Edit(') && !rule.includes('/.vault-meta/worker/'));
}

export function denialDisplay(d: PermissionDenial): string {
  const cmd = input(d, 'command');
  if (cmd !== undefined) return `${d.toolName}: ${cmd}`;
  const p = input(d, 'file_path');
  if (p !== undefined) return `${d.toolName}: ${p}`;
  const u = input(d, 'url');
  if (u !== undefined) return `${d.toolName}: ${u}`;
  return d.toolName;
}

function canonical(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canonical).join(',')}]`;
  if (v && typeof v === 'object') {
    const o = v as Record<string, unknown>;
    return `{${Object.keys(o).sort().map((k) => `${JSON.stringify(k)}:${canonical(o[k])}`).join(',')}}`;
  }
  return JSON.stringify(v) ?? 'null';
}

/** Deduplicate by deep equality (Swift `Array(Set(denials))`). */
export function uniqueDenials(denials: PermissionDenial[]): PermissionDenial[] {
  const seen = new Set<string>();
  return denials.filter((d) => {
    const key = canonical({ toolName: d.toolName, input: d.input });
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}
