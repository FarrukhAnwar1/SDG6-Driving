"""Compare identical reviewed frames and paired, correctly selected distances."""
import argparse
import csv
import json
from pathlib import Path
import statistics


def load(root):
    summary = json.loads((root/"accuracy_summary.json").read_text())
    rows = {row["id"]: row for row in csv.DictReader((root/"scored_frames.csv").open())}
    manifest_path = root/"dataset/manifest.json"
    if not manifest_path.exists():
        manifest_path = root/"manifest.json"
    manifest = json.loads(manifest_path.read_text())
    images = {row["id"]: row["imageSha256"] for row in manifest["frames"]}
    return summary, rows, images


def compare(baseline_root, candidate_root):
    before, old, old_images = load(baseline_root)
    after, new, new_images = load(candidate_root)
    if old.keys() != new.keys() or old_images != new_images:
        raise ValueError("Both runs must contain identical input images and scored frame IDs")
    for key in old:
        for field in ("referenceTrackId", "referenceDistanceMeters", "referenceHeadwaySeconds", "speedMph"):
            if old[key][field] != new[key][field]:
                raise ValueError(f"Reference changed: {key} {field}")
    common = [key for key in old if old[key]["predictedDistanceMeters"] and new[key]["predictedDistanceMeters"]
              and float(old[key]["selectedLeadIoU"]) >= .5 and float(new[key]["selectedLeadIoU"]) >= .5]

    def distance_metrics(rows):
        errors = [float(rows[key]["distanceErrorMeters"]) for key in common]
        return {"n": len(errors), "maeMeters": statistics.mean(abs(value) for value in errors) if errors else None,
                "meanBiasMeters": statistics.mean(errors) if errors else None,
                "medianAbsoluteErrorMeters": statistics.median(abs(value) for value in errors) if errors else None}

    old_distances, new_distances = distance_metrics(old), distance_metrics(new)
    old_mae, new_mae = old_distances["maeMeters"], new_distances["maeMeters"]
    lost = [key for key in old if old[key]["predictedDistanceMeters"] and not new[key]["predictedDistanceMeters"]]
    gained = [key for key in old if not old[key]["predictedDistanceMeters"] and new[key]["predictedDistanceMeters"]]
    return {
        "scoredFrames": len(old), "inputFrames": len(old_images),
        "pairedCorrectLeadDistances": {"baseline": old_distances, "candidate": new_distances,
            "relativeMaeReduction": (old_mae-new_mae)/old_mae if old_mae else None, "frameIds": common},
        "unsafeGapClassification": {"baseline": before["unsafeHeadway"], "candidate": after["unsafeHeadway"]},
        "coverage": {"baseline": before["coverage"], "candidate": after["coverage"], "lostUsableIds": lost,
                     "gainedUsableIds": gained},
        "matchedLeadDistanceMetrics": {"baseline": before["distanceMatchedLeadOnly"], "candidate": after["distanceMatchedLeadOnly"]},
        "gradeResults": {"baseline": before["finalGrades"], "candidate": after["finalGrades"]},
        "note": "Paired distance metrics include the same correctly selected, usable reference leads in both runs; coverage changes are reported separately.",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = compare(args.baseline, args.candidate)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2))
    print(json.dumps({key: value for key, value in result.items() if key not in ["unsafeGapClassification", "gradeResults"]}, indent=2))


if __name__ == "__main__":
    main()
