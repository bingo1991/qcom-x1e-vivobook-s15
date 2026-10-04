# Windows 导出分析（qcom-info.zip）

对着 [windows-hardware-info.md](windows-hardware-info.md) 那套步骤，从 Windows 侧
采回来的那份 `qcom-info.zip`（152 个文件 / 918 MB 解压后）看完的结果。

采集时间：2026-10-04。机器：ASUS Vivobook S 15 `S5507QA/S5507QAD`，X1E80100。

---

## 0. 结论速览

| 问题 | 这次拿到了什么 | 结论 / 下一步 |
| --- | --- | --- |
| 视频硬解缺固件 | `qcvss8380.mbn`（Windows 驱动包里的原件，两个版本） | ✅ **已打通**：装上后 `qcom_iris` 绑定，`/dev/video0`（解码）+ `/dev/video1`（编码）出现 |
| 摄像头 sensor 型号 | `OV02C10`（`ov02c10_2.pb` / `qsh_camera_ov02c10_2.json`） | 有型号了；还差 I²C 地址 / 供电 / 复位 → 需要 DSDT |
| 内置麦克风 | 是 **4 麦阵列**（另一个低功耗端点走 2 麦）；codec 走 SoundWire，2 个 slave | 硬件确实存在且就是 DMIC；电源/GPIO 仍在 DSDT 里，**这轮没采到** |
| 耳机 / 扬声器 | 不用采（已可用） | — |
| WiFi | 不用采（已可用） | — |
| **ACPI 表** | 只有 15 张小表，**没有 DSDT / SSDT** | ⚠️ 这是本轮最大的缺口，见 §5 |

---

## 1. 这份导出里到底有什么

```
qcom-info/
  raw/enum.reg                 5.5 MB   HKLM\SYSTEM\CurrentControlSet\Enum 全量导出 ★
  raw/pnp-entities.csv          36 KB   所有 PnP 设备
  raw/acpi-devices.txt          24 KB   ACPI 设备（HID / DeviceDesc / Service）
  raw/camera-devices.txt         8 KB   摄像头设备及 HWID/CID/INF
  raw/audio-devices.txt         22 KB   音频设备
  raw/{audio,camera,firmware}-*.txt      INF 字符串命中、固件 blob 清单
  raw/qcdx8380.inf_arm64_8053adc44985505a/   ← 整个驱动目录（含 qcvss8380.mbn）
  raw/qcdx8380.inf_arm64_95e56db089b80d1a/   ← 上一代驱动目录
  acpi/*.bin                    15 个   APIC BGRT CSRT DBG2 FACP FPDT GTDT IORT MCFG
                                        MSDM PPTT SDEV SPCR TPM2 UEFI
```

没在里面的（下一轮要补的）：

- **`DSDT_*.bin` / `SSDT_*.bin`** —— 摄像头供电/GPIO、mic bias 都写在里面；
- 音频驱动目录（`qcadsprpc8380.inf_*`、`qcsubsys_ext_adsp8380.inf_*`）和
  `qcacsp_crd8380.inf_*`（`acdb_cal.acdb`，639 KB）——只在文本清单里被提到；
- `qcsensorsconfigcrd8380.inf_arm64_2bd5cab8544dcc9a/`（sensor 配置文件目录）。

顺带一提：`enum.reg` 是 UTF-16LE，Linux 侧读的时候先 `iconv -f UTF-16LE`（或者
`tr -d '\0'`），直接 `grep` 会一个字节都匹配不到。

---

## 2. 摄像头：sensor 是 `OV02C10`

证据（`enum.reg` 里的 FASTRPC 映射，同一个 sensor 配置被注册了两遍）：

```
"C:\WINDOWS\System32\DriverStore\...\qcsensorsconfigcrd8380.inf_arm64_2bd5cab8544dcc9a\ov02c10_2.pb"
      ->  "\vendor\lib64\camera\ov02c10_2.pb"
...\qsh_camera_ov02c10_2.json  ->  \vendor\etc\sensors\config\qsh_camera_ov02c10_2.json
```

同一目录里还有 `qsh_camera_ov08x_2/3.json`、`qsh_camera_imx688_2.json`——那是
CRD 参考板通用的 sensor 配置集，**不能**据此认为本机有多个 sensor；本机的
front sensor 设备（`QCOM0C06`，"Camera Front Sensor Device"）只对应一组。

