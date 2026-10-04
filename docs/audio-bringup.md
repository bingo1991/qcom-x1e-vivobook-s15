# Vivobook S15 (X1E80100) 声卡调试记录

## 现状（已核实）

| 检查项 | 结果 |
|---|---|
| ADSP/CDSP remoteproc | running（`qcom/x1e80100/ASUSTeK/vivobook-s15/qcadsp8380.mbn`） |
| 内核模块 | `snd-soc-x1e80100.ko` 存在但**未加载**，`snd_soc_lpass_*_macro`、`snd_q6apm`、`q6prm` 已加载 |
| `/dev/snd`、`/proc/asound/cards` | 不存在 / 空 |
| 活跃 device tree | 根节点**没有** `sound` 子节点 |
| 机型 DTB | `x1e80100-asus-vivobook-s15.dtb` 里 `qcom,x1e80100-sndcard` 出现 0 次（Zenbook A14 / XPS13 各 1 次） |
| 固件 | 本机 ADSP 固件、`X1E80100-ASUS-Vivobook-S15-tplg.bin` 均在（后者是指向 Romulus tplg 的软链） |

结论：**不是驱动缺失，是 device tree 没有描述这台机器的声卡**。机器驱动
`snd-soc-x1e80100` 靠 `compatible = "qcom,x1e80100-sndcard"` 匹配，DT 里没有该节点
就永远不会 probe。

## 本次改动

新增 `arch/arm64/boot/dts/qcom/x1-asus-vivobook-s15-audio.dtsi`，并在
`x1e80100-asus-vivobook-s15.dts` 里 include 它。内容照抄同厂的
`x1-asus-zenbook-a14.dtsi`（ASUS 同代 X1 参考设计）：

- `wcd938x`（WCD9385 耳机/耳麦 codec）+ `swr1`(RX) / `swr2`(TX)
- `left_spkr` / `right_spkr`（WSA8845，SoundWire `swr0`）
- `sound` 节点：VA Capture / WCD Capture / WCD Playback / WSA Playback 四条 dai-link
- 补上 PM8550 的 `vreg_l1b_1p8`（DMIC micbias）与 `vreg_l12b_1p2`（WSA vdd-io）

### 仍是假设、需要实测确认的点

1. WCD9385 复位脚 = TLMM gpio 191（hamoa EVK 与 Zenbook A14 都用它）
2. DMIC 麦克风偏压 = PM8550 LDO1，WSA vdd-io = PM8550 LDO12
3. 扬声器是 **2 颗** WSA8845（左右各一）。若实机是 4 颗（woofer+tweeter），
   SoundWire 总线上会多枚举出 2 个从设备，日志里能看到。
4. `qcom,port-mapping` 沿用 Zenbook 的值，声道可能需要对调。

## 编译

本机没有 flex/bison，但 `linux-headers` 包里有现成的 `dtc`，所以只编 DTB：

```bash
cd ~/Workspace
./build-dtb.sh
# 产物: build/x1e80100-asus-vivobook-s15.dtb
```

已实测构建通过（与源码树内核同版本、同编译参数）：

- `out/x1e80100-asus-vivobook-s15.dtb`，224577 字节（原厂 220981）——完整版
- `out/x1e80100-asus-vivobook-s15-wsa-only.dtb`，222772 字节——只留 WSA 扬声器
  （`CPPFLAGS_EXTRA=-DX1E_AUDIO_WSA_ONLY` 编出）
- dtc 无新增告警；相比原 DTB 只多出 9 个 label：
  `wcd938x / wcd_rx / wcd_tx / wcd_default / left_spkr / right_spkr /
  spkr_01_sd_n_active / vreg_l1b_1p8 / vreg_l12b_1p2`
- 校验：`sound` 节点存在，`swr0/1/2` 为 `okay`，speaker/codec 的 phandle 全部解析成功

### 建议的测试顺序

1. 先装 **wsa-only**（只有 VA Capture + WSA Playback 两条 dai-link，swr1/swr2 保持
   disabled）。它不依赖对 WCD9385 的任何猜测，是最可能一次成功的版本。
2. 扬声器出声后，再装完整版验证耳机/耳麦（WCD9385）。
3. 每次启动后按下面「症状 -> 下一步」表判断。

```bash
sudo scripts/legacy/deploy-dtb.sh build/x1e80100-asus-vivobook-s15-wsa-only.dtb
sudo grub-reboot "Ubuntu X1E - custom DTB (x1e80100-asus-vivobook-s15-wsa-only)"
sudo reboot
```

## 部署 / 启动

### 真正的机制（重要，前面几版都白试了）

Ubuntu 的 qcom-x1e 内核镜像是用 **stubble** 打包的：kernel 在 `.linux` 段，
41 个机型的 DTB 分别放在 41 个 `.dtbauto` 段里，另有 `.hwids` 段存
硬件 ID → DTB 的映射。开机时 **EFI stub 按 .hwids 自动挑 DTB**，所以：

- `/usr/lib/firmware/<kver>/device-tree/**` 那份 DTB 只是个副本，改它没用；
- GRUB 的 `devicetree` 行同样不参与（stubble 用的是自己内嵌的 DTB）；
- 想换 DTB，只能把 `vmlinuz` 里对应的 `.dtbauto` 段换掉。

证据：本机 `vmlinuz-7.3.0-15-qcom-x1e` 是 PE 镜像，含 41 个 `.dtbauto` 段；
其中 idx=28（文件偏移 `0x460e00`，原始大小 221184）的 DTB 与内核包里那份
`x1e80100-asus-vivobook-s15.dtb` **sha256 完全一致**，其 `__symbols__` 与
当前活动 DT 的 724 个符号一一对应 —— 也就是说现在跑的 DT 就是这一段。

