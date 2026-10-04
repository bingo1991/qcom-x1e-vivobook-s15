# 视频硬解（iris）——2026-10-05 更正版

> 这篇文档在 10-05 被**大幅更正**：之前写的是"iris 是 V4L2 无状态（stateless）
> 解码器，所以只有 Chromium 能用"。**那是错的** —— 把驱动和内核的符号表翻出来
> 才看清 iris 在这台机器的内核里是**有状态**的 M2M 解码器，于是 ffmpeg / mpv /
> GStreamer 全都能直接用，一行命令就行，不用编译任何东西。走过的弯路记在最后
> 一节，留着别再走。

## 能用什么（都实测过）

| 用户态 | 状态 | 命令 |
| --- | --- | --- |
| ffmpeg | ✅ | `ffmpeg -c:v h264_v4l2m2m -i in.mp4 …`（HEVC/VP9 换 `hevc_v4l2m2m` / `vp9_v4l2m2m`） |
| mpv | ✅ | `mpv --hwdec=v4l2m2m-copy in.mp4`（注意是 `-copy`；纯 `v4l2m2m` mpv 会报 Unsupported） |
| GStreamer | ✅ | `gst-launch-1.0 filesrc location=in.mp4 ! qtdemux ! h264parse ! v4l2h264dec ! …` |
| Chromium | ❓ 待核实 | `chrome://gpu` 报 `Video Decode: Hardware accelerated`，但它的 V4L2 解码器走的是**无状态**探测，是否真硬解要用 `chrome://media-internals` 看 `video_decoder` 字段（见文末） |

支持的输入格式（`v4l2-ctl -d /dev/video0 --list-formats-out`）：
`H264`、`HEVC`、`VP90`、`AV01`。

## 为什么是 `v4l2m2m` 而不是 `v4l2sl*`

证据（都是在一台真实设备上查的，不是推测）：

```
# 驱动里没有任何 request API / 无状态控件的痕迹
$ readelf -sW /tmp/iris.ko | grep -c 'media_request\|v4l2_ctrl_request'
0
$ strings /tmp/iris.ko | grep -c STATELESS
0

# 但它支持有状态的 decoder cmd
$ sudo v4l2-compliance -d /dev/video0 | grep -iE "decoder_cmd|request"
	test VIDIOC_(TRY_)DECODER_CMD: OK
	test Requests: OK (Not Supported)

# 设备形态：M2M、多平面、动态分辨率
$ v4l2-ctl -d /dev/video0 --all | head -12
	Driver name      : iris_driver
	Capabilities     : 0x84204000  (Video Memory-to-Memory Multiplanar, Streaming, Extended Pix Format)

# 一跑就明白：ffmpeg 自己报了它用的是哪个设备和哪种模式
$ ffmpeg -c:v h264_v4l2m2m -i /tmp/t.mp4 -f null -
[h264_v4l2m2m] Using device /dev/video0
[h264_v4l2m2m] driver 'iris_driver' on card 'Iris Decoder' in mplane mode
[h264_v4l2m2m] requesting formats: output=H264/none capture=NV12/yuv420p
frame=  300 … speed=20.7x
```

有状态 M2M 意味着**固件自己解析码流**（driver 只负责搬运和握手），所以对的是
传统那套客户端：ffmpeg 的 `*_v4l2m2m` 解码器、GStreamer `video4linux2` 插件里的
`v4l2h264dec/v4l2h265dec/v4l2vp9dec`、mpv 的 `--hwdec=v4l2m2m-copy`。

## 怎么确认它真的是在解码（而不是吐黑帧）

"没报错"不等于"解对了"。`scripts/verify-hwdecode.sh` 会把同一段片子硬解、软解
各出一份逐帧校验和（`framemd5`，两边都强制 `yuv420p` 所以哈希可比），逐帧比对：