ACPI 拓扑（`camera-devices.txt` + `acpi-devices.txt`）：

| HID | 设备 | 说明 |
| --- | --- | --- |
| `QCOM0C25` | Spectra 695 ISP Camera Device | 摄像头主设备（AVStream / 媒体设备挂这里） |
| `QCOM0C06` | Camera **Front** Sensor Device | 前置 sensor 通道 |
| `QCOM0C99` | Camera Auxiliary Sensor Device | 辅助通道（本机可能是空/未接） |
| `QCOM0C98` | Camera MipiCsi Device | CSI PHY |
| `QCOM0C32` | Camera Platform Device | `qcCameraPlatform`，带 `CAMP_*.bin` 表 |
| `QCOM0C33` | Camera JPEG Encoder | JPEG 硬件编码 |
| `QCOM0C27` | Camera Flash Device | 闪光灯（本机无线圈，仅驱动存在） |
| `QCOM0D06` | Camera Always On Sensing | 常开感知（Windows Studio Effects 用） |

注意这些都是 **Qualcomm 的 ACPI 设备**，没有 `OVTI...` 之类的 sensor 厂商 HID：
sensor 挂在 CCI I²C 上，由 Qualcomm 的相机子系统统一描述，所以 **I²C 地址、
供电、reset/pwdn GPIO 只能从 DSDT 的 `_CRS`/`_DSD` 里读**——见 §5。

可用的模板：Lenovo **Yoga Slim 7x（83ED）** 用的是同一颗 OV02C10，内核里已有
`x1e80100-lenovo-yoga-slim7x.dts`（`ov02c10` + `camss`/`cci`/`csiphy`）可以抄，
缺的只是"这个机型的地址和供电脚"。

---

## 3. 音频 / 麦克风

### 3.1 设备

（来自 `pnp-entities.csv`，`Service` 列就是 Windows 驱动名）

| InstanceId | 设备名 | Service |
| --- | --- | --- |
| `ADCM\VEN_QCOM&DEV_0CE6` | Qualcomm(R) Aqstic(TM) **ACX Audio Device** | `qcasd`（静态端点：麦克风阵列就挂在这里） |
| `AUCD\VEN_QCOM&DEV_0C29` | Aqstic(TM) **Audio Adapter Device** | `QCAUD`（拓扑端点，主通路） |
| `ADCM\VEN_QCOM&DEV_0CC1` | Aqstic(TM) | `qcaucd`（codec 侧，`CodecInitializationParameters` 在它下面） |
| `ADSP\VEN_QCOM&DEV_0C22` | Aqstic(TM) **Audio DSP and Calibration Manager** | `qcadcm` |
| `ADSP\VEN_QCOM&DEV_0C0F` | Qualcomm(R) **Slimbus** Device | `qcslimbus` |
| `ACPI\QCOM0C1B` | Audio DSP Subsystem Device | `qcsubsys`（ADSP remoteproc） |

音频端点本身叫 **"麦克风阵列 (Qualcomm(R) Aqstic(TM) ACX Static Endpoints Audio
Device)"**，是一个 `AudioEndpoint` 类设备——即 Windows 直接把阵列当**麦克风阵列**
暴露，而不是"单个麦克风"。

### 3.2 麦克风阵列参数（`enum.reg` → `...\Device Parameters\QCASD\MicArray1\Microphones`）

| 项 | 低功耗端点 (`ADCM 0CE6`) | 主端点 (`AUCD 0C29`) |
| --- | --- | --- |
| 麦数量 | `NumberOfMicrophones = 2` | `usNumberOfMicrophones = **4**` |
| 阵列类型 | `1`（线性阵列） | `1` |
| 通道 / 位深 / 采样率 | 2ch / 16bit / 48 kHz | **4ch** / 16bit / 48 kHz |
| 频带 | 100 Hz – 20 kHz | 100 Hz – 20 kHz |
| 麦位置（Y 轴, 0.5 mm 单位） | −45 / +45 | −30 / +108 / +30 / −30 |

结论：

- 本机**确实有 4 个数字麦**（沿机身前缘一字排开），不是"没有麦克风"；
- 48 kHz / 16 bit，和 Linux 侧试的采样率一致，所以采样率不是问题；
- 低功耗那条只用 2 个麦（唤醒词），主通路上是 4 个。

### 3.3 codec 初始化参数（`ADCM 0CC1` → `AUCD\CodecInitializationParameters`）

