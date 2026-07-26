from __future__ import annotations

import datetime as dt
import sys
from dataclasses import dataclass
from typing import Iterable, Literal


UTC = dt.timezone.utc


@dataclass(frozen=True)
class JoinBatch:
    batch_id: int
    captured_at: dt.datetime


@dataclass(frozen=True)
class BoundarySelection:
    status: Literal["MATCH", "WAIT", "AMBIGUOUS"]
    match_window_seconds: int
    batch: JoinBatch | None = None
    skew_seconds: float | None = None


def parse_utc(value: str) -> dt.datetime:
    parsed = dt.datetime.fromisoformat(
        value[:-1] + "+00:00" if value.endswith("Z") else value
    )
    if parsed.tzinfo is None:
        raise ValueError("timestamp timezone icermiyor")
    return parsed.astimezone(UTC)


def format_utc(value: dt.datetime) -> str:
    return value.astimezone(UTC).isoformat(timespec="microseconds").replace(
        "+00:00", "Z"
    )


def match_window_seconds(source_frequency_seconds: int) -> int:
    if isinstance(source_frequency_seconds, bool) or source_frequency_seconds < 2:
        raise ValueError("source frequency en az 2 saniye olmali")
    # A scheduled successor starts no earlier than one source frequency later;
    # PoWA also rejects a second forced snapshot within ten seconds.  Stay one
    # full second inside both boundaries so a missing matching batch can never
    # be replaced by an unrelated future capture.
    return min(source_frequency_seconds - 1, 9)


def select_boundary(
    telemetry_finished_at: dt.datetime,
    source_frequency_seconds: int,
    batches: Iterable[JoinBatch],
) -> BoundarySelection:
    if telemetry_finished_at.tzinfo is None:
        raise ValueError("telemetry timestamp timezone icermiyor")
    telemetry_finished_at = telemetry_finished_at.astimezone(UTC)
    window = match_window_seconds(source_frequency_seconds)
    eligible: list[tuple[JoinBatch, float]] = []
    seen_ids: set[int] = set()

    for batch in batches:
        if isinstance(batch.batch_id, bool) or batch.batch_id < 1:
            raise ValueError("JOIN batch id pozitif olmali")
        if batch.batch_id in seen_ids:
            raise ValueError("JOIN batch id tekrari")
        seen_ids.add(batch.batch_id)
        if batch.captured_at.tzinfo is None:
            raise ValueError("JOIN capture timestamp timezone icermiyor")
        captured_at = batch.captured_at.astimezone(UTC)
        skew = (captured_at - telemetry_finished_at).total_seconds()
        if 0.0 <= skew <= float(window):
            eligible.append((JoinBatch(batch.batch_id, captured_at), skew))

    if not eligible:
        return BoundarySelection("WAIT", window)
    if len(eligible) != 1:
        return BoundarySelection("AMBIGUOUS", window)

    batch, skew = eligible[0]
    return BoundarySelection("MATCH", window, batch, skew)


def parse_batches(lines: Iterable[str]) -> list[JoinBatch]:
    batches: list[JoinBatch] = []
    for line_number, raw_line in enumerate(lines, 1):
        line = raw_line.strip()
        if not line:
            continue
        fields = line.split("|")
        if len(fields) != 2:
            raise ValueError(f"JOIN batch satiri gecersiz: {line_number}")
        try:
            batch_id = int(fields[0])
            captured_at = parse_utc(fields[1])
        except (TypeError, ValueError) as exc:
            raise ValueError(f"JOIN batch satiri parse edilemedi: {line_number}") from exc
        batches.append(JoinBatch(batch_id, captured_at))
    return batches


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(
            "Kullanim: realistic_join_boundary.py <telemetry-finished-at> "
            "<source-frequency-seconds>",
            file=sys.stderr,
        )
        return 2
    try:
        telemetry_finished_at = parse_utc(argv[1])
        source_frequency_seconds = int(argv[2])
        selection = select_boundary(
            telemetry_finished_at,
            source_frequency_seconds,
            parse_batches(sys.stdin),
        )
    except (TypeError, ValueError) as exc:
        print(f"JOIN boundary girdisi gecersiz: {exc}", file=sys.stderr)
        return 2

    if selection.status == "MATCH":
        assert selection.batch is not None
        assert selection.skew_seconds is not None
        print(
            f"MATCH|{selection.batch.batch_id}|"
            f"{format_utc(selection.batch.captured_at)}|"
            f"{selection.skew_seconds:.6f}|{selection.match_window_seconds}"
        )
    else:
        print(f"{selection.status}||||{selection.match_window_seconds}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
