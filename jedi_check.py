"""Build check for the Jedi language server shipped in the Python extension (run by build.ps1).

build.ps1 patches it twice: semantic highlighting on (`semanticTokens`) and its handlers moved off a
worker thread. Jedi is not thread-safe; with highlighting computed in a thread while completions run
on the main thread, the shared helper process gets garbled (UnpicklingError) and the server stops
answering: students see "Loading..." and no completions. Both failures are silent in the editor.

Checks: completions (case-insensitive module names), highlighting tokens, and an editor-like burst
(a keystroke followed by tokens + completion + hover, without waiting) that must all get answers.

    build\\python\\python.exe jedi_check.py
"""
import json
import os
import pathlib
import queue
import subprocess
import sys
import tempfile
import threading
import time

ROOT = pathlib.Path(__file__).parent / "build"
PYTHON = ROOT / "python" / "python.exe"
SERVER = next((ROOT / "vscode" / "data" / "extensions").glob("ms-python.python-*")) / "python_files" / "run-jedi-language-server.py"
# what ms-python sends, after build.ps1's camelCase fix
OPTIONS = {"markupKindPreferred": "markdown", "completion": {"resolveEagerly": False, "disableSnippets": True},
           "diagnostics": {"enable": True, "didOpen": True, "didSave": True, "didChange": True},
           "workspace": {"environmentPath": str(PYTHON)}, "semanticTokens": {"enable": True}}
SRC = "from PyQt5.QtWidgets import QApplication, QPushButton\nimport pygame\napp = QApplication([])\nbtn = QPushButton('Дальше')\n"


class Server:
    def __init__(self, folder):
        self.p = subprocess.Popen([str(PYTHON), str(SERVER)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.inbox, self.outbox, self.next_id = queue.Queue(), queue.Queue(), 0
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._write, daemon=True).start()  # a stuck server must not block us
        self.wait(self.ask("initialize", {"processId": os.getpid(), "rootUri": folder.as_uri(), "capabilities": {}, "initializationOptions": OPTIONS}))
        self.notify("initialized", {})

    def _read(self):
        while True:
            headers = {}
            while line := self.p.stdout.readline().decode().strip():
                key, value = line.split(":", 1)
                headers[key.lower()] = value.strip()
            if not headers:
                return
            self.inbox.put(json.loads(self.p.stdout.read(int(headers["content-length"]))))

    def _write(self):
        while True:
            try:
                self.p.stdin.write(self.outbox.get())
                self.p.stdin.flush()
            except OSError:
                return

    def _send(self, message):
        body = json.dumps({"jsonrpc": "2.0", **message}).encode()
        self.outbox.put(b"Content-Length: %d\r\n\r\n" % len(body) + body)

    def notify(self, method, params):
        self._send({"method": method, "params": params})

    def ask(self, method, params):
        self.next_id += 1
        self._send({"id": self.next_id, "method": method, "params": params})
        return self.next_id

    def wait(self, *ids, timeout=60):
        """Collect results for ids; stops when the server goes quiet for `timeout` seconds."""
        results, last = {}, time.time()
        while len(results) < len(ids) and time.time() - last < timeout:
            try:
                m = self.inbox.get(timeout=1)
            except queue.Empty:
                continue
            last = time.time()
            if "method" in m and "id" in m:  # server -> client request
                self._send({"id": m["id"], "result": None})
            elif m.get("id") in ids:
                results[m["id"]] = m.get("result")
        return results if len(ids) > 1 else results.get(ids[0], "TIMEOUT")


def labels(result):
    return [c["label"] for c in (result["items"] if isinstance(result, dict) else result or [])]


folder = pathlib.Path(tempfile.mkdtemp())
uri = (folder / "my_app.py").as_uri()
server = Server(folder)
server.notify("textDocument/didOpen", {"textDocument": {"uri": uri, "languageId": "python", "version": 1, "text": SRC}})
failures = []

for text, want in [("from pyq", "PyQt5"), ("import pyg", "pygame"), ("btn.setT", "setText")]:
    doc = (folder / f"c{len(failures)}{want}.py").as_uri()
    full = SRC + text
    server.notify("textDocument/didOpen", {"textDocument": {"uri": doc, "languageId": "python", "version": 1, "text": full}})
    lines = full.split("\n")
    got = labels(server.wait(server.ask("textDocument/completion", {"textDocument": {"uri": doc}, "position": {"line": len(lines) - 1, "character": len(lines[-1])}})))
    if want not in got:
        failures.append(f"completion {text!r} -> {want!r} missing (got {got[:5]})")

tokens = server.wait(server.ask("textDocument/semanticTokens/full", {"textDocument": {"uri": uri}}))
if not (isinstance(tokens, dict) and tokens.get("data")):
    failures.append(f"no semantic tokens: {tokens!r:.80}")

# editor-like burst: type a line, after each key ask for tokens + completion + hover without waiting
line, col, version, pending = 4, 0, 1, []
for ch in "btn.clicked.connect(app.quit)":
    version += 1
    server.notify("textDocument/didChange", {"textDocument": {"uri": uri, "version": version},
                  "contentChanges": [{"range": {"start": {"line": line, "character": col}, "end": {"line": line, "character": col}}, "text": ch}]})
    col += 1
    pending += [server.ask("textDocument/semanticTokens/full", {"textDocument": {"uri": uri}}),
                server.ask("textDocument/completion", {"textDocument": {"uri": uri}, "position": {"line": line, "character": col}}),
                server.ask("textDocument/hover", {"textDocument": {"uri": uri}, "position": {"line": 2, "character": 7}})]
answered = server.wait(*pending, timeout=30)
if len(answered) < len(pending):
    failures.append(f"server stalled under editor-like load: {len(pending) - len(answered)} of {len(pending)} requests unanswered")

server.p.kill()
print("jedi:", "ok" if not failures else "FAILED", *failures, sep="\n  ")
sys.exit(1 if failures else 0)
