#!/usr/bin/env python3
"""Append one wide CSV row of all lm-sensors readings to ~/sensors_log.csv.

Column per sensor (chip/feature/subfeature from `sensors -j`), row per run,
first column is unix epoch. The header is written on first run and then
treated as canonical: subsequent runs emit values in header order, blank for
sensors that have vanished. Sensors that appear later (new hardware) are
reported to stderr rather than silently dropped or reordered.
"""
import csv
import json
import os
import subprocess
import sys
import time

CSV_PATH = os.path.expanduser("~/sensors_log.csv")


def flatten(obj, prefix=""):
    out = {}
    if isinstance(obj, dict):
        for k, v in obj.items():
            out.update(flatten(v, f"{prefix}/{k}" if prefix else k))
    else:
        out[prefix] = obj
    return out


def main():
    raw = subprocess.run(["sensors", "-j"], capture_output=True, text=True).stdout
    readings = flatten(json.loads(raw))
    epoch = int(time.time())

    if not os.path.exists(CSV_PATH) or os.path.getsize(CSV_PATH) == 0:
        header = ["epoch"] + sorted(readings)
        with open(CSV_PATH, "w", newline="") as f:
            csv.writer(f).writerow(header)
    else:
        with open(CSV_PATH, newline="") as f:
            header = next(csv.reader(f))

    known = set(header[1:])
    new = sorted(set(readings) - known)
    if new:
        print(f"sensors not in CSV header (ignored): {', '.join(new)}", file=sys.stderr)

    row = [epoch] + [readings.get(col, "") for col in header[1:]]
    with open(CSV_PATH, "a", newline="") as f:
        csv.writer(f).writerow(row)


if __name__ == "__main__":
    main()
