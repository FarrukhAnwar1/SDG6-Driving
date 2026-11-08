"""Run public dataset frames in an Android profile diagnostic's private cache.

Windows ADB can translate CRLF in binary stdin. Transfer a base64-encoded tar,
extract it as the app UID, then verify every image SHA-256 before launching.
No shared-storage permissions or real trip/GPS records are used.
"""
import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import time

PACKAGE = "com.example.flutter_driving_app"
DEVICE_DIRECTORY = "cache/following_distance_benchmark"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", action="store_true")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((args.dataset/"manifest.json").read_text())
    frames = manifest["frames"]
    adb_path = shutil.which("adb.exe") or shutil.which("adb")
    if not adb_path:
        raise SystemExit("ADB not found")
    adb_prefix = [adb_path, "-s", args.serial]

    def adb(*command, **kwargs):
        result = subprocess.run(adb_prefix+list(command), capture_output=True, timeout=kwargs.pop("timeout", 60), **kwargs)
        if result.returncode:
            raise RuntimeError(result.stderr.decode(errors="replace"))
        return result.stdout

    for row in frames:
        if not re.fullmatch(r"[A-Za-z0-9_./-]+", row["image"]) or ".." in Path(row["image"]).parts:
            raise ValueError("Unexpected dataset path")
        actual = hashlib.sha256((args.dataset/row["image"]).read_bytes()).hexdigest()
        if actual != row["imageSha256"]:
            raise ValueError(f"Local image checksum mismatch: {row['id']}")
    adb("shell", "am", "force-stop", PACKAGE)
    adb("shell", "run-as", PACKAGE, "mkdir", "-p", DEVICE_DIRECTORY)
    tar_path = args.output/"device-input.tar"
    encoded_path = args.output/"device-input.tar.b64"
    config = json.dumps({"mode": "dataset", "baseline": args.baseline}).encode()
    with tarfile.open(tar_path, "w") as archive:
        archive.add(args.dataset, arcname="dataset")
        entry = tarfile.TarInfo("config.json")
        entry.size, entry.mode = len(config), 0o600
        archive.addfile(entry, io.BytesIO(config))
    with tar_path.open("rb") as source, encoded_path.open("wb") as output:
        while chunk := source.read(3*1024*1024):
            output.write(base64.b64encode(chunk))
    print(f"Transferring {len(frames)} verified images to app-private storage...", flush=True)
    command = f"base64 -d | run-as {PACKAGE} tar -x -o -f - -C {DEVICE_DIRECTORY}"
    with encoded_path.open("rb") as source:
        adb("shell", "-T", command, stdin=source, timeout=300)
    remote_paths = [DEVICE_DIRECTORY+"/dataset/"+row["image"] for row in frames]
    actual_hashes = adb("exec-out", "run-as", PACKAGE, "sha256sum", *remote_paths, timeout=60).decode().splitlines()
    expected_hashes = [row["imageSha256"] for row in frames]
    if [line.split()[0] for line in actual_hashes] != expected_hashes:
        raise ValueError("On-phone image checksums differ from local manifest")
    print(f"Verified all {len(frames)} on-phone image checksums. Starting {'letterbox baseline' if args.baseline else 'depth crop'}.", flush=True)
    # The process writes a fresh event log before loading the models.
    adb("shell", "run-as", PACKAGE, "rm", "-f", DEVICE_DIRECTORY+"/dataset-events.jsonl")
    adb("shell", "am", "start", "-W", "-n", PACKAGE+"/.MainActivity")
    started = last_progress = time.monotonic()
    previous_count, previous_phase = -1, None
    while True:
        try:
            raw = adb("exec-out", "run-as", PACKAGE, "cat", DEVICE_DIRECTORY+"/dataset-events.jsonl")
        except RuntimeError:
            if time.monotonic()-started > 10:
                raise
            raw = b""
        rows = [json.loads(line) for line in raw.decode().splitlines() if line.strip()]
        if rows:
            errors = [row for row in rows if row["event"] == "error"]
            if errors:
                (args.output/"phone_dataset_events.jsonl").write_bytes(raw)
                raise RuntimeError(errors[-1]["error"])
            predictions = [row for row in rows if row["event"] == "prediction"]
            count = len(predictions)
            phases = [row["phase"] for row in rows if row["event"] == "phase"]
            phase = phases[-1] if phases else "starting"
            if count > previous_count:
                last_progress = time.monotonic()
            if phase != previous_phase or count//10 != max(previous_count, 0)//10:
                print(json.dumps({"phase": phase, "completed": count, "total": len(frames)}), flush=True)
            previous_count, previous_phase = count, phase
            if phase == "done":
                (args.output/"phone_dataset_events.jsonl").write_bytes(raw)
                break
        if time.monotonic()-started > 1800 or time.monotonic()-last_progress > 60:
            raise TimeoutError("Diagnostic stopped making progress; inspect its phase/error on the phone")
        time.sleep(3)
    prediction_bytes = adb("exec-out", "run-as", PACKAGE, "cat", DEVICE_DIRECTORY+"/predictions.jsonl")
    predictions = [json.loads(line) for line in prediction_bytes.decode().splitlines()]
    if len(predictions) != len(frames) or {row["id"] for row in predictions} != {row["id"] for row in frames}:
        raise ValueError("Incomplete or duplicate prediction IDs")
    (args.output/"phone_predictions.jsonl").write_bytes(prediction_bytes)
    (args.output/"device_run.json").write_text(json.dumps({"baseline": args.baseline, "frames": len(frames),
        "allRemoteImageHashesVerified": True, "elapsedSeconds": time.monotonic()-started,
        "model": adb("shell", "getprop", "ro.product.model").decode().strip()}, indent=2))
    print(f"Complete: saved {len(predictions)} predictions to {args.output}", flush=True)


if __name__ == "__main__":
    main()
