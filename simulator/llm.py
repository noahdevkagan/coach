"""Local LLM providers.

Hard constraint (PLAN.md): inference is local only. The Ollama provider REFUSES
any base URL whose host is not loopback, so a misconfiguration cannot route
inference to a cloud provider.

The Mock provider is a deterministic keyword heuristic so the whole loop +
backtest runs in CI / a sandbox with no model installed. It is NOT the product;
it just exercises the plumbing and gives a non-empty baseline.
"""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.parse
import urllib.request
from typing import Protocol

LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}

# Overridable because MeetingCoach.app's bundled ollama occupies the default
# port; the loopback assertion below still applies to any override.
DEFAULT_BASE_URL = os.environ.get("OLLAMA_BASE_URL", "http://127.0.0.1:11434/v1")


class Provider(Protocol):
    def complete(self, system: str, user: str) -> str: ...


def _assert_loopback(base_url: str) -> None:
    host = urllib.parse.urlparse(base_url).hostname
    if host not in LOOPBACK_HOSTS:
        raise ValueError(
            f"LLM base URL host {host!r} is not loopback. Refusing — inference "
            f"must stay on this machine. Allowed: {sorted(LOOPBACK_HOSTS)}"
        )


class OllamaProvider:
    """Talks to a local Ollama daemon (OpenAI-compatible chat endpoint)."""

    def __init__(self, model: str = "qwen2.5:7b-instruct",
                 base_url: str = DEFAULT_BASE_URL, timeout: float = 60.0):
        _assert_loopback(base_url)
        self.model = model
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def complete(self, system: str, user: str) -> str:
        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            "temperature": 0.2,
            "stream": False,
        }
        req = urllib.request.Request(
            f"{self.base_url}/chat/completions",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            body = json.loads(resp.read().decode())
        return body["choices"][0]["message"]["content"]


class MockProvider:
    """Deterministic keyword heuristic. Stand-in for offline runs only."""

    def complete(self, system: str, user: str) -> str:
        text = user.lower()
        calls: list[dict] = []

        def add(signal_id, confidence, evidence, nudge):
            calls.append({"signal_id": signal_id, "confidence": confidence,
                          "evidence": evidence, "nudge": nudge})

        if any(p in text for p in ["i think we agree", "sounds like we agree",
                                   "we're aligned", "i'm on board", "same page"]):
            add("alignment_reached_still_talking", 0.78,
                "participants signalling agreement", "They converged. Close it.")
        if any(p in text for p in ["circle back", "revisit", "as we discussed",
                                   "go back to", "reopen"]):
            add("reopening_closed_thread", 0.72,
                "a settled topic resurfacing", "This was settled. On purpose?")
        if any(p in text for p in ["by end of quarter", "sometime next", "roughly",
                                   "ballpark", "a few weeks", "ish", "should be able to"]):
            add("hedge_not_pinned", 0.83,
                "commitment stated as a range", "That was a range. Pin the date.")
        if any(p in text for p in ["churn", "missed", "down ", "risk", "behind plan",
                                   "miss the number", "lost the deal"]):
            add("buried_signal_ignored", 0.7,
                "a high-stakes number/risk mentioned", "That was the headline. Don't move on.")
        if any(p in text for p in ["who owns", "no owner", "let's decide", "what do we do",
                                   "still open", "haven't decided"]):
            add("no_decision_owner_date", 0.68,
                "open question with no owner/date", "Nothing named. Decide it or park it.")

        # Honor the per-trigger cap implied by the prompt (max 3 mentioned).
        return json.dumps(calls[:3])


def make_provider(kind: str, model: str | None = None) -> Provider:
    if kind == "ollama":
        return OllamaProvider(model=model or "qwen2.5:7b-instruct")
    if kind == "mock":
        return MockProvider()
    raise ValueError(f"unknown provider {kind!r} (use 'ollama' or 'mock')")
