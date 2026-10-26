"""Build pinned, pretrained road-perception ONNX assets (CPU only, no training)."""

import argparse
import hashlib
import json
from pathlib import Path
import sys
import types
import urllib.request
import zipfile

APP = Path(__file__).resolve().parents[1]
BUILD = APP / "build" / "vision_models"
ASSETS = APP / "assets" / "models"
UNIDEPTH_REV = "8d8cfe4c7ee15297099983607febf0d4f32eb3d6"
WEIGHTS_REV = "038c238f06c87b6c2f5b3749fd51fbf442b1f218"
YOLOP_REV = "8d8f68df318c71f01d6f813c024df646c7d1978f"
DEPTH_HEIGHT, DEPTH_WIDTH = 532, 392


def download(url, destination):
    if destination.is_file():
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".download")
    print(f"Downloading {destination.name}", flush=True)
    with urllib.request.urlopen(url, timeout=120) as response, temporary.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            output.write(chunk)
    temporary.replace(destination)


def prepare():
    source = BUILD / "unidepth_source"
    if not (source / "unidepth/models/unidepthv2/export.py").is_file():
        archive = BUILD / "unidepth.zip"
        download(f"https://codeload.github.com/lpiccinelli-eth/UniDepth/zip/{UNIDEPTH_REV}", archive)
        with zipfile.ZipFile(archive) as zipped:
            for entry in zipped.infolist():
                relative = Path(*Path(entry.filename).parts[1:])
                if not relative.parts or relative.parts[0] not in {"unidepth", "configs", "LICENSE", "README.md"}:
                    continue
                destination = (source / relative).resolve()
                if not destination.is_relative_to(source.resolve()):
                    raise ValueError("Unexpected archive path")
                if not entry.is_dir():
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes(zipped.read(entry))
    for name in ("model.safetensors", "config.json"):
        download(f"https://huggingface.co/lpiccinelli/unidepth-v2-vits14/resolve/{WEIGHTS_REV}/{name}", BUILD / name)
    download(f"https://raw.githubusercontent.com/hustvl/YOLOP/{YOLOP_REV}/weights/yolop-640-640.onnx", ASSETS / "yolop_640.onnx")
    for repository, revision, name in (
        ("lpiccinelli-eth/UniDepth", UNIDEPTH_REV, "UNIDEPTH_LICENSE"),
        ("hustvl/YOLOP", YOLOP_REV, "YOLOP_LICENSE"),
    ):
        download(f"https://raw.githubusercontent.com/{repository}/{revision}/LICENSE", ASSETS / name)
    sys.path.insert(0, str(source))
    # Bypass package initializers that eagerly import training visualizers and
    # V1 models. All V2 inference modules below are the unmodified pinned code.
    for package in ("unidepth.models", "unidepth.utils"):
        namespace = types.ModuleType(package)
        namespace.__path__ = [str(source.joinpath(*package.split(".")))]
        sys.modules[package] = namespace
    return source


def export_depth(*, write=True):
    import torch
    from safetensors.torch import load_file
    from unidepth.models.unidepthv2.export import UniDepthV2ONNX

    torch.set_num_threads(4)
    config = json.loads((BUILD / "unidepth_source/configs/config_v2_vits14.json").read_text())
    config["training"]["export"] = True

    class MetricDepth(UniDepthV2ONNX):
        def forward(self, rgbs):
            points, confidence, intrinsics = super().forward(rgbs)
            # Camera-forward Z, in metres; not radial range or relative depth.
            return points[:, 2:3], confidence, intrinsics

    model = MetricDepth(config).eval()
    model.load_state_dict(load_file(str(BUILD / "model.safetensors")), strict=True)
    sample = torch.zeros(1, 3, DEPTH_HEIGHT, DEPTH_WIDTH)
    destination = ASSETS / "unidepth_v2_small.onnx"
    if write:
        print("Exporting UniDepthV2 Small metric depth", flush=True)
        with torch.inference_mode():
            torch.onnx.export(
                model, (sample,), str(destination), opset_version=14, dynamo=False,
                input_names=["rgbs"], output_names=["depth_meters", "confidence", "intrinsics"],
            )
        pack_weights(destination)
    return model


def pack_weights(path):
    """Store large weights in float16; retain float32 operators and public I/O."""
    import numpy as np
    import onnx
    from onnx import helper, numpy_helper

    model = onnx.load(str(path))
    casts = []
    for tensor in model.graph.initializer:
        values = numpy_helper.to_array(tensor)
        if tensor.data_type != onnx.TensorProto.FLOAT or values.size < 64:
            continue
        name = tensor.name
        storage_name = name + "__fp16_storage"
        tensor.CopyFrom(numpy_helper.from_array(values.astype(np.float16), name=storage_name))
        casts.append(helper.make_node("Cast", [storage_name], [name], name=storage_name + "_cast", to=onnx.TensorProto.FLOAT))
    nodes = list(model.graph.node)
    del model.graph.node[:]
    model.graph.node.extend(casts)
    model.graph.node.extend(nodes)
    onnx.checker.check_model(model)
    onnx.save(model, str(path))


