"""Rubric loading. A rubric is a swappable YAML config (see ../rubrics/).

Swapping the file swaps the coach's judgment with no code change.
"""
from __future__ import annotations

import dataclasses
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml


@dataclass
class Signal:
    id: str
    tier: str
    description: str
    nudge: str = ""
    needs_diarization: bool = False
    params: dict[str, Any] = field(default_factory=dict)
    # Resolved from the tier table at load time.
    min_confidence: float = 0.6


@dataclass
class Cadence:
    heartbeat_seconds: int = 45
    extra_check_on_long_pause_seconds: int = 8
    extra_check_on_speaker_handoff: bool = True


@dataclass
class Window:
    transcript_seconds: int = 240
    keep_running_summary: bool = True


@dataclass
class Output:
    max_calls_per_trigger: int = 3
    min_confidence_to_show: float = 0.6


@dataclass
class Rubric:
    name: str
    cadence: Cadence
    window: Window
    output: Output
    signals: list[Signal]
    end_of_meeting: list[dict[str, Any]] = field(default_factory=list)
    version: int = 1

    def signal(self, signal_id: str) -> Signal | None:
        return next((s for s in self.signals if s.id == signal_id), None)

    @property
    def signal_ids(self) -> list[str]:
        return [s.id for s in self.signals]


def load_rubric(path: str | Path) -> Rubric:
    data = yaml.safe_load(Path(path).read_text())
    tiers = data.get("tiers", {})

    signals: list[Signal] = []
    for raw in data.get("signals", []):
        tier = raw.get("tier", "A")
        tier_floor = tiers.get(tier, {}).get("min_confidence", 0.6)
        signals.append(
            Signal(
                id=raw["id"],
                tier=tier,
                description=raw.get("description", ""),
                nudge=raw.get("nudge", ""),
                needs_diarization=raw.get("needs_diarization", False),
                params=raw.get("params", {}),
                min_confidence=tier_floor,
            )
        )

    return Rubric(
        name=data.get("name", "unnamed"),
        version=data.get("version", 1),
        cadence=Cadence(**(data.get("cadence", {}))),
        window=Window(**(data.get("window", {}))),
        output=Output(**(data.get("output", {}))),
        signals=signals,
        end_of_meeting=data.get("end_of_meeting", []),
    )