```
ExternalMicBiasNeeded = 0        ; 不需要外部偏压（codec 自己有）
IsMBHCReq             = 1        ; 需要耳麦检测（multibutton headset）
SwrSleep              = 1        ; SoundWire 可进睡眠
SlaveInfo: NumSlaveTypes = 2
   1: SlaveType 0, Interface 2 (=SoundWire), enabled
   2: SlaveType 1, Interface 2 (=SoundWire), enabled
GPIO: NoofGPIOs = 3  (UID 0, 1, 3)
```

两个 SoundWire slave 和本机 Linux 下枚举到的 `sdw:2:0:0217:010d:00:4`、
`sdw:3:0:0217:010d:00:3`（都是 WCD9380/9385）对得上，说明 **codec 侧拓扑没错**；
`ExternalMicBiasNeeded=0` 也解释了为什么 Linux 侧给 VA/TX macro 各种加偏压都没用
——偏压不是从那里来的。

### 3.4 和 Linux 侧现状的对照

| Linux 侧现象 | 现在的解释 |
| --- | --- |
| TX macro PDM（`tx-dmic01..67`）录到全 1 的常数 | 通路上没有真实数据在流——PDM 引脚没接（或没使能） |
| VA macro PDM 全 0 | 同上 |
| WCD9385 SWR 数字麦 / 模拟麦 → `pcm_read EIO` | 与 codec 侧参数无关（slave 拓扑是对的），更像是 ADSP 采集图（tplg）或供电没起来 |
| 试遍所有 mic bias 路由都无效 | 与 `ExternalMicBiasNeeded=0` 一致：本机不用外部偏压 |

仍缺的关键信息：**mic 的那路供电/时钟 enable GPIO**（DSDT 里），以及 ADSP 用的
`acdb_cal.acdb`（校准文件，这轮没取到）。

---

## 4. 视频硬解：`qcvss8380.mbn` 找到了

DTB 里 `video-codec@aa00000` 点名的就是它：

```
/proc/device-tree/soc@0/video-codec@aa00000/firmware-name
  = qcom/x1e80100/ASUSTeK/vivobook-s15/qcvss8380.mbn
```

导出里有两个版本（都来自本机 Windows 的 `DriverStore`）：

| 驱动包目录 | DriverVer | `qcdxkmsucpurwa.mbn` md5 | `qcvss8380.mbn` 大小 | md5 |
| --- | --- | --- | --- | --- |
| `..._8053adc44985505a` | 01/08/2026, 31.0.137.0 | `f9e759d8…` | 2 323 048 | `dee58ef0…` |
| `..._95e56db089b80d1a` | 02/25/2025, 31.0.96.0 | `60c13cf4…` | 2 314 856 | `ddbc99cc…` |

**哪一个是"本机的"**：拿本机已装的
`/lib/firmware/updates/qcom/x1e80100/ASUSTeK/vivobook-s15/qcdxkmsucpurwa.mbn`
（md5 `f9e759d8…`）去比，命中的是 **8053adc…** 那一代——也就是说这台机器现有的
ADSP/CDSP/GPU 固件本来就是从那个驱动包里取的，VSS 只差没一起拷过来。

另外：linux-firmware 里已经有**同 SoC** 的 VSS 固件，只是没有 ASUSTeK 分支：

```
/lib/firmware/qcom/x1e80100/LENOVO/21N1/qcvss8380.mbn.zst   (ThinkPad T14s gen6)
/lib/firmware/qcom/x1e80100/LENOVO/83ED/qcvss8380.mbn.zst   (Yoga Slim 7x)
```

（同一个驱动包里还有 `qcvss8380_pa.mbn`、`qcav1e8380.mbn`，但本机 DTB 没点名、
内核的 `qcom_iris` 模块里也没有对应的文件名，所以脚本默认不装这两个。）

**实测结果（2026-10-04 23:36）**：装上 8053adc 那份后
`sudo modprobe -r qcom_iris && sudo modprobe qcom_iris`，设备立刻绑定成功：

```
/sys/class/video4linux/video0 -> qcom-iris-decoder
/sys/class/video4linux/video1 -> qcom-iris-encoder
```

注意内核**成功时不打印任何 iris 日志**（`dmesg` 里看不到东西 ≠ 失败），判断
标准是 `/sys/class/video4linux/video*/name`。怎么真正用起来（GStreamer 的
`v4l2sl*` 无状态解码器 / `ffmpeg -hwaccel v4l2request`）见
[video-decode.md](video-decode.md)。