### 用 patch-vmlinuz-dtb.py 替换镜像里的 DTB

段大小固定 221184 字节，所以替换用的 DTB 必须塞得下。去掉 `dtc -@`
（不再生成 `__symbols__`）后从 ~225 kB 缩到 ~172 kB，绰绰有余：

```bash
# 1) 编译"无符号"版本（运行期不需要 __symbols__）
cd ~/Workspace
DTC_SYMBOLS=0 CPPFLAGS_EXTRA=-DX1E_AUDIO_WSA_ONLY \
  OUT=$PWD/out/x1e80100-asus-vivobook-s15-wsa-only-nosym.dtb ./build-dtb.sh

# 2) 先看要改哪一段
sudo ./patch-vmlinuz-dtb.py --check

# 3) 打补丁（自动备份 vmlinuz，交互确认；加 --yes 免确认）
sudo ./patch-vmlinuz-dtb.py \
     --dtb build/x1e80100-asus-vivobook-s15-wsa.dtb

# 4) 重启
sudo reboot
```

回滚：

```bash
sudo scripts/patch-vmlinuz-dtb.py --restore --yes
sudo reboot
```

注意：**内核升级会重装 vmlinuz，补丁随之失效**，升级后要重跑第 3 步。

下面是早期基于 `/boot/dtb-*` 的做法，现在知道它不起作用，保留仅作记录。

注意：当前活跃的 device tree 是**固件/引导器提供**的（`/boot/dtb-*` 不存在，
grub.cfg 里没有 devicetree 行），所以内核包里那份 DTB 其实没被用。要让新
DTB 生效，必须让 GRUB 显式加载它——脚本会生成一个独立菜单项：

```bash
sudo scripts/legacy/deploy-dtb.sh build/x1e80100-asus-vivobook-s15-wsa-only.dtb
sudo reboot            # 或加 --reboot 让脚本自己重启
```

脚本做两件事：把 DTB 放到 `/boot/dtb/qcom/<名字>.dtb` 并生成一个独立菜单项，
**同时**复制一份到 `/boot/dtb-$(uname -r)`——后者的存在会让 `10_linux` 给
**每一个**生成的启动项都加上 `devicetree`，所以默认项也能自动用上，不需要选菜单。

### 坑：这台机器上 `grub-reboot` 是空操作

`grub-reboot "标题"` 靠 GRUB 的 `next_entry` 变量实现，而本机安装的 GRUB
（`grubaa64.efi` + `/boot/grub/arm64-efi/*.mod`，GRUB 2.14-2ubuntu2.1）里
**完全没有 `next_entry`**（`saved_entry` 同样没有）。所以它写完变量后 GRUB
启动时根本不读，直接走默认项——第一次重启就是这样，DTB 没生效。菜单默认还是
隐藏的（`GRUB_TIMEOUT_STYLE=hidden`），所以也别指望手动选。

结论：走 `/boot/dtb-$(uname -r)` 这条自动路径，或开机时按住 ESC 调出菜单手选。

回滚（任选）：

```bash
sudo rm -f /boot/dtb-$(uname -r) /etc/grub.d/36_x1e_custom_dtb_*
sudo update-grub && sudo reboot
```

开机时在 GRUB 里按 `e`，删掉 `devicetree` 那一行再 Ctrl-X 也能临时救回来。

## 启动后怎么判断走到哪一步

```bash
# 0) 一键自检（推荐，所有检查都自动跑一遍）
scripts/selftest.sh
# 想让每次开机自动跑一遍：sudo scripts/selftest.sh --install
#   -> 报告写在 /var/log/x1e-selftest.log，也可 journalctl -u x1e-selftest

# 1) 声卡是否注册
cat /proc/asound/cards
aplay -l

# 2) 各组件 probe 情况
dmesg | grep -iE 'x1e80100-sndcard|snd-soc-x1e80100|wsa884|wcd938|q6apm|swr|soundwire'
ls /sys/bus/soundwire/devices/          # 期望看到 slave 0x0217:0204:00 等
cat /sys/kernel/debug/soundwire/*/status 2>/dev/null

# 3) 播放
sudo alsamixer                          # 打开 SpkrLeft/SpkrRight 的 PA/数字音量
speaker-test -c2 -twav -l1
```

### 症状 -> 下一步

| 症状 | 含义 | 处理 |
|---|---|---|
| 完全没有 `sound` 节点相关日志 | GRUB 没加载我们的 DTB | 确认菜单项选对，`cat /proc/device-tree/sound` 应存在 |
| `x1e80100-sndcard: probe deferred` 卡住 | 某个 codec 没 probe | 先删 `wcd-*-dai-link` + `wcd938x` 节点重编，只留 WSA，再逐个加回 |
| WSA 有 probe 但没有 slave | 功放供电/复位不对 | 检查 gpio 191 / lpass gpio12 / LDO12 电压，看 `dmesg` 里的 `sdw` 报错 |
| 有 card 但没声音 | routing / 音量 / port-mapping | `alsamixer -c0`，必要时空拍 `qcom,port-mapping` |
| `swr0` 上有 4 个从设备 | 实机是 4 喇叭 | 改成 EVK 式布局（woofer+tweeter，`swr0`+`swr3`） |

## 自检脚本覆盖的检查项

