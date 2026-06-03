#!/usr/bin/env python3
import argparse
import base64
import json
import sys


def device_summary(device):
    return {"id": device.get("id"), "name": device.get("name")}


def load_state(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def fail(message):
    raise SystemExit(message)


def assert_device(state, expected_id, expected_name):
    devices = {device.get("id"): device for device in state.get("devices", [])}
    device = devices.get(expected_id)
    if device is None:
        seen = [device_summary(device) for device in state.get("devices", [])]
        fail(f"missing expected device {expected_id}; seen devices: {seen}")
    if device.get("name") != expected_name:
        fail(f"device {expected_id} name mismatch: expected {expected_name!r}, got {device.get('name')!r}")


def frame_sources(state):
    counts = frame_source_counts(state)
    if counts:
        return [source for source, count in counts.items() if count > 0]

    sources = []
    for item in state.get("frames", []):
        source = item.get("from")
        frame = item.get("frame", {})
        wire = frame.get("wireDataBase64", "")
        if source and valid_base64(wire):
            sources.append(source)
    return sources


def frame_source_counts(state):
    raw_counts = state.get("frameCountsBySource", {})
    if not isinstance(raw_counts, dict):
        return {}

    counts = {}
    for source, count in raw_counts.items():
        if not source:
            continue
        try:
            counts[source] = int(count)
        except (TypeError, ValueError):
            continue
    return counts


def valid_base64(value):
    if not value:
        return False
    try:
        base64.b64decode(value, validate=True)
    except Exception:
        return False
    return True


def main():
    parser = argparse.ArgumentParser(description="Assert Sonar simulator relay E2E state")
    parser.add_argument("state_json")
    parser.add_argument("--expected-a-id", required=True)
    parser.add_argument("--expected-b-id", required=True)
    parser.add_argument("--expected-a-name", default="SIM-A")
    parser.add_argument("--expected-b-name", default="SIM-B")
    parser.add_argument("--min-total-frames", type=int, default=10)
    args = parser.parse_args()

    state = load_state(args.state_json)
    assert_device(state, args.expected_a_id, args.expected_a_name)
    assert_device(state, args.expected_b_id, args.expected_b_name)

    frame_count = int(state.get("frameCount", 0))
    if frame_count < args.min_total_frames:
        fail(f"expected at least {args.min_total_frames} relayed frames, got {frame_count}")

    sources = frame_sources(state)
    source_counts = frame_source_counts(state)
    missing_sources = [
        expected_id for expected_id in [args.expected_a_id, args.expected_b_id] if expected_id not in sources
    ]
    if missing_sources:
        fail(f"missing frame(s) from {missing_sources}; frame sources: {sources}")

    print(
        json.dumps(
            {
                "devices": [device_summary(device) for device in state.get("devices", [])],
                "frameCount": frame_count,
                "frameCountsBySource": source_counts,
                "frameSources": sorted(set(sources)),
                "serverSeq": state.get("serverSeq", 0),
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as error:
        print(f"assert_relay_state failed: {error}", file=sys.stderr)
        raise SystemExit(1) from None
