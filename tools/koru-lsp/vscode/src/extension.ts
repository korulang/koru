import * as path from "node:path";
import { workspace, ExtensionContext, window, OutputChannel, commands } from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  Trace,
  TransportKind,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;
let log: OutputChannel | undefined;

function append(line: string): void {
  log?.appendLine(line);
}

export function activate(context: ExtensionContext): void {
  log = window.createOutputChannel("Koru");
  context.subscriptions.push(log);

  const serverModule = context.asAbsolutePath(
    path.join("..", "package", "dist", "server.js"),
  );

  const korucPath =
    process.env.KORUC_PATH ??
    workspace.getConfiguration("koru").get<string>("korucPath") ??
    "koruc";
  const trace = workspace.getConfiguration("koru").get<string>("trace.server");
  const projectRoot =
    workspace.workspaceFolders?.[0]?.uri.fsPath ?? process.cwd();

  append("Koru extension activated.");
  append(`  server: ${serverModule}`);
  append(`  koruc:  ${korucPath}`);
  append(`  root:   ${projectRoot}`);
  append("Open a .k file, then check this panel for LSP + CCP status.");

  const showLog = commands.registerCommand("koru.showLog", () => {
    log?.show(true);
  });
  context.subscriptions.push(showLog);

  const env: NodeJS.ProcessEnv = {
    ...process.env,
    KORUC_PATH: korucPath,
    KORU_PROJECT_ROOT: projectRoot,
  };

  const run: ServerOptions = {
    command: "node",
    args: [serverModule, "--stdio"],
    transport: TransportKind.stdio,
    options: { env },
  };

  const debug: ServerOptions = {
    command: "node",
    args: ["--inspect=9229", serverModule, "--stdio"],
    transport: TransportKind.stdio,
    options: { env },
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ language: "koru" }],
    synchronize: {
      fileEvents: workspace.createFileSystemWatcher("**/*.{k,kz,kjs}"),
    },
    outputChannel: log,
  };

  client = new LanguageClient("koru-lsp", "Koru Language Server", { run, debug }, clientOptions);
  client.setTrace(trace === "verbose" ? Trace.Verbose : trace === "messages" ? Trace.Messages : Trace.Off);

  void client
    .start()
    .then(() => {
      append("Language client started.");
      log?.show(true);
    })
    .catch((err: unknown) => {
      const msg = err instanceof Error ? err.message : String(err);
      append(`Language client failed to start: ${msg}`);
      void window.showErrorMessage(`Koru LSP failed to start: ${msg}`);
      log?.show(true);
    });

  context.subscriptions.push({ dispose: () => { void client?.stop(); } });
}

export function deactivate(): Promise<void> | undefined {
  if (!client) return undefined;
  return client.stop();
}