`x1e-selftest.sh` 按顺序检查：环境/`cmdline` → DT 里有没有 `sound` 节点、
有没有我们加的 `left_spkr` 等 label → ADSP/CDSP remoteproc → 音频相关模块是否加载
→ SoundWire 上枚举到几个从设备 → ALSA 声卡和 `SpkrLeft/Right` 控件 → 内核日志
（**只取本次启动**）里的音频报错 → 缺失固件 → APM/GPR 音频服务超时 → ath12k WiFi
状态（含挂起唤醒后的 WMI 超时判定）→ 汇总 PASS/FAIL/WARN 和下一步建议。

退出码：`0` 全部正常 / `2` 有 FAIL / `3` 只有 WARN。

### 首次运行已发现的两个额外问题

- `qcom/x1e80100/ASUSTeK/vivobook-s15/qcvss8380.mbn` **真的缺文件**，所以
  `qcom-iris`（硬件视频解码）初始化失败。Windows 提取的固件包里没有这个 blob，
  需要另外补（不影响音频）。
- `qcom-apm gprsvc:service:2:1: CMD timeout for [1001021] opcode`：ADSP 的音频
  服务有命令超时。即使 DT 补对了，声卡也可能"注册成功但没声音"，需要单独盯。

## 麦克风（内置 DMIC）——2026-10-04 追加

扬声器跑通后，把 VA/DMIC 录音通路也接上：

- DTB 里本来就有 VA macro，`audio-routing` 已写好
  `"VA DMIC0", "MIC BIAS1"` / `"VA DMIC1", "MIC BIAS1"`（照抄 Zenbook A14），
  以及 `vdd-micb-supply = <&vreg_l1b_1p8>`。
- UCM profile 新增 `SectionDevice."Mic"`（DMIC0 + DMIC1，`CapturePCM hw:0,3`
  = MultiMedia4），并在 Verb 的 EnableSequence 里加
  `cset "name='MultiMedia4 Mixer VA_CODEC_DMA_TX_0' 1"`。
- 手工验证（等价于 UCM 动作，绕开 WirePlumber）：`scripts/test-mic.sh`，
  设好控件后录 5 秒并回放，录音过程中有电平条可看有没有信号。

待验证：`vreg_l1b_1p8`（DMIC 偏压）在排查时状态是 `unknown`——这属于正常，
DMIC DAPM 上电时才会打开。若录到的全是静音，第一优先怀疑这条偏压轨道选错。

### 追加：静音的真正原因 = DMIC 偏压路由指错了

录音无信号，并且 `vreg_l1b_1p8` 的 sysfs `state` 始终是 `unknown`
（= 从来没有被 enable 过）。根因在 `audio-routing`：

照抄 Zenbook A14 写的那两行 `"VA DMIC0" -> "MIC BIAS1"` /
`"VA DMIC1" -> "VA MIC BIAS1"`，这两个 DAPM 控件**只存在于 WCD 编解码器**
（`sound/soc/codecs/wcd938x.c`）。wsa-only 设备树里没有 WCD9385，所以路由悬空，
VA macro 自带的 `SND_SOC_DAPM_REGULATOR_SUPPLY("vdd-micb")` 永远不上电
→ 麦克风没有偏压 → 录音全是静音。

对照组：同平台、同样没有 WCD 的 Lenovo Yoga Slim 7x 写的就是
`"VA DMIC0" -> "vdd-micb"`。已据此修正 `X1E_AUDIO_WSA_ONLY` 分支的路由，
`full` 变体保留 Zenbook 的写法（那时 WCD 控件确实存在）。

### 结论：麦克风尚未打通（2026-10-04 收尾）

#### 线索：SoundWire "Bus clash"（2026-10-04 深夜发现，可能是关键）

`scripts/selftest.sh` 在日志里翻出成片的：

```
qcom-soundwire 6b10000.soundwire: qcom_swrm_irq_handler: SWR bus clsh detected
wcd9380-codec sdw:3:0:0217:010d:00:3: Bus clash detected
wcd9380-codec sdw:3:0:0217:010d:00:3: Reached MAX_RETRY on alert read
```

出现时间点（21:42 / 22:18 / 22:21 / 22:25 / 22:28）都紧挨着
**音频路径被拆掉**的时刻（播放结束、切 Speaker/Headphones profile）。
`6b10000.soundwire` 是 WSA（扬声器）那条 SoundWire 主控，
而报 clash 的从设备是 **WCD9385 的 TX**（`sdw:3:...00:3`，swr2 上）。

推测：LPASS 掉电/时钟切换时总线出现竞争，把 **WCD9385 TX 从设备卡住**。
这能解释为什么所有走 codec 侧的采集候选（`swr-dmic*`、`swr-adc*`，
以及耳麦的 `--path adc`）都报 `pcm_read: 输入/输出错误`——
TX 从设备已经不在正常工作状态了。

**下一步（很便宜）**：重启后**先不要放任何声音、也不要切 profile**，
直接跑

```bash
scripts/test-mic.sh --path adc     # 耳麦
scripts/mic-scan.sh                # 15 条通路（现在会自动跳过前 0.6s 冲击）
```

如果这时能采到数据，就说明麦克风本身没问题，是"播放/切 profile 之后总线被搞坏"，
那就要去查 LPASS 掉电时序 / UCM 的 disable 序列 / SoundWire 主控的 clash 处理。

#### 干净复测结果：**bus clash 不是原因**（2026-10-04 22:46）

重启后（`boot_id` 从 `69fed061…` 变为 `69ca8fe5…`，uptime 2 分钟，
全程没有播放、没有切 profile），`scripts/mic-scan.sh` 的结果与有 clash 时**完全一致**：

