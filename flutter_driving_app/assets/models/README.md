# YOLO11n COCO detection baseline

These are unmodified official Ultralytics detection assets from the
[v0.2.0 release](https://github.com/ultralytics/yolo-flutter-app/releases/tag/v0.2.0).
They are bundled so inference does not require a first-use model download.

| Asset | Upstream source | Bytes | SHA-256 |
| --- | --- | --- | --- |
| `yolo11n.tflite` | [Android model](https://github.com/ultralytics/yolo-flutter-app/releases/download/v0.2.0/yolo11n.tflite) | 5406462 | `555249e028f51955da4435595c00cb87bddcace79177132a00c5b4edc0842f66` |
| `yolo11n.mlpackage.zip` | [iOS model](https://github.com/ultralytics/yolo-flutter-app/releases/download/v0.2.0/yolo11n.mlpackage.zip) | 2500209 | `e5bdbf4950f468f401d1cf06c2859148fe26b7499fe75b4ddbd0a8ef840ec1e0` |

The TFLite file's embedded `metadata.json` identifies Ultralytics 8.3.122,
COCO training, task `detect`, input 320x320, and AGPL-3.0 licensing. Vehicle
classes are car (2), motorcycle (3), bus (5), and truck (7). The Core ML ZIP
contains `yolo11n.mlpackage` with its manifest, model, and weights; the plugin
extracts and compiles it on iOS.

The accompanying [AGPL-3.0 license](LICENSE) is copied from the pinned
Ultralytics Flutter package. See the [upstream licensing page](https://ultralytics.com/license).

These assets have not been fine-tuned on BDD100K or validated against
KITTI/nuScenes. See [baseline assumptions and grading rules](../../docs/following_distance.md).
