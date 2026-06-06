"""Tests for the thinking/reasoning/beta upgrades.

Covers:
- ClaudeThinkingConfig union ({type,budget_tokens} + legacy {enabled}).
- Inbound thinking/redacted_thinking blocks are accepted (no validation error)
  and dropped during assistant conversion.
- stop_reason mapping (content_filter -> refusal).
- Provider reasoning_content -> Claude thinking block (non-streaming).
- effort forwarding (dynamic, from output_config.effort).
"""

import pytest

from src.conversion.request_converter import (
    _resolve_reasoning_effort,
    convert_claude_assistant_message,
    convert_claude_to_openai,
)
from src.conversion.response_converter import (
    _map_finish_reason,
    convert_openai_to_claude_response,
)
from src.core.config import config
from src.core.constants import Constants
from src.core.model_manager import model_manager
from src.models.claude import ClaudeMessagesRequest, ClaudeThinkingConfig


# --------------------------------------------------------------------------
# ClaudeThinkingConfig union
# --------------------------------------------------------------------------
def test_thinking_config_type_enabled():
    assert ClaudeThinkingConfig(type="enabled").is_enabled() is True


def test_thinking_config_type_disabled_is_off():
    # Regression: previously {"type":"disabled"} still extracted thinking.
    assert ClaudeThinkingConfig(type="disabled").is_enabled() is False


def test_thinking_config_unknown_type_is_enabled_not_422():
    # Regression: real Claude Code sends {"type":"adaptive"}. A strict Literal
    # 422'd the whole request. Any non-"disabled" mode must parse and count as on.
    assert ClaudeThinkingConfig(type="adaptive").is_enabled() is True
    assert ClaudeThinkingConfig(type="DISABLED").is_enabled() is False  # case-insensitive


def test_request_with_adaptive_thinking_does_not_raise():
    req = ClaudeMessagesRequest(
        model="claude-opus-4-7",
        max_tokens=100,
        messages=[{"role": "user", "content": "hi are u there?"}],
        thinking=ClaudeThinkingConfig(type="adaptive"),
    )
    assert req.thinking.is_enabled() is True


def test_thinking_config_legacy_enabled_flag():
    assert ClaudeThinkingConfig(enabled=True).is_enabled() is True
    assert ClaudeThinkingConfig(enabled=False).is_enabled() is False


def test_thinking_config_empty_defaults_enabled():
    # Matches prior behavior where enabled defaulted to True.
    assert ClaudeThinkingConfig().is_enabled() is True


def test_thinking_config_carries_budget_tokens():
    cfg = ClaudeThinkingConfig(type="enabled", budget_tokens=8000)
    assert cfg.budget_tokens == 8000


# --------------------------------------------------------------------------
# Inbound thinking blocks must not 422 and must be dropped on conversion
# --------------------------------------------------------------------------
def test_request_with_inbound_thinking_block_is_accepted():
    req = ClaudeMessagesRequest(
        model="claude-opus-4-7",
        max_tokens=100,
        messages=[
            {
                "role": "assistant",
                "content": [
                    {"type": "thinking", "thinking": "internal", "signature": "sig"},
                    {"type": "text", "text": "hello"},
                ],
            }
        ],
    )
    # The assistant turn parses without raising and yields a text-only message.
    assistant_msg = req.messages[0]
    out = convert_claude_assistant_message(assistant_msg, allow_tools=True)
    assert out["role"] == "assistant"
    assert out["content"] == "hello"  # thinking block dropped, text kept


def test_redacted_thinking_block_is_accepted():
    req = ClaudeMessagesRequest(
        model="claude-opus-4-7",
        max_tokens=100,
        messages=[
            {
                "role": "assistant",
                "content": [
                    {"type": "redacted_thinking", "data": "xxxx"},
                    {"type": "text", "text": "done"},
                ],
            }
        ],
    )
    out = convert_claude_assistant_message(req.messages[0], allow_tools=True)
    assert out["content"] == "done"


# --------------------------------------------------------------------------
# stop_reason mapping
# --------------------------------------------------------------------------
def test_map_finish_reason_content_filter_is_refusal():
    assert _map_finish_reason("content_filter") == Constants.STOP_REFUSAL


def test_map_finish_reason_standard_values():
    assert _map_finish_reason("stop") == Constants.STOP_END_TURN
    assert _map_finish_reason("length") == Constants.STOP_MAX_TOKENS
    assert _map_finish_reason("tool_calls") == Constants.STOP_TOOL_USE
    assert _map_finish_reason(None) == Constants.STOP_END_TURN


