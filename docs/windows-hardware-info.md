# 回 Windows 采集硬件信息 —— 操作手册

给 ASUS Vivobook S 15（X1E80100）在 Linux 侧继续 bring-up 用。目标是把
**Linux 侧看不到、只能在 Windows/固件里拿到**的信息一次采全。

（下文统一用工作目录 `C:\qcom-info\`，随便换个名字也行。）

> **2026-10-04 更新**：第一轮已经采回来了（`qcom-info.zip`），分析结果见
> [windows-hardware-findings.md](windows-hardware-findings.md)。结论：摄像头 sensor
> 是 `OV02C10`、内置麦是 4 麦阵列、缺的 `qcvss8380.mbn` 找到了；**但 ACPI 只拿到
> 15 张小表，没有 DSDT/SSDT**，音频的 `acdb_cal.acdb` 也没取。第二轮只要补这几样，
> 见该文档 §5 和下面第 9 节。

---

## 0. 我们到底缺什么

| 子系统 | Linux 侧现状 | 需要从 Windows 拿到什么 |
| --- | --- | --- |
| **内置麦克风 / 耳麦** | 15 条可能通路（VA/TX macro 的 PDM、WCD9385 的 SWR 数字麦、WCD9385 模拟麦）全部采不到数据，路由与偏压都试过 | ① 麦克风阵列的 ACPI 设备（HID + `_DSD`）：供电/使能 GPIO、时钟、数据通道映射；② 音频驱动 INF 里对 DMIC 的描述；③ 任何 ACDB/校准文件 |
| **摄像头** | DTB 里 `camss`/`cci` 是 `disabled`，没有 sensor 节点 | sensor **型号**（OV02C10 / OV08X40 / HI556 …）、I²C 地址、供电/复位 GPIO/时钟 |
| **视频硬解** | 缺 `qcvss8380.mbn`（iris/VSS 固件） | 驱动包/固件分区里的 `*.mbn` 等 blob |
| **耳机 / 扬声器** | 已可用 | 不用采（顺手确认型号也行） |
| **WiFi** | 可用（仅挂起唤醒后失效） | 不用采 |

第 2 节（全局快照）和第 6 节（ACPI 表）覆盖了大半需求，3~5 节是针对性挖掘。
所有命令都在**管理员 PowerShell** 里执行（开始菜单搜 PowerShell → 右键"以管理员身份运行"）。

---

## 1. 准备

```powershell
New-Item -ItemType Directory -Force C:\qcom-info | Out-Null
New-Item -ItemType Directory -Force C:\qcom-info\raw | Out-Null
```

原则：**所有原始输出都存成文件**，不要只截图——纯文本我能直接解析。

---

## 2. 全局硬件快照（最有用，先做这个）

```powershell
# 2.1 注册表设备枚举：ACPI / PCI / USB / SoundWire 全都在里面，
#     含每个设备实例的 HardwareID / CompatibleID
reg export "HKLM\SYSTEM\CurrentControlSet\Enum" C:\qcom-info\raw\enum.reg /y

# 2.2 所有 PnP 设备的大表（CSV，便于筛选）
Get-CimInstance Win32_PnPEntity |
    Select-Object Name, PNPClass, PNPDeviceID, Manufacturer, Service, Status |
    Export-Csv C:\qcom-info\raw\pnp-entities.csv -NoTypeInformation -Encoding UTF8

# 2.3 所有第三方驱动包（INF 名称/版本/厂商）
pnputil /enum-drivers | Out-File C:\qcom-info\raw\pnputil-drivers.txt -Encoding UTF8

# 2.4 只列音频/摄像头相关的驱动包（更好读）
Get-WindowsDriver -Online -All |
    Where-Object { $_.ClassName -match 'Audio|Camera|Image|Media' } |
    Select-Object Driver, ClassName, ProviderName, Date, Version |
    Sort-Object ClassName |
    Format-Table -AutoSize | Out-File C:\qcom-info\raw\drivers-audio-camera.txt -Encoding UTF8
