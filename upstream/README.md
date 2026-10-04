# 上游化材料

这里是这台机器（ASUS Vivobook S 15 / X1E80100）已经**实测验证过**、可以直接提交
上游的部分。每条都标了成熟度，别把没验证的一起发出去。

## 状态

| 项目 | 成熟度 | 目标仓 / 列表 |
| --- | --- | --- |
| **摄像头 DTS**（`0001-arm64-dts-qcom-...camera.patch`） | ✅ **推荐提交**：驱动绑定、出图、方向正确，本机实测 | `linux-arm-msm`（linux 内核 DT）→ `b4` / `git send-email` |
| **UCM profile**（`0001-ucm2-Qualcomm-...Vivobook-S15.patch`） | ✅ 可提交：扬声器/耳机两个 verb 在本机工作；含 dispatcher 分支 | `alsa-ucm-conf`（GitHub PR） |
| 音频 DTS（WSA8845 + WCD9385 节点） | ⚠️ 暂缓：`dts/x1-asus-vivobook-s15-audio.dtsi` 里还带着实验性的偏压路由（`X1E_AUDIO_WSA_ONLY` 等内容），要清理成"只有验证过的连线"再发 | 同内核 DT |
| 内部麦克风 | ❌ 不可提交：`hw:0,2` EIO、`hw:0,3` 全零，原因未定 | 先出问题报告，别发 patch |

## 怎么用这些 patch

### 1. 摄像头 DTS（内核）

```bash
cd <你的 linux 内核树（mainline 或 linux-next）>
git checkout -b vivobook-s15-camera
git apply /path/to/upstream/0001-arm64-dts-qcom-x1e80100-asus-vivobook-s15-add-camera.patch

# 编译验证（arm64 交叉编译或本机）
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- dtbs
git commit -s -F <(sed -n '/^Subject/,$p' ...)   # 或直接把下面那段 commit message 用上
```

提交前**先读一遍 patch 里的注释**，其中一处是推断值：

- `vreg_l1c_1p2` / `vreg_l2c_0p8`（CSIPHY 的两条轨）取自同代机型（XPS 13 9345 /
  Zenbook A14 / Yoga Slim 7x 都是这两条、电压 1.2V / 0.88V）。支持它的旁证：本板
  `x1-asus-vivobook-s15.dtsi` 的 PM8550VE-C 块**已经声明了** `vdd-l1-supply` /
  `vdd-l2-supply`（说明这两颗 LDO 在本板上存在），而同族的 `l3c` 电压（0.912V）
  与 Zenbook 完全一致，说明 PMIC 编号两边一致。如果维护者要更硬的依据，就让他们
  参考 ASUS 的原理图。
- 其余全部来自本机 Windows 驱动的资源文件（`CAMF_RES_QRD.bin` 的上电时序：
  LDO7_B / LDO3_M / MCLK4 / TLMM 235+236+237）与 sensor 配置（0x36），在
  [../docs/camera-probe.md](../docs/camera-probe.md) 里有完整证据链。

建议的 commit message：

```
arm64: dts: qcom: x1e80100-asus-vivobook-s15: add the camera

The front camera is an OV02C10 on cci1_i2c1 at address 0x36, powered by
LDO7_B (2.8 V) and LDO3_M (1.8 V), reset on TLMM 237, clocked from MCLK4
at 19.2 MHz and connected through CSIPHY4 with two data lanes.

The sensor is mounted rotated 180 degrees on this chassis, so the node sets
rotation = <180> for libcamera to correct the picture.

Verified on hardware: the driver binds, camss registers the media device and
a camera application shows a correctly oriented picture.
```

### 2. UCM profile

```bash
git clone https://github.com/alsa-project/alsa-ucm-conf
cd alsa-ucm-conf
git checkout -b asus-vivobook-s15
git apply /path/to/upstream/0001-ucm2-Qualcomm-x1e80100-add-ASUS-Vivobook-S15.patch
```

提交时说明白两点（都写在 [../docs/audio-bringup.md](../docs/audio-bringup.md) 里）：

- 为什么 Speaker 和 Headphones 必须是**两个 verb**而不是一个 verb 下的两个设备：
  ACP 只有在多个 UCM 设备共用同一条 PCM 时才能放进同一个 profile，而本机扬声器
  （MultiMedia2）和耳机（MultiMedia1）不是同一条；
- dispatcher（`x1e80100.conf`）里为什么要给这台机器单独一条分支：原来的
  Lenovo T14s 分支按 DMI 也会匹配到这台 ASUS，而它引用的 WCD9385 控件在精简
  DTB 下不存在，会导致 UCM 整体打不开 → WirePlumber 只剩 "Dummy Output"。

## 不建议现在发的

- **音频 DTS**：`dts/x1-asus-vivobook-s15-audio.dtsi` 是 bring-up 用的，里面有
  成组的实验性音频路由（多种偏压候选）。要发就得先收敛成"只有一条验证过的
  routing"的最小版本，并且在**干净上游内核**上再跑一遍验证。
- **麦克风**：现象和排除清单（15 条通路、偏压、bus clash、tplg、参数）适合写成
  一个 issue / 邮件而不是 patch，见 `docs/audio-bringup.md` 的"麦克风结论"。
- **视频硬解**：`qcvss8380.mbn` 属于 linux-firmware 的范围（本机已用
  `scripts/install-video-firmware.sh` 从 Windows 驱动包里装好），上游要的是
  把这份固件加进 linux-firmware 的对应目录，而不是内核 patch。