```
va-dmic01..67   rms=0      （纯零）
tx-dmic01..67   rms=1      （只剩量化底噪）
swr-dmic01..67  打不开: arecord: pcm_read:2285: 读取错误：输入/输出错误
swr-adc1..3     打不开: 同上
```

也就是说 SoundWire bus clash **不是**（至少不是唯一）原因，这条线索可以划掉。

#### 更值得注意的观察：`hw:0,2` 这条 PCM 本身就坏

所有失败的候选都走 **`hw:0,2`（MultiMedia3 = `TX_CODEC_DMA_TX_3`，即 WCD capture）**，
而同一个 codec 的**播放**走 **`hw:0,0`（MultiMedia1）是正常的**。换哪个麦克风源
（codec 数字麦 SWR_DMICn / codec 模拟麦 ADCn）都是同一个 `pcm_read` EIO。

这更像 **ADSP 侧的采集图有问题**（tplg / 端口映射 / BE 链路），而不是"麦克风没供电"。
下一步可以做的最便宜检查（不需要重启、不需要改 DTB）：

```bash
# 不做任何 mixer 设置，直接打开这条采集 PCM
arecord -D hw:0,2 -f S16_LE -r 48000 -c 2 -d 2 /tmp/x.wav ; echo "rc=$?"
```

- 如果**同样 EIO** → 确认是 PCM/BE 链路问题：值得去看 Romulus tplg 里
  `TX_CODEC_DMA_TX_3` 的采集图，以及我们 DTB 里
  `qcom,tx-port-mapping = <2 2 3 4>`（抄自 Zenbook A14）是否与本机一致；
- 如果**能打开**（哪怕全是零）→ 说明是麦克风源/偏压问题，回到"需要 Windows 硬件信息"。

#### 实测：`hw:0,2` 连"裸开"都 EIO

```console
$ arecord -D hw:0,2 -f S16_LE -r 48000 -c 2 -d 2 /tmp/x.wav
正在录音 WAVE '/tmp/x.wav' : ... Stereo
arecord: pcm_read:2285: 读取错误：输入/输出错误
rc=1
```

不做任何 mixer 设置、不选任何麦克风源，这条采集 PCM 依然读不到数据，而且
内核日志里**没有任何对应报错**（静默失败）。所以问题就在 ADSP 的采集链路本身，
与麦克风硬件/偏压无关。

#### 新方向：tplg 可能是"占位符"

`/lib/firmware/qcom/x1e80100/*tplg.bin` 全都极小（941–1610 字节）。它们是**控件
骨架**（UCM 里那些 `... Audio Mixer MultiMedia...` 名字就来自这里），ADSP 侧的
图另行提供。

**2026-10-05 更正**：当时写的"每机型内容都不同"是错的 —— `--list` 那条链一看就
清楚，`X1E80100-*` 那一堆名字绝大多数只是**别名**，真正不同的叶子文件只有 5 个：

| 真实文件 | 大小 | 谁指向它 |
| --- | --- | --- |
| `X1E80100-Romulus-tplg.bin.zst` | 1610 B | **本机（Vivobook-S15）**、Vivobook-16、Zenbook-A14、HP-Omnibook-X14、Thinkpad-T14s |
| `X1E001DE-DEVKIT-tplg.bin.zst` | 1565 B | CRD、EVK、TUXEDO-Elite-14 |
| `LENOVO/83ED/…Yoga-Slim7x…` | 941 B | Yoga-Slim7x |
| `dell/inspiron-14-plus-7441/…` | 1383 B | Inspiron-14p、Latitude-7455 |
| `dell/xps13-9345/…` | 943 B | XPS-13-9345 |

也就是说"换一台机型的 tplg"绝大多数时候换了个名字而已；**真正没试过的只有两个
Dell 的**（`--list` 里能看到各自解出多少字符串）。

而本机用的这份是 **Ubuntu 打包时给的占位软链**：

```
X1E80100-ASUS-Vivobook-S15-tplg.bin.zst -> ASUSTeK/vivobook-s15/... -> ../../X1E80100-Romulus-tplg.bin.zst
```

既然每台机器都不一样，这个占位就可能与本机不匹配。**可尝试**（一次重启、可秒退）：

```bash
cd /lib/firmware/qcom/x1e80100
sudo cp -a ASUSTeK/vivobook-s15/X1E80100-ASUS-Vivobook-S15-tplg.bin.zst /tmp/tplg.bak   # 备份原软链
sudo ln -sf ../../X1E80100-EVK-tplg.bin.zst ASUSTeK/vivobook-s15/X1E80100-ASUS-Vivobook-S15-tplg.bin.zst
sudo reboot
```

重启后先跑那条裸 `arecord -D hw:0,2`：如果不再是 EIO，就说明是 tplg 不匹配。
回退：把备份拷回去再重启（或直接 `ln -sf ../../X1E80100-Romulus-tplg.bin.zst ...`）。

#### 实测结果：tplg **也排除**（2026-10-04 22:57）

软链切到 `X1E80100-EVK-tplg.bin.zst`（→ `X1E001DE-DEVKIT-tplg.bin.zst`）后重启
（`boot_id` 变更为 `00eede58…`，确认新链接已生效），`arecord -D hw:0,2` **依旧**
`pcm_read: 输入/输出错误`。所以换 tplg 解决不了。

回退用 `sudo scripts/try-tplg.sh --revert`（脚本会把原始软链备份到
`/var/backups/x1e-tplg-original` —— **不要用 `/tmp`，重启会被清空**，
没备份时脚本会自动恢复成原始的 Romulus 链接）。

