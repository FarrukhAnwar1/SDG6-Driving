"""Prepare a reproducible KITTI raw pilot and score the production Dart probe.

KITTI does not annotate following-distance violations or ego-lane membership.
The pilot uses a declared geometric lead proxy on straight road sections:
nearest annotated Car/Van/Truck with |LiDAR lateral center| <= 1.5 m.
Frames without an unambiguous annotated lead are excluded from classification.
This is a conditional diagnostic, not an official KITTI or on-road safety score.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import csv
import datetime as dt
import hashlib
import io
import json
import math
from pathlib import Path
import re
import statistics
import struct
import threading
import xml.etree.ElementTree as ET
import zipfile
import zlib

import numpy as np
import requests

BASE = "https://s3.eu-central-1.amazonaws.com/avg-kitti/raw_data/"
DATE = "2011_09_26"
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/following_distance_benchmark"


def production_headway_seconds():
    source = (ROOT/"lib/widgets/following_distance/following_distance_grading_service.dart").read_text()
    match = re.search(r"requiredHeadwaySeconds\s*=\s*([\d.]+)\s*;", source)
    if match is None:
        raise ValueError("Cannot read the production headway threshold")
    return float(match.group(1))


def download(url):
    response = requests.get(url, timeout=60)
    response.raise_for_status()
    return response.content


class RemoteZip(io.RawIOBase):
    """Seekable public HTTP ZIP; never downloads the complete driving archive."""
    def __init__(self, url):
        self.url, self.pos, self.transferred = url, 0, 0
        response = requests.get(url, headers={"Range": "bytes=-65536"}, timeout=60)
        response.raise_for_status()
        if response.status_code != 206:
            raise RuntimeError(f"Server did not honor range request: {url}")
        content_range = response.headers["Content-Range"]
        self.size = int(content_range.split("/")[1])
        start = int(content_range.split()[1].split("-")[0])
        self.cache = [(start, response.content)]
        self.transferred += len(response.content)
        self.lock = threading.Lock()
        self.zip = zipfile.ZipFile(self)

    def seekable(self):
        return True

    def readable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, offset, whence=0):
        self.pos = offset if whence == 0 else self.pos + offset if whence == 1 else self.size + offset
        return self.pos

    def read(self, size=-1):
        size = self.size - self.pos if size < 0 else size
        value = self.range(self.pos, self.pos + size)
        self.pos += len(value)
        return value

    def range(self, start, end):
        end = min(end, self.size)
        for offset, content in self.cache:
            if start >= offset and end <= offset + len(content):
                return content[start - offset:end - offset]
        response = requests.get(self.url, headers={"Range": f"bytes={start}-{end-1}"}, timeout=90)
        response.raise_for_status()
        expected = f"bytes {start}-{end-1}/{self.size}"
        if response.status_code != 206 or response.headers.get("Content-Range") != expected:
            raise RuntimeError(f"Unexpected HTTP range: {response.headers.get('Content-Range')} != {expected}")
        with self.lock:
            self.transferred += len(response.content)
        return response.content

    @staticmethod
    def unpack(info, content):
        if content[:4] != b"PK\x03\x04":
            raise ValueError("Invalid local ZIP header")
        name_size, extra_size = struct.unpack_from("<HH", content, 26)
        start = 30 + name_size + extra_size
        compressed = content[start:start + info.compress_size]
        data = zlib.decompress(compressed, -15) if info.compress_type == zipfile.ZIP_DEFLATED else compressed
        if len(data) != info.file_size or zlib.crc32(data) != info.CRC:
            raise ValueError(f"ZIP CRC/size mismatch: {info.filename}")
        return data

    def member(self, info):
        content = self.range(info.header_offset, info.header_offset + info.compress_size + 4096)
        return self.unpack(info, content)

    def group(self, infos):
        first = min(i.header_offset for i in infos)
        last = max(i.header_offset + i.compress_size + 4096 for i in infos)
        content = self.range(first, last)
        return {i.filename: self.unpack(i, content[i.header_offset-first:]) for i in infos}


def calib():
    path = OUT / "sources/calibration.zip"
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        path.write_bytes(download(BASE + DATE + "_calib.zip"))
    with zipfile.ZipFile(path) as archive:
        values = {}
        for name in archive.namelist():
            if not name.endswith(".txt"):
                continue
            rows = {}
            for line in archive.read(name).decode().splitlines():
                key, value = line.split(":", 1)
                try:
                    rows[key] = np.array([float(x) for x in value.split()])
                except ValueError:
                    pass
            values[Path(name).name] = rows
    c = values["calib_cam_to_cam.txt"]
    v = values["calib_velo_to_cam.txt"]
    transform = np.eye(4)
    transform[:3, :3], transform[:3, 3] = v["R"].reshape(3, 3), v["T"]
    rectification = np.eye(4)
    rectification[:3, :3] = c["R_rect_00"].reshape(3, 3)
    return rectification @ transform, c["P_rect_02"].reshape(3, 4), c["S_rect_02"].astype(int)


def labels(xml_bytes, transform, projection, dimensions):
    tracks = ET.fromstring(xml_bytes).find("tracklets")
    frames = {}
    for track_id, item in enumerate(tracks.findall("item")):
        kind = item.findtext("objectType")
        if kind not in ("Car", "Van", "Truck"):
            continue
        h, w, length = [float(item.findtext(k)) for k in ("h", "w", "l")]
        first = int(item.findtext("first_frame"))
        for i, pose in enumerate(item.find("poses").findall("item")):
            x, y, z, yaw = [float(pose.findtext(k)) for k in ("tx", "ty", "tz", "rz")]
            c, s = math.cos(yaw), math.sin(yaw)
            corners = np.array([[a*length/2, b*w/2, level, 1]
                                for a in (-1, 1) for b in (-1, 1) for level in (0, h)]).T
            rotation = np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])
            corners[:3] = rotation @ corners[:3] + np.array([x, y, z])[:, None]
            camera = transform @ corners
            if np.min(camera[2]) <= 0:
                continue
            points = projection @ camera
            points[:2] /= points[2:3]
            width, height = dimensions
            box = [float(points[0].min()/width), float(points[1].min()/height),
                   float(points[0].max()/width), float(points[1].max()/height)]
            if box[2] <= 0 or box[0] >= 1 or box[3] <= 0 or box[1] >= 1:
                continue
            frames.setdefault(first+i, []).append({
                "trackId": str(track_id), "type": kind, "forwardMeters": x,
                "lateralMeters": y, "distanceMeters": float(np.min(camera[2])),
                "box": box, "occlusion": int(pose.findtext("occlusion")),
                "truncation": int(pose.findtext("truncation")),
            })
    return frames


def metadata(drive):
    sequence = f"{DATE}_drive_{drive}"
    meta_path = OUT / f"sources/{sequence}.json"
    if meta_path.exists():
        return json.loads(meta_path.read_text())
    transform, projection, dimensions = calib()
    source = RemoteZip(BASE + f"{sequence}/{sequence}_sync.zip")
    infos = source.zip.infolist()
    packet_infos = [i for i in infos if "/oxts/data/" in i.filename and i.filename.endswith(".txt")]
    packets = source.group(packet_infos)
    time_info = next(i for i in infos if i.filename.endswith("image_02/timestamps.txt"))
    timestamps = source.member(time_info).decode().splitlines()
    track_path = OUT / f"sources/{sequence}_tracklets.zip"
    if not track_path.exists():
        track_path.write_bytes(download(BASE + f"{sequence}/{sequence}_tracklets.zip"))
    with zipfile.ZipFile(track_path) as archive:
        xml = archive.read(next(n for n in archive.namelist() if n.endswith(".xml")))
    objects = labels(xml, transform, projection, dimensions)
    rows = []
    all_packets = {int(Path(name).stem): [float(v) for v in data.decode().split()]
                   for name, data in packets.items()}
    for index, text in enumerate(timestamps):
        packet = all_packets[index]
        before, after = max(0, index-5), min(len(timestamps)-1, index+5)
        change = all_packets[after][5] - all_packets[before][5]
        change = (change + math.pi) % (2*math.pi) - math.pi
        yaw_rate = change / max(0.1, (after-before)/10)
        annotated = objects.get(index, [])
        candidates = sorted([v for v in annotated if abs(v["lateralMeters"]) <= 1.5
                             and 1 <= v["distanceMeters"] <= 100], key=lambda v: v["distanceMeters"])
        lead = candidates[0] if candidates else None
        ambiguity = any(1.5 < abs(v["lateralMeters"]) < 2.0
                        and (lead is None or v["distanceMeters"] < lead["distanceMeters"])
                        for v in annotated)
        speed = math.hypot(packet[6], packet[7]) / 0.44704
        eligible = bool(speed >= 25 and abs(yaw_rate) <= 0.02 and lead
                        and not ambiguity and lead["truncation"] == 0)
        moment = dt.datetime.fromisoformat(text).replace(tzinfo=dt.timezone.utc)
        rows.append({"id": f"{sequence}/{index:010}", "sequence": sequence, "frame": index,
                     "timestampUs": int(moment.timestamp()*1e6), "speedMph": speed,
                     "latitude": packet[0], "longitude": packet[1], "yawRate": yaw_rate,
                     "eligible": eligible, "lead": lead, "objects": annotated})
    result = {"sequence": sequence, "url": source.url, "dimensions": dimensions.tolist(),
              "metadataBytesDownloaded": source.transferred, "frames": rows}
    meta_path.write_text(json.dumps(result, indent=2))
    return result


def describe(meta, headway_seconds):
    rows = meta["frames"][::10]
    eligible = [r for r in rows if r["eligible"]]
    positive = [r for r in eligible if r["lead"]["distanceMeters"]/(r["speedMph"]*0.44704) < headway_seconds]
    return {"sequence": meta["sequence"], "totalFrames": len(meta["frames"]),
            "sampledFrames": len(rows), "eligible": len(eligible), "unsafe": len(positive),
            "safe": len(eligible)-len(positive), "requiredHeadwaySeconds": headway_seconds,
            "maxSpeedMph": round(max(r["speedMph"] for r in rows), 1)}


def prepare(drives, headway_seconds):
    metas = [metadata(drive) for drive in drives]
    target = OUT / "dataset"
    target.mkdir(parents=True, exist_ok=True)
    frames = []
    for meta in metas:
        source = RemoteZip(meta["url"])
        by_name = {i.filename: i for i in source.zip.infolist()}
        rows = meta["frames"][::10]
        def fetch(row):
            frame = row["frame"]
            relative = f"images/{meta['sequence']}/{frame:010}.png"
            path = target / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            if not path.exists():
                suffix = f"/image_02/data/{frame:010}.png"
                info = next(v for k, v in by_name.items() if k.endswith(suffix))
                path.write_bytes(source.member(info))
            return {**row, "image": relative, "imageSha256": hashlib.sha256(path.read_bytes()).hexdigest()}
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            frames.extend(pool.map(fetch, rows))
        print(json.dumps({**describe(meta, headway_seconds), "imageBytesDownloaded": source.transferred}), flush=True)
    provenance = {}
    for path in sorted((ROOT/"lib/widgets/following_distance").glob("*.dart")):
        provenance[str(path.relative_to(ROOT)).replace("\\", "/")] = hashlib.sha256(path.read_bytes()).hexdigest()
    for path in (ROOT/"assets/models").glob("*.onnx"):
        provenance[str(path.relative_to(ROOT)).replace("\\", "/")] = hashlib.sha256(path.read_bytes()).hexdigest()
    manifest = {"dataset": "KITTI raw, left color image_02, 1 Hz subset", "drives": drives,
                "protocol": __doc__, "sourceHashes": provenance, "frames": frames}
    (target/"manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"Prepared {len(frames)} frames at {target}", flush=True)


def contact_sheets():
    from PIL import Image, ImageDraw, ImageFont
    manifest = json.loads((OUT/"dataset/manifest.json").read_text())
    directory = OUT/"contact_sheets"
    directory.mkdir(exist_ok=True)
    try:
        font = ImageFont.truetype("C:/Windows/Fonts/arial.ttf", 16)
    except OSError:
        font = ImageFont.load_default()
    for sequence in dict.fromkeys(row["sequence"] for row in manifest["frames"]):
        rows = [r for r in manifest["frames"] if r["sequence"] == sequence]
        for start in range(0, len(rows), 15):
            batch = rows[start:start+15]
            sheet = Image.new("RGB", (1860, math.ceil(len(batch)/3)*230), "#202020")
            canvas = ImageDraw.Draw(sheet)
            for position, row in enumerate(batch):
                im = Image.open(OUT/"dataset"/row["image"]).convert("RGB")
                draw = ImageDraw.Draw(im)
                for vehicle in row["objects"]:
                    box = vehicle["box"]
                    is_lead = row["lead"] is not None and vehicle["trackId"] == row["lead"]["trackId"]
                    color = "lime" if is_lead else "orange"
                    bounds = [box[0]*im.width, box[1]*im.height, box[2]*im.width, box[3]*im.height]
                    draw.rectangle(bounds, outline=color, width=3)
                    draw.text((max(0, bounds[0]), max(0, bounds[1]-20)), f"id{vehicle['trackId']}", fill=color, font=font)
                im.thumbnail((620, 188))
                x, y = position%3*620, position//3*230
                sheet.paste(im, (x, y+38))
                lead = row["lead"]
                reference = f"lead={lead['trackId']} d={lead['distanceMeters']:.1f}m h={lead['distanceMeters']/(row['speedMph']*.44704):.2f}s" if lead and row["speedMph"]>.1 else "no reference lead"
                canvas.text((x+5, y), f"frame {row['frame']} | {row['speedMph']:.1f}mph | eligible={row['eligible']}", fill="white", font=font)
                canvas.text((x+5, y+19), reference, fill="white", font=font)
            path = directory/f"{sequence}_{start//15}.jpg"
            sheet.save(path, quality=95)
            print(path, flush=True)


def ratio(numerator, denominator):
    return numerator / denominator if denominator else None


def wilson(numerator, denominator):
    if not denominator:
        return None
    z = 1.959963984540054
    p = numerator/denominator
    divisor = 1+z*z/denominator
    center = (p+z*z/(2*denominator))/divisor
    radius = z*math.sqrt(p*(1-p)/denominator+z*z/(4*denominator**2))/divisor
    return [max(0, center-radius), min(1, center+radius)]


def classification(pairs):
    tp = sum(truth and prediction for truth, prediction in pairs)
    tn = sum(not truth and not prediction for truth, prediction in pairs)
    fp = sum(not truth and prediction for truth, prediction in pairs)
    fn = sum(truth and not prediction for truth, prediction in pairs)
    counts = {"truePositive": tp, "trueNegative": tn, "falsePositive": fp, "falseNegative": fn}
    definitions = {"accuracy": (tp+tn, len(pairs)), "recall": (tp, tp+fn),
                   "falsePositiveRate": (fp, fp+tn), "falseNegativeRate": (fn, fn+tp),
                   "precision": (tp, tp+fp), "specificity": (tn, tn+fp)}
    return {"n": len(pairs), "counts": counts,
            "metrics": {key: {"value": ratio(a, b), "numerator": a, "denominator": b,
                              "wilson95": wilson(a, b)} for key, (a, b) in definitions.items()},
            "f1": ratio(2*tp, 2*tp+fp+fn)}


def iou(a, b):
    overlap = max(0, min(a[2], b[2])-max(a[0], b[0])) * max(0, min(a[3], b[3])-max(a[1], b[1]))
    union = (a[2]-a[0])*(a[3]-a[1])+(b[2]-b[0])*(b[3]-b[1])-overlap
    return overlap/union if union else 0


class ReferenceGrader:
    """Reference rule applied to annotated distances, independent of predictions."""
    def __init__(self, required_headway_seconds):
        self.required_headway_seconds = required_headway_seconds
        self.grade = 100.0
        self.start = self.last = self.track = self.charged_through = None

    def step(self, time_seconds, speed_mph, distance, track):
        if (self.last is not None and time_seconds-self.last > 1.5) or distance is None or speed_mph < 25:
            self.start = self.track = self.charged_through = None
        self.last = time_seconds
        if distance is None or speed_mph < 25 or distance/(speed_mph*.44704) >= self.required_headway_seconds:
            self.start = self.track = self.charged_through = None
            return False
        if self.start is None or track != self.track:
            self.start, self.track, self.charged_through = time_seconds, track, None
        charge_from = self.charged_through if self.charged_through is not None else self.start+5
        if time_seconds > charge_from:
            severity = 1+(self.required_headway_seconds-distance/(speed_mph*.44704))/.5
            self.grade = max(0, self.grade-(time_seconds-charge_from)*severity)
            self.charged_through = time_seconds
        return self.charged_through is not None


def score(predictions_path, headway_seconds):
    manifest_path = OUT/"dataset/manifest.json"
    review_path = OUT/"reference_review.json"
    manifest = json.loads(manifest_path.read_text())
    review = json.loads(review_path.read_text())
    predictions = [json.loads(line) for line in predictions_path.read_text().splitlines()]
    by_id = {p["id"]: p for p in predictions}
    expected = {r["id"] for r in manifest["frames"]}
    if len(by_id) != len(predictions) or set(by_id) != expected:
        raise ValueError(f"Prediction IDs mismatch: {len(predictions)} records, {len(by_id)} unique, {len(expected)} expected")
    if any(p.get("requiredHeadwaySeconds", headway_seconds) != headway_seconds for p in predictions):
        raise ValueError("Phone predictions used a different headway threshold from the scoring policy")
    detailed, pairs, available_pairs, penalty_pairs, robust_pairs, automatic_pairs = [], [], [], [], [], []
    matched_errors, all_errors, relative_errors, strict_delta = [], [], [], []
    grades, per_sequence = {}, {}
    grader = None
    sequence = None
    detected, identity_correct = 0, 0
    reference_events = predicted_events = 0
    previous_reference_penalty = previous_predicted_penalty = False
    for row in manifest["frames"]:
        if row["sequence"] != sequence:
            sequence = row["sequence"]
            grader = ReferenceGrader(headway_seconds)
            previous_reference_penalty = previous_predicted_penalty = False
        prediction = by_id[row["id"]]
        annotation = next((a for a in review["ranges"][sequence]
                           if a["firstFrame"] <= row["frame"] <= a["lastFrame"]), None)
        reference = next((v for v in row["objects"] if annotation and v["trackId"] == annotation["trackId"]), None)
        eligible = reference is not None and row["speedMph"] >= 25 and reference["truncation"] == 0
        distance = reference["distanceMeters"] if reference is not None else None
        truth_penalty = grader.step(row["timestampUs"]/1e6, row["speedMph"], distance,
                                   reference["trackId"] if reference else None)
        reference_events += bool(truth_penalty and not previous_reference_penalty)
        predicted_events += bool(prediction["isPenalizing"] and not previous_predicted_penalty)
        previous_reference_penalty = truth_penalty
        previous_predicted_penalty = prediction["isPenalizing"]
        grades[sequence] = {"referenceGrade": grader.grade, "predictedGrade": prediction["grade"]}
        if not eligible:
            continue
        truth_headway = distance/(row["speedMph"]*.44704)
        available = prediction["status"] == "tracking" and prediction["distanceMeters"] is not None
        predicted_headway = prediction["distanceMeters"]/(row["speedMph"]*.44704) if available else None
        true_unsafe = truth_headway < headway_seconds
        predicted_unsafe = available and predicted_headway < headway_seconds
        pair = (true_unsafe, predicted_unsafe)
        pairs.append(pair)
        per_sequence.setdefault(sequence, []).append(pair)
        if available:
            available_pairs.append(pair)
        if abs(truth_headway-headway_seconds) >= .1:
            robust_pairs.append(pair)
        if row["eligible"]:
            automatic_pairs.append(pair)
        penalty_pairs.append((truth_penalty, prediction["isPenalizing"]))
        detections = [v for v in prediction["vehicles"] if v["confidence"] >= .25]
        max_overlap = max((iou(reference["box"], v["box"]) for v in detections), default=0)
        detected += max_overlap >= .5
        selected = [v for v in prediction["vehicles"] if available and v["inEgoLane"] and
                    v["distanceMeters"] is not None and abs(v["distanceMeters"]-prediction["distanceMeters"]) < .0001]
        selected_overlap = max((iou(reference["box"], v["box"]) for v in selected), default=0)
        identity_correct += selected_overlap >= .5
        error = prediction["distanceMeters"]-distance if available else None
        if error is not None:
            all_errors.append(error)
            if selected_overlap >= .5:
                matched_errors.append(error)
                relative_errors.append(abs(error)/distance)
                strict_delta.append(max(prediction["distanceMeters"]/distance, distance/prediction["distanceMeters"]) < 1.25)
        detailed.append({"id": row["id"], "speedMph": row["speedMph"], "referenceTrackId": reference["trackId"],
                         "referenceDistanceMeters": distance, "predictedDistanceMeters": prediction["distanceMeters"],
                         "referenceHeadwaySeconds": truth_headway, "predictedHeadwaySeconds": predicted_headway,
                         "referenceUnsafe": true_unsafe, "predictedUnsafe": predicted_unsafe,
                         "status": prediction["status"], "referenceIsPenalizing": truth_penalty,
                         "predictedIsPenalizing": prediction["isPenalizing"], "referenceDetectionIoU": max_overlap,
                         "selectedLeadIoU": selected_overlap, "distanceErrorMeters": error})
    def distance_metrics(errors):
        return {"n": len(errors), "maeMeters": statistics.mean(abs(e) for e in errors) if errors else None,
                "rmseMeters": math.sqrt(statistics.mean(e*e for e in errors)) if errors else None,
                "meanBiasMeters": statistics.mean(errors) if errors else None,
                "medianAbsoluteErrorMeters": statistics.median(abs(e) for e in errors) if errors else None}
    result = {"scope": "KITTI pilot; actual production Flutter/ONNX perception, lead selection and grading run on phone; offline source-time replay at 1 Hz",
              "gradingPolicy": {"requiredHeadwaySeconds": headway_seconds, "minimumSpeedMph": 25,
                                "graceSeconds": 5, "maxSampleGapSeconds": 1.5,
                                "pointsPerSecond": 1, "secondsPerPenaltyStep": .5,
                                "unsafeComparison": "headwaySeconds < requiredHeadwaySeconds"},
              "totalInferredFrames": len(predictions), "scoredFrames": len(pairs),
              "referenceReview": review, "unsafeHeadway": classification(pairs),
              "availableOnly": classification(available_pairs), "coverage": ratio(len(available_pairs), len(pairs)),
              "penalizingFrameClassification": classification(penalty_pairs),
              "referenceConfirmedViolations": reference_events,
              "predictedConfirmedViolations": predicted_events,
              "excludingPointOneSecondBoundaryBand": classification(robust_pairs),
              "originalStraightRoadGeometricSubset": classification(automatic_pairs),
              "leadVehicleDetectionRecallAtIoUPointFive": {"matched": detected, "referenceLeads": len(pairs), "recall": ratio(detected, len(pairs))},
              "correctSelectedLeadsAtIoUPointFive": identity_correct,
              "distanceAllAvailable": distance_metrics(all_errors), "distanceMatchedLeadOnly": {
                  **distance_metrics(matched_errors), "absoluteRelativeError": statistics.mean(relative_errors) if relative_errors else None,
                  "deltaOneWithinFactorOnePointTwoFive": statistics.mean(strict_delta) if strict_delta else None},
              "perSequenceHeadway": {s: classification(ps) for s, ps in per_sequence.items()},
              "finalGrades": grades,
              "inferenceSeconds": {"median": statistics.median(p["inferenceUs"]/1e6 for p in predictions),
                                   "mean": statistics.mean(p["inferenceUs"]/1e6 for p in predictions),
                                   "max": max(p["inferenceUs"]/1e6 for p in predictions)},
              "sha256": {"manifest": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
                         "referenceReview": hashlib.sha256(review_path.read_bytes()).hexdigest(),
                         "predictions": hashlib.sha256(predictions_path.read_bytes()).hexdigest()},
              "limitations": [f"{len(manifest['drives'])} deliberately selected daytime drives; correlated frames; {sum(pair[0] for pair in pairs)} unsafe examples, not independent events.",
                              "Reference lead IDs visually reviewed by assistant; no independent human adjudication or official following-distance labels.",
                              "Reference distance is nearest annotated 3D-box camera-forward surface; not directly measured bumper-to-bumper headway.",
                              "No model weights or distance scale were fitted for this threshold rerun; crop preprocessing was previously selected using development examples. Upstream pretrained models may have seen KITTI.",
                              "Missing/uncertain predictions count as no unsafe-gap detection in primary metrics; available-only metrics and coverage are also reported.",
                              "Offline 1 Hz replay does not include live camera/GPS failures or inference frame drops; observed phone throughput is slower than 1 Hz.",
                              "Wilson intervals treat frames as independent and are optimistic for correlated video; use separate drives/events for stronger uncertainty estimates."]}
    (OUT/"accuracy_summary.json").write_text(json.dumps(result, indent=2))
    with (OUT/"scored_frames.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(detailed[0]) if detailed else ["id"])
        writer.writeheader()
        writer.writerows(detailed)
    print(json.dumps(result, indent=2))


def self_test():
    known = classification([(True, True)]*8+[(True, False)]*2+[(False, True)]+[(False, False)]*9)
    for key, expected in {"accuracy": .85, "recall": .8, "falsePositiveRate": .1, "falseNegativeRate": .2}.items():
        assert abs(known["metrics"][key]["value"]-expected) < 1e-12
    assert classification([])["metrics"]["recall"]["value"] is None
    for threshold, headway, expected_grade in [(1.5, 1.0, 98), (3.0, 1.0, 95), (3.0, 2.5, 98), (3.0, 2.99, 98.98)]:
        grader = ReferenceGrader(threshold)
        for time in range(6):
            assert not grader.step(time, 30, 30*.44704*headway, "a")
        assert grader.grade == 100
        assert grader.step(6, 30, 30*.44704*headway, "a")
        assert abs(grader.grade-expected_grade) < 1e-9
        assert not grader.step(7, 30, 30*.44704*headway, "b")
        assert not grader.step(8, 25, 25*.44704*threshold, "b")
    grader = ReferenceGrader(3)
    for time in [0, 1.501, 3.002, 4.503, 6.004, 7.505]:
        assert not grader.step(time, 30, 30*.44704, "a")
    assert grader.grade == 100
    assert iou([0, 0, 1, 1], [0, 0, 1, 1]) == 1
    assert iou([0, 0, 1, 1], [2, 2, 3, 3]) == 0
    print("Scoring checks passed: known confusion matrix, undefined denominators, grace, target change, threshold equality and box matching.")


def main():
    global OUT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["inspect", "prepare", "contact-sheets", "score", "self-test"])
    parser.add_argument("--predictions", type=Path)
    parser.add_argument("--output", type=Path, default=OUT)
    parser.add_argument("--headway-seconds", type=float, default=production_headway_seconds(),
                        help="Unsafe headway threshold; defaults to the current production Dart constant")
    parser.add_argument("--drives", nargs="+", default=["0029", "0056", "0027", "0015"])
    args = parser.parse_args()
    if not math.isfinite(args.headway_seconds) or args.headway_seconds <= 0:
        parser.error("--headway-seconds must be finite and positive")
    OUT = args.output.resolve()
    if args.action == "inspect":
        for drive in args.drives:
            try:
                print(json.dumps(describe(metadata(drive), args.headway_seconds)), flush=True)
            except requests.HTTPError as error:
                print(json.dumps({"drive": drive, "error": str(error)}), flush=True)
    elif args.action == "prepare":
        prepare(args.drives, args.headway_seconds)
    elif args.action == "contact-sheets":
        contact_sheets()
    elif args.action == "score":
        score(args.predictions or OUT/"phone_predictions.jsonl", args.headway_seconds)
    else:
        self_test()


if __name__ == "__main__":
    main()
