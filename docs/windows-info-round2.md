# 第二轮 Windows 采集操作指导

配合 [windows-hardware-info.md](windows-hardware-info.md)（第一轮通用手册）使用。
第一轮的产出与分析见 [windows-hardware-findings.md](windows-hardware-findings.md)：
**该拿的都拿到了，唯独 ACPI 只有 15 张小表**，缺的两样正好是现在卡住麦克风和
摄像头的东西。

这一轮目标很窄：**3 个目录 + 1 张表**，打包后几十 MB（第一轮那个 zip 里光显卡
驱动就 900 MB，这次不要带）。

| 要采的东西 | 用来解决 |
| --- | --- |
| **DSDT / SSDT**（ACPI 表的正文） | 摄像头的 I²C 地址 / reset GPIO / 三条供电、麦克风的 PDM 使能与供电、耳麦检测脚 |
| `acdb_cal.acdb` 所在驱动目录 | ADSP 的音频校准库，和麦克风采集图（`hw:0,3` 全零 / `hw:0,2` EIO）对照 |
| sensor 配置目录 | `ov02c10_2.pb`（寄存器序列）、`qsh_camera_ov02c10_2.json`（时钟/分辨率），写 DTS 时核对 |

全部命令都在**管理员 PowerShell**里跑。

```powershell
New-Item -ItemType Directory -Force C:\qcom-round2 | Out-Null
cd C:\qcom-round2
```

---

## 1. DSDT / SSDT（最重要，其它都能省这个不能省）

第一轮用的那段 C# 快照只拿到 15 张小表，`DSDT_*.bin` / `SSDT_*.bin` **没有生成**
（`C:\qcom-info\acpi\` 里只有 APIC/BGRT/CSRT/…/UEFI）。所以这次换工具：
ACPICA 官方的 Windows 版 `acpidump.exe`（在 acpica.org 的 "ACPICA tools -
Windows binaries" 包里，解压即可，不需要安装）。

```powershell
# 把 acpidump.exe 解压到 C:\qcom-round2\acpica\，然后：
New-Item -ItemType Directory -Force C:\qcom-round2\acpi2 | Out-Null
cd C:\qcom-round2\acpi2
C:\qcom-round2\acpica\acpidump.exe -b          # -b = 二进制，输出 *.dat
Get-ChildItem | Select-Object Name, Length | Sort-Object Name
```

**验一下再打包**（第一轮就是没验）：

```powershell
Get-ChildItem C:\qcom-round2\acpi2 |
    Where-Object Name -match '^(dsdt|ssdt)' |
    Select-Object Name, Length
```

期望：`dsdt.dat` 存在，大小约 **100 KB – 1.5 MB**（X1E 这种板子通常 500 KB 上下）；
`ssdt*.dat` 若干（0 字节的可以忽略）。如果 `dsdt.dat` 是 0 字节或压根没有，回退方案
（第一轮那张 C# 脚本仍然有效，只是这次要确认它真的写出了 DSDT）：

```powershell
# 回退：用 Win32 API 直接导（脚本见 windows-hardware-info.md 第 6 节），
# 跑完同样要检查 DSDT_*.bin 的大小
```

顺便把设备清单再导一份，方便和第一轮对照：

```powershell
Get-CimInstance Win32_PnPEntity |
    Select-Object Name, PNPClass, PNPDeviceID, Service, Status |
    Export-Csv C:\qcom-round2\pnp-entities.csv -NoTypeInformation -Encoding UTF8
```

---

## 2. 音频驱动目录（含 `acdb_cal.acdb`）

```powershell
$sr = "$env:windir\System32\DriverStore\FileRepository"
New-Item -ItemType Directory -Force C:\qcom-round2\audio | Out-Null

foreach ($w in 'qcacsp_crd8380.inf_*', 'qcadsprpc8380.inf_*', 'qcadsprpcd8380.inf_*',
               'qcsubsys_ext_adsp8380.inf_*', 'qcsubsys_ext_cdsp8380.inf_*') {
    Get-ChildItem "$sr\$w" -Directory -ErrorAction SilentlyContinue |
        Copy-Item -Destination C:\qcom-round2\audio -Recurse -Force
}

Get-ChildItem C:\qcom-round2\audio -Recurse -File |
    Where-Object { $_.Extension -in '.acdb', '.bin', '.mbn', '.json', '.xml', '.inf' } |
    Select-Object FullName, Length | Format-Table -AutoSize
```

重点：**`acdb_cal.acdb`（约 639 714 B）**。它是 ADSP 的音频校准库，里面按
"设备 / 采样率 / 通路"存着增益与拓扑——麦克风那条通路是死是活，这里可能有线索。

---

## 3. 摄像头：sensor 配置目录 + 相机驱动包

```powershell
New-Item -ItemType Directory -Force C:\qcom-round2\camconfig | Out-Null

Get-ChildItem "$sr\qcsensorsconfigcrd8380.inf_*" -Directory -ErrorAction SilentlyContinue |
    Copy-Item -Destination C:\qcom-round2\camconfig -Recurse -Force

