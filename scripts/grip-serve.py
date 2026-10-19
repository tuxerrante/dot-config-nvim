#!/opt/homebrew/Cellar/grip/4.6.2_21/libexec/bin/python
"""
grip only knows how to render Markdown - any other file it serves gets run
through the same Markdown renderer (a Python script's "#" comments turn into
headers, blank-line-sensitive formatting collapses, etc). This wraps grip so
that non-Markdown source files are instead served as plain text, skipping
the Markdown pass entirely.
"""
import os
import socket
import sys

from grip.app import Grip
from grip.readers import DirectoryReader

CODE_EXTENSIONS = {
    ".py", ".js", ".mjs", ".ts", ".tsx", ".jsx", ".go", ".rb", ".sh",
    ".bash", ".zsh", ".yaml", ".yml", ".json", ".lua", ".rs", ".java",
    ".c", ".h", ".cpp", ".hpp", ".toml", ".ini", ".cfg", ".conf",
    ".tf", ".hcl", ".sql", ".env",
}


class CodeAwareReader(DirectoryReader):
    def _is_code(self, subpath):
        return subpath and os.path.splitext(subpath)[1].lower() in CODE_EXTENSIONS

    def is_binary(self, subpath=None):
        if self._is_code(subpath):
            return True
        return super().is_binary(subpath)

    def mimetype_for(self, subpath=None):
        if self._is_code(subpath):
            return "text/plain"
        return super().mimetype_for(subpath)


def free_port():
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("localhost", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def main():
    root = sys.argv[1]
    # A fixed port would collide with a still-running server from a
    # previous Neovim session (that one holds the port, this one fails to
    # bind, and the caller never finds out). Always ask the OS for a free
    # one, and announce it so the caller doesn't have to guess when we're
    # actually ready.
    port = free_port()
    print("PORT=%d" % port, flush=True)
    app = Grip(CodeAwareReader(root), quiet=True)
    app.run(port=port)


if __name__ == "__main__":
    main()
