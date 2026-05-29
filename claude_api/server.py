"""
OpenAI-compatible API server backed by Claude Code CLI.

Exposes /v1/chat/completions that translates OpenAI-format requests
into `claude -p` invocations and returns OpenAI-format responses.

Supports both streaming (SSE) and non-streaming modes.

Usage:
    python server.py                     # runs on port 8082
    PORT=9000 python server.py           # custom port

    # Then point any OpenAI-compatible client at it:
    export OPENAI_BASE_URL=http://localhost:8082/v1
    export OPENAI_API_KEY=dummy
"""

import asyncio
import json
import logging
import os
import time
import uuid
from typing import Optional

from fastapi import FastAPI
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("claude-proxy")

app = FastAPI(title="Claude Code OpenAI Proxy")

# ---------------------------------------------------------------------------
# Request / response models (subset of OpenAI spec)
# ---------------------------------------------------------------------------

class Message(BaseModel):
    role: str
    content: str

class ChatCompletionRequest(BaseModel):
    model: str = "claude-code"
    messages: list[Message]
    stream: bool = False
    temperature: Optional[float] = None
    max_tokens: Optional[int] = None

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Map incoming model names to claude CLI --model values.
# None means "use the default" (whatever claude code is configured with).
MODEL_MAP = {
    "claude-code": None,
    "gpt-4": None,
    "gpt-4o": None,
    "gpt-4o-mini": None,
    "gpt-3.5-turbo": None,
    "claude-opus": "opus",
    "claude-sonnet": "sonnet",
    "claude-haiku": "haiku",
    "claude-sonnet-4-6": "claude-sonnet-4-6",
    "claude-opus-4-7": "claude-opus-4-7",
}

# Per-model effort level (maps to --effort flag)
MODEL_EFFORT = {
    "claude-sonnet-4-6": "medium",
}


def build_prompt(messages: list[Message]) -> str:
    """Flatten OpenAI-style messages into a single prompt for claude -p."""
    parts = []
    for m in messages:
        if m.role == "system":
            parts.append(f"[System]: {m.content}")
        elif m.role == "user":
            parts.append(m.content)
        elif m.role == "assistant":
            parts.append(f"[Assistant previously said]: {m.content}")
    return "\n\n".join(parts)


def _claude_binary() -> str:
    """Find the claude binary, checking PATH and common install locations."""
    import shutil
    found = shutil.which("claude")
    if found:
        return found
    for candidate in [
        os.path.expanduser("~/.local/bin/claude"),
        "/usr/local/bin/claude",
    ]:
        if os.path.isfile(candidate):
            return candidate
    return "claude"  # fallback, will fail with a clear error


def build_claude_cmd(prompt: str, model: Optional[str], stream: bool, effort: Optional[str] = None) -> list[str]:
    cmd = [_claude_binary(), "-p"]
    if model:
        cmd += ["--model", model]
    if effort:
        cmd += ["--effort", effort]
    if stream:
        cmd += ["--output-format", "stream-json"]
    else:
        cmd += ["--output-format", "json"]
    cmd.append(prompt)
    return cmd


def make_completion_id() -> str:
    return f"chatcmpl-{uuid.uuid4().hex[:12]}"


def openai_response(completion_id: str, model: str, content: str,
                    prompt_tokens: int = 0, completion_tokens: int = 0,
                    finish_reason: str = "stop") -> dict:
    return {
        "id": completion_id,
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [{
            "index": 0,
            "message": {"role": "assistant", "content": content},
            "finish_reason": finish_reason,
        }],
        "usage": {
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "total_tokens": prompt_tokens + completion_tokens,
        },
    }


def openai_chunk(completion_id: str, model: str, content: str = "",
                 finish_reason: Optional[str] = None) -> str:
    chunk = {
        "id": completion_id,
        "object": "chat.completion.chunk",
        "created": int(time.time()),
        "model": model,
        "choices": [{
            "index": 0,
            "delta": {"content": content} if content else {},
            "finish_reason": finish_reason,
        }],
    }
    return f"data: {json.dumps(chunk)}\n\n"


