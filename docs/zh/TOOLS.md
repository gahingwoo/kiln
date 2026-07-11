# 工具:kiln、kiln-doctor、kiln-config、kiln-convert

英文版:[TOOLS.md](../TOOLS.md)。

装到 `/usr/bin`,和 `kiln-chat` / `kiln-vision` / `kiln-serve` 一起:一个总启动器、一个健康检查、
一个配置 TUI、一个板上转模型工具。

## kiln —— 总启动器

`kiln` 不带参数会开一个菜单(whiptail)选功能;也能直接分发到某个工具:

```sh
kiln                 # 菜单:对话 · 视觉 · 模型 · 服务 · 连接 Web UI · 设置 · 诊断
kiln chat            # -> kiln-chat        (大模型对话 CLI)
kiln vision <图>     # -> kiln-vision      (分类 / 检测;第二个路径参数可存标注图)
kiln models          # -> kiln-convert     (板上获取 / 转模型)
kiln serve           # -> kiln-serve       (或在菜单里开/关 systemd 服务)
kiln config          # -> kiln-config
kiln doctor          # -> kiln-doctor
```

菜单里的 **Connect a web UI** 会显示填好板子 IP 的连接串 + 可直接粘贴的 `docker run`——把"接入
Web UI"这件事从文档里提到菜单里看得见。它只启动下面这些工具;各自处理自己的权限
(`kiln-config` / `kiln-doctor` 自己 re-exec sudo)。

## kiln-doctor —— 健康检查

`kiln-doctor` 打印通俗的通过/失败报告——对齐的 `[ OK ] / [FAIL] / [WARN] / [INFO]` 标签,每项一行——
**任一关键检查失败就以非 0 退出**,所以可脚本化,也是"提 issue 前先贴这个"的工具。它也是 kiln-config
状态页背后的引擎。

```sh
kiln-doctor          # 完整报告
kiln-doctor -q       # 安静:只列失败 + 最终结论
sudo kiln-doctor     # 以 root 跑才能读 dmesg(MMU 检查)
```

它检查:内核&安装、驱动(`rknpu` 加载 + `renderD*` 节点)、MMU 四 bank 状态、运行时版本、工具、
模型(存在 + 版本匹配)、**API 服务**(`[server] host` 是不是 127.0.0.1,以及跑起来后的连接串)、
网络。

## kiln-config —— 配置 TUI

`sudo kiln-config` 是 `whiptail`(退化到 `dialog`)菜单工具,仿 `armbian-config`。它是
`/etc/kiln/config.ini` 的**前端**,不是替代:**就地**编辑文件,保留你的注释和未知字段;`<Save>`
写入、`<Back>` 丢弃。它需要 root(配置是 root 所有、状态页读 dmesg),没给就自己 re-exec sudo。

页面:状态、LLM、Vision、Server、Models(获取/转换/设置)、System(驱动/内核/wifi/更新)。文件选择器
扫 `/opt/models`,枚举用单选。

## kiln-convert —— 板上获取 / 转模型

`kiln-convert` 把 ONNX 在**板子上**转成版本匹配的 `.rknn`——不用 x86 机器、不用手动装 rknn-toolkit2、
不用 scp。首次用会在 `/opt/kiln/rknn-venv` 建一个私有 `rknn-toolkit2` venv,**锁到你装的 librknnrt**
版本(版本不匹配转出的 `.rknn` 加载会 `std::out_of_range`,所以它拒绝装别的版本)。首次那次要下几百
MB、几分钟;之后就快了。

```sh
kiln-convert mobilenet            # 拉 MobileNetV2(Apache-2.0)+ 转 -> 分类
kiln-convert yolov8n              # 拉 YOLOv8n(Ultralytics AGPL-3.0!先问)-> 检测
kiln-convert ./my_model.onnx      # 转本地 ONNX(按文件名猜类型)
kiln-convert https://host/m.onnx  # 下载 + 转
kiln-convert https://host/m.rknn  # 只把预转好的 .rknn 放进 /opt/models
kiln-convert mobilenet --set-active   # ……并把 /etc/kiln/config.ini 指过去
```

源可以是**model-zoo 快捷词**(`mobilenet` / `yolov8n`,从 `airockchip/rknn_model_zoo` 抓)、**URL**
或**本地路径**。预设设归一化(`mobilenet`:ImageNet mean/std;`yolo`:`0..255`);用 `--type` /
`--mean` / `--std` 覆盖。默认 fp16;`--quant --dataset 文件` 做 INT8。`--set-active` 把模型
(以及 YOLO 的 `task=detect` + COCO 标签)写进配置。见 `kiln-convert --help` 和 [视觉](VISION.md)。

> **许可证。** Kiln 不附带模型。`mobilenet` 是 Apache-2.0(干净)。`yolov8n` 拉的是 Ultralytics 权重,
> 是 **AGPL-3.0**——`kiln-convert` 会先给提示并征询。YOLOX(Apache-2.0)是宽松替代:用 URL/路径指向
> 一个 YOLOX ONNX 即可。
