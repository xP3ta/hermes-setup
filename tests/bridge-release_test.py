#!/usr/bin/env python3
"""Verify that the release manifest describes the exact Bridge bytes."""

import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
manifest_path = ROOT / "bridge-release.json"
bridge_path = ROOT / "hermes_bridge.py"
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
bridge = bridge_path.read_bytes()

expected_fields = {"schema", "version", "min_app_build", "sha256", "size"}
assert set(manifest) == expected_fields, "unexpected bridge manifest fields"
assert manifest["schema"] == 1, "unsupported bridge manifest schema"
assert isinstance(manifest["min_app_build"], int) and manifest["min_app_build"] > 0
assert isinstance(manifest["size"], int) and 0 < manifest["size"] <= 512 * 1024
assert re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", manifest["version"])
assert re.fullmatch(r"[a-f0-9]{64}", manifest["sha256"])
assert len(bridge) == manifest["size"], "Bridge byte size does not match manifest"
assert hashlib.sha256(bridge).hexdigest() == manifest["sha256"], "Bridge SHA-256 does not match manifest"

source = bridge.decode("utf-8", errors="strict")
versions = re.findall(
    r'''^VERSION\s*=\s*["']((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))["']\s*(?:#.*)?$''',
    source,
    re.MULTILINE,
)
assert versions == [manifest["version"]], "Bridge source VERSION does not match manifest"
compile(source, str(bridge_path), "exec")
print("Bridge release manifest: OK")
