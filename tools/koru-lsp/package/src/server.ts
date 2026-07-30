#!/usr/bin/env node
/**
 * Koru language server — LSP front-end for `koruc --ccp`.
 */

import {
  createConnection,
  TextDocuments,
  ProposedFeatures,
  InitializeParams,
  TextDocumentSyncKind,
  Hover,
  Definition,
  Location,
  Diagnostic,
  DiagnosticSeverity,
  CompletionItem,
  CompletionList,
  CompletionItemKind,
} from "vscode-languageserver/node.js";
import { TextDocument } from "vscode-languageserver-textdocument";
import { URI } from "vscode-uri";
import { CcpClient } from "./ccp-client.js";

const connection = createConnection(ProposedFeatures.all);
const documents = new TextDocuments(TextDocument);

const korucPath = process.env.KORUC_PATH ?? "koruc";
const ccp = new CcpClient(korucPath);
let ccpReady = false;
const diagnosticTimers = new Map<string, ReturnType<typeof setTimeout>>();

function filePathFromUri(uri: string): string {
  return URI.parse(uri).fsPath;
}

function uriFromPath(filePath: string): string {
  return URI.file(filePath).toString();
}

async function publishDiagnosticsFor(uri: string): Promise<void> {
  if (!ccpReady) return;
  const file = filePathFromUri(uri);
  try {
    const result = await ccp.diagnostics(file);
    const items: Diagnostic[] = result.items.map((d) => {
      const diag: Diagnostic = {
        severity: DiagnosticSeverity.Error,
        range: {
          start: { line: d.line - 1, character: d.column - 1 },
          end: { line: d.endLine - 1, character: d.endColumn - 1 },
        },
        message: d.message,
        source: "koruc",
        code: d.code,
      };
      if (d.hint) {
        diag.message = `${d.message}\n\n${d.hint}`;
      }
      return diag;
    });
    connection.sendDiagnostics({ uri, diagnostics: items });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    connection.console.error(`koru-lsp: diagnostics failed for ${file}: ${msg}`);
  }
}

function scheduleDiagnostics(uri: string): void {
  const existing = diagnosticTimers.get(uri);
  if (existing) clearTimeout(existing);
  diagnosticTimers.set(
    uri,
    setTimeout(() => {
      diagnosticTimers.delete(uri);
      void publishDiagnosticsFor(uri);
    }, 400),
  );
}

connection.onInitialize((_params: InitializeParams) => {
  connection.console.log(`koru-lsp: koruc at ${korucPath}`);
  return {
    capabilities: {
      textDocumentSync: TextDocumentSyncKind.Incremental,
      hoverProvider: true,
      definitionProvider: true,
      completionProvider: {
        triggerCharacters: [":", "/"],
      },
    },
  };
});

connection.onInitialized(async () => {
  try {
    const ready = await ccp.start();
    ccpReady = true;
    connection.console.log(`koru-lsp: CCP ready (koruc ${ready.version})`);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    connection.console.error(`koru-lsp: failed to start CCP: ${msg}`);
  }
});

documents.onDidOpen(async (event) => {
  if (!ccpReady) return;
  const file = filePathFromUri(event.document.uri);
  try {
    await ccp.open(file, event.document.getText(), event.document.version);
    scheduleDiagnostics(event.document.uri);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    connection.console.error(`koru-lsp: open failed for ${file}: ${msg}`);
  }
});

documents.onDidChangeContent(async (event) => {
  if (!ccpReady) return;
  const file = filePathFromUri(event.document.uri);
  try {
    await ccp.change(file, event.document.getText(), event.document.version);
    scheduleDiagnostics(event.document.uri);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    connection.console.error(`koru-lsp: change failed for ${file}: ${msg}`);
  }
});

documents.onDidClose(async (event) => {
  if (!ccpReady) return;
  const file = filePathFromUri(event.document.uri);
  const existing = diagnosticTimers.get(event.document.uri);
  if (existing) {
    clearTimeout(existing);
    diagnosticTimers.delete(event.document.uri);
  }
  connection.sendDiagnostics({ uri: event.document.uri, diagnostics: [] });
  try {
    await ccp.close(file);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    connection.console.error(`koru-lsp: close failed for ${file}: ${msg}`);
  }
});

connection.onHover(async (params): Promise<Hover | null> => {
  if (!ccpReady || !params.textDocument?.uri || !params.position) return null;

  const file = filePathFromUri(params.textDocument.uri);
  try {
    const result = await ccp.hover(file, params.position.line, params.position.character);
    if (!result.contents) return null;
    return {
      contents: { kind: "markdown", value: result.contents },
    };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    connection.console.error(`koru-lsp: hover failed for ${file}: ${msg}`);
    return null;
  }
});

connection.onDefinition(async (params): Promise<Definition | null> => {
  if (!ccpReady || !params.textDocument?.uri || !params.position) return null;

  const file = filePathFromUri(params.textDocument.uri);
  try {
    const result = await ccp.definition(file, params.position.line, params.position.character);
    if (!result.target) return null;
    const loc: Location = {
      uri: uriFromPath(result.target.file),
      range: {
        start: {
          line: result.target.line - 1,
          character: result.target.column - 1,
        },
        end: {
          line: result.target.line - 1,
          character: result.target.column - 1,
        },
      },
    };
    return loc;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    connection.console.error(`koru-lsp: definition failed for ${file}: ${msg}`);
    return null;
  }
});

function completionKind(kind: string): CompletionItemKind {
  switch (kind) {
    case "module":
      return CompletionItemKind.Module;
    case "function":
      return CompletionItemKind.Function;
    default:
      return CompletionItemKind.Text;
  }
}

connection.onCompletion(async (params): Promise<CompletionItem[] | CompletionList | null> => {
  if (!ccpReady || !params.textDocument?.uri || !params.position) return null;

  const file = filePathFromUri(params.textDocument.uri);
  try {
    const result = await ccp.completion(file, params.position.line, params.position.character);
    const replaceRange = {
      start: {
        line: params.position.line,
        character: result.startColumn - 1,
      },
      end: {
        line: params.position.line,
        character: result.endColumn - 1,
      },
    };

    const items: CompletionItem[] = result.items.map((item) => ({
      label: item.label,
      kind: completionKind(item.kind),
      detail: item.detail,
      insertText: item.label,
      textEdit: {
        range: replaceRange,
        newText: item.label,
      },
    }));

    return items;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    connection.console.error(`koru-lsp: completion failed for ${file}: ${msg}`);
    return null;
  }
});

connection.onShutdown(async () => {
  await ccp.stop();
});

documents.listen(connection);
connection.listen();
