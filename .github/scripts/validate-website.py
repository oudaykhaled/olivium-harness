#!/usr/bin/env python3
"""Check the static Pages entry point and every local HTML asset/fragment."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[2] / "website"

class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = set()
        self.references = []

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if "id" in attrs:
            assert attrs["id"] not in self.ids, "Duplicate HTML id: " + attrs["id"]
            self.ids.add(attrs["id"])
        for name in ("href", "src"):
            if attrs.get(name):
                self.references.append(attrs[name])

page = Page()
page.feed((ROOT / "index.html").read_text())
checked = 0
for reference in page.references:
    url = urlsplit(reference)
    if url.scheme or url.netloc:
        assert url.scheme in ("https", "mailto"), "Unexpected URL scheme: " + reference
        continue
    assert not url.path.startswith("/"), "Root-relative asset breaks project Pages: " + reference
    if url.path:
        path = (ROOT / unquote(url.path)).resolve()
        assert path.is_relative_to(ROOT.resolve()), "Asset escapes website folder: " + reference
        assert path.is_file(), "Missing website asset: " + reference
    if url.fragment and not url.path:
        assert unquote(url.fragment) in page.ids, "Missing section: " + reference
    checked += 1
assert (ROOT / ".nojekyll").is_file(), "Missing .nojekyll marker"
assert not any(p.is_symlink() for p in ROOT.rglob("*")), "Pages artifact cannot contain symlinks"
print(f"Validated index.html and {checked} local asset/section references.")
