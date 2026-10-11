#!/usr/bin/env python3
"""Invert an Instruments time-profile export — the "Invert Call Tree" view without Instruments.

`performance.md` §5 ends on "the next step is Instruments with the call tree inverted", because
the thread summary can only name *threads*, not functions. It turns out `xctrace` can record the
trace headlessly and export every sample **with its full backtrace**, and Time Profiler's inverted
call tree is only an aggregation of that data — so it can be computed here, on a machine where the
Instruments GUI cannot be driven.

Record (the app must already be running; the trace attaches to the live process):

    xcrun xctrace record --template 'Time Profiler' \
        --attach "$(pgrep -f 'Dirigo.app/Contents/MacOS/Dirigo' | head -1)" \
        --time-limit 20s --output /tmp/dirigo-live.trace

Export the time-profile table to XML:

    xcrun xctrace export --input /tmp/dirigo-live.trace \
        --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
        --output /tmp/dirigo-tp.xml

Then:

    tools/invert-profile.py /tmp/dirigo-tp.xml --thread main
    tools/invert-profile.py /tmp/dirigo-tp.xml --app-binary Dirigo   # the app's own frames only

Four things about the export that are easy to get wrong, each of which cost a round:

* It is **not** plain repeated XML. Each distinct object is emitted once with its attributes and an
  `id`; every later use is a bare reference (`<frame ref="11"/>`, `<thread ref="2"/>`). Left
  unresolved, a "Main Thread" filter matches exactly one row out of two thousand, and every frame
  labels as `ref:NN`.
* Frames are listed **innermost-first**, so the *first* frame is the leaf and the *last* is `start`.
  Reversing them makes `start` look like a 95%-of-CPU leaf, which is what it did here first.
* `weight` is **not** the sample interval. Every row in a real trace reads `1.00 ms` while the
  samples are ~11 ms apart (2 113 samples over 20.4 s), so weights must not be summed as CPU time.
  Count samples, and report shares of samples.
* Samples taken while the process is idle have an **empty backtrace** (~7% here). They are not
  zero-cost instructions, they are unsampled time; excluding them is right, but say so, because the
  denominator changes.
"""

import argparse
import sys
import xml.etree.ElementTree as ET
from collections import Counter

sys.setrecursionlimit(20000)


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("export", help="time-profile XML from `xctrace export`")
    parser.add_argument("--thread", default="main", choices=["main", "all"],
                        help="restrict to the main thread (default) or use every thread")
    parser.add_argument("--app-binary", default=None, metavar="NAME",
                        help="also report only the frames inside this binary, e.g. Dirigo")
    parser.add_argument("--top", type=int, default=25)
    return parser.parse_args()


class Profile:
    """The samples, with the export's shared element pool resolved."""

    def __init__(self, path):
        root = ET.parse(path).getroot()
        self.attrs_by_id = {}
        for element in root.iter():
            if element.get("id") is not None:
                self.attrs_by_id[element.get("id")] = element.attrib
        self.rows = [row for row in root.iter("row") if row.find("weight") is not None]

    def label(self, element):
        """A readable name for an element that may carry only a `ref`."""
        if element is None:
            return "?"
        if element.get("fmt"):
            return element.get("fmt")
        reference = element.get("ref")
        if reference is not None:
            target = self.attrs_by_id.get(reference) or {}
            return target.get("name") or target.get("fmt") or f"ref:{reference}"
        return element.get("name") or element.tag

    def binary(self, frame):
        element = frame.find("binary")
        if element is None:
            return None
        if element.get("name"):
            return element.get("name")
        return self.attrs_by_id.get(element.get("ref"), {}).get("name")

    def frames(self, row):
        """The backtrace, innermost-first, as (name, binary) pairs."""
        backtrace = row.find("tagged-backtrace")
        if backtrace is None:
            return []
        return [(self.label(frame), self.binary(frame)) for frame in backtrace.findall("frame")]


def pct(part, whole):
    return f"{100.0 * part / whole:5.1f}%" if whole else "  0.0%"


def main():
    args = parse_args()
    profile = Profile(args.export)

    self_time = Counter()
    inclusive = Counter()
    by_thread = Counter()
    app_self = Counter()
    app_inclusive = Counter()
    samples = 0
    empty = 0

    for row in profile.rows:
        thread = profile.label(row.find("thread")) or "?"
        if args.thread == "main" and "Main Thread" not in thread:
            continue
        by_thread[thread] += 1

        frames = profile.frames(row)
        if not frames:
            empty += 1
            continue

        samples += 1
        self_time[frames[0][0]] += 1
        for name, _ in set(frames):
            inclusive[name] += 1

        if args.app_binary:
            own = [name for name, binary in frames if binary == args.app_binary]
            if own:
                app_self[own[0]] += 1
                for name in set(own):
                    app_inclusive[name] += 1

    print(f"file:             {args.export}")
    print(f"samples analysed: {samples}   (empty backtrace: {empty})")
    print()
    print("=== threads by sample share ===")
    for name, count in by_thread.most_common(6):
        print(f"  {count:6d} {pct(count, samples)}  {name}")
    print()
    print(f"=== top {args.top} frames by SELF time — where the CPU actually is ===")
    for name, count in self_time.most_common(args.top):
        print(f"  {count:6d} {pct(count, samples)}  {name}")
    print()
    print(f"=== top {args.top} frames by INCLUSIVE time — what is driving it ===")
    for name, count in inclusive.most_common(args.top):
        print(f"  {count:6d} {pct(count, samples)}  {name}")

    if args.app_binary:
        own_samples = sum(app_self.values())
        print()
        print(f"=== samples whose innermost frame is inside {args.app_binary}: "
              f"{own_samples} ({pct(own_samples, samples)}) ===")
        print(f"--- self time inside {args.app_binary} ---")
        for name, count in app_self.most_common(args.top):
            print(f"  {count:6d} {pct(count, samples)}  {name}")
        print(f"--- inclusive time inside {args.app_binary} ---")
        for name, count in app_inclusive.most_common(args.top):
            print(f"  {count:6d} {pct(count, samples)}  {name}")


if __name__ == "__main__":
    main()
