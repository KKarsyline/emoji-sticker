"""Streaming parser and validation helpers for emoji reactions."""
from __future__ import annotations

from typing import Any, Optional

import emoji


MAX_REACTION_PREFIX_CHARS = 128
MAX_REACTION_TARGET_ID_BYTES = 512
MAX_REACTION_EMOJI_BYTES = 64
_OPEN = "<react>"
_CLOSE = "</react>"


def is_valid_reaction_emoji(value: Any) -> bool:
    """Accept exactly one emoji sequence supported by the pinned Unicode data."""
    return (
        isinstance(value, str)
        and bool(value)
        and len(value.encode("utf-8")) <= MAX_REACTION_EMOJI_BYTES
        and "\n" not in value
        and "\r" not in value
        and emoji.is_emoji(value)
    )


def is_valid_user_reaction_payload(target_message_id: Any, value: Any) -> bool:
    return (
        isinstance(target_message_id, str)
        and bool(target_message_id)
        and len(target_message_id.encode("utf-8")) <= MAX_REACTION_TARGET_ID_BYTES
        and is_valid_reaction_emoji(value)
    )


def user_reaction_prefix(value: str) -> str:
    if not is_valid_reaction_emoji(value):
        raise ValueError("invalid reaction emoji")
    return f"user posted:{value}\n"


def reaction_from_message(
    message: Optional[dict[str, Any]],
    target_message_id: str,
) -> Optional[dict[str, str]]:
    """Read one branch-owned reaction only when both ownership links agree."""
    if (not isinstance(message, dict)
            or message.get("role") != "assistant"
            or message.get("parent_message_id") != target_message_id):
        return None
    content = message.get("content")
    if not isinstance(content, list):
        return None
    for block in content:
        if not isinstance(block, dict) or block.get("type") != "reaction":
            continue
        target = block.get("target_message_id")
        value = block.get("emoji")
        if target == target_message_id and is_valid_reaction_emoji(value):
            return {"target_message_id": target, "emoji": value}
    return None


class ReactionPrefixParser:
    """Incrementally strip one valid leading <react> prefix, preserving all else."""

    def __init__(self, *, enabled: bool = True) -> None:
        self._pending = ""
        self._plain = not enabled
        self.reaction: Optional[str] = None

    @property
    def has_pending_prefix(self) -> bool:
        return bool(self._pending)

    def _classify(self) -> tuple[str, Optional[str], str]:
        """Return (possible|invalid|valid, emoji, suffix) for the bounded candidate."""
        candidate = self._pending
        if len(candidate) > MAX_REACTION_PREFIX_CHARS:
            return "invalid", None, ""
        offset = 0
        while offset < len(candidate) and candidate[offset].isspace():
            offset += 1
        if offset == len(candidate):
            return "possible", None, ""
        tag = candidate[offset:]
        matched = min(len(tag), len(_OPEN))
        if tag[:matched] != _OPEN[:matched]:
            return "invalid", None, ""
        if len(tag) < len(_OPEN):
            return "possible", None, ""
        body_start = offset + len(_OPEN)
        close_at = candidate.find(_CLOSE, body_start)
        if close_at < 0:
            return "possible", None, ""
        prefix_end = close_at + len(_CLOSE)
        if prefix_end > MAX_REACTION_PREFIX_CHARS:
            return "invalid", None, ""
        raw_value = candidate[body_start:close_at]
        if "\n" in raw_value or "\r" in raw_value:
            return "invalid", None, ""
        value = raw_value.strip()
        if not is_valid_reaction_emoji(value):
            return "invalid", None, ""
        return "valid", value, candidate[prefix_end:]

    def feed(self, text: str) -> tuple[str, Optional[str]]:
        """Return visible text and a newly parsed emoji, if this chunk completes it."""
        if not text:
            return "", None
        if self._plain:
            return text, None
        visible: list[str] = []
        for index, char in enumerate(text):
            self._pending += char
            state, value, suffix = self._classify()
            if state == "possible":
                continue
            if state == "invalid":
                visible.append(self._pending)
                self._pending = ""
                self._plain = True
                visible.append(text[index + 1:])
                return "".join(visible), None
            self.reaction = value
            self._pending = ""
            self._plain = True
            visible.append(suffix)
            visible.append(text[index + 1:])
            return "".join(visible), value
        return "".join(visible), None

    def finish(self) -> str:
        """Flush an incomplete prefix literally at done/error/cancellation."""
        pending, self._pending = self._pending, ""
        self._plain = True
        return pending
