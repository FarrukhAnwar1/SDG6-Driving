"""Sample Android total-process PSS/RSS during the local benchmark probe."""
import argparse
import datetime as dt
import json
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import time

PACKAGE = "com.example.flutter_driving_app"
DEVICE_ROOT = "cache/following_distance_benchmark"
ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--seconds", type=int, default=150)
    parser.add_argument("--summarize-only", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "build/following_distance_benchmark/phone_memory")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    adb_path = shutil.which("adb.exe") or shutil.which("adb")
    if not adb_path:
        raise SystemExit("ADB not found")

    def adb(*command):
        result = subprocess.run([adb_path, "-s", args.serial, *command], capture_output=True, timeout=30)
        if result.returncode:
            raise RuntimeError(result.stderr.decode(errors="replace"))
        return result.stdout.decode(errors="replace").replace("\r", "")

    path = args.output / "samples.jsonl"
    if args.summarize_only:
        info = json.loads((args.output/"device.json").read_text())
        samples = [json.loads(line) for line in path.read_text().splitlines()]
    else:
        info = {key: adb("shell", "getprop", key).strip() for key in
                ["ro.product.model", "ro.build.version.release", "ro.build.version.sdk", "ro.product.cpu.abi"]}
        (args.output / "device.json").write_text(json.dumps(info, indent=2))
        adb("shell", "am", "force-stop", PACKAGE)
        adb("shell", "am", "start", "-W", "-n", f"{PACKAGE}/.MainActivity")
        samples = []
        started = time.monotonic()
        with path.open("w") as stream:
            while time.monotonic() - started < args.seconds:
                tick = time.monotonic()
                text = adb("shell", "dumpsys", "meminfo", PACKAGE)
                row = {"at": dt.datetime.now(dt.timezone.utc).isoformat(),
                       "elapsedSeconds": round(time.monotonic()-started, 3), "raw": text}
                for name, pattern in {"pssKiB": r"TOTAL PSS:\s*(\d+)", "rssKiB": r"TOTAL RSS:\s*(\d+)",
                                      "swapPssKiB": r"TOTAL SWAP PSS:\s*(\d+)",
                                      "nativeHeapKiB": r"Native Heap:\s*(\d+)"}.items():
                    match = re.search(pattern, text)
                    row[name] = int(match.group(1)) if match else None
                stream.write(json.dumps(row)+"\n")
                stream.flush()
                samples.append(row)
                if len(samples) % 10 == 0:
                    print(json.dumps({key: row[key] for key in ("elapsedSeconds", "pssKiB", "rssKiB")}), flush=True)
                time.sleep(max(0, 1-(time.monotonic()-tick)))
        (args.output/"events.jsonl").write_text(adb("exec-out", "run-as", PACKAGE, "cat", DEVICE_ROOT+"/memory-events.jsonl"))
    events = [json.loads(line) for line in (args.output/"events.jsonl").read_text().splitlines()]
    phase_events = [(parse_time(e["at"]), e["phase"]) for e in events if e["event"] == "phase"]
    timings = [e for e in events if e["event"] == "timing"]
    first_timing = parse_time(timings[0]["at"]) if timings else None
    grouped = {}
    for row in samples:
        at = parse_time(row["at"])
        preceding = [(when, phase) for when, phase in phase_events if when <= at]
        if not preceding or row["pssKiB"] is None:
            continue
        since, phase = preceding[-1]
        row["phase"] = phase
        if phase == "vision_start" and first_timing is not None and (at-first_timing).total_seconds() >= 5:
            phase = "vision_steady"
        elif (at-since).total_seconds() < 3:
            phase += "_transition"
        grouped.setdefault(phase, []).append(row)

    def metrics(rows):
        result = {"samples": len(rows)}
        for key in ("pssKiB", "rssKiB", "nativeHeapKiB"):
            values = sorted(row[key]/1024 for row in rows if row[key] is not None)
            if values:
                result[key.replace("KiB", "MiB")] = {
                    "min": round(values[0], 2), "median": round(statistics.median(values), 2),
                    "p95": round(values[min(len(values)-1, math_ceil(0.95*len(values))-1)], 2),
                    "max": round(values[-1], 2)}
        return result

    summary = {"device": info, "buildMode": "profile", "samplingIntervalSeconds": 1,
               "scope": "Diagnostic Flutter process using production camera, models and monitoring/grading; not the complete signed-in dashboard",
               "phases": {key: metrics(rows) for key, rows in grouped.items()},
               "overall": metrics([r for r in samples if r["pssKiB"] is not None]),
               "completedFrames": sum(e["event"] == "measurement" for e in events),
               "inferenceSeconds": [sum(e["microseconds"].values())/1e6 for e in timings],
               "errors": [e for e in events if e["event"] in ("error", "camera_error")]}
    (args.output/"summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2), flush=True)


def math_ceil(value):
    return int(-(-value // 1))


def parse_time(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


if __name__ == "__main__":
    main()
