# SKYFORGE — Apache-2.0
"""Shared bounded network reads for the build-time tools (never trust a remote to stop sending)."""
import re

MAX_BYTES = 256 * 1024 * 1024
HEX64 = re.compile(r"^[0-9a-f]{64}$")


def read_bounded(resp, max_bytes=MAX_BYTES, chunk=1 << 20):
    """Read a file-like response fully, raising if it would exceed max_bytes."""
    declared = None
    try:
        declared = int(resp.headers.get("Content-Length")) if resp.headers.get("Content-Length") else None
    except (AttributeError, ValueError):
        declared = None
    if declared is not None and declared > max_bytes:
        raise ValueError(f"response of {declared} bytes exceeds limit {max_bytes}")
    buf = bytearray()
    while True:
        part = resp.read(min(chunk, max_bytes + 1 - len(buf)))
        if not part:
            return bytes(buf)
        buf += part
        if len(buf) > max_bytes:
            raise ValueError(f"response exceeds limit {max_bytes} bytes")
