#!/usr/bin/env python3
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

# GitHub's stylesheet defines every colour variable (syntax highlighting, link
# blue, background) under data-color-mode/-theme attributes on <html>, which
# grip's page omits, so code and links render uncoloured. "auto" follows the
# OS light/dark setting. It also only underlines in-text links when its a11y
# setting is on, which a local render never has.
HTML_ATTRS = b'<html data-color-mode="auto" data-light-theme="light" data-dark-theme="dark"'
PAGE_STYLE = (
    b"<style>body{background:var(--bgColor-default);color:var(--fgColor-default)}"
    b".markdown-body a[href]:not(.anchor){text-decoration:underline;text-underline-offset:.2rem}</style>"
)


def theme_page(response):
    if response.mimetype == "text/html" and not response.direct_passthrough:
        page = response.get_data().replace(b"<html", HTML_ATTRS, 1)
        response.set_data(page.replace(b"</head>", PAGE_STYLE + b"</head>", 1))
    return response


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
    # silent: a root without a README (most directories) is still servable;
    # grip only needs one to pick a default landing page.
    app = Grip(CodeAwareReader(root, silent=True), quiet=True)
    app.after_request(theme_page)
    print("PORT=%d" % port, flush=True)
    app.run(port=port)


if __name__ == "__main__":
    main()
