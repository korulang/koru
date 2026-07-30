/**
 * JSONL client for `koruc --ccp`.
 *
 * Spawns the daemon once, serializes commands on stdin, reads one response line per request.
 */

import { spawn, type ChildProcess } from "node:child_process";
import readline from "node:readline";

export type CcpReady = { type: "ready"; version: string };
export type CcpError = { type: "error"; id?: number; msg: string };
export type CcpParsed = {
  type: "parsed";
  id?: number;
  file: string;
  items: number;
  imports: number;
};
export type CcpOpened = { type: "opened"; id?: number; file: string; version: number };
export type CcpChanged = { type: "changed"; id?: number; file: string; version: number };
export type CcpClosed = { type: "closed"; id?: number; file: string };
export type CcpHover = {
  type: "hover";
  id?: number;
  file: string;
  line: number;
  column: number;
  contents: string | null;
  definition?: { file: string; line: number; column: number } | null;
};

export type CcpDefinition = {
  type: "definition";
  id?: number;
  file: string;
  line: number;
  column: number;
  target: { file: string; line: number; column: number } | null;
};

export type CcpDiagnosticItem = {
  line: number;
  column: number;
  endLine: number;
  endColumn: number;
  severity: string;
  code: string;
  message: string;
  hint?: string;
};

export type CcpDiagnostics = {
  type: "diagnostics";
  id?: number;
  file: string;
  items: CcpDiagnosticItem[];
};

export type CcpCompletionItem = {
  label: string;
  insert: string;
  detail?: string;
  kind: string;
};

export type CcpCompletion = {
  type: "completion";
  id?: number;
  file: string;
  startColumn: number;
  endColumn: number;
  items: CcpCompletionItem[];
};

export type CcpMessage =
  | CcpReady
  | CcpError
  | CcpParsed
  | CcpOpened
  | CcpChanged
  | CcpClosed
  | CcpHover
  | CcpDefinition
  | CcpDiagnostics
  | CcpCompletion
  | Record<string, unknown>;

type CcpProcess = ChildProcess & {
  stdin: NodeJS.WritableStream;
  stdout: NodeJS.ReadableStream;
};

let nextId = 1;

function logEnabled(): boolean {
  return process.env.KORU_LSP_LOG === "1" || process.env.KORU_LSP_LOG === "true";
}

function log(msg: string): void {
  if (logEnabled()) {
    process.stderr.write(`[koru-lsp] ${msg}\n`);
  }
}

export class CcpClient {
  private proc: CcpProcess | null = null;
  private pending = Promise.resolve();
  private rl: readline.Interface | null = null;
  private responseQueue: Array<{
    resolve: (line: string) => void;
    reject: (err: Error) => void;
  }> = [];

  constructor(private readonly korucPath: string) {}

  async start(): Promise<CcpReady> {
    if (this.proc) {
      throw new Error("CCP client already started");
    }

    log(`spawn ${this.korucPath} --ccp`);
    const proc = spawn(this.korucPath, ["--ccp"], {
      stdio: ["pipe", "pipe", "inherit"],
      cwd: process.env.KORU_PROJECT_ROOT ?? process.cwd(),
    });
    if (!proc.stdin || !proc.stdout) {
      throw new Error("koruc --ccp: expected piped stdin/stdout");
    }
    this.proc = proc as CcpProcess;

    this.rl = readline.createInterface({ input: this.proc.stdout });
    this.rl.on("line", (line) => {
      log(`<< ${line}`);
      const waiter = this.responseQueue.shift();
      if (waiter) {
        waiter.resolve(line);
      }
    });

    this.proc.on("error", (err) => {
      while (this.responseQueue.length > 0) {
        this.responseQueue.shift()?.reject(err);
      }
    });
    this.proc.on("exit", (code) => {
      const err = new Error(`koruc --ccp exited (${code})`);
      while (this.responseQueue.length > 0) {
        this.responseQueue.shift()?.reject(err);
      }
    });

    const readyLine = await this.waitForLine();
    const msg = JSON.parse(readyLine) as CcpMessage;
    if (msg.type !== "ready") {
      throw new Error(`expected ready, got ${readyLine}`);
    }
    return msg as CcpReady;
  }

  private waitForLine(): Promise<string> {
    return new Promise((resolve, reject) => {
      this.responseQueue.push({ resolve, reject });
    });
  }

  /** Send one JSONL command; returns the next response line. */
  async request(payload: Record<string, unknown>): Promise<CcpMessage> {
    if (!this.proc?.stdin) throw new Error("CCP client not started");

    const withId =
      payload.id === undefined ? { ...payload, id: nextId++ } : payload;
    const line = JSON.stringify(withId) + "\n";
    log(`>> ${line.trimEnd()}`);

    const response = await new Promise<string>((resolve, reject) => {
      this.pending = this.pending.then(async () => {
        this.responseQueue.push({ resolve, reject });
        this.proc!.stdin.write(line, (err) => {
          if (err) reject(err);
        });
      });
    });

    const msg = JSON.parse(response) as CcpMessage;
    if (msg.type === "error") {
      throw new Error((msg as CcpError).msg);
    }
    return msg;
  }

  async open(file: string, text: string, version = 1): Promise<CcpOpened> {
    return (await this.request({ cmd: "open", file, text, version })) as CcpOpened;
  }

  async change(file: string, text: string, version: number): Promise<CcpChanged> {
    return (await this.request({ cmd: "change", file, text, version })) as CcpChanged;
  }

  async close(file: string): Promise<CcpClosed> {
    return (await this.request({ cmd: "close", file })) as CcpClosed;
  }

  async hover(file: string, line: number, column: number): Promise<CcpHover> {
    return (await this.request({
      cmd: "hover",
      file,
      line: line + 1,
      column: column + 1,
    })) as CcpHover;
  }

  async definition(file: string, line: number, column: number): Promise<CcpDefinition> {
    return (await this.request({
      cmd: "definition",
      file,
      line: line + 1,
      column: column + 1,
    })) as CcpDefinition;
  }

  async diagnostics(file: string): Promise<CcpDiagnostics> {
    return (await this.request({ cmd: "diagnostics", file })) as CcpDiagnostics;
  }

  async completion(
    file: string,
    line: number,
    column: number,
  ): Promise<CcpCompletion> {
    return (await this.request({
      cmd: "completion",
      file,
      line: line + 1,
      column: column + 1,
    })) as CcpCompletion;
  }

  async stop(): Promise<void> {
    if (!this.proc) return;
    try {
      await this.request({ cmd: "exit" });
    } catch {
      // daemon may already be gone
    }
    this.rl?.close();
    this.rl = null;
    this.proc = null;
  }
}