# --------------------------------------------------------------------------
# reasoning_content -> thinking block (non-streaming)
# --------------------------------------------------------------------------
def _req(thinking=True):
    return ClaudeMessagesRequest(
        model="claude-opus-4-7",
        max_tokens=100,
        messages=[{"role": "user", "content": "hi"}],
        thinking=ClaudeThinkingConfig(type="enabled") if thinking else None,
    )


def test_reasoning_content_becomes_thinking_block():
    openai_response = {
        "id": "x",
        "choices": [
            {
                "finish_reason": "stop",
                "message": {"content": "the answer", "reasoning_content": "let me think"},
            }
        ],
    }
    result = convert_openai_to_claude_response(openai_response, _req(thinking=True))
    types = [b["type"] for b in result["content"]]
    assert "thinking" in types
    thinking_block = next(b for b in result["content"] if b["type"] == "thinking")
    assert thinking_block["thinking"] == "let me think"
    # text content still present
    assert any(b["type"] == "text" and b["text"] == "the answer" for b in result["content"])


def test_reasoning_content_ignored_when_thinking_disabled():
    openai_response = {
        "id": "x",
        "choices": [
            {
                "finish_reason": "stop",
                "message": {"content": "the answer", "reasoning_content": "hidden"},
            }
        ],
    }
    result = convert_openai_to_claude_response(openai_response, _req(thinking=False))
    assert all(b["type"] != "thinking" for b in result["content"])


# --------------------------------------------------------------------------
# Effort forwarding (dynamic, from Claude Code's output_config.effort)
# --------------------------------------------------------------------------
def test_resolve_effort_from_client():
    req = ClaudeMessagesRequest(
        model="claude-opus-4-8", max_tokens=100,
        messages=[{"role": "user", "content": "hi"}],
        output_config={"effort": "xhigh"},
    )
    assert _resolve_reasoning_effort(req) == "high"


def test_resolve_effort_none_when_absent():
    req = ClaudeMessagesRequest(
        model="claude-opus-4-8", max_tokens=100,
        messages=[{"role": "user", "content": "hi"}],
    )
    assert _resolve_reasoning_effort(req) is None


# --------------------------------------------------------------------------
# Adaptive thinking: display handling (Opus 4.7/4.8 -> omitted by default)
# --------------------------------------------------------------------------
import pytest

from src.conversion.response_converter import (
    _should_surface_thinking,
    _strip_think_tags,
    convert_openai_streaming_to_claude_with_cancellation,
)
from src.conversion.request_converter import _client_effort, _map_client_effort


def test_surfaces_text_matrix():
    from src.models.claude import ClaudeThinkingConfig as T
    assert T(type="disabled").surfaces_text() is False
    # adaptive with no display -> omitted default -> not surfaced
    assert T(type="adaptive").surfaces_text() is False
    assert T(type="adaptive", display="summarized").surfaces_text() is True
    assert T(type="adaptive", display="omitted").surfaces_text() is False
    # classic enabled -> summarized default -> surfaced
    assert T(type="enabled").surfaces_text() is True
    assert T(type="enabled", display="omitted").surfaces_text() is False


def _adaptive_req(display=None):
    from src.models.claude import ClaudeThinkingConfig
    return ClaudeMessagesRequest(
        model="claude-opus-4-8",
        max_tokens=256,
        messages=[{"role": "user", "content": "hi"}],
        thinking=ClaudeThinkingConfig(type="adaptive", display=display),
    )


def test_should_surface_respects_override(monkeypatch):
    monkeypatch.setattr(config, "thinking_display_override", "")
    assert _should_surface_thinking(_adaptive_req()) is False  # omitted default
    monkeypatch.setattr(config, "thinking_display_override", "summarized")
    assert _should_surface_thinking(_adaptive_req()) is True
    monkeypatch.setattr(config, "thinking_display_override", "omitted")
    assert _should_surface_thinking(_adaptive_req(display="summarized")) is False


def test_strip_think_tags():
    assert _strip_think_tags("a<think>secret</think>b") == "ab"
    assert _strip_think_tags("hello") == "hello"
    assert _strip_think_tags("x<think>unclosed") == "x"


def test_nonstream_adaptive_omitted_suppresses_reasoning(monkeypatch):
    monkeypatch.setattr(config, "thinking_display_override", "")
    resp = {
        "id": "x",
        "choices": [{
            "finish_reason": "stop",
            "message": {"content": "<think>plan</think>answer", "reasoning_content": "deep"},
        }],
    }
    out = convert_openai_to_claude_response(resp, _adaptive_req())  # omitted default
    assert all(b["type"] != "thinking" for b in out["content"])  # no thinking surfaced
    text = "".join(b.get("text", "") for b in out["content"])
    assert "plan" not in text and "deep" not in text  # reasoning stripped
    assert text == "answer"


