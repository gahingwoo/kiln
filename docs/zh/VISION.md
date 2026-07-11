# 图像推理(分类 / 检测)

英文版(更详尽,含导出/家族细节):[VISION.md](../VISION.md)。

Kiln 的大模型走 **RKLLM**;视觉走 **RKNN**(`librknnrt`,通用 CNN 运行时)。默认是 **MobileNet 图像
分类**;另有一条独立的 **YOLO 目标检测**路径(默认关)。同一颗 NPU、同一套 out-of-tree 驱动。

## 最省事:板上转模型

在板子上:

```sh
kiln-convert mobilenet --set-active    # 拉 MobileNetV2(Apache-2.0)+ 转 -> 分类,并写进配置
kiln-convert yolov8n  --set-active     # 拉 YOLOv8n(Ultralytics AGPL,会先问)-> 检测
```

它建一个私有 `rknn-toolkit2` venv,**锁到你装的 `librknnrt`**(所以不会版本对不上崩)。也可在 x86 上
转好后把 `.rknn` 丢进 `/opt/models`。详见 [工具 → kiln-convert](TOOLS.md)。

> **版本锁:** `.rknn` 必须用 **2.3.x** 的 rknn-toolkit2 转,匹配运行时 `librknnrt` 2.3.0。2.1.0 转的
> 会在 `rknn_inputs_set` 里抛 `std::out_of_range`。`kiln-convert` 自动锁版本。

## 运行

```sh
kiln-vision /opt/models/test.jpg        # 分类:打印 top-5 + 推理耗时
kiln-vision 图.jpg out.jpg              # 检测(task=detect):打印框,并把带框+标签的图存到 out.jpg
```

分类真实输出(约 6 ms、约 169 fps):

```
top-5 of 1000 classes  (NPU inference 5.9 ms):
  1. [ 494] chime, bell, gong            18.6719
  ...
[bench] rknn inference: 5.9 ms (169.5 fps)
```

## 目标检测(YOLO)

> **状态:板上可用,默认关。** 在 ROCK 4D 上验证过:`yolov8n` 在经典 dog-bike-car 图上正确检出
> bicycle / truck / dog,约 37 ms。比分类新、测的模型少,所以对一个新模型当"确认一次"处理。

用 `[vision] task = detect` 开启。支持这些 YOLO 家族:**YOLOv8 / YOLO11**(anchor-free,DFL)、
**YOLOv5 / YOLOv7**(anchor-based)、**YOLOX**(anchor-free + objectness),以及 **yolo-raw**——已解码但
未 NMS 的单输出 `[1, N, 4+ncls]`(Ultralytics `nms=False`,如 YOLO26 / YOLOv10)。`detector = auto`
从输出形状猜家族;也可强制 `yolov8`/`yolov5`/`yolox`/`yoloraw`。

> **导出要关 NMS。** `nms=True` / **end2end** 导出把 NMS 烤进模型(`[1, N, 6]` 输出)。rknn-toolkit2
> 能*转*,但内置的 NMS 算子(TopK / GatherElements)**在 RK3576 NPU 上跑不了——运行时会崩**。所以
> 关掉 NMS 导出:
> ```sh
> yolo export model=yolov8n.pt format=onnx nms=False opset=19 imgsz=640
> ```
> 然后 `kiln-convert ./yolov8n.onnx --set-active`(`kiln-convert yolov8n` 本身就抓一个关了 NMS 的)。

检测用 **COCO-80** 标签(不是分类的 ImageNet-1000)。切到 `task=detect` 时 `kiln-config` 会主动问你要
不要把标签切成 `coco_80_labels.txt`;`kiln-doctor` 在标签看着像 ImageNet 时会报警。存图上会画框 +
`<类别> <分数>` 文字(内嵌 8×13 位图字体)。

## 配置

```ini
[vision]
task = detect
detector = auto                              # 或 yolov8 / yolov5 / yolox / yoloraw
model = /opt/models/yolov8n_rk3576.rknn      # 你的 YOLO .rknn
labels = /opt/models/coco_80_labels.txt      # 附带:80 个 COCO 类
conf_threshold = 0.25
nms_iou = 0.45
```

`kiln-serve` 也暴露 `POST /v1/vision/classify` 和 `/v1/vision/detect`(见 [服务](SERVER.md))。

**许可证(重要):** Ultralytics **YOLOv5 / YOLOv8 / YOLO11 是 AGPL-3.0**;公开部署 `kiln-serve` 带
这类模型可能有网络使用义务。**YOLOX 是 Apache-2.0**(宽松),想避开 AGPL 可以用它。