**副产物（当时的观察）**：切到 EVK/DEVKIT 的 tplg 后，`audio-output.sh status`
里 Speaker profile 消失了（只剩 `Headphones` / `pro-audio`）。所以这个实验无论
成败都必须换回原始链接。

> 2026-10-05 补：现在直接比对两个 tplg 的字符串集合，Romulus 与 DEVKIT 的差别
> **只有 DisplayPort 那几条**（`DISPLAY_PORT_RX_2 Audio Mixer/Playback`，
> DEVKIT 没有），音频相关（WSA/WCD/VA、MultiMedia1..3）完全一致 —— 所以那次
> Speaker profile 消失的原因**未必是 tplg 本身**（可能是当时 UCM/ACP 的状态、
> 或是二进制图里的边）。这条老结论先降级为"待确认"。

#### 第二次尝试：换成 Yoga Slim 7x 的 tplg（2026-10-05）——也没用，而且更糟

换它的理由很足：内核源码里 Yoga Slim 7x 的内置麦就是 `VA DMIC0..3 -> vdd-micb`、
走 `VA_CODEC_DMA_TX_0`，跟 Windows 报的 4 麦阵列最接近；linux-firmware 里又正好有
`X1E80100-LENOVO-Yoga-Slim7x-tplg.bin.zst`。于是
`sudo scripts/try-tplg.sh Yoga-Slim7x` + 重启。

结果：

```
   0 [X1E80100ASUSViv]: x1e80100 - X1E80100-ASUS-Vivobook-S15
  hw:0,2 不存在！          <- 换 tplg 后 codec 采集那对前端 DAI 直接没了
  hw:0,3 存在
（预演：hw:0,3 打开失败）
   arecord: main:850: 音乐打开错误： 没有那个文件或目录     <- ENOENT，不是 EIO
```

同时会话音频栈塌了（与 EVK 那次同一个副作用）：`wpctl status` 里 Sink 变成
「虚拟输出」、**Sources 空**。原因还是那条：tplg 就是每机型一份的**控件骨架**，
UCM profile 里那些 `... Audio Mixer MultiMedia...` 名字对不上 → WirePlumber
放弃 profile → 只剩 dummy。

**结论：换 tplg 这条路到此为止。** 它确实能改变前端 DAI 的集合（这次直接把
hw:0,2 拿掉了），但是：

- 换来换去都是别的机型的骨架，本机 UCM 必然对不上（每次都得连 UCM 一起改）；
- 原来的问题（hw:0,2 EIO、VA 全零）一个都没解决；
- 麦克风真正缺的信息（供电/时钟/使能）不在这里，在 DSDT。

**换之前现在会先做检查**（`scripts/try-tplg.sh --check <名字>`，换的时候自动跑）：
它比对"当前 tplg 提供、候选没有"的字符串，看看 UCM profile 引用的控件还在不在。
拿 Yoga 那份跑，它会直接报：

```
  ❌ UCM 会打不开：下列控件是 UCM profile 要设的，当前 tplg 有、候选没有
       RX_CODEC_DMA_RX_0 Audio Mixer MultiMedia1
```

和实际现象完全对上（Headphones 那条 `cset` 就是它）——**以后不会再有"换完才发现
桌面变虚拟输出"这种事**；非要换就得 `--force`。

至于"下一个候选"：本来打算试 Zenbook A14，但 `--list` 一看它**只是 Romulus 的
别名**（和本机用的完全同一个文件），换了等于没换。真正没试过的只有两个 Dell 的
topology。而 Zenbook A14 这份 DTS 仍然有价值 —— 它的音频路由与本机几乎一致
（`VA DMIC0/1 -> MIC BIAS1`、`VA MIC BIAS1`、`AMIC2 -> MIC BIAS2`），而且有和
本机一样的四条 dai-link，**包括 Yoga 没有的那条 `WCD Capture =
TX_CODEC_DMA_TX_3`**，写 DTS/UCM 时继续以它为准。

（回退：`sudo scripts/try-tplg.sh --revert && sudo reboot`。）

#### 参数扫描：通道数 / 采样率也排除（2026-10-04 23:00）

```console
$ for c in 1 2 4; do for r in 16000 48000; do
    arecord -D hw:0,2 -f S16_LE -r $r -c $c -d 1 /tmp/x.wav >/dev/null 2>&1
    echo "ch=$c rate=$r rc=$?"; done; done
ch=1 rate=16000 rc=1    ch=1 rate=48000 rc=1
ch=2 rate=16000 rc=1    ch=2 rate=48000 rc=1
ch=4 rate=16000 rc=1    ch=4 rate=48000 rc=1
```

2 通道 48 kHz 本来就跟上游 UCM 一致，其它组合也一样失败，
所以不是参数/通道映射的问题。

### 麦克风结论（本地排查到此为止）

`hw:0,2`（MultiMedia3 / `TX_CODEC_DMA_TX_3`）**在任何配置下都读不到数据**，
内核日志无对应报错；而同一 codec 的播放（`hw:0,0`）完全正常。
本地能试的假设已全部排除（见上表：15 条采集通路、偏压、bus clash、tplg、
参数），剩下的只有两条外部路径：

1. Windows 侧硬件信息（`docs/windows-hardware-info.md`）：DSDT 里音频 codec /
   麦克风的 `_DSD`，能给出供电与使能脚；
2. 问上游 `linux-arm-msm` / qcom audio 维护者——ASUS 这台新机型他们多半没有
   实际数据，正好把上面的现象与排除清单提供一个完整案例。