两个都可以拿来试。安装脚本默认优先用 Windows 原件（与本机固件同代），
也可以 `--from-lenovo` 用 linux-firmware 里的那份：

```bash
scripts/install-video-firmware.sh --list        # 有哪些可选（不用 root）
sudo scripts/install-video-firmware.sh          # 自动选同代的那份并安装
sudo modprobe -r qcom_iris && sudo modprobe qcom_iris
dmesg -T | tail -20                             # 不该再有 "firmware download failed"
```

一个值得注意的差别（万一第一份加载失败就换另一份试）：三份 blob 都是
Xtensa 的 ELF，但 **Windows 那份的 `p_vaddr`/入口是 0**，而 linux-firmware 的
两份是**绝对地址 `0xf500000`**。内核的 `qcom_mdt_load()` 是按 `p_paddr` 往
预留区里搬的，两种布局各自自洽，但和驱动传进来的基址对不对得上只能实测。

`scripts/selftest.sh` 现在会直接把 DTB 点名的 6 个固件逐个列出来，缺哪个一目了然
（见 §6）。

---

## 5. 下一轮还要采什么

按重要性排：

### 5.1 DSDT + 全部 SSDT（最重要）

上一位执行者给的 C# 快照在 Windows 上 **只拿到 15 张小表，DSDT/SSDT 两个大表都
没有**（`acpi/` 里连 `DSDT_*.bin` 文件都没生成）。这两个表正是摄像头供电/GPIO、
mic bias/时钟的来源，所以第二轮必须拿到。两条路：

```powershell
# A. 先按老脚本再跑一次，确认到底有没有生成
Get-ChildItem C:\qcom-info\acpi | Where-Object Name -match 'DSDT|SSDT' |
    Select-Object Name, Length
#    必须看到 DSDT_*.bin 且大小 ~100 KB-1.5 MB；0 字节或没有 = 没成功

# B. 更可靠：ACPICA 官方 Windows 版（acpidump.exe / acpixtract.exe）
#    下载 acpica 的 windows binary 包，然后：
mkdir C:\qcom-info\acpi2
cd C:\qcom-info\acpi2
acpidump.exe -b            # -b = 二进制，写出一堆 dsdt.dat / ssdt1.dat ...
Get-ChildItem | Select-Object Name, Length
```

把整个 `acpi2\` 目录一起打包回来即可。

### 5.2 音频那几个驱动目录（含 ACDB）

```powershell
$sr = "$env:windir\System32\DriverStore\FileRepository"
$want = 'qcacsp_crd8380.inf_*','qcadsprpc8380.inf_*','qcadsprpcd8380.inf_*',
        'qcsubsys_ext_adsp8380.inf_*','qcsubsys_ext_cdsp8380.inf_*'
foreach ($w in $want) {
    Get-ChildItem "$sr\$w" -Directory -ErrorAction SilentlyContinue |
        Copy-Item -Destination C:\qcom-info\audio -Recurse -Force
}
```

重点是 `acdb_cal.acdb`（639 714 B）——它是 ADSP 的音频校准库，里面按
"设备 / 采样率 / 通路"存着增益和拓扑，对麦克风那条 `pcm_read EIO` 是很重要的参考。

### 5.3 摄像头配置目录

```powershell
Copy-Item "$sr\qcsensorsconfigcrd8380.inf_*" C:\qcom-info\camconfig -Recurse -Force
```

要的是 `ov02c10_2.pb`（sensor 寄存器序列）和 `qsh_camera_ov02c10_2.json`
（分辨率/时钟配置）——写 DTS 时用得上，也是确认"本机就是这颗 sensor"的铁证。

### 5.4 顺手但有用

- 设备管理器 → 麦克风阵列 → 属性 → 详细信息：把 `DEVPKEY_Device_*` 全导一份；
- Windows 声音设置里录音条能动的截图（证明"Windows 下确实是这 4 个麦在工作"）；
- `powercfg /a`、BIOS 版本（`Get-CimInstance Win32_BIOS`）——以后比对固件版本用。

---

## 6. 这轮分析带来的仓库改动

| 文件 | 改动 |
| --- | --- |
| `scripts/install-video-firmware.sh` | 新脚本：从 Windows 导出 / linux-firmware 里挑出 `qcvss8380.mbn` 装到 DTB 点名的路径，带 `--list` / `--revert` |
| `scripts/selftest.sh` | 新增一节：把 DTB 里所有 `firmware-name` 逐个对 `/lib/firmware` 检查，缺了直接 FAIL |
| `docs/windows-hardware-findings.md` | 本文件 |
| `docs/windows-hardware-info.md` | 加了"第二轮采集清单"的指针 |

---

## 7. 复现本文所有结论

```bash
unzip -q ~/Workspace/qcom-info.zip -d /tmp/qc          # 只解文本部分是秒级
cd /tmp/qc/qcom-info/raw
iconv -f UTF-16LE -t UTF-8 enum.reg > enum.utf8        # ⚠ enum.reg 是 UTF-16LE