def verify(model):
    import time
    import cv2
    import numpy as np
    import onnx
    import onnxruntime as ort
    import torch

    image_path = BUILD / "road.jpg"
    download(f"https://raw.githubusercontent.com/hustvl/YOLOP/{YOLOP_REV}/inference/images/7dd9ef45-f197db95.jpg", image_path)
    rgb = cv2.cvtColor(cv2.imread(str(image_path)), cv2.COLOR_BGR2RGB)
    # A portrait crop exercises the phone's deployed aspect ratio.
    h, w = rgb.shape[:2]
    crop_width = round(h * DEPTH_WIDTH / DEPTH_HEIGHT)
    rgb = rgb[:, (w - crop_width) // 2:(w + crop_width) // 2]

    def input_tensor(height, width, padding):
        h, w = rgb.shape[:2]
        scale = min(width / w, height / h)
        rh, rw = round(h * scale), round(w * scale)
        image = np.zeros((height, width, 3), np.float32) + padding
        top, left = (height - rh) // 2, (width - rw) // 2
        image[top:top + rh, left:left + rw] = cv2.resize(rgb, (rw, rh), interpolation=cv2.INTER_LINEAR) / 255
        image = (image - [0.485, 0.456, 0.406]) / [0.229, 0.224, 0.225]
        return image.transpose(2, 0, 1)[None].astype(np.float32)

    options = ort.SessionOptions()
    options.intra_op_num_threads = 4
    options.inter_op_num_threads = 1
    options.log_severity_level = 3
    import importlib.metadata
    records = {"build": {
        "unidepth_revision": UNIDEPTH_REV, "unidepth_weights_revision": WEIGHTS_REV,
        "yolop_revision": YOLOP_REV,
        "weight_storage": "UniDepth large initializers float16, operators and I/O float32",
        "python": sys.version.split()[0],
        "packages": {name: importlib.metadata.version(name) for name in ["torch", "onnx", "onnxruntime", "numpy", "safetensors", "timm", "einops", "scipy", "huggingface_hub", "opencv-python-headless"]},
        "unidepth_weights_sha256": hashlib.sha256((BUILD / "model.safetensors").read_bytes()).hexdigest(),
    }}
    for asset, tensor in (
        ("yolop_640.onnx", input_tensor(640, 640, 114 / 255)),
        ("unidepth_v2_small.onnx", input_tensor(DEPTH_HEIGHT, DEPTH_WIDTH, [0.485, 0.456, 0.406])),
    ):
        path = ASSETS / asset
        onnx.checker.check_model(str(path))
        session = ort.InferenceSession(str(path), sess_options=options, providers=["CPUExecutionProvider"])
        start = time.perf_counter()
        output = session.run(None, {session.get_inputs()[0].name: tensor})
        elapsed = time.perf_counter() - start
        assert all(np.isfinite(value).all() for value in output)
        records[asset] = {
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "bytes": path.stat().st_size,
            "input": {session.get_inputs()[0].name: list(tensor.shape)},
            "outputs": {info.name: list(value.shape) for info, value in zip(session.get_outputs(), output)},
            "desktop_cpu_seconds": round(elapsed, 3),
        }
        if asset.startswith("unidepth"):
            with torch.inference_mode():
                expected = [value.numpy() for value in model(torch.from_numpy(tensor))]
            for name, actual, reference in zip(records[asset]["outputs"], output, expected):
                relative = np.abs(actual - reference) / np.maximum(np.abs(reference), 1e-3)
                assert np.quantile(relative, 0.99) < 0.005, (name, relative.max())
                records[asset].setdefault("p99_relative_error_vs_pytorch", {})[name] = float(np.quantile(relative, 0.99))
            records[asset]["depth_meters_range"] = [float(output[0].min()), float(output[0].max())]
            assert (output[0] > 0).all()
        else:
            scores = output[0][0, :, 4] * output[0][0, :, 5]
            records[asset]["vehicle_proposals_above_0.4"] = int((scores > 0.4).sum())
        del session
    records["note"] = "Numerical/format smoke check on a published road image, not distance ground truth or a phone benchmark."
    (ASSETS / "validation.json").write_text(json.dumps(records, indent=2) + "\n")
    print(json.dumps(records, indent=2), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    prepare()
    if not args.prepare_only:
        model = export_depth(write=not args.verify_only)
        verify(model)


if __name__ == "__main__":
    main()