换上完整版 DTB（含 WCD9385，已确认能注册、RX/TX 两个 SoundWire 从设备
`Attached`、`wcd938x_codec: bound ...`）后，用 `scripts/mic-scan.sh`
把 15 条可能的采集通路全试了一遍（每次录 2 秒，只统计跳过上电冲击后的
稳态 RMS）：

| 通路 | 结果 |
| --- | --- |
| LPASS VA macro 的 PDM 麦（`VA DMIC MUX0..3` = DMIC0..7） | rms=0，纯数字零 |
| LPASS TX macro 的 PDM 麦（`TX DEC0 MUX=MSM_DMIC` + `TX DMIC MUX0..7`） | rms=1（只剩量化底噪） |
| WCD9385 数字麦经 SoundWire（`TX DEC0 MUX=SWR_MIC` + `TX SMIC MUX0=SWR_DMIC0..7`） | `pcm_read: 输入/输出错误` |
| WCD9385 模拟麦（`TX SMIC MUX0=ADC0..3` + codec `ADCn` 通路） | 同上 |

期间还做了两次针对性修改，**都没有让麦克风出数据**：

1. `X1E_AUDIO_WSA_ONLY` 分支改成 `VA DMICx -> vdd-micb`（虽然确实让
   `vreg_l1b_1p8` 被上电又断电，但录音仍是全零）；
2. `full` 分支把 VA/TX 两个 macro 的 DMIC 输入挂到 `MIC BIAS1/2/3`
   和 `vdd-micb` 全部候选偏压上（一次重启覆盖所有组合）。

另外排除了一个假阳性：TX 通路最初在扫描里显示 rms≈2245，看起来像信号，
但波形分析显示是**上电冲击**——0.2s 起步、0.4s 内指数衰减到纯零，
0–0.5s 直流均值 -1790、1ms 自相关 0.99，不是语音。扫描脚本因此改成
只统计后段稳态（跳过前 0.6s）。

**下一步该做什么**（这些是脚本猜不出来的，需要硬件信息）：

1. 进 Windows 看「设备管理器 → 音频输入和输出」里内置麦克风阵列的
   硬件 ID / 驱动程序 INF——能确认麦克风是挂在 codec 还是 SoC 上；
2. 从 Windows 侧导出 ACPI 表（`acpidump`）或音频驱动的 INF，找麦克风的
   上电使能（GPIO / regulator）——Linux 这套 DTB 里没有任何"麦克风电源"
   描述，而"通路能跑、采不到数据"最像供电/时钟没给上；
3. 拿到信息后再补 DTS（电源/时钟/引脚）与 UCM 的 `Mic` 设备。

在此之前，**内置麦克风请用外接 USB 麦克风/摄像头麦替代**。

#### 2026-10-04 深夜：Windows 侧证据回来了（`enum.reg`）

见 [windows-hardware-findings.md](windows-hardware-findings.md) §3。要点：

- 内置麦是 **4 麦阵列**（`AUCD\...\TopologyMicArray1`：4ch / 48 kHz / 16 bit，
  4 个麦沿机身前缘一字排开；另有一个只带 2 麦的低功耗端点，唤醒词用）；
- codec 初始化参数里 `ExternalMicBiasNeeded = 0`，`NumSlaveTypes = 2`
  （两个 SoundWire slave，和本机 `sdw:2:...:4`、`sdw:3:...:3` 一致）
  —— 也就是说"给 PDM 加各种偏压"这条路本来就该是无效的；
- 所以现在的判断没有变：**缺的是 DSDT 里的使能/供电**（第一轮没采到 DSDT），
  以及 ADSP 的 `acdb_cal.acdb`。

## 耳机（WCD9385）——2026-10-04 打通

结论：**耳机可用**，左右声道都在硬件上验证过。它建立在"完整版 DTB
（含 WCD9385）"之上（`make build`，现在默认就是完整版），因为 wsa-only 变体里
根本没有 codec 节点。

打通过程（`scripts/test-headphone.sh` 是手工版，等价于 UCM 里的动作）：

```
FE->BE : cset "RX_CODEC_DMA_RX_0 Audio Mixer MultiMedia1" 1
RX macro: RX_HPH PWR Mode=LOHIFI, RX_MACRO RX0/RX1 MUX=AIF1_PB,
          RX INT0/1_1 MIX1 INP0=RX0/RX1, RX INT0/1 DEM MUX=CLSH_DSM_OUT,
          RX_COMP1/2 Switch=1
codec   : HPHL_RDAC/HPHL/HPHR_RDAC/HPHR/CLSH/LO Switch=1, HPHL/HPHR_COMP=0,
          RX HPH Mode=CLS_H_ULP, HPHL/HPHR Volume=20
播放    : hw:0,0（MultiMedia1 = WCD playback）
```

`HPHL/HPHR Volume` 是 `line_gain` 控件：量程 -30 dB … +6 dB、步进 1.5 dB
（`SOC_SINGLE_TLV(..., 0, 0x18, 1, line_gain)`，`DECLARE_TLV_DB_SCALE(line_gain,
-3000, 150, 0)`），所以 **索引 20 = 0 dB（单位增益）**，上游 T14s profile 用的就是
20。本仓库的 UCM 默认取 16（-6 dB），其余交给桌面软件音量。

### 过程中踩到的两个 UCM 坑（都已在仓库里规避）

1. **UCM2 不支持 C 风格注释**。`Value { /* ... */ }` 会让整份 profile 解析失败，
   WirePlumber 于是**静默退回通用 profile**：sink 名字从 `Speaker playback`
   变成 `立体声`／`虚拟输出`，端口全丢。判断依据很直接——
   `grep -rl '/\*' /usr/share/alsa/ucm2/` 当时只有我们这一个文件命中。
   `install-vivobook-ucm.sh` 现在带 lint，会直接拒绝安装含 `/*` 的 profile。
