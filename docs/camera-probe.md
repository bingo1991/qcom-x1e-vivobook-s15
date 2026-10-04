# 摄像头探路：先把 CCI 打开（2026-10-05）

## 现状

- sensor 型号已知：**OV02C10**（Windows 导出；内核里 `CONFIG_VIDEO_OV02C10=m`
  的驱动也在）
- `qcom-camss.ko`、`i2c-qcom-cci.ko` 都在，**但一个都没加载**
- 原因在设备树：SoC dtsi（`hamoa.dtsi`）里两颗 CCI（摄像头 sensor 挂的 I²C
  控制器，`cci@ac15000` / `cci@ac16000`）和 CAMSS（`isp@acb7000`）都是
  `status = "disabled"`，所以**现在这台机器上根本没有摄像头 I²C 总线**

## 这一版做了什么（`make build-cam-cci`）

只加三行：把 `cci0`、`cci1` 打开（`dts/x1-asus-vivobook-s15-camera-probe.dtsi`）。
音频部分不受影响（同一份 DTB 里 sound 节点、WSA8845 都在，已验证）。

**故意没做的事**：不加 sensor 节点。因为它的供电和 reset 脚在这台机器的设备树里
完全没有描述，而同代机型用的是这台机器 DT 里**根本没定义**的几条轨
（Zenbook A14 / Yoga Slim 7x 用 `vreg_l7b_2p8`、`vreg_l3m_1p8`、`vreg_l2c_0p8`、
`vreg_l1c_1p2`；Vivobook 的 dtsi 里只有 15 条 LDO，一个都不沾）。照抄那些节点
= 猜"本机哪条 LDO 供摄像头"，而 sensor 驱动会把它当成 camera rail 去设电压：
给错的轨上电、或者把某个未知引脚当 reset 拉来拉去，是有可能烧硬件的。这些映射
必须从 ACPI DSDT 里读（见 [windows-info-round2.md](windows-info-round2.md)）。

## 操作

```bash
make build-cam-cci            # 编译（离线可跑，已验证：CCI buses enabled: 2）
sudo make patch-cam-cci       # 写进 /boot/vmlinuz-$(uname -r) 的 .dtbauto 段
sudo reboot
```

重启后：

```bash
# 1. 总线出来了吗（应该有 4 条 cci 总线）
i2cdetect -l | grep -i cci
dmesg | grep -i -E "cci|camss" | tail -20

# 2. 每条总线上都有谁（把 <n> 换成 1..x，用 i2cdetect -l 里的编号）
for i in $(i2cdetect -l | awk '/cci/{sub("i2c-","",$1); print $1}'); do
	echo "== i2c-$i"; i2cdetect -y "$i" 2>&1 | tail -10
done
```

## 结果怎么读

| 现象 | 含义 | 下一步 |
| --- | --- | --- |
| 某条总线的 **0x36** 上有设备 | 和同代机型一致（Zenbook A14 / Yoga Slim 7x 的 OV02C10 都在 `cci1_i2c1` @ `0x36`），而且说明 sensor 此刻是通电的 | 记下总线号；等 DSDT 里的 reset/供电，把 sensor 节点补上就能 probe |
| 4 条总线都空的 | **不能证伪** —— 摄像头供电默认是关的，不通电的 sensor 不会应答 | 等第二轮 DSDT（里面有 I²C 地址、reset 脚、三条轨） |
| `i2cdetect -l` 里没有 cci 总线 | CCI 驱动没 probe（看 `dmesg \| grep cci`） | 把 dmesg 发我 |

风险：这一步不动任何供电/GPIO，只是把 CCI 控制器的时钟、电源域和 I²C 引脚
接上，属于低风险。如果 `i2cdetect` 报 "Functionality not supported"，试
`i2cdetect -y -r <bus>`（用 read-byte 方式扫）。

## 回退

```bash
make build && sudo make patch      # 回到正常的 full 版 DTB
# 或者
sudo scripts/patch-vmlinuz-dtb.py --restore --yes
sudo reboot
```

---

## 结果（2026-10-05）：一次成功

