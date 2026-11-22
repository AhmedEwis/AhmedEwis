"""LLM provider abstraction. Credentials stay server-side."""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any, Protocol

import httpx

from ..config import Settings
from ..errors import APIError


@dataclass
class LLMResult:
    content: str | None
    tool_calls: list[dict] = field(default_factory=list)
    input_tokens: int = 0
    output_tokens: int = 0
    provider: str = ""
    model: str = ""


class LLMProvider(Protocol):
    name: str

    def chat(self, messages: list[dict], tools: list[dict] | None = None, json_schema: dict | None = None, max_tokens: int = 800) -> LLMResult: ...


class DisabledProvider:
    name = "disabled"

    def chat(self, messages, tools=None, json_schema=None, max_tokens=800) -> LLMResult:
        raise APIError(503, "provider_not_configured", "Cloud AI is not configured on this server")


class AzureOpenAIProvider:
    name = "azure_openai"

    def __init__(self, endpoint: str, api_key: str, deployment: str, api_version: str, client: httpx.Client | None = None):
        if not (endpoint and api_key and deployment):
            raise ValueError("Azure OpenAI endpoint, key and deployment are required")
        self.endpoint = endpoint.rstrip("/")
        self.api_key = api_key
        self.deployment = deployment
        self.api_version = api_version
        self.client = client or httpx.Client(timeout=30.0)

    def chat(self, messages, tools=None, json_schema=None, max_tokens=800) -> LLMResult:
        body: dict[str, Any] = {"messages": messages, "max_tokens": max_tokens, "temperature": 0.1}
        if tools:
            body["tools"] = [{"type": "function", "function": t} for t in tools]
            body["tool_choice"] = "auto"
        if json_schema:
            body["response_format"] = {"type": "json_schema", "json_schema": {"name": "extraction", "schema": json_schema, "strict": True}}
        url = f"{self.endpoint}/openai/deployments/{self.deployment}/chat/completions?api-version={self.api_version}"
        try:
            r = self.client.post(url, headers={"api-key": self.api_key}, json=body)
        except httpx.HTTPError as e:
            raise APIError(503, "provider_unavailable", "AI provider is unavailable") from e
        if r.status_code == 429:
            raise APIError(503, "provider_throttled", "AI provider is busy; try again shortly")
        if r.status_code >= 400:
            raise APIError(502, "provider_error", f"AI provider returned {r.status_code}")
        data = r.json()
        choice = data["choices"][0]["message"]
        calls = []
        for tc in choice.get("tool_calls") or []:
            fn = tc.get("function", {})
            try:
                args = json.loads(fn.get("arguments") or "{}")
            except json.JSONDecodeError:
                args = {}
            calls.append({"id": tc.get("id"), "name": fn.get("name"), "arguments": args})
        usage = data.get("usage", {})
        return LLMResult(
            content=choice.get("content"),
            tool_calls=calls,
            input_tokens=int(usage.get("prompt_tokens", 0)),
            output_tokens=int(usage.get("completion_tokens", 0)),
            provider=self.name,
            model=data.get("model", self.deployment),
        )


class FakeProvider:
    """Deterministic provider used ONLY by the test-suite (refused in production)."""

    name = "fake"

    def __init__(self):
        self.responses: list[LLMResult] = []
        self.calls: list[dict] = []

    def chat(self, messages, tools=None, json_schema=None, max_tokens=800) -> LLMResult:
        self.calls.append({"messages": messages, "tools": tools, "json_schema": json_schema})
        if self.responses:
            return self.responses.pop(0)
        return LLMResult(content="ok", input_tokens=10, output_tokens=5, provider="fake", model="fake-1")


def build_llm(settings: Settings) -> LLMProvider:
    if settings.llm_provider == "azure_openai":
        return AzureOpenAIProvider(
            settings.azure_openai_endpoint,
            settings.azure_openai_api_key,
            settings.azure_openai_deployment,
            settings.azure_openai_api_version,
        )
    if settings.llm_provider == "fake":
        if settings.is_production:
            raise ValueError("fake LLM provider is not allowed in production")
        return FakeProvider()
    return DisabledProvider()