2. **Jack 控件名**：machine driver 用
   `snd_soc_card_jack_new_pins(card, "Headset Jack", ...)` 建 jack（名字是
   "Headset Jack"，同时生成一个 input 设备），但它下面的**两个 pin 会注册成
   CARD interface 控件**：

   ```
   numid=137,iface=CARD,name='Headphone Jack'
   numid=136,iface=CARD,name='Mic Jack'
   ```

   UCM 的 `JackControl` 要写这两个名字（上游 T14s profile 写的
   `"Headphone Jack"` 是对的）。注意 `amixer scontrols` **列不出**它们
   （那只列 simple mixer control），要用 `amixer -c0 controls | grep -i jack`。

### 最终 UCM 布局

| UCM verb | 设备 | PCM | Jack |
| --- | --- | --- | --- |
| `HiFi` | Speaker（2× WSA8845） | `hw:<card>,1` (MultiMedia2) | — |
| `Headphones` | Headphones（WCD9385） | `hw:<card>,0` (MultiMedia1) | —（见下） |

### 为什么是"一个输出一个 verb"（而不是同一 verb 下两个设备）

最初把两个设备放进同一个 `HiFi` verb，结果 ACP（WirePlumber 用的
alsa-card-profile）只暴露出一个 profile：

```
[0] off   [1] HiFi (Speaker)   [2] pro-audio     # 耳机设备被丢掉
```

试着去掉两者之间的 `ConflictingDevice` 想让它们变成同一 profile 的两个端口，
结果更糟——**整个 HiFi verb 都没了**（只剩 off/pro-audio，输出变成"虚拟输出"）。

原因：ACP 把多个 UCM 设备放进同一条 profile 的前提是它们**共用同一个 PCM**；
而扬声器是 `hw:0,1`、耳机是 `hw:0,0`，组合非法，于是该 verb 被整体丢弃。
所以改成**每个输出一个 verb**——ACP 是"一个 verb 一个 profile"，
`audio-output.sh`（或 pavucontrol 的"配置"标签）就能在两个 profile 之间切。

注意 GNOME 的"声音"面板同一时刻只显示当前生效的那个 sink（它没有 profile 切换
UI），手切用：

```bash
scripts/audio-output.sh status       # 列出 profile
scripts/audio-output.sh headphones
scripts/audio-output.sh speaker
```

实测（2026-10-04）：

```
card device 48 profiles:
  [0] off            (关)
  [1] HiFi           (Speaker playback)
  [2] Headphones     (Headphones playback)
  [3] pro-audio      (专业音频)

$ scripts/audio-output.sh headphones
switching card 48 to Headphones (profile 2)
$ wpctl status            # Sink 变成 "内置音频 Headphones playback"，切换生效
```

### 插孔自动切换：**测过，不可用**（2026-10-04）

给 `Headphones` 加上 `JackControl "Headphone Jack"` 并把优先级提到扬声器之上后，
**插拔耳机时 `wpctl status` 里的 sink 完全不变**（三次采样都是
`Speaker playback`）。原因：machine driver 把 jack 的两个 pin 注册成了
**CARD 接口**控件

```
numid=137,iface=CARD,name='Headphone Jack'
numid=136,iface=CARD,name='Mic Jack'
```

而 alsa-lib 的 UCM 在解析 `JackControl` 时按默认的 **MIXER** 接口查找，永远找不到
（卡上也没有 MIXER 风格的 jack 控件；jack 自身叫 "Headset Jack"，只作为 input
设备存在，例如 `/devices/.../input13`）。

所以上游那句 `JackControl "Headphone Jack"` 在这些机器上大概率也**从未生效**——
名字是对的，接口类型对不上。

可选的后续尝试（都没验证过）：

1. 打开 ACP 的自动端口切换——`api.acp.auto-port` / `api.acp.auto-profile`
   在 `wpctl inspect` 里当前都是 `false`，ACP 有可能用 **input 设备**做 jack 检测：

   ```ini
   # ~/.config/wireplumber/wireplumber.conf.d/51-x1e-jack.conf
   monitor.alsa.rules = [
     { matches = [ { device.name = "~alsa_card.*" } ]
       actions = { update-props = { api.acp.auto-port = true } } }
   ]
   ```

2. 上游层面让 ASoC 把这些 jack pin 也暴露成 MIXER 接口控件（需要改内核/框架，
   不是本地配置能解决的）。

## 摄像头（第二优先级）

**2026-10-04 更新**：sensor 型号已确认 = **OV02C10**（Windows 导出里
`qcsensorsconfigcrd8380.inf_*` 的 `ov02c10_2.pb` / `qsh_camera_ov02c10_2.json`，
与 Lenovo Yoga Slim 7x 同款，内核里已有 `ov02c10` 驱动和对应的 DTS 可以抄）。
还缺的是这颗 sensor 在本机上的 **I²C 地址 / 供电 / reset GPIO**——写在 ACPI
DSDT 里，第一轮导出没有带上。细节见
[windows-hardware-findings.md](windows-hardware-findings.md) §2。

## ✅ 最终状态（2026-10-04 12:02 起，扬声器已在桌面下可用）