grep -n NumberOfMicrophones      enum.utf8             # 2 麦端点 / 4 麦端点
grep -n CodecInitializationParameters -A 20 enum.utf8  # SoundWire slave 拓扑
grep -n ov02c10                  enum.utf8             # camera sensor 型号
grep -n AcbdFilePath1            enum.utf8             # ACDB 路径

unzip -l ~/Workspace/qcom-info.zip | grep -E "qcvss|qcav1e"   # 两个驱动代次
scripts/install-video-firmware.sh --list                     # 本机该装哪一份
```

---

## 8. 第二轮（2026-10-05）：DSDT 与 sensor 配置

这轮拿回来了：`acpi2/dsdt.dat`（287 099 B）、`audio/.../acdb_cal.acdb`（639 714 B）、
`camconfig/.../qsh_camera_ov02c10_2.json`、相机设备属性、BIOS/powercfg。
**注意：里面没有 SSDT**（acpidump 只写出一张 DSDT；XSDT 里也没列出更多）。

### 8.1 摄像头：地址拿到了，引脚有两个来源且对不上

`qsh_camera_ov02c10_2.json`（Qualcomm 相机配置，Windows 侧真正用的那份）：

| 项 | 值 | 说明 |
| --- | --- | --- |
| 从地址 | `slave_config = 54` → **0x36** | 与 Zenbook A14 / Yoga Slim 7x 相同 ✓ |
| 总线 | `bus_type = 0`（I²C/CCI）、`bus_instance = 9` | 9 是 Qualcomm 自己的编号，待映射到 cci0/cci1 |
| 速率 | 400 kHz | CCI 总线可以设 400k |
| 供电轨 | `vana → /pmic/client/aoc_avdd`、`vio → /pmic/client/aoc_dovdd_crd`、`vdig → /pmic/client/aoc_dvdd` | 三条，都是 **AOC 域**的名字（AVDD/DOVDD/DVDD） |
| reset | `reset_pin = 22`，`is_chip_pin = 0` | ⚠️ 不是 TLMM 237（Zenbook/Yoga 的值） |
| dri | `dri_pin = 113`，`is_chip_pin = 1` | ⚠️ 也不是 Zenbook 的 gpio100 |
| aux / toggle_mclk | -1（未使用） | |
| 省电 | `aoc_power_save`（事件 832/833） | 摄像头电源归 AOC 管 |

DSDT（用 `iasl -d` 反编译，2026-10-05）里能看清 ACPI 侧的相机拓扑：

```
Device (CAMP)   _HID = QCOM0C32  _UID = 0x1B      // 相机平台
  _CRS: Memory32Fixed 0x0AC13000, 0x0AC19000(+0xC000),
                     0x0AC15000  = cci0,  0x0AC16000 = cci1      <- 两颗 CCI 都归它
        Interrupt 492 / 303 / 491   (= GSI，减 32 = hamoa.dtsi 里 cci0 460 / cci1 271 / 459)
        GpioIo Shared   PullUp   \_SB.GIO0 pin 0x63 = 99
        GpioIo Exclusive PullNone \_SB.GIO0 pin 0x6E = 110

Device (MPCS)   _HID = QCOM0C98                    // MipiCsi
  _CRS: 0x0ACE4000, 0x0ACE6000, 0x0ACE8000, 0x0ACEC000   <- 正好是 hamoa.dtsi 的
                                                             csiphy0/1/2/4 四个
        + 0x0ACF6000..8000 (CSID)

Device (CAMF)   _HID = QCOM0C06  _UID = 0x1A       // 前 sensor
  _DEP = { \_SB.MPCS }，_STA = 0x0F，**没有 _CRS**