CCI 探针那一版（`cam-cci`）证明了两颗 CCI 都能起来，但**四条总线全空** —— 模块
没供电。随后在 Windows 驱动的资源文件 `CAMF_RES_QRD.bin` 里找到了完整上电时序
（见 [windows-hardware-findings.md](windows-hardware-findings.md) §8.1），于是做了
`cam-sensor` 变体。重启后：

```
[    0.051728] /soc@0/cci@ac16000/i2c-bus@1/camera@36: Fixed dependency cycle(s) ...
[    4.557294] qcom-camss acb7000.isp: Entity type for entity msm_tpg0 was not initialized!   (无害)

$ v4l2-ctl --list-devices
Qualcomm Camera Subsystem (platform:acb7000.isp):
	/dev/video0 /dev/video1 /dev/video3 ... /dev/video17
	/dev/media0

$ sudo i2cdetect -y 3
30: -- -- -- -- -- -- UU -- -- -- -- -- -- -- --      <- 0x36 = UU：驱动已绑定
```

**这些值因此被确认是对的**（全部来自本机资源，不是抄板子）：

| 项 | 值 |
| --- | --- |
| 总线 / 地址 | `cci1_i2c1`（cci@ac16000 的 i2c-bus@1）@ **0x36** |
| 复位 | `TLMM gpio 237`（active low） |
| 时钟 | `CAM_CC_MCLK4_CLK` @ 19.2 MHz |
| 供电 | `vreg_l7b_2p8`（2.8V, avdd+dvdd）+ `vreg_l3m_1p8`（1.8V, dovdd） |
| CSI | `csiphy4`，`data-lanes <1 2>`，400 MHz |

注意 dmesg 里**没有 ov02c10 的日志** —— 又一次"成功即静默"（和 iris 固件那次一样），
判断依据是 `/dev/media0`、18 个 video 节点、以及 `i2cdetect` 里 0x36 的 `UU`。

### 出图了（2026-10-05）

拿系统里的相机应用打开，**直接就有画面** —— sensor → csiphy4 → csid → vfe 整条
管线都是通的，不用手工 `media-ctl` 配格式（应用自己会协商）。

唯一的问题是画面**上下颠倒**：这颗模块在本机是 180° 装配的。修法是加一个通用属性
（提交 f8c24ce）：

```dts
&cci1_i2c1 {
	camera@36 {
		orientation = <0>;	/* 前摄 */
		rotation = <180>;	/* 本机装配方向 */
		...
	};
};
```

依据：Dell XPS 13 9345（同一颗 OV02C10 前摄）就是这么写的；Zenbook A14 / Yoga
Slim 7x 不需要（装配方向不同）。本机 ACPI 里那两块 `_PLD` 属于 `SEN2`（运动传感器，
rotation 都是 0），跟摄像头无关。

注意 `rotation` 是**元数据**（内核暴露成 `V4L2_CID_CAMERA_SENSOR_ROTATION`）：
libcamera 系的应用会读它并自动转正；裸 V4L2 消费者（`v4l2-ctl` 抓帧、VLC、ffmpeg
直读 `/dev/videoN`）不会，需要自己转。

### 复现步骤（现在只有这些）

```bash
make build            # = 音频 + 摄像头（full 现在默认带相机）
sudo make patch
sudo reboot
# 打开任意相机应用，方向正确、有画面
```

想单独检查硬件层：

```bash
v4l2-ctl --list-devices     # Qualcomm Camera Subsystem，18 个 video 节点 + /dev/media0
sudo i2cdetect -y 3         # cci1_i2c1 上 0x36 显示 UU（驱动已绑定）
dmesg | grep -iE "camss|ov02c10"
```

（`make build-cam-sensor` 现在与 `make build` 等价，保留这个名字是因为本文档一直用它；
`make build-cam-cci` 仍是"只开 CCI 不挂 sensor"的探针版，用于排查。）

`/dev/media0` 的出现还有个副作用：GStreamer 的 `v4l2codecs` 插件声明依赖
`/dev/media*`，现在它的元素应该能注册出来了 —— 不过 iris 是有状态解码器，视频那条
路用不上它，见 [video-decode.md](video-decode.md)。）
