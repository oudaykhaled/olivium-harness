#!/usr/bin/env python3
"""Rebuild third-party task material for the value benchmark into a scratch directory.

Reads manifest.json (references only) and writes, per task, issue.md, test.patch,
gold.patch, repo/ (a tree at base_sha without .git) and a .complete marker. The
issue text is re-fetched and checked against issue_sha256.

This directory holds select.py, whose name shadows a standard library module
that subprocess imports, so the script directory is dropped from sys.path before
anything else is imported.
"""

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:] = [p for p in sys.path if os.path.abspath(p or os.getcwd()) != _HERE]

import subprocess  # noqa: E402,F401

sys.path.append(_HERE)

from corpus_lib import materialize_main  # noqa: E402

if __name__ == "__main__":
    sys.exit(materialize_main(sys.argv[1:]))