def test_nonstream_adaptive_summarized_surfaces(monkeypatch):
    monkeypatch.setattr(config, "thinking_display_override", "")
    resp = {
        "id": "x",
        "choices": [{
            "finish_reason": "stop",
            "message": {"content": "<think>plan</think>answer"},
        }],
    }
    out = convert_openai_to_claude_response(resp, _adaptive_req(display="summarized"))
    assert any(b["type"] == "thinking" for b in out["content"])


def test_nonstream_thinking_disabled_strips_leak():
    req = ClaudeMessagesRequest(
        model="claude-opus-4-8", max_tokens=128,
        messages=[{"role": "user", "content": "hi"}],
    )  # no thinking -> disabled
    resp = {"id": "x", "choices": [{"finish_reason": "stop",
            "message": {"content": "<think>noise</think>visible"}}]}
    out = convert_openai_to_claude_response(resp, req)
    text = "".join(b.get("text", "") for b in out["content"])
    assert text == "visible"
    assert all(b["type"] != "thinking" for b in out["content"])


# --- effort passthrough ---
def test_map_client_effort():
    assert _map_client_effort("xhigh") == "high"
    assert _map_client_effort("max") == "high"
    assert _map_client_effort("medium") == "medium"
    assert _map_client_effort("low") == "low"
    assert _map_client_effort(None) is None


def test_client_effort_read():
    req = ClaudeMessagesRequest(
        model="claude-opus-4-8", max_tokens=128,
        messages=[{"role": "user", "content": "hi"}],
        output_config={"effort": "xhigh"},
    )
    assert _client_effort(req) == "xhigh"


def test_effort_injected_dynamically():
    req = ClaudeMessagesRequest(
        model="claude-opus-4-8", max_tokens=128,
        messages=[{"role": "user", "content": "hi"}],
        output_config={"effort": "xhigh"},
    )
    out = convert_claude_to_openai(req, model_manager)
    assert out.get("reasoning_effort") == "high"


def test_no_effort_no_injection():
    req = ClaudeMessagesRequest(
        model="claude-opus-4-8", max_tokens=128,
        messages=[{"role": "user", "content": "hi"}],
    )
    out = convert_claude_to_openai(req, model_manager)
    assert "reasoning_effort" not in out


def test_effort_skipped_for_unsupported_model():
    from src.core.client import _EFFORT_UNSUPPORTED_MODELS
    req = ClaudeMessagesRequest(
        model="claude-opus-4-8", max_tokens=128,
        messages=[{"role": "user", "content": "hi"}],
        output_config={"effort": "high"},
    )
    backend = config.big_model  # opus -> big_model
    _EFFORT_UNSUPPORTED_MODELS.add(backend)
    try:
        out = convert_claude_to_openai(req, model_manager)
        assert "reasoning_effort" not in out
    finally:
        _EFFORT_UNSUPPORTED_MODELS.discard(backend)


# --- streaming drop / surface ---
class _DummyReq:
    async def is_disconnected(self):
        return False


class _DummyClient:
    def cancel_request(self, _):
        return True


class _DummyLog:
    def debug(self, *a, **k): pass
    def info(self, *a, **k): pass
    def warning(self, *a, **k): pass
    def error(self, *a, **k): pass


async def _think_stream():
    import json as _j
    yield "data: " + _j.dumps({"choices": [{"delta": {"content": "<think>secret"}, "finish_reason": None}]})
    yield "data: " + _j.dumps({"choices": [{"delta": {"content": " plan</think>hello"}, "finish_reason": None}]})
    yield "data: " + _j.dumps({"choices": [{"delta": {}, "finish_reason": "stop"}]})
    yield "data: [DONE]"


async def _collect(req):
    out = []
    async for ev in convert_openai_streaming_to_claude_with_cancellation(
        _think_stream(), req, _DummyLog(), _DummyReq(), _DummyClient(), "rid"
    ):
        out.append(ev)
    return "".join(out)


@pytest.mark.asyncio
async def test_stream_adaptive_omitted_drops_think(monkeypatch):
    monkeypatch.setattr(config, "thinking_display_override", "")
    serialized = await _collect(_adaptive_req())  # omitted default
    assert "thinking_delta" not in serialized
    assert "secret" not in serialized and "plan" not in serialized
    assert '"text": "hello"' in serialized


@pytest.mark.asyncio
async def test_stream_adaptive_summarized_surfaces(monkeypatch):
    monkeypatch.setattr(config, "thinking_display_override", "")
    serialized = await _collect(_adaptive_req(display="summarized"))
    assert "thinking_delta" in serialized
    assert '"text": "hello"' in serialized
