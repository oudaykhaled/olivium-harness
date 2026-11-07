"""Private framed worker entrypoint. Root alone launches the isolated image."""
import os

# Deny ambient key/proxy/tracer discovery before importing any dependency.
for _key in tuple(os.environ):
    if _key.endswith(("_API_KEY", "_TOKEN")) or _key.lower().endswith("_proxy") or _key.startswith(("OTEL_", "HARNESSFORGE_")):
        os.environ.pop(_key, None)
os.environ["GRAPHITI_TELEMETRY_ENABLED"] = "false"
os.environ["PYTHON_DOTENV_DISABLED"] = "1"

import asyncio
import logging
import sys
from pathlib import Path

logging.disable(logging.CRITICAL)
# -I excludes the script directory: add only this root-owned immutable directory.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from worker import serve

if __name__ == "__main__":
    asyncio.run(serve())
