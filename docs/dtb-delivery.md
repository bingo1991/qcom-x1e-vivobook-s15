# 设备树是怎么送到内核的（以及为什么常规套路都无效）

这份笔记解释 Ubuntu `linux-qcom-x1e` 内核上 DTB 的投递机制，以及在这台
ASUS Vivobook S 15 上实测踩到的坑。排查日期 2026-10-04，内核
`7.3.0-15-qcom-x1e`。

## 结论速览

| 常见做法 | 在这台机器上是否有效 |
| --- | --- |
| 替换 `/usr/lib/firmware/<kver>/device-tree/qcom/*.dtb` | 无效，没有任何东西读它 |
| 在 `/boot/dtb-*` 放 DTB，靠 `10_linux` 生成 `devicetree` 行 | 无效，EFI stub 不用 GRUB 传的 DTB |
| `sudo grub-reboot "<菜单项>"` | 无效，本机 GRUB 里没有 `next_entry`，等于空操作 |
| 手选 GRUB 菜单项 | 能启动，但 DTB 仍然由 stub 自己选 |
| 替换 `vmlinuz` 里对应机型的 `.dtbauto` 段 | 有效 |

> 早期那套 `/boot/dtb-*` + GRUB `devicetree` 做法的残留可以用
> `sudo scripts/cleanup-legacy-grub.sh` 清掉（同时会清掉多余的 vmlinuz 备份，
> 只保留最旧的原厂镜像）。清理不影响音频——DTB 仍然是 `vmlinuz` 里
> `.dtbauto` 段提供的那份。

## 机制：stubble + `.dtbauto` + `.hwids`

`debian.qcom-x1e/rules.d/arm64.mk` 指定：

```
build_image = vmlinuz.efi
kernel_file = arch/arm64/boot/vmlinuz.efi
```

`debian/rules.d/2-binary-arch.mk` 用 stubble 把 DTB 打进镜像：

```
STUBBLEDTBS = $(shell /usr/libexec/stubble/finddtbs.py .../dts /usr/share/stubble/hwids \
               | sed 's|.*|--devicetree-auto=&|' | tr '\n' ' ')
```

于是 `vmlinuz` 变成一个 PE 镜像，结构大致是：

```
.text .rodata .data .reloc .osrel
.dtbauto x 41        <- 每个机型一个 DTB，各自独立 PE 段
.hwids               <- 硬件 ID 到 DTB 的映射表
.linux               <- zstd 压缩的内核 Image
.uname .sbat ...
```

开机时 EFI stub 读 SMBIOS（`chid_match` / `smbios_get_string`），按 `.hwids`
选出一个 `.dtbauto` 段再交给内核。stub 里的日志字符串有
`%s:%i@%s: selecting device-tree %s based on model`、
`found device-tree based on HWID: %s`，以及一个 `dtb_override` 机制。

## 实测证据

- `/boot/dtb-*` 不存在；`/etc/grub.d/10_linux` 只在存在
  `/boot/dtb-<kver>` 时才生成 `devicetree` 行。
- `grep -c next_entry`（对 `grubaa64.efi` 和 `/boot/grub/arm64-efi/*.mod`）
  结果为 `0`：本机 GRUB 根本没有这个变量。
- `file /boot/vmlinuz-7.3.0-15-qcom-x1e` 报
  `PE32+ executable for EFI (application), ARM64`，不是裸 Image。
- `objdump -h` 显示 41 个 `.dtbauto` 段。
- 其中 idx=28（文件偏移 `0x460e00`）的内容与内核包里那份
  `x1e80100-asus-vivobook-s15.dtb` sha256 完全一致，其 `__symbols__` 也与当时
  活动的 `/proc/device-tree/__symbols__`（724 个符号）一一对应——证明正在使
  用的设备树就是镜像里这一段。

## 为什么整段替换是安全的

- 段的文件偏移/大小在替换前后不变（余量用 0 填充），其余 40 个机型的段和内核
  本体一个字节都没动；`scripts/patch-vmlinuz-dtb.py` 在写入前会校验新 DTB
  是否塞得下，并保留一份 `/var/backups/x1e/vmlinuz-<kver>.orig-<时间戳>` 备份。
  **备份不能放 `/boot`**：GRUB 的 `10_linux` 用 `/boot/vmlinuz-*` 通配符枚举内核，
  放那里的备份会被当成"另一个内核"生成菜单项，而它找不到配套的
  `initrd.img-...orig-...`，启动就会 panic
  （`VFS: Unable to mount root fs on unknown-block(0,0)`）。
- `.hwids` 映射不变，所以选中逻辑不受影响。
- DTB 需要去掉 `dtc -@`（不再生成 `__symbols__`）才能塞进固定大小的段：
  225 KB 降到 172 KB；运行期并不需要 `__symbols__`。
- Secure Boot 关闭时 GRUB 不校验镜像签名；本机 `SecureBoot=0`。

## 相关内核代码位置（便于跟进上游变化）

- `scripts/Makefile.dtbs`：内核自己的 cpp + dtc 调用方式，本仓库的
  `scripts/build-dtb.sh` 复刻了它。
- `drivers/firmware/efi/libstub/zboot.c`：`vmlinuz.efi` 的入口。
- `sound/soc/qcom/qdsp6/topology.c` 的 `audioreach_tplg_init()`：
  拓扑文件名 = `qcom/<card->driver_name>/<card->name>-tplg.bin`。这也是为什么
  DTB 里 `sound` 节点的 `model` 必须写成 `X1E80100-ASUS-Vivobook-S15`——
  linux-firmware 里正好有这个软链名。
