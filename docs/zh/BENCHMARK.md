# 性能(跑分)

英文版:[BENCHMARK.md](../BENCHMARK.md)。

下面的数字都测自**唯一实测目标**:一块跑 Armbian 的 **Radxa ROCK 4D(RK3576)**,Kiln 主线
`linux-7.1.3` 内核,`librkllmrt` 1.2.0 / `librknnrt` 2.3.0。实际值随模型、量化、散热和内存频率变化。
每个工具都打印自己的 `[bench]` 行,所以很好复现。

## 大模型(kiln-chat / kiln-serve)

贪心(`top_k = 1`)、W4A16 量化、NPU 上的解码吞吐:

| 模型 | 解码 | 备注 |
|---|---|---|
| **Llama-3.2-1B-Instruct**(w4a16) | **约 13 tok/s** | 两者中更快 |
| **Qwen2.5-1.5B-Instruct**(w4a16) | **约 9 tok/s** | 更大,略慢 |

`kiln-chat` 每轮打印:
```
[bench] tokens=…  prefill(TTFT)=… ms  decode=… tok/s  total=… ms
```
- **decode tok/s** 是稳态生成速率("跑多快"通常指这个)。
- **TTFT**(首 token 时间)是 prefill 延迟;随 prompt + 历史长度增长。

复现:`kiln-chat` 问一句,看 `[bench]` 行。`/model` 现场切换在同一块板上对比。

## 视觉——分类(kiln-vision)

MobileNetV2,224×224,fp16,单次 NPU 推理:

| 负载 | 延迟 | 吞吐 |
|---|---|---|
| **MobileNetV2-12** | **约 6 ms**(实测 5.9 ms) | **约 169 fps** |

复现:`kiln-vision /opt/models/test.jpg` → `[bench] rknn inference: 5.9 ms (169.5 fps)`。

## 视觉——检测(kiln-vision, task = detect)

YOLOv8n(airockchip 导出),640×640,fp16,经典 dog-bike-car 图:

| 负载 | 延迟 | 结果 |
|---|---|---|
| **YOLOv8n** | **约 37 ms** | bicycle / truck / dog,正确 |

复现:`kiln-vision /opt/models/dog_bike_car.jpg out.jpg`(打印框 + 存标注图)。

## 一点背景

- 这些是 **NPU 推理**耗时——Kiln 的意义在于*厂商 NPU 栈跑在主线内核上*,而且和厂商 BSP 上一样快。
- 一块约 $40 级别的板子,分类约 169 fps、大模型 9–13 tok/s、全程离线,这就是卖点:边缘上的私有助手
  + 准实时视觉。
- 检测比分类新、测的模型少——新模型当"确认一次"处理(见 [视觉](VISION.md))。

有别的模型或(尤其)**别的板子**的数字?在 [issue](https://github.com/gahingwoo/kiln/issues) 里贴
`kiln-doctor` 输出 + 你的 `[bench]` 行,非常欢迎。