```

也就是说：**两颗 CCI、四个 CSIPHY 的地址在 ACPI 里都有**，但 **sensor 自己的
_CRS 是空的** —— 地址/引脚全在 Windows 相机驱动的配置里。而配置里的 reset=22、
dri=113 **在整份 DSDT 里根本不存在**（`0x0016`/`0x0071` 各 0 处），说明那两个脚
不属于 ACPI 描述的域（AOC/PMIC 侧或固件自己管）。

**结论与不确定处**：地址 0x36 可靠；`\_SB.GIO0` = SoC 的 TLMM，`\_SB.PM01`
（`_HID = QCOM0C2D`，就是 round 1 里的 `qcpmgpio`）= PMIC GPIO。CAMP 声明的
TLMM 99/110 是相机域**仅有的两个** SoC GPIO（110 与 Zenbook 的
`cam_indicator_en` 同号），但 JSON 的 22/113 与它们对不上 —— **不能直接写进 DTS**；
这也是为什么当初没照抄 Zenbook 的 `reset-gpios = <&tlmm 237>`：本机不是那个脚。

### 8.2 音频/麦克风：DSDT 里没有额外的电源/使能描述

音频侧的 ASL 结构（`iasl -d` 之后一目了然）：

```
Device (ADSP)  _HID = QCOM0C1B
  Device (ADCM)  _HID = QCOM0CC1   (_ADR = 1, CHLD = {ADCM\QCOM0CC1, ADCM\QCOM0CE6})
    Device (AUCD)  _HID = QCOM0C29 (_ADR = 0, CHLD = {AUCD\QCOM0C29})
      _CRS: GpioIo Exclusive PullNone \_SB.GIO0 pin 0xBF = 191   <- WCD9385 reset
            GpioIo Exclusive PullNone \_SB.GIO0 pin 0xCC = 204
            GpioIo Exclusive PullNone \_SB.GIO0 pin 0x44 =  68
            GpioInt Edge ActiveBoth ExclusiveAndWake PullDown pin 0x1C0 = 448
            Interrupt 0x210 (528) / 0xBB (187) / 0xCA (202)
```

- **191 与我们的 DTS 完全一致**（`reset-gpios = <&tlmm 191>`）—— ACPI 反过来验证了
  我们的 DTS 值是对的；204 / 68 是本机另外两个 codec 侧 GPIO
- 那个 **GpioInt / pin 448 / ExclusiveAndWake** 是 Windows 侧给 codec 留的中断/
  唤醒线。**它不需要搬到 Linux**：内核的 wcd938x MBHC 走 codec 自己的 SoundWire
  中断，Zenbook A14 的 codec 节点同样没有额外 `interrupts` 属性（只有 reset-gpios
  和 mbhc 阈值），我们 DTS 里的 mbhc 阈值也与它一致。所以插孔自动切换那条的障碍
  仍然在 UCM 的 JackControl 上，不是缺中断
- 整段里**没有任何"麦克风电源/使能"**：既没有 DMIC 专用 GPIO，也没有 `aoc_*` /
  `vana` / `vdig` 之类供电描述（整份 DSDT 都搜不到）
- 所以麦克风剩下的还是 **ADSP 侧那套**（采集图 / PDM 时钟 / tplg），而不是某个
  缺失的 GPIO —— 新的输入只有 `acdb_cal.acdb`

顺带：`acdb_cal.acdb` 是分块二进制（文件头 `ACDB`，块名 `HEAD` / `CLIVers_1` /
`GKVT` …，设备与通路都用数字 ID 引用，没有任何可读的 `DMIC`/`SPKR` 字样），要看它
得用 Qualcomm 的 ACDB/QACT 工具或逆向格式，暂时放一边。

### 8.3 下一步

1. `sudo apt install acpica-tools && iasl -d acpi2/dsdt.dat`，然后按设备把
   `_CRS`/`_DSD`/`PowerResource` 读出来（确认 99/110 属于谁、GIO0/PM01 是什么），
   再动摄像头的 DTS；
2. `acdb_cal.acdb` 是 Qualcomm 的二进制校准库（`strings` 出来全是乱码，没有可读
   通路名），要看它得用 QACT/ACDB 工具或逆格式，先放一边；
3. 麦克风的下一步仍是把 VA 那条 PDM 路径的时钟/采集图弄对（`hw:0,3` 现在能开、
   全零），tplg 已验证换不了（见 [audio-bringup.md](audio-bringup.md)）。
