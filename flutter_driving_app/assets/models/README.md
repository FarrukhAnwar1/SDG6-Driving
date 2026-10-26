# Pretrained road-perception assets

The app bundles both networks for local inference, with no first-use download.
See [pipeline behavior and limitations](../../docs/following_distance.md).

| Asset | Source | License |
| --- | --- | --- |
| `yolop_640.onnx` | Official [YOLOP 640 export](https://github.com/hustvl/YOLOP/blob/8d8f68df318c71f01d6f813c024df646c7d1978f/weights/yolop-640-640.onnx), unchanged BDD100K pretrained detector/road/lane network | [MIT](YOLOP_LICENSE) |
| `unidepth_v2_small.onnx` | [UniDepthV2 Small pretrained weights](https://huggingface.co/lpiccinelli/unidepth-v2-vits14/tree/038c238f06c87b6c2f5b3749fd51fbf442b1f218), exported with [pinned upstream code](https://github.com/lpiccinelli-eth/UniDepth/tree/8d8cfe4c7ee15297099983607febf0d4f32eb3d6) | [CC BY-NC 4.0](UNIDEPTH_LICENSE), Luigi Piccinelli and contributors |

Both license texts are included as Flutter assets. Lead selection uses a simple
comparison with the last observed vehicle box; it requires no tracking model.

UniDepth's exported input is ImageNet-normalized RGB `[1,3,532,392]`. Outputs
are `depth_meters` (camera-forward Z, `[1,1,532,392]`), `confidence` of the same
shape, and predicted `[1,3,3]` `intrinsics`. The export wraps upstream's
`points = rays * radius` and selects Z without changing its learned scale.
Large weights are stored in float16 with explicit casts back to float32.
Operators and input/output remain float32 for CPU portability. This reduces
the bundled depth asset to about 71MB; it does not imply
half the inference memory or a GPU speedup. Smaller storage is checked against
the original float32 PyTorch predictions.

`validation.json` records SHA-256 checksums, sizes, input/output contracts,
pinned source/weight revisions, build-package versions, and a numerical check
on an official YOLOP road image. Its CPU timings are development-machine smoke
measurements, not phone benchmarks. Export agreement is not measured road
distance accuracy or KITTI/nuScenes validation.

Rebuild from the Flutter app directory using Python with CPU PyTorch and the
versions in `tool/vision_model_requirements.txt` (prefer an isolated virtual
environment). Run:

```text
python tool/build_following_distance_models.py
```

Downloads and temporary source/weights remain in ignored `build/vision_models/`.
The script loads safetensors with strict state-dict matching and bypasses only
unused upstream package initializers that eagerly import training visualizers.
It uses upstream inference modules without modifications, sets the upstream
export option to avoid memory-efficient attention, and fixes batch/spatial
dimensions. ONNX validation checks output finiteness, positive depth, and
99th-percentile relative agreement with PyTorch. No model is trained or
fine-tuned by this build.