foreach ($w in 'qccamfrontsensor_extension8380.inf_*', 'qccamplatform_ext8380.inf_*',
               'qccamjpege8380.inf_*') {
    Get-ChildItem "$sr\$w" -Directory -ErrorAction SilentlyContinue |
        Copy-Item -Destination C:\qcom-round2\camconfig -Recurse -Force
}
```

要的是 `ov02c10_2.pb` 和 `qsh_camera_ov02c10_2.json`。还有一个**免费的小动作**，
在设备管理器里点两下就行，能顺手确认 sensor 是挂在哪个 I²C 上：

```powershell
Get-PnpDevice -PresentOnly |
    Where-Object { $_.Class -in @('Camera','Image') } |
    ForEach-Object {
        $id = $_.InstanceId
        "名称: $($_.FriendlyName)"
        foreach ($k in 'DEVPKEY_Device_HardwareIds','DEVPKEY_Device_CompatibleIds',
                       'DEVPKEY_Device_DriverInfPath','DEVPKEY_Device_LocationPaths') {
            "  $k : $((Get-PnpDeviceProperty -InstanceId $id -KeyName $k -ErrorAction SilentlyContinue).Data)"
        }
    } | Tee-Object C:\qcom-round2\camera-devinfo.txt
```

---

## 4. 顺手但很有用的四样

```powershell
# 4.1 固件/BIOS 版本（以后比对用）
Get-CimInstance Win32_BIOS | Select-Object SMBIOSBIOSVersion, ReleaseDate |
    Out-File C:\qcom-round2\bios.txt

# 4.2 电源能力（摄像头/S0ix 相关）
powercfg /a | Out-File C:\qcom-round2\powercfg-a.txt

# 4.3 麦克风阵列端点属性（第一轮只有个数，这次把实例属性也带上）
Get-PnpDevice -PresentOnly |
    Where-Object { $_.Class -eq 'AudioEndpoint' -or $_.FriendlyName -match '麦克风|Microphone' } |
    Select-Object Status, Class, FriendlyName, InstanceId |
    Format-Table -AutoSize | Out-File C:\qcom-round2\audio-endpoints.txt

# 4.4 证明"在 Windows 下这套硬件真的在工作"（截个图就行，不用命令）
#     - 相机 App 能出画
#     - 设置 → 声音 → 输入，对着麦说话电平条会动
```

---

## 5. 打包

```powershell
Compress-Archive C:\qcom-round2\acpi2, C:\qcom-round2\audio,
                 C:\qcom-round2\camconfig, C:\qcom-round2\*.txt,
                 C:\qcom-round2\*.csv -DestinationPath C:\qcom-round2\round2.zip -Force
(Get-Item C:\qcom-round2\round2.zip).Length / 1MB    # 期望几十 MB
```

**不要**再带 `DriverStore` 下的显卡/音频整包（那是第一轮的 900 MB）。

---

## 6. 传回 Linux

```bash
# 方式 A：直接挂 Windows 分区读
sudo mkdir -p /mnt/win && sudo mount -o ro /dev/nvme0n1p14 /mnt/win
ls -l /mnt/win/qcom-round2/round2.zip

# 方式 B：拷到用户目录（zip 里的路径随便，我会自己解）
cp /mnt/win/qcom-round2/round2.zip ~/Workspace/
```

---

## 7. 拿到之后我会做什么

| 输入 | 动作 |
| --- | --- |
| DSDT/SSDT | `iasl` 反编译成 ASL，找 `QCOM0C06`（前 sensor）/ `QCOM0C25`（ISP）/ 音频那几个 HID 的 `_CRS`、`_DSD`、`GpioIo/GpioInt`、`PowerResource` —— 得到 I²C 地址、reset/pwdn 脚、三条供电轨，以及麦克风 PDM 的使能与偏压来源 |
| `acdb_cal.acdb` | 和 ADSP 侧的采集图对照（我们现在的 `hw:0,3` 全零、`hw:0,2` EIO 需要一个解释） |
| `ov02c10_2.pb` / `qsh_camera_*.json` | 核对 MCLK、lane 数、link frequency，和内核里那份 `ovti,ov02c10` 驱动对得上再写 DTS |
| 相机设备属性 | 交叉验证 sensor 挂在 `cci0` 还是 `cci1` 的哪条总线上 |

产出会直接写进 `dts/`（摄像头节点 + 麦克风电源/时钟）与 `docs/`。

---

## 8. 时间紧的话，最小集合

只采两个文件也够我往前推一大步：

1. `C:\qcom-round2\acpi2\dsdt.dat`（DSDT；有 SSDT 更好）
2. `C:\qcom-round2\audio\qcacsp_crd8380.inf_*`
   **`acdb_cal.acdb`**

其余（sensor 配置、相机 INFs、BIOS/电源）都属于"有更好，没有也能开工"。

---

## 9. 收到之后（2026-10-05 实际结果）

这一轮已经把 DSDT（287 KB，没有 SSDT）和 `acdb_cal.acdb` 拿回来了，分析写在
[windows-hardware-findings.md](windows-hardware-findings.md) §8。要点：

- **sensor 配置目录才是这次的宝藏**：`qsh_camera_ov02c10_2.json` 里有从地址
  （0x36）、总线、400 kHz、三条供电轨（AOC 域的 avdd/dovdd/dvdd）、reset/dri
  引脚号 —— ACPI 里反而没有（DSDT 搜不到 `aoc_*` 之类的字符串）
- DSDT 里能解出 GPIO 号，但和 JSON 的编号**对不上**（99/110 vs 22/113），需要用
  `iasl` 反编译看清归属与控制器（`\_SB.GIO0` / `\_SB.PM01`）
- 音频设备的 `_CRS` 只有 GPIO（其中 191 = WCD9385 复位脚，和我们的 DTS 一致），
  **没有麦克风专用的电源/使能** —— 所以麦克风的问题不在 GPIO 上