| 环节 | 状态 |
|---|---|
| 设备树 | 自定义 DTB（wsa-only）经 `.dtbauto` 段替换后生效 |
| 声卡 | `card0 X1E80100-ASUS-Vivobook-S15` 注册成功 |
| 功放 | 2× WSA8845（`sdw20217020400`）Attached，驱动 `wsa884x-codec` |
| ALSA 直连 | `speaker-test -D hw:0,1 -c2` 出声（出现 pop + "Front Right" 测试音） |
| UCM | 专用 profile `ASUS-Vivobook-S15.conf`，`HiFi` verb 正常加载 |
| 桌面 | `wpctl` 里 Sink = `内置音频 Speaker playback`，`speaker-test` 走 default 出声 |

### 让桌面出声的关键三步

1. **把 DTB 塞进内核镜像的 `.dtbauto` 段**（stubble 机制，GRUB 的 devicetree 无效）：
   `sudo ./patch-vmlinuz-dtb.py --dtb out/x1e80100-asus-vivobook-s15-wsa-only-nosym.dtb`
2. **修 UCM 分派冲突**：原分派文件里 T14s 的正则也匹配 Vivobook，而 UCM 主配置
   只允许一个 `SectionUseCase."HiFi"`，两个 `If` 同时命中就报
   `compound type expected for the merged block` / `-22`。
   装 `ASUS-Vivobook-S15.conf` 并把 T14s 正则里的 `Vivobook S 15` 去掉：
   `sudo ./install-vivobook-ucm.sh`
3. **重启会话音频栈**：`systemctl --user restart wireplumber`

### 升级后会失效、需要重跑的两处

| 东西 | 什么时候丢 | 怎么恢复 |
|---|---|---|
| `vmlinuz` 里的 `.dtbauto` 段 | 内核包升级重装 vmlinuz | 重跑 `patch-vmlinuz-dtb.py` |
| `/usr/share/alsa/ucm2/.../x1e80100.conf` 等 | `alsa-ucm-conf` 升级 | 重跑 `install-vivobook-ucm.sh` |

### 已知的小瑕疵

- `alsaucm -c x1e80100 list _devices` 会报 `No such file or directory`，但不影响
  WirePlumber——设备确实存在（`wpctl` 里的 `Speaker playback` 就是它）。这是
  alsaucm 不带 verb 参数时的 CLI 行为。

## 早期状态（2026-10-04 11:35 那次启动，wsa-only DTB 生效）

| 检查项 | 结果 |
|---|---|
| `/proc/device-tree/sound` | 存在，`compatible = qcom,x1e80100-sndcard` |
| 扬声器节点 | `soundwire@6b10000/speaker@0,0`、`speaker@0,1`，compatible `sdw20217020400` |
| `snd_soc_x1e80100` | 已加载 |
| SoundWire | `sdw-master-1-0` + 2 个从设备，均 **Attached**，驱动 `wsa884x-codec` |
| ALSA | card0 `X1E80100-ASUS-Vivobook-S15`，有 `pcm0p/pcm1p/pcm2c/pcm3c` |
| => **实机确认是 2 颗 WSA8845**（假设 2 正确） |

PCM 与 UCM 的对应关系（来自 `/usr/share/alsa/ucm2/Qualcomm/x1e80100/T14s-HiFi.conf`）：

| PCM | 用途 |
|---|---|
| `hw:0,0` MultiMedia1 | 耳机 / DP-HDMI（需要 WCD9385，当前 wsa-only 没有） |
| `hw:0,1` MultiMedia2 | **扬声器**（`WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia2`） |
| `hw:0,2` MultiMedia3 | 耳麦录音（WCD9385 TX） |
| `hw:0,3` MultiMedia4 | 内置 DMIC（VA macro） |

UCM 分发是按 **DMI** 匹配的：本机 `board_vendor-product_family-board_name`
= `ASUSTeK COMPUTER INC.-ASUS Vivobook S 15-S5507QAD`，命中
`conf.d/x1e80100/x1e80100.conf` 里 `ASUS (Zenbook A14|Vivobook S 15)` 那条，
因此套用 `LENOVO-T14s.conf` → `T14s-HiFi.conf`（正好是 2 喇叭 + WCD9385 布局）。

已知的无害告警：

- `soundwire ...: no matching ACPI device found, ignoring peripheral`
  —— 纯 DT 启动路径的正常提示，功放实际已 Attached。
- `alsactl: unable to execute cset 'name='HPHL Volume' 20'`
  —— UCM 的 BootSequence 里带 WCD9385 的控件，wsa-only 版本没有，非致命。
  换上**完整版 DTB**（含 WCD9385）后这条会消失，并附带耳机/耳麦支持。

还没验证的一步：**实际出声**。需要在正常桌面会话里跑：

```bash
aplay -l               # 期望 card0 device1 = 扬声器
speaker-test -c2 -twav -l1
wpctl status
```

如果没声音，先看 `alsamixer -c0` 里 `SpkrLeft/SpkrRight PA Volume`，
或直接 `alsaucm -c x1e80100 set _verb HiFi set _enadev Speaker` 后再放。

没有 ACPI（`/sys/firmware/acpi` 不存在），ISP/CCI 在 DT 里是 `disabled`，
也没有 sensor 节点，所以目前完全无法 probe。缺的是**sensor 型号**。

可行的取证路径（需要在有 root 的会话里做）：

1. 只读挂载 Windows 分区 `/dev/nvme0n1p14`，在
   `Windows/System32/DriverStore/FileRepository/` 里找摄像头驱动 INF，
   里面会写明 sensor（如 `OV02C10` / `OV08X40` / `HI556`）。
2. 拿到型号后，对照 `x1e80100-lenovo-yoga-slim7x.dts`（OV02C10）补
   `camss`+`csiphy`+`cci`+sensor 节点，再编 DTB 验证。

在拿到型号之前不建议盲写摄像头节点。