```bash
scripts/verify-hwdecode.sh                    # 自动生成 1080p 测试片
scripts/verify-hwdecode.sh ~/Videos/xxx.mp4   # 拿真实片子测
CLIP_SECS=30 scripts/verify-hwdecode.sh        # 长一点更能看出吞吐差异
HW_CODEC=hevc_v4l2m2m scripts/verify-hwdecode.sh x.mp4   # 换 codec

# 0 = 逐帧一致；2 = 打不开解码器；3 = 哈希不一致（真有问题）
```

**性能上别用小片段下结论**：10 秒 720p / 100 KB 这种，硬件反而比软解慢
（初始化开销 ≈ 0.4 s，软解只要 0.07 s）。要比较就用 1080p 以上、长一点的片子。

## 前置条件：固件

DTB（`video-codec@aa00000` 的 `firmware-name`）点名的是：

```
qcom/x1e80100/ASUSTeK/vivobook-s15/qcvss8380.mbn
```

linux-firmware 里没有 ASUSTeK 这一支，所以要么用 Windows 驱动包里的原件，要么用
同 SoC 的 Lenovo 那份：

```bash
scripts/install-video-firmware.sh --list     # 挑与本机固件同一代的
sudo scripts/install-video-firmware.sh
sudo modprobe -r qcom_iris && sudo modprobe qcom_iris
```

本机装的是 Windows 驱动包 `qcdx8380.inf_arm64_8053adc44985505a`
（DriverVer 01/08/2026, 31.0.137.0）里的那份，2323048 B，
md5 `dee58ef0ac912a0e5ac1eb6fe00ace0a`。

**注意：装对了以后内核什么都不打印**（加载成功时没有日志），判断标准是
`/sys/class/video4linux/video*/name` 里有没有 `qcom-iris-*`、设备在
`/sys/bus/platform/drivers/qcom-iris/` 下有没有绑定符号链接。装之前则是
`firmware download failed -2` / `core init failed` 而且节点不出现。

## 走过的弯路（别再走）

这三件事都建立在"iris 是无状态解码器"这个错误前提上，全部排除：

1. **`ffmpeg -hwaccel v4l2request`** —— 上游 ffmpeg 根本没有这个 hwaccel
   （`libavcodec/` 里只有 `v4l2_m2m*.c`，全树没有一个 request API 调用；
   `--enable-v4l2-request` 是 ChromeOS 分支的选项，Collabora 另有配套的
   `libva-v4l2-request` VA-API 驱动，Ubuntu 仓库里都没有）。
2. **GStreamer 的 `v4l2slh264dec`（无状态那一族）** —— 那族元素所在的
   `v4l2codecs` 插件声明了 `/dev/media*` 依赖，而 iris 不注册 media 设备
   （`readelf` 里一个 `media_*` 符号都没有）；造个假 `/dev/media0` 也没用，
   插件是真的要打开并分析 media 设备。**但这不影响 `v4l2h264dec`**，那是另一个
   插件（`video4linux2`）里的有状态元素，跟 media 设备无关。
3. **克隆 ChromeOS 的 ffmpeg / Collabora 的 libva-v4l2-request** —— 两者都是
   无状态实现，跟 iris 对不上，克隆编译只会白花时间。

## Chromium 那个 `Hardware accelerated` 要单独核实

`chrome://gpu` 说 `Video Decode: Hardware accelerated`，但 Chromium 的
`V4L2VideoDecoder` 走的是请求 API（无状态）那一套，而 iris 不提供。所以要么
Chromium 另有回退路径，要么那行状态是探测结论、实际解码时回落软解。核实方法：

```bash
mkdir -p ~/Videos && cp /tmp/t.mp4 ~/Videos/     # snap 的 /tmp 是私有的
# 用 Chromium 打开 file:///home/user/Videos/t.mp4，然后看
#   chrome://media-internals  →  正在播放的条目里 video_decoder 字段
#   V4L2VideoDecoder = 真硬解；FFmpegVideoDecoder = 其实在软解
```

## 回退

```bash
sudo scripts/install-video-firmware.sh --revert
sudo modprobe -r qcom_iris && sudo modprobe qcom_iris
```