```

---

## 3. 摄像头：找出 sensor 型号

### 3.1 设备与硬件 ID

```powershell
Get-PnpDevice -PresentOnly |
    Where-Object { $_.Class -in @('Camera','Image','Media') -or $_.FriendlyName -match 'camera|webcam|imaging' } |
    ForEach-Object {
        $id  = $_.InstanceId
        $hw  = (Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_HardwareIds').Data
        $cid = (Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_CompatibleIds').Data
        $inf = (Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_DriverInfPath').Data
        "名称 : {0}`n  实例 : {1}`n  HWID : {2}`n  CID  : {3}`n  INF  : {4}`n" -f `
            $_.FriendlyName, $id, ($hw -join ', '), ($cid -join ', '), $inf
    } | Tee-Object C:\qcom-info\raw\camera-devices.txt
```

ACPI 设备的 HWID 形如 `ACPI\QCOMxxxx` 或 `ACPI\OVTI02C1` —— **这一行往往就是
sensor 型号的直接线索**（例如 `QCOM0C10` → OV02C10）。

### 3.2 在驱动包里搜 sensor 型号字符串

```powershell
$sr = "$env:windir\System32\DriverStore\FileRepository"
Get-ChildItem $sr -Recurse -Include *.inf,*.txt,*.xml -ErrorAction SilentlyContinue |
    Select-String -List -Pattern 'ov02c10|ov08x40|ovti|hi556|hi846|s5k|imx[0-9]|gc[0-9]{4}' |
    Select-Object Path, Line |
    Out-File C:\qcom-info\raw\camera-inf-hits.txt -Encoding UTF8
```

### 3.3 记录模板

```text
[摄像头]
设备名称                  ：
HWID / CID                ：
驱动 INF                  ：
sensor 型号（据 INF/字符串）：
其它（I²C 地址、供电、复位 GPIO，如有）：
```

---

## 4. 音频 / 麦克风

### 4.1 音频设备枚举

```powershell
Get-PnpDevice -PresentOnly |
    Where-Object { $_.Class -in @('AudioEndpoint','MEDIA','Media','SoftwareDevice') `
                   -or $_.FriendlyName -match 'audio|sound|mic|aqstic|qualcomm' } |
    Select-Object Status, Class, FriendlyName, InstanceId |
    Format-Table -AutoSize |
    Out-File C:\qcom-info\raw\audio-devices.txt -Encoding UTF8
```

### 4.2 找 Qualcomm 音频驱动 / codec / DMIC 相关字符串

```powershell
$sr = "$env:windir\System32\DriverStore\FileRepository"
Get-ChildItem $sr -Recurse -Include *.inf,*.txt,*.xml,*.json -ErrorAction SilentlyContinue |
    Select-String -List -Pattern 'wcd938|wcd939|wsa88|aqstic|lpass|dmic|micb|acdb|slimbus|soundwire' |
    Select-Object Path, Line |
    Out-File C:\qcom-info\raw\audio-inf-hits.txt -Encoding UTF8
```

### 4.3 找音频校准 / ACDB 类文件

```powershell
Get-ChildItem "$env:windir\System32\DriverStore" -Recurse -ErrorAction SilentlyContinue `
    -Include *.acdb,*.bin,*.mbn,*.json |
    Where-Object { $_.FullName -match 'audio|acdb|codec|adsp|qcom' } |
    Select-Object FullName, Length |
    Format-Table -AutoSize |
    Out-File C:\qcom-info\raw\audio-blobs.txt -Encoding UTF8
```

### 4.4 麦克风阵列的 ACPI 设备（关键）

```powershell
Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Enum\ACPI" | ForEach-Object {
    $hid = $_.PSChildName
    Get-ChildItem $_.PSPath | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath
        "$hid\$($_.PSChildName)`n   FriendlyName : $($p.FriendlyName)`n   DeviceDesc   : $($p.DeviceDesc)`n   Service      : $($p.Service)"
    }
} | Out-File C:\qcom-info\raw\acpi-devices.txt -Encoding UTF8
```

在 `acpi-devices.txt` 里重点找名字含 `mic` / `audio` / `codec` / `dmic` / `sensor`
的条目——那通常就是要补进 DTS 的设备，它的 `_DSD`（第 6 节）里往往写着供电/使能脚。

### 4.5 记录模板

```text
[音频/麦克风]
音频 codec（是不是 WCD9385）：
麦克风阵列 ACPI HID / 实例   ：
音频驱动 INF（名称 + 版本）  ：
DMIC / mic 相关字符串命中    ：
找到的 ACDB / 校准文件       ：
```

---

## 5. 固件 blob（视频硬解等）

```powershell
# 5.1 驱动仓库里所有 mbn/elf/bin/fw
Get-ChildItem "$env:windir\System32\DriverStore\FileRepository" -Recurse `
    -Include *.mbn,*.elf,*.bin,*.fw,*.zst -ErrorAction SilentlyContinue |
    Select-Object FullName, Length |
    Sort-Object FullName |
    Format-Table -AutoSize |
    Out-File C:\qcom-info\raw\firmware-blobs.txt -Encoding UTF8

# 5.2 直接找 Linux 侧缺的那几个
Get-ChildItem C:\ -Recurse -ErrorAction SilentlyContinue `
    -Include qcvss*,*vss8380*,qcdxkmsuc*,qcadsp*,qccdsp* |
    Select-Object FullName, Length |
    Out-File C:\qcom-info\raw\vss-search.txt -Encoding UTF8
```

如果搜不到 `qcvss8380.mbn`，再看两处：`MYASUS` / `RECOVERY` 分区，
以及 `C:\Windows\SoftwareDistribution\` 里的 Windows Update 缓存
（VSS 固件通常随显示驱动一起下发）。

### 记录模板

```text
[固件]
qcvss8380.mbn               ：找到 / 未找到（路径、大小）
其它 qcom 固件（名称+路径）  ：
```

---

## 6. ACPI 表（进阶，麦克风供电/GPIO 的关键）

Windows 下可以直接调 Win32 API 导出 ACPI 表：

```powershell
$dir = "C:\qcom-info\acpi"
New-Item -ItemType Directory -Force $dir | Out-Null

Add-Type -TypeDefinition @"
using System; using System.IO; using System.Text;
using System.Runtime.InteropServices;
public static class Fw {
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern uint EnumSystemFirmwareTables(uint provider, byte[] buf, uint size);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern uint GetSystemFirmwareTable(uint provider, uint id, byte[] buf, uint size);
  const uint ACPI = 0x41435049;
  public static void Dump(string dir) {
    byte[] sigs = new byte[EnumSystemFirmwareTables(ACPI, null, 0)];
    EnumSystemFirmwareTables(ACPI, sigs, (uint)sigs.Length);
    for (int i = 0; i + 4 <= sigs.Length; i += 4) {
      uint id = BitConverter.ToUInt32(sigs, i);
      uint size = GetSystemFirmwareTable(ACPI, id, null, 0);
      if (size == 0) continue;
      byte[] buf = new byte[size];
      GetSystemFirmwareTable(ACPI, id, buf, size);
      string name = Encoding.ASCII.GetString(sigs, i, 4);
      string path = Path.Combine(dir, name + "_" + i + ".bin");
      File.WriteAllBytes(path, buf);
      Console.WriteLine(name + "  " + size + " bytes -> " + path);
    }
  }
}
"@
[Fw]::Dump($dir)
```

已知限制：`GetSystemFirmwareTable` 对**同名表（多个 SSDT）只会返回第一个**，
所以 SSDT 可能拿不全。但 **DSDT 一定能拿到**，而音频/摄像头设备通常就写在
DSDT 里，够用；确实需要全部 SSDT 时可以用 ACPICA 官方的 Windows 版
`acpidump.exe` 再导一次。

导出的 `.bin` 我在 Linux 侧用 `iasl` / 脚本反编译，就能读出 `_DSD`、`_CRS`、
`GpioIo` 等，从而确定麦克风/摄像头的供电与使能引脚。

---

## 7. 把结果带回 Linux

两种方式都行（推荐 A，不用 U 盘）：

**A. 留在 Windows 分区**（`C:\qcom-info\`），Linux 只读挂载读出来：

```bash
# Windows OS 分区是 /dev/nvme0n1p14
sudo mkdir -p /mnt/win
sudo mount -o ro /dev/nvme0n1p14 /mnt/win
ls -R /mnt/win/qcom-info
```

**B. 复制到 Data 分区**（Windows 里的 `D:` → `/dev/nvme0n1p15`），Linux 同样
`mount -o ro` 读取。

---

## 8. 最少给我这三样

1. `C:\qcom-info\raw\camera-devices.txt`（摄像头 HWID / CID / INF）
2. `C:\qcom-info\raw\acpi-devices.txt` + `C:\qcom-info\acpi\DSDT_*.bin`
3. `C:\qcom-info\raw\audio-inf-hits.txt`（音频 / codec / DMIC 字符串命中）

如果能一并带回来 `enum.reg` 和 `pnp-entities.csv` 更好——那基本是一份完整硬件
清单，摄像头 sensor、麦克风阵列、视频固件都能从里面推出来。

拿到之后我会：用 `iasl` 反编译 DSDT，找音频 codec / mic-array / camera 三个设备
节点的 `_DSD`，对照现有 DTS 补 `dmic` / `camss` 的供电与 GPIO，再更新本仓库的
`dts/` 与 `ucm/`。

---

## 9. 第二轮：还差这些（2026-10-04 补）

第一轮已经把 `enum.reg`、设备清单、驱动包、`qcvss8380.mbn` 都带回来了（详见
[windows-hardware-findings.md](windows-hardware-findings.md)）。**还要跑一次**的只有：

```powershell
# 9.1 DSDT + 全部 SSDT（第一轮没成功，这次用 ACPICA 的 acpidump）
#     下载 acpica 的 windows binary 包，解压后在这个目录里执行：
New-Item -ItemType Directory -Force C:\qcom-info\acpi2 | Out-Null
cd C:\qcom-info\acpi2
acpidump.exe -b
Get-ChildItem | Select-Object Name, Length    # 要能看到 dsdt.dat / ssdt*.dat 且非 0 字节

# 9.2 音频驱动目录（含 acdb_cal.acdb）
$sr = "$env:windir\System32\DriverStore\FileRepository"
foreach ($w in 'qcacsp_crd8380.inf_*','qcadsprpc8380.inf_*','qcadsprpcd8380.inf_*',
               'qcsubsys_ext_adsp8380.inf_*','qcsubsys_ext_cdsp8380.inf_*') {
    Get-ChildItem "$sr\$w" -Directory -ErrorAction SilentlyContinue |
        Copy-Item -Destination C:\qcom-info\audio -Recurse -Force
}

# 9.3 sensor 配置目录（ov02c10_2.pb 等）
Get-ChildItem "$sr\qcsensorsconfigcrd8380.inf_*" -Directory -ErrorAction SilentlyContinue |
    Copy-Item -Destination C:\qcom-info\camconfig -Recurse -Force

# 9.4 打包（只打新的三块，别再把 900 MB 的显卡驱动带上）
Compress-Archive C:\qcom-info\acpi2,C:\qcom-info\audio,C:\qcom-info\camconfig `
                 C:\qcom-info\round2.zip -Force
```