def clean_env() -> dict:
    """Return a copy of os.environ without CLAUDECODE (prevents nested-session error)."""
    env = {**os.environ}
    env.pop("CLAUDECODE", None)
    return env


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.get("/v1/models")
async def list_models():
    models = []
    for name in MODEL_MAP:
        models.append({
            "id": name,
            "object": "model",
            "created": int(time.time()),
            "owned_by": "claude-code-proxy",
        })
    return {"object": "list", "data": models}


@app.post("/v1/chat/completions")
async def chat_completions(req: ChatCompletionRequest):
    prompt = build_prompt(req.messages)
    mapped_model = MODEL_MAP.get(req.model)
    completion_id = make_completion_id()
    model_name = req.model
    env = clean_env()

    effort = MODEL_EFFORT.get(req.model)

    if req.stream:
        return StreamingResponse(
            stream_response(prompt, mapped_model, completion_id, model_name, env, effort),
            media_type="text/event-stream",
        )
    else:
        return await non_stream_response(prompt, mapped_model, completion_id, model_name, env, effort)


async def non_stream_response(prompt, model, completion_id, model_name, env, effort=None):
    cmd = build_claude_cmd(prompt, model, stream=False, effort=effort)
    log.info("non-stream request (prompt %d chars)", len(prompt))

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        env=env,
    )
    stdout, stderr = await proc.communicate()

    if proc.returncode != 0:
        log.error("claude CLI error: %s", stderr.decode()[:500])
        return JSONResponse(
            status_code=500,
            content={"error": {"message": f"Claude CLI error: {stderr.decode()}", "type": "server_error"}},
        )

    try:
        data = json.loads(stdout.decode())
    except json.JSONDecodeError:
        data = {"result": stdout.decode().strip()}

    content = data.get("result", "")
    usage = data.get("usage", {})
    prompt_tokens = usage.get("input_tokens", 0) + usage.get("cache_read_input_tokens", 0)
    completion_tokens = usage.get("output_tokens", 0)

    log.info("response: %d chars, %d prompt tokens, %d completion tokens",
             len(content), prompt_tokens, completion_tokens)

    return JSONResponse(content=openai_response(
        completion_id, model_name, content,
        prompt_tokens=prompt_tokens,
        completion_tokens=completion_tokens,
    ))


async def stream_response(prompt, model, completion_id, model_name, env, effort=None):
    cmd = build_claude_cmd(prompt, model, stream=True, effort=effort)
    log.info("stream request (prompt %d chars)", len(prompt))

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        env=env,
    )

    # Initial role chunk
    yield openai_chunk(completion_id, model_name)

    streamed_any_content = False
    async for raw_line in proc.stdout:
        line = raw_line.decode().strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue

        etype = event.get("type", "")

        # assistant message with content blocks
        if etype == "assistant" and "content" in event:
            for block in event.get("content", []):
                if block.get("type") == "text":
                    text = block.get("text", "")
                    if text:
                        yield openai_chunk(completion_id, model_name, content=text)
                        streamed_any_content = True

        # content_block_delta (incremental text)
        elif etype == "content_block_delta":
            delta = event.get("delta", {})
            if delta.get("type") == "text_delta":
                text = delta.get("text", "")
                if text:
                    yield openai_chunk(completion_id, model_name, content=text)
                    streamed_any_content = True

        # result event — fallback if no incremental content was streamed
        elif etype == "result":
            result_text = event.get("result", "")
            if result_text and not streamed_any_content:
                yield openai_chunk(completion_id, model_name, content=result_text)
                streamed_any_content = True

    yield openai_chunk(completion_id, model_name, finish_reason="stop")
    yield "data: [DONE]\n\n"
    await proc.wait()


@app.get("/health")
async def health():
    return {"status": "ok"}


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("PORT", 8082))
    log.info("Starting Claude Code OpenAI proxy on port %d", port)
    uvicorn.run(app, host="0.0.0.0", port=port)
