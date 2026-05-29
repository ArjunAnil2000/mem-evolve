"""Thin adapter that wraps the Anthropic SDK behind an OpenAI-compatible interface.

Usage:
    client = create_llm_client(cfg["llm"])
    # Then use client.chat.completions.create(...) as normal
"""

import os
from typing import Any, Optional


class _AnthropicMessage:
    def __init__(self, content: str):
        self.content = content


class _AnthropicChoice:
    def __init__(self, content: str):
        self.message = _AnthropicMessage(content)


class _AnthropicResponse:
    def __init__(self, content: str):
        self.choices = [_AnthropicChoice(content)]


class _AnthropicCompletions:
    """Mimics client.chat.completions.create() using the Anthropic SDK."""

    def __init__(self, anthropic_client, thinking_budget: int = 10000):
        self._client = anthropic_client
        self._thinking_budget = thinking_budget

    def create(self, model: str, messages: list, temperature: float = 0.7,
               max_tokens: int = 16384, **kwargs) -> _AnthropicResponse:
        # Split system prompt from conversation messages
        system = ""
        msgs = []
        for m in messages:
            role = m["role"] if isinstance(m, dict) else m.role
            content = m["content"] if isinstance(m, dict) else m.content
            if role == "system":
                system = content
            else:
                msgs.append({"role": role, "content": content})

        create_kwargs = dict(
            model=model,
            messages=msgs,
            max_tokens=max_tokens,
        )
        if system:
            create_kwargs["system"] = system

        # Enable extended thinking for medium reasoning
        if self._thinking_budget > 0:
            create_kwargs["thinking"] = {
                "type": "enabled",
                "budget_tokens": self._thinking_budget,
            }
            # Anthropic API requires max_tokens > thinking.budget_tokens
            if create_kwargs["max_tokens"] <= self._thinking_budget:
                create_kwargs["max_tokens"] = self._thinking_budget + 8192
        else:
            create_kwargs["temperature"] = temperature

        resp = self._client.messages.create(**create_kwargs)

        # Extract text from response blocks
        text = ""
        for block in resp.content:
            if block.type == "text":
                text = block.text
                break

        return _AnthropicResponse(text)


class _AnthropicChat:
    def __init__(self, completions: _AnthropicCompletions):
        self.completions = completions


class AnthropicAdapter:
    """Drop-in replacement for OpenAI() that uses the Anthropic SDK."""

    def __init__(self, api_key: str, thinking_budget: int = 10000):
        import anthropic
        self._client = anthropic.Anthropic(api_key=api_key)
        self.chat = _AnthropicChat(_AnthropicCompletions(self._client, thinking_budget))


def create_llm_client(llm_cfg: dict) -> Any:
    """Create an LLM client based on the config's provider setting.

    Supports:
        provider = "anthropic" — uses Anthropic SDK with extended thinking
        provider = "openai" (default) — uses OpenAI SDK
    """
    provider = llm_cfg.get("provider", "openai")
    api_key = os.environ.get(llm_cfg["api_key_env"], "")

    if not api_key:
        print(f"Warning: {llm_cfg['api_key_env']} not set, LLM calls will fail")

    if provider == "anthropic":
        thinking_budget = llm_cfg.get("thinking_budget", 10000)
        return AnthropicAdapter(api_key=api_key, thinking_budget=thinking_budget)
    else:
        from openai import OpenAI
        return OpenAI(base_url=llm_cfg.get("api_base", ""), api_key=api_key)
