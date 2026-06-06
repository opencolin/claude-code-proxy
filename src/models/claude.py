from typing import Any, Dict, List, Literal, Optional, Union

from pydantic import BaseModel, Field


class ClaudeContentBlockText(BaseModel):
    type: Literal["text"]
    text: str


class ClaudeContentBlockImage(BaseModel):
    type: Literal["image"]
    source: Dict[str, Any]


class ClaudeContentBlockToolUse(BaseModel):
    type: Literal["tool_use"]
    id: str
    name: str
    input: Dict[str, Any]


class ClaudeContentBlockToolResult(BaseModel):
    type: Literal["tool_result"]
    tool_use_id: str
    content: Union[str, List[Dict[str, Any]], Dict[str, Any]]


class ClaudeContentBlockThinking(BaseModel):
    """Extended-thinking block echoed back by clients (interleaved thinking).

    Anthropic sends prior `thinking`/`redacted_thinking` blocks inside assistant
    turns. They must be accepted (not 422'd) even though OpenAI-compatible
    backends don't consume them; conversion deliberately drops them.
    """

    type: Literal["thinking", "redacted_thinking"]
    thinking: Optional[str] = None
    signature: Optional[str] = None
    data: Optional[str] = None  # present on redacted_thinking

    class Config:
        extra = "allow"


class ClaudeSystemContent(BaseModel):
    type: Literal["text"]
    text: str


class ClaudeMessage(BaseModel):
    role: Literal["user", "assistant", "system"]
    content: Union[
        str,
        List[
            Union[
                ClaudeContentBlockText,
                ClaudeContentBlockImage,
                ClaudeContentBlockToolUse,
                ClaudeContentBlockToolResult,
                ClaudeContentBlockThinking,
            ]
        ],
    ]

    class Config:
        extra = "allow"  # Forward compat: ignore unknown fields (e.g. cache_control on the message)


class ClaudeTool(BaseModel):
    """Represents both standard function tools and schema-less Anthropic tools.

    Standard tools have: name, input_schema, optional description
    Schema-less tools have: type (e.g. "computer_20251124"), name, and
    type-specific fields (display_width_px, display_height_px, etc.)
    """

    # Common fields
    name: str
    type: Optional[str] = None  # e.g. "computer_20251124", "bash_20250124", "text_editor_20250728"
    description: Optional[str] = None
    input_schema: Optional[Dict[str, Any]] = None  # None for schema-less tools

    # Computer use specific fields
    display_width_px: Optional[int] = None
    display_height_px: Optional[int] = None
    display_number: Optional[int] = None
    enable_zoom: Optional[bool] = None

    class Config:
        extra = "allow"  # Allow extra fields for forward compatibility

    def is_schema_less(self) -> bool:
        """Check if this is a schema-less Anthropic tool (computer, bash, text_editor)."""
        if self.type is None:
            return False
        return any(
            self.type.startswith(prefix) for prefix in ("computer_", "bash_", "text_editor_")
        )


class ClaudeThinkingConfig(BaseModel):
    """Extended-thinking configuration.

    Anthropic's wire shape is ``{"type": "enabled"|"disabled", "budget_tokens": N}``.
    Some clients (and older builds) send ``{"enabled": bool}``. Both are accepted.
    Use :meth:`is_enabled` instead of reading a single field.
    """

    # NOTE: `type` is intentionally a free string, not a Literal. Anthropic adds
    # new thinking modes over time (e.g. "enabled", "disabled", "adaptive"); a
    # strict enum would 422 on any value we haven't seen yet. "disabled" is the
    # only value that turns thinking off — everything else is an enabled mode.
    type: Optional[str] = None
    budget_tokens: Optional[int] = None
    enabled: Optional[bool] = None  # legacy/alternate clients
    # "summarized" | "omitted". Controls whether thinking *text* is returned.
    # On Opus 4.7/4.8 (adaptive) the API default is "omitted".
    display: Optional[str] = None

    class Config:
        extra = "allow"

    def is_enabled(self) -> bool:
        if self.type is not None:
            return self.type.lower() != "disabled"
        if self.enabled is not None:
            return bool(self.enabled)
        # A thinking object present with neither field set defaults to enabled,
        # matching the previous behavior (enabled defaulted to True).
        return True

    def surfaces_text(self) -> bool:
        """Whether the model's thinking *text* should be surfaced to the client.

        Honors `display` exactly when the client sets it. When unset, mirrors the
        Anthropic model defaults: adaptive mode defaults to "omitted" (Opus
        4.7/4.8), classic `enabled` mode defaults to "summarized". Returns False
        whenever thinking is disabled.
        """
        if not self.is_enabled():
            return False
        disp = (self.display or "").lower()
        if disp == "summarized":
            return True
        if disp == "omitted":
            return False
        # No explicit display: adaptive -> omitted, enabled/other -> summarized.
        return (self.type or "").lower() != "adaptive"


class ClaudeMessagesRequest(BaseModel):
    model: str
    max_tokens: int
    messages: List[ClaudeMessage]
    system: Optional[Union[str, List[ClaudeSystemContent]]] = None
    stop_sequences: Optional[List[str]] = None
    stream: Optional[bool] = False
    temperature: Optional[float] = 1.0
    top_p: Optional[float] = None
    top_k: Optional[int] = None
    metadata: Optional[Dict[str, Any]] = None
    tools: Optional[List[ClaudeTool]] = None
    tool_choice: Optional[Dict[str, Any]] = None
    thinking: Optional[ClaudeThinkingConfig] = None
    # Beta headers forwarded by Anthropic SDK clients
    betas: Optional[List[str]] = None

    class Config:
        extra = "allow"  # Forward compatibility


class ClaudeTokenCountRequest(BaseModel):
    model: str
    messages: List[ClaudeMessage]
    system: Optional[Union[str, List[ClaudeSystemContent]]] = None
    tools: Optional[List[ClaudeTool]] = None
    thinking: Optional[ClaudeThinkingConfig] = None
    tool_choice: Optional[Dict[str, Any]] = None
