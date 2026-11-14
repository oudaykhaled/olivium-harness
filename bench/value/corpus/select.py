#!/usr/bin/env python3
"""Task selection for the value benchmark (see ../PROTOCOL.md, "Task selection").

Walks merged pull requests newest first through read-only `gh api` GET calls,
applies the pre-registered static rule, validates survivors in Docker in
round-robin order and writes manifest.json and rejected.jsonl.

This file has to be called select.py, which is also the name of a standard
library module that subprocess imports. The script directory is therefore
removed from sys.path before anything else is imported.
"""

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:] = [p for p in sys.path if os.path.abspath(p or os.getcwd()) != _HERE]

import subprocess  # noqa: E402,F401  (imports the real select module first)

sys.path.append(_HERE)

from corpus_lib import selection_main  # noqa: E402

if __name__ == "__main__":
    sys.exit(selection_main(sys.argv[1:]))
