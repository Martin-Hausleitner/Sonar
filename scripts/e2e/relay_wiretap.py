#!/usr/bin/env python3
"""Fetch every frame the simulator relay has routed, as an observer.

Uses the relay's normal /api/poll endpoint with an unregistered observer id,
so it sees frames from ALL real devices (poll returns frames whose sender is
not the polling id) without perturbing relay state.

Output JSON: {"fetchedAt": ..., "serverSeq": ..., "frames": [...]}
"""

import argparse
import json
import sys
import time
import urllib.request


def main():
    parser = argparse.ArgumentParser(description="Dump all relayed Sonar frames")
    parser.add_argument("--relay-url", default="http://127.0.0.1:8787")
    parser.add_argument("--observer-id", default="WIRETAP-OBSERVER")
    parser.add_argument("--out", required=True, help="output JSON path")
    args = parser.parse_args()

    url = f"{args.relay_url}/api/poll?deviceId={args.observer_id}&after=0"
    with urllib.request.urlopen(url, timeout=5) as response:
        payload = json.loads(response.read().decode("utf-8"))

    frames = payload.get("frames", [])
    dump = {
        "fetchedAt": time.time(),
        "relayURL": args.relay_url,
        "serverSeq": payload.get("serverSeq", 0),
        "frameCount": len(frames),
        "frames": frames,
    }
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(dump, handle, indent=2, sort_keys=True)

    by_source = {}
    for frame in frames:
        by_source[frame.get("from", "?")] = by_source.get(frame.get("from", "?"), 0) + 1
    print(json.dumps({"frameCount": len(frames), "bySource": by_source}, sort_keys=True))
    if not frames:
        print("wiretap: relay has routed no frames", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
