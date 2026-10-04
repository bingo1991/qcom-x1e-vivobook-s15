# ASUS Vivobook S 15 (Snapdragon X Elite) — Linux audio bring-up

Make the built-in speakers work on the **ASUS Vivobook S 15** (S5507QA/S5507QAD),
Snapdragon X Elite `X1E80100`, under Ubuntu's `linux-qcom-x1e` kernel.

Tested on: **Ubuntu 26.04, kernel `7.3.0-15-qcom-x1e`**, device tree with
2 × WSA8845 SoundWire amplifiers.

> 中文说明见文末 → [跳转](#中文说明)

## Status

| Feature | State |
| --- | --- |
| Speakers (2 × WSA8845) | ✅ working, the default output (UCM verb `HiFi`) |
| Headphones (WCD9385) | ✅ working, UCM verb `Headphones`; switch with `scripts/audio-output.sh` (or pavucontrol), needs the `full` DTB |
| Auto-switch on plug-in | ❌ jack pins are CARD-interface controls, UCM's JackControl only looks at MIXER — see docs |
| Headset mic (WCD9385, 3.5 mm) | ❌ not capturing (same bias/power class of problem as the DMIC) |
| Internal DMIC | ❌ not captured by any of the 15 plausible paths — see Roadmap |
| Camera | ✅ works — `OV02C10` on `cci1_i2c1` @ 0x36, camss up, a camera app shows a correctly oriented picture (`rotation = <180>` for this chassis). Part of the default DTB now — see docs/camera-probe.md |
| Hardware video decode (iris) | ✅ `ffmpeg -c:v h264_v4l2m2m`, `mpv --hwdec=v4l2m2m-copy`, `gst … ! v4l2h264dec` all work — iris is a *stateful* M2M decoder (H264/HEVC/VP9/AV1). Verify with `scripts/verify-hwdecode.sh`. See docs/video-decode.md |

## Why it does not work out of the box

Three independent problems stacked on top of each other.

**1. The device tree never reaches the kernel.**
Ubuntu's `linux-qcom-x1e` images are built with [stubble].  All 41 machine DTBs
live in **`.dtbauto` PE sections inside `vmlinuz`**, together with a `.hwids`
table, and the EFI stub picks one at boot by matching SMBIOS.  Consequences:

- `/usr/lib/firmware/<kver>/device-tree/**` is just a copy that nothing uses;
- GRUB's `devicetree` command is ignored, so `/boot/dtb-*` tricks do nothing;
- `grub-reboot` is a **no-op** on this machine (the installed GRUB has no
  `next_entry` variable at all).

So the DTB has to be replaced *inside the kernel image*.
See [docs/dtb-delivery.md](docs/dtb-delivery.md) for the full analysis.

**2. The machine DTS has no `sound` node.**
Upstream (`x1-asus-vivobook-s15.dtsi`) still describes this laptop without
audio, so `snd-soc-x1e80100` matches nothing and no sound card appears at all.
This repo adds the missing nodes.

**3. The ALSA UCM profile that matches this laptop is the wrong one.**
`/usr/share/alsa/ucm2/conf.d/x1e80100/x1e80100.conf` dispatches by DMI, and its
Lenovo T14s branch also matches `ASUS ... Vivobook S 15`.  That profile drives
WCD9385 controls (`HPHL Volume`, …) which do not exist without the codec, so
`snd_use_case_mgr_open()` fails, `alsactl` falls back to the generic method and
WirePlumber ends up with **no usable profile → "Dummy Output"**.

## Quick start

```bash
git clone <this repo> ~/Workspace/x1e-vivobook-s15-linux-audio
cd ~/Workspace/x1e-vivobook-s15-linux-audio

make status                  # what is already in place?
make build                   # build the DTB - "full" variant, speakers + headphones
                             # (needs the matching kernel source tree)
sudo make patch              # write it into /boot/vmlinuz-$(uname -r)
sudo make ucm                # install the UCM profile
sudo reboot                  # the DTB is picked up at boot

make selftest                # after reboot: one-shot bring-up checks
```

`make patch` modifies the kernel image, so it always keeps a backup in
`/var/backups/x1e/` (**not** in `/boot`: GRUB enumerates kernels with
`/boot/vmlinuz-*`, so a backup there turns into a broken menu entry whose
matching initrd does not exist) and refuses to run without `--yes` or an
interactive confirmation.  Everything is reversible:

```bash
sudo scripts/patch-vmlinuz-dtb.py --restore --yes && sudo reboot
sudo scripts/install-vivobook-ucm.sh --restore
```

## Repository layout

| Path | What |
| --- | --- |
| `dts/x1-asus-vivobook-s15-audio.dtsi` | the missing audio nodes (WSA8845 + WCD9385 + VA macro) |
| `dts/x1-asus-vivobook-s15-camera-probe.dtsi` | camera nodes: CCI controllers, and (in the default build) the OV02C10 with its rails and reset |
| `ucm/ASUS-Vivobook-S15*.conf` | dedicated ALSA UCM profile (speaker) |
| `scripts/build-dtb.sh` | applies the dtsi to a kernel tree and builds the DTB |
| `scripts/audio-output.sh` | switch the card between the Speaker and Headphones profiles |
| `scripts/patch-vmlinuz-dtb.py` | finds the `.dtbauto` section for this machine and replaces it |
| `scripts/install-vivobook-ucm.sh` | installs the UCM profile + fixes the DMI dispatch |
| `scripts/reapply-after-upgrade.sh` | re-applies both after package upgrades (+ optional apt hook) |
| `scripts/cleanup-legacy-grub.sh` | removes the leftovers of the old `/boot/dtb-*` + GRUB entry approach |
| `scripts/selftest.sh` | one-shot post-boot check (DTB live? firmware blobs? card? amps? Wi-Fi?) |
| `scripts/install-video-firmware.sh` | install the missing `qcvss8380.mbn` (iris/VSS) for hardware video decode |
| `scripts/verify-hwdecode.sh` | decode a clip in hardware and in software, compare frame checksums |
| `docs/video-decode.md` | how to decode in hardware (ffmpeg/mpv/GStreamer), and the wrong turns we took first |
| `scripts/test-speaker.sh` | bring the speaker path up with plain `amixer` and play a tone |
| `scripts/test-mic.sh` | same for the DMIC capture path (records a few seconds) |
| `scripts/mic-scan.sh` | brute-force scan over every plausible mic capture route |
| `scripts/try-tplg.sh` | borrow another machine's audio topology — checks UCM compatibility first (`--list` shows that most of them are aliases of two files) |
| `scripts/test-headphone.sh` | WCD9385 headphone path (needs the `full` DTB) |
| `docs/` | detailed bring-up notes (Chinese) |

Looking for the microphone array, the camera sensor or the missing video
firmware?  [docs/windows-hardware-info.md](docs/windows-hardware-info.md) is a
step-by-step guide for harvesting that information from the Windows install
(device IDs, driver store, ACPI tables) and bringing it back to Linux;
[docs/windows-hardware-findings.md](docs/windows-hardware-findings.md) is the
analysis of the first export (what it proved, and what is still missing).

## After a kernel / alsa-ucm-conf upgrade

Two things live in package-owned files and are overwritten by upgrades:

| Lost | Trigger | Restore |
| --- | --- | --- |
| `.dtbauto` section in `vmlinuz` | any `linux-*qcom-x1e` kernel upgrade | `sudo make reapply` |
| UCM profile + dispatcher tweak | `alsa-ucm-conf` upgrade | `sudo make reapply` |

Or let it happen automatically:

```bash
sudo make hook      # apt post-invoke hook -> /var/log/x1e-reapply.log
```

## WiFi dies after suspend/resume (workaround)

The WCN7850 does not survive a suspend/resume cycle: ath12k comes back looping
with `wmi command 16387 timeout` / `fail to start mac operations ... ret -11`
and WiFi stays dead until the modules are reloaded.

```bash
sudo scripts/install-wifi-suspend-hook.sh        # installs the systemd sleep hook
# remove with: sudo scripts/install-wifi-suspend-hook.sh --remove
```

The hook unloads `ath12k_wifi7`/`ath12k` before the suspend and reloads them on
resume, so the firmware is re-initialised from scratch instead of being asked
to recover (a few seconds of downtime on resume, NetworkManager reconnects by
itself).  `scripts/selftest.sh` reports whether the hook is installed and
whether the current boot hit the ath12k timeout loop.

## Roadmap

- [ ] internal DMIC: none of the 15 candidate routes (VA/TX macro PDM pins,
      WCD9385 digital mics over SoundWire, WCD9385 analog mics) produced
      anything but zeros; routing every candidate mic bias did not help.
      Next step is hardware information (Windows audio INF / ACPI) to find the
      mic array's power/enable — see docs/audio-bringup.md
- [x] ruled out: SoundWire "Bus clash" is *not* the cause - a clean boot with
      no playback gives identical results
- [ ] new lead: every codec-side capture candidate fails with `pcm_read:
      I/O error` on hw:<card>,2 (MultiMedia3 / TX_CODEC_DMA_TX_3) while the
      same codec's playback on hw:<card>,0 works, so the ADSP capture graph
      (Romulus tplg, `qcom,tx-port-mapping`) is the next thing to look at
- [x] ruled out: swapping the placeholder tplg for the EVK/DEVKIT one does not
      change the `pcm_read: I/O error` on hw:<card>,2
- [x] ruled out: channel count / sample rate (1/2/4 ch x 16/48 kHz all fail),
      so hw:<card>,2 is broken regardless of configuration
- [x] headphones (WCD9385) - separate UCM verb, switched with
      `scripts/audio-output.sh` (or pavucontrol; GNOME has no profile UI)
- [ ] headphone jack auto-switching (`api.acp.auto-port`, or a MIXER-interface
      jack control upstream)
- [ ] headset mic on the 3.5 mm jack
- [ ] verify the `full` DTB variant (WCD9385 headphone + headset mic)
- [x] camera (bring-up): `OV02C10` is bound at 0x36 on cci1_i2c1, with rails
      `l7b_2p8` + `l3m_1p8`, reset on TLMM 237 and MCLK4 - all taken from this
      machine's own Windows resource file (`CAMF_RES_QRD.bin`), not copied from
      a sibling board.  `make build-cam-sensor` + patch + reboot does it
- [x] camera (capture): a camera app opens it and shows a correctly oriented
      picture (`rotation = <180>`); sensor→csiphy4→csid→vfe all negotiate on
      their own, no manual media-ctl setup needed
- [x] hardware video decode (kernel): `scripts/install-video-firmware.sh`
      installs `qcvss8380.mbn` (from the Windows driver package that the rest
      of the firmware set came from) - `qcom_iris` binds, `/dev/video0`
      (decoder) and `/dev/video1` (encoder) appear, H264/HEVC/VP9/AV1 are
      accepted.  Note that a *successful* probe logs nothing: judge it by
      `/sys/class/video4linux`, not by `dmesg`
- [x] hardware video decode (userspace): **ffmpeg, mpv and GStreamer all work**
      through the ordinary stateful v4l2m2m interface (`h264_v4l2m2m`,
      `--hwdec=v4l2m2m-copy`, `v4l2h264dec`) - the earlier "only Chromium" note
      was based on iris being stateless, which the driver's symbol table
      disproves.  `scripts/verify-hwdecode.sh` compares frame checksums against
      a software decode
- [ ] check what Chromium's `Video Decode: Hardware accelerated` line really
      means here: its V4L2 path is the stateless one, so `chrome://media-
      internals` (does it say V4L2VideoDecoder or FFmpegVideoDecoder?) is the
      thing to read
- [ ] the *stateless* path (GStreamer `v4l2sl*`, ChromeOS ffmpeg's
      `v4l2request`, libva-v4l2-request) is a dead end on this driver: iris
      registers no media device and has no request API.  Not worth reporting
      upstream unless someone ports iris to stateless
- [ ] encoder (`/dev/video1`): node exists, never exercised
- [x] work around the ath12k suspend/resume `WMI command timeout`
      (`scripts/install-wifi-suspend-hook.sh`; the underlying driver bug is
      still worth reporting upstream)
- [ ] **upstream the DTS nodes** to `linux-arm-msm` and a UCM profile to
      `alsa-ucm-conf` — this repo is only the local workaround

## Contributing

Reports from other X1E laptops are welcome — especially: which machine you have,
`wpctl inspect <card>` output, `alsaucm -c x1e80100 list _verbs`, and whether
the "full" (WCD9385) variant registers a card on your machine.

## License

Scripts and documentation: MIT (see `LICENSE`).
`dts/`: kernel code, keeps its original `BSD-3-Clause` SPDX identifier.

[stubble]: https://github.com/ubuntu/stubble

---

## 中文说明

**目标**：让 ASUS Vivobook S 15（骁龙 X Elite / X1E80100）在 Ubuntu 的
`linux-qcom-x1e` 内核下能用内置扬声器。实测环境：Ubuntu 26.04 +
`7.3.0-15-qcom-x1e`，2 颗 WSA8845。

**为什么开箱不出声**——三层问题叠加：

1. **设备树根本没送到内核**。Ubuntu 的 qcom-x1e 内核用 stubble 打包，41 个机型
   的 DTB 都在 `vmlinuz` 的 `.dtbauto` PE 段里，由 EFI stub 按 `.hwids`
   自动挑。所以改 `/usr/lib/firmware/.../device-tree/` 没用，GRUB 的
   `devicetree` 也没用，`grub-reboot` 在这台机器上更是空操作（GRUB 里根本没有
   `next_entry`）。必须直接替换镜像里那一段。
2. **机型 DTS 里没有 `sound` 节点**，`snd-soc-x1e80100` 匹配不到任何东西。
3. **UCM profile 选错了**：分派文件把 Vivobook S 15 归到 Lenovo T14s 那条，
   而那份 profile 需要 WCD9385 的控件；控件不存在 → UCM 打开失败 →
   WirePlumber 只剩 "Dummy Output"。

**三条命令搞定**：

```bash
make build            # 编译 DTB（需要对应版本的内核源码树）
sudo make patch       # 写进 /boot/vmlinuz-$(uname -r)
sudo make ucm         # 安装 UCM profile
sudo reboot
```

**升级内核或 alsa-ucm-conf 后**会失效，重跑 `sudo make reapply` 即可；
也可以用 `sudo make hook` 装个 apt hook 自动重打补丁。

**当前状态**：扬声器（默认输出）+ 耳机（`scripts/audio-output.sh headphones` 切换）
都已实机验证，用的是 `make build` 生成的"完整版"DTB（含 WCD9385）；
`make build-wsa` 是只带扬声器的精简版（万一某台机器没有 codec 时用它兜底）。
**摄像头已经可用**：`OV02C10` 挂在 `cci1_i2c1` @ 0x36，供电/复位/时钟全部取自本机
自己的 Windows 资源文件；`make build`（默认变体）已经带上相机节点，打开相机应用就能
出图且方向正确（本机是 180° 装配，靠 `rotation = <180>` 修正）。细节见
[docs/camera-probe.md](docs/camera-probe.md)。

还没解决的是：**内置麦/耳麦**（`hw:0,2` EIO、`hw:0,3` 全零，ADSP 侧采集图那条）
和耳机插孔的自动切换。

**视频硬解**：DTB 里点名的 `qcvss8380.mbn` 之前是缺的（`selftest.sh` 现在会直接
报出来），用 `sudo scripts/install-video-firmware.sh` 从 Windows 驱动包或
linux-firmware 的 Lenovo 分支装上即可。装上后**内核不会有任何日志**（成功时
不打印），判断标准是 `/dev/video0`（解码）+ `/dev/video1`（编码）出现。

**怎么用**：iris 在这台机器的内核里是**有状态**（stateful）M2M 解码器，所以
普通那套就能用，一行命令、不用编译：

```bash
ffmpeg -c:v h264_v4l2m2m -i in.mp4 -f null -          # 或 hevc_v4l2m2m / vp9_v4l2m2m
mpv --hwdec=v4l2m2m-copy in.mp4
gst-launch-1.0 filesrc location=in.mp4 ! qtdemux ! h264parse ! v4l2h264dec ! autovideosink
scripts/verify-hwdecode.sh                            # 逐帧比对硬解/软解，确认不是黑帧
```

（之前文档里写的"只有 Chromium 能用、得走无状态 v4l2request"是错的 —— 那是
建立在"iris 是无状态解码器"这个错误前提上。误判过程与证据见
[docs/video-decode.md](docs/video-decode.md)。）
Windows 侧采回来的硬件信息分析见
[docs/windows-hardware-findings.md](docs/windows-hardware-findings.md)
（摄像头 sensor = `OV02C10`，内置麦 = 4 麦阵列）。

详细排查记录见 [docs/audio-bringup.md](docs/audio-bringup.md)，
DTB 投递机制的完整分析见 [docs/dtb-delivery.md](docs/dtb-delivery.md)。
