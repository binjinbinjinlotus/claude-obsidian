import fs from 'node:fs';
import path from 'node:path';

/** realpath of `p`, or of its nearest existing ancestor joined with the rest (the path may not exist yet). */
export function realish(p: string): string {
  const abs = path.resolve(p);
  const rest: string[] = [];
  let cur = abs;
  for (;;) {
    try {
      return path.join(fs.realpathSync(cur), ...rest.reverse());
    } catch {
      const parent = path.dirname(cur);
      if (parent === cur) return abs;
      rest.push(path.basename(cur));
      cur = parent;
    }
  }
}

/** `child` is `parent` or inside it (folder boundaries respected; both already resolved). */
export function isWithin(child: string, parent: string): boolean {
  return child === parent || child.startsWith(parent.endsWith('/') ? parent : parent + '/');
}
