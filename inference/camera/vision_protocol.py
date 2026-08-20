"""Wire-format helpers for the Mac-to-ESP32 camera result bridge."""

from __future__ import annotations

import math


VISION_ACTIONS = frozenset(
    {"TAKE", "DRINK", "TOUCH_FACE", "ADJUST", "PICK_ONLY", "NONE", "UNCERTAIN"}
)


def encode_vision_message(label: str, confidence: float) -> bytes:
    """Encode one validated UDP datagram accepted by the combined firmware."""
    normalized = label.strip().upper()
    if normalized not in VISION_ACTIONS:
        raise ValueError(f"Unsupported vision action: {label}")
    if not math.isfinite(confidence) or not 0.0 <= confidence <= 1.0:
        raise ValueError("Vision confidence must be finite and between 0 and 1")
    return f"VISION|{normalized}|{confidence:.3f}".encode("ascii")
