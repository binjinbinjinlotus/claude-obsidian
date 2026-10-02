import type { DistillCore } from '../contracts.js';

export interface ServerOptions {
  core: DistillCore;
  host?: string; // must stay 127.0.0.1
  port?: number; // 0 = pick a free port
  token: string;
}

export interface RunningServer {
  port: number;
  close(): Promise<void>;
}

// OWNER: server-cli teammate. Replace this stub with the HTTP API.
export async function startServer(_opts: ServerOptions): Promise<RunningServer> {
  throw new Error('server: not implemented');
}
