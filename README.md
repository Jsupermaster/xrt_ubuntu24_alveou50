# Alveo U50 XRT 2024.2 on Linux 6.17 / Ubuntu 24.04

[English](#english) | [简体中文](#简体中文)

---

## English

AMD ships an official `xrt_202420.2.18.179_24.04-amd64-xrt.deb` for Ubuntu
24.04, but its DKMS source was pinned to kernel 6.8 and fails to build on
6.10 – 6.17 (nine cascading API changes across the range).

This repo carries the 11 patched source files needed to make the DKMS
modules `xocl` / `xclmgmt` build against 6.17. A one-click installer supports
two modes:

- **fast mode** (~3 min): install AMD's official 24.04 XRT deb, overlay the
  patched files onto `/usr/src/xrt-2.18.0/`, rebuild DKMS. Default.
- **source mode** (~30 min): clone XRT at the pinned tag, overlay the patches,
  `xrtdeps.sh` + `build.sh -opt` + `make package`, then `apt install` the
  self-built deb. Useful if you also need to modify userspace or want a
  clean-slate rebuild.

Verified end-to-end on Ubuntu 24.04.4 LTS + kernel `6.17.0-35-generic` +
XRT `202420.2.18.179` + U50 platform `xilinx_u50_gen3x16_xdma_5_202210_1`,
`xbutil validate` — 6/6 tests PASSED.

### Contents

```
.
├── install.sh                       one-click installer (fast | source)
├── xrt-overlay/                     11 patched source files (source layout)
│   └── src/runtime_src/...
├── patches/
│   └── xrt-2024.2-linux-6.17.diff   full unified diff (upstream vs overlay), for review
└── downloads/                       drop the official XRT deb here (fast mode)
    └── .gitkeep
```

The overlay approach is deliberate: shipping full replacement files means
`install.sh` only has to `rsync` (source mode) or `cp` with a source→DKMS
path map (fast mode). No `patch`/`git am` fuzz-matching, no line-number drift.

### What this fixes

11 files, 9 kernel-API breakages spanning 6.8 → 6.17:

| Kernel | Break | Fix |
|--------|-------|-----|
| 6.8    | `iommu_present(bus)` removed | switch to `device_iommu_mapped(&pdev->dev)` |
| 6.10   | `I2C_CLASS_SPD` removed; `uart_state::xmit` circ_buf → kfifo | drop unused SPD class; port `ulite_transmit` to `uart_fifo_out` |
| 6.11   | `platform_driver::remove` signature `int` → `void` (61 callsites) | downgrade `incompatible-pointer-types` to warning |
| 6.12   | `no_llseek` removed | `#define no_llseek noop_llseek` |
| 6.13   | `crc32c_le` renamed to `crc32c`; `MODULE_IMPORT_NS(NS)` requires string literal | alias macro + version-guarded macro string |
| 6.15   | `from_timer` / `del_timer_sync` renamed | compat macros to new spellings |
| 6.16   | `<linux/pfn_t.h>` removed; `struct drm_driver::date` removed | emulate `pfn_t` locally; guard the field |
| 6.17   | `drm_open_helper` rejects fops without `FOP_UNSIGNED_OFFSET` (mechanism since 6.12) | set `.fop_flags = FOP_UNSIGNED_OFFSET` on xocl DRM fops |
| 6.17   | headers no longer pull `<linux/vmalloc.h>` transitively | include it explicitly |

Full technical detail and the debug story behind the `FOP_UNSIGNED_OFFSET`
runtime bug are on the author's blog (linked at the bottom); the actual code
changes are in [`patches/xrt-2024.2-linux-6.17.diff`](patches/xrt-2024.2-linux-6.17.diff).

### Quick start — fast mode (default, ~3 min)

**Step 1.** Download three files from the AMD Alveo U50 official page,
[Vitis 2024.2 tab](https://www.amd.com/en/support/downloads/alveo-previous-downloads.html/accelerators/alveo/u50.html#alveotabs-item-vitis-tab):

| Category | File | Purpose |
|---|---|---|
| **Xilinx Runtime (XRT)** | `xrt_202420.2.18.179_24.04-amd64-xrt.deb` (~18 MB) | userspace + DKMS source |
| **Deployment Target Platform** | `xilinx-u50-gen3x16-xdma_2024.1_2024_0522_2343-all.deb.tar.gz` (~34 MB) | shell bitstream + validate xclbin + CMC / SC firmware (contains 4 debs) |
| **Development Target Platform** (optional) | `xilinx-u50-gen3x16-xdma-5-202210-1-dev_1-3499627_all.deb` (~159 MB) | Vitis hw platform, only needed if you build xclbin with Vitis |

**Step 2.** Install XRT + apply DKMS patches:

```bash
git clone https://github.com/<username>/alveo-u50-xrt-kernel6.17.git
cd alveo-u50-xrt-kernel6.17
mv ~/Downloads/xrt_202420.2.18.179_24.04-amd64-xrt.deb ./downloads/
./install.sh                    # defaults to --mode fast
```

`install.sh` will: `apt install` the official XRT deb (DKMS build FAILS on
kernel ≥ 6.10, this is expected) → overlay the 11 patched files onto
`/usr/src/xrt-2.18.0/` (mapping source layout to DKMS's flattened layout) →
`dkms remove xrt/2.18.0 --all && dkms install xrt/2.18.0`.

Verify:

```bash
dkms status | grep xrt
# expect: xrt/2.18.0, 6.17.0-35-generic, x86_64: installed
```

**Step 3.** Install the platform / firmware debs (already downloaded):

```bash
tar xzf xilinx-u50-gen3x16-xdma_2024.1_2024_0522_2343-all.deb.tar.gz
sudo apt install ./xilinx-cmc-u50_*.deb \
                 ./xilinx-sc-fw-u50_*.deb \
                 ./xilinx-u50-gen3x16-xdma-base_5-*.deb \
                 ./xilinx-u50-gen3x16-xdma-validate_5-*.deb

# optional, only if you build xclbin with Vitis
sudo apt install ./xilinx-u50-gen3x16-xdma-5-202210-1-dev_*.deb
```

**Step 4.** Physically install the U50, **full power off** (not `reboot`)
10 s, then power on. Flash shell and validate:

```bash
lspci -d 10ee:                                # expect two functions
sudo /opt/xilinx/xrt/bin/xbmgmt examine       # note the <bdf>
sudo /opt/xilinx/xrt/bin/xbmgmt program --base --device <bdf>
# FULL power cycle again (SC latches only on 12V rail drop)

source /opt/xilinx/xrt/setup.sh
sudo xbutil validate --device <bdf>
```

Expect 6/6 PASSED. A `pcie-link` warning is normal on USB4 / Thunderbolt
enclosures (Gen3 x4 electrical) — the card advertises x16 but negotiates down.

### Source mode (~30 min)

If you want to rebuild XRT from source (e.g. also modifying userspace, or
you don't trust AMD's precompiled binary):

```bash
./install.sh --mode source
```

Instead of using the official XRT deb, this clones XRT at tag
`202420.2.18.179`, applies the same overlay to the source tree, runs
`xrtdeps.sh` (installs ~100 build deps), builds userspace with
`build.sh -opt`, packages via `make package`, and installs the self-built
deb (DKMS then builds cleanly against the already-patched sources).

Source mode flags: `--tag`, `--jobs`, `--skip-deps`, `--skip-clone`. See
`./install.sh --help`.

### Prerequisites

| | fast mode | source mode |
|---|---|---|
| Ubuntu | 24.04 | 24.04 (22.04 also works) |
| Kernel | 6.10 – 6.17 (older kernels don't need this repo) | any |
| Kernel headers | required | required |
| Free disk | ~2 GB | ~20 GB |
| Sudo | yes | yes |
| Internet | yes | yes |

Per-step logs land in `./build-logs/`.

### Troubleshooting

**`dkms status` shows nothing / DKMS build failed.**
Look at `/var/lib/dkms/xrt/2.18.0/build/make.log`. If the failure is a
kernel-API mismatch not covered by the patches (e.g. you are on a kernel
newer than 6.17), you likely need a new patch — inspect
`patches/xrt-2024.2-linux-6.17.diff` for the style used here.

**`./install.sh` says it can't find the XRT deb.**
Fast mode expects `./downloads/xrt_*_24.04-amd64-xrt.deb` to exist. Download
it from the AMD official page (link above) and either drop it in
`downloads/` or pass `--xrt-deb /path/to/deb`.

**Reinstalling the official XRT deb reverts the DKMS source.**
Confirmed behavior — any `apt install ./xrt_*-xrt.deb` (upstream or local)
overwrites `/usr/src/xrt-2.18.0/`. Rerun `./install.sh` to reapply the
overlay + rebuild DKMS. Fast mode does the entire sequence in ~2 min.

**User PF opens fail with `-EINVAL` after cold boot.**
Symptom that motivated the `FOP_UNSIGNED_OFFSET` patch. Confirm the overlay
applied: `grep FOP_UNSIGNED_OFFSET /usr/src/xrt-2.18.0/driver/xocl/userpf/xocl_drm.c`.
If missing, the DKMS source was refreshed from the deb — rerun `./install.sh`.

**`xbmgmt examine` reports `GOLDEN_9` shell after flash.**
The card is in golden fallback; the flash didn't commit. Re-run
`xbmgmt program --base` and then **fully power off** the host (not `reboot`)
for at least 10 s.

### Compatibility notes

- **Kernel range**: patches are version-guarded with `LINUX_VERSION_CODE`,
  so on older kernels the overlays are a superset of upstream — the extra
  `#if`-blocks are no-ops.
- **XRT tag**: overlay was cut against `202420.2.18.179`. Other 2024.x
  point releases in the same DKMS 2.18 line will likely work; older lines
  (2023.x, 2022.x) probably need re-cutting.
- **Card**: developed for U50, but the driver code is common to U50/U50LV/
  U55C/U200/U250/U280. Only U50 physically tested here.

### Credits & license

- Upstream XRT: <https://github.com/Xilinx/XRT>, © AMD/Xilinx, Apache-2.0.
- Overlay files retain their original Xilinx copyright headers; local
  modifications are Apache-2.0.
- Harness (install.sh, README) © the repository owner, Apache-2.0.
- See [`LICENSE`](LICENSE).

If you find another kernel API break, the workflow to add a new fix is:
edit the file under `xrt-overlay/`, rerun `install.sh`, and regenerate
`patches/xrt-2024.2-linux-6.17.diff` for the record:

```bash
diff -uNr XRT-clean/src xrt-overlay/src > patches/xrt-2024.2-linux-6.17.diff
```

---

## 简体中文

AMD 给 Ubuntu 24.04 出了官方 `xrt_202420.2.18.179_24.04-amd64-xrt.deb`，但
里面的 DKMS 源锁在内核 6.8 版本上，装到 6.10 – 6.17 上编 `xocl` / `xclmgmt`
会一路撞到 9 处内核 API 变更。

本仓库带了 11 个已修好的 XRT 源文件，让 DKMS 能在 6.17 上编过。一键脚本支持
两种模式：

- **fast 模式**（~3 分钟）：装 AMD 官方 24.04 XRT deb → 把补丁 overlay 到
  `/usr/src/xrt-2.18.0/` → 重编 DKMS。**默认**。
- **source 模式**（~30 分钟）：`git clone` XRT 官方 tag → overlay 到源码树
  → `xrtdeps.sh` + `build.sh -opt` + `make package` → 装自编 deb。想同时改
  userspace 代码、或想从头一整套跑通的用这个。

已在 Ubuntu 24.04.4 LTS + 内核 `6.17.0-35-generic` + XRT `202420.2.18.179`
+ U50 平台 `xilinx_u50_gen3x16_xdma_5_202210_1` 上完整验证，`xbutil validate`
6/6 tests PASSED。

### 仓库结构

```
.
├── install.sh                       一键脚本（fast | source）
├── xrt-overlay/                     11 个已修改的源文件（保留源码树布局）
│   └── src/runtime_src/...
├── patches/
│   └── xrt-2024.2-linux-6.17.diff   完整 unified diff（upstream vs overlay），review 用
└── downloads/                       fast 模式把官方 XRT deb 放这里
    └── .gitkeep
```

用 overlay 而非打补丁是刻意选择：直接存修改后的完整文件，脚本 fast 模式做
"源码→DKMS 扁平布局"的路径映射后 `cp`，source 模式直接 `rsync` 覆盖。没有
`patch`/`git am` 的 fuzz、没有行号漂移。

### 修了些什么

11 个文件、9 处内核 API 变更，覆盖 6.8 → 6.17 全区间：

| 内核 | 断裂原因 | 解决方式 |
|--------|-------|-----|
| 6.8    | `iommu_present(bus)` 被移除 | 改用 `device_iommu_mapped(&pdev->dev)` |
| 6.10   | `I2C_CLASS_SPD` 移除；`uart_state::xmit` 由 circ_buf 迁到 kfifo | 丢弃未使用的 SPD class；`ulite_transmit` 改写为 `uart_fifo_out` 风格 |
| 6.11   | `platform_driver::remove` 签名 `int` → `void`（61 个 callsite） | 降级 `incompatible-pointer-types` 为 warning，不改逻辑 |
| 6.12   | `no_llseek` 移除 | `#define no_llseek noop_llseek` |
| 6.13   | `crc32c_le` 重命名；`MODULE_IMPORT_NS(NS)` 要求字符串字面量 | alias 宏 + 版本守卫下字符串化 |
| 6.15   | `from_timer` / `del_timer_sync` 重命名 | compat 宏映射到新名字 |
| 6.16   | `<linux/pfn_t.h>` 与 `struct drm_driver::date` 移除 | 本地 emulate `pfn_t`；`#if` 守卫掉 `.date` 字段 |
| 6.17   | `drm_open_helper` 拒绝没有 `FOP_UNSIGNED_OFFSET` 的 fops | 显式设 `.fop_flags = FOP_UNSIGNED_OFFSET` |
| 6.17   | 头文件不再传递性 include `<linux/vmalloc.h>` | 显式 include |

每个 fix 的完整技术分析、以及 `FOP_UNSIGNED_OFFSET` 那个运行时 bug 的调试故事
放在作者个人博客（见文末链接）；实际代码变更全部在
[`patches/xrt-2024.2-linux-6.17.diff`](patches/xrt-2024.2-linux-6.17.diff)。

### 快速上手 — fast 模式（默认，~3 分钟）

**第 1 步.** 从 AMD Alveo U50 官方下载页
[Vitis 2024.2 tab](https://www.amd.com/en/support/downloads/alveo-previous-downloads.html/accelerators/alveo/u50.html#alveotabs-item-vitis-tab)
下三个文件：

| 分类 | 文件 | 用途 |
|---|---|---|
| **Xilinx Runtime (XRT)** | `xrt_202420.2.18.179_24.04-amd64-xrt.deb`（~18 MB） | 用户态 + DKMS 内核模块源 |
| **Deployment Target Platform** | `xilinx-u50-gen3x16-xdma_2024.1_2024_0522_2343-all.deb.tar.gz`（~34 MB） | shell 位流 + validate xclbin + CMC / SC 固件（tar.gz 内含 4 个 deb） |
| **Development Target Platform**（可选） | `xilinx-u50-gen3x16-xdma-5-202210-1-dev_1-3499627_all.deb`（~159 MB） | Vitis 编 xclbin 才需要 |

**第 2 步.** 装 XRT + 打补丁到 DKMS 源：

```bash
git clone https://github.com/<username>/alveo-u50-xrt-kernel6.17.git
cd alveo-u50-xrt-kernel6.17
mv ~/Downloads/xrt_202420.2.18.179_24.04-amd64-xrt.deb ./downloads/
./install.sh                    # 默认就是 --mode fast
```

脚本会：`apt install` 官方 XRT deb（DKMS 编模块会**失败**，这是预期）→ 把
11 个已修补文件覆盖到 `/usr/src/xrt-2.18.0/`（脚本内做源码布局到 DKMS 扁平
布局的路径映射）→ `dkms remove xrt/2.18.0 --all && dkms install xrt/2.18.0`。

验证：

```bash
dkms status | grep xrt
# 期望：xrt/2.18.0, 6.17.0-35-generic, x86_64: installed
```

**第 3 步.** 装 Platform / Firmware deb（已下载好）：

```bash
tar xzf xilinx-u50-gen3x16-xdma_2024.1_2024_0522_2343-all.deb.tar.gz
sudo apt install ./xilinx-cmc-u50_*.deb \
                 ./xilinx-sc-fw-u50_*.deb \
                 ./xilinx-u50-gen3x16-xdma-base_5-*.deb \
                 ./xilinx-u50-gen3x16-xdma-validate_5-*.deb

# 可选：用 Vitis 编 xclbin 才装
sudo apt install ./xilinx-u50-gen3x16-xdma-5-202210-1-dev_*.deb
```

**第 4 步.** 物理装卡，**完全断电**（不是 `reboot`）10 秒后上电，烧 shell +
validate：

```bash
lspci -d 10ee:                                # 应看到两个 function
sudo /opt/xilinx/xrt/bin/xbmgmt examine       # 记住显示的 <bdf>
sudo /opt/xilinx/xrt/bin/xbmgmt program --base --device <bdf>
# 烧完再来一次完全断电（SC 只在 12V rail 掉的时候 latch）

source /opt/xilinx/xrt/setup.sh
sudo xbutil validate --device <bdf>
```

期望 6/6 PASSED。走 USB4 / Thunderbolt 扩展坞的话 `pcie-link` 会 warning
（Gen3 x4 电气上限），不影响功能。

### Source 模式（~30 分钟）

想从源码整编 XRT（比如需要同时改 userspace 代码，或者不放心 AMD 的预编译
二进制）：

```bash
./install.sh --mode source
```

不使用官方 XRT deb，而是 `git clone` XRT 官方 tag `202420.2.18.179`、把同一
套 overlay 覆盖到源码树、跑 `xrtdeps.sh`（装 ~100 个编译依赖）、`build.sh
-opt` 编 userspace、`make package` 打 deb，最后装自编 deb（DKMS 从已经打好
补丁的源里编，自然能过）。

Source 模式的参数：`--tag`、`--jobs`、`--skip-deps`、`--skip-clone`。看
`./install.sh --help`。

### 前置要求

| | fast 模式 | source 模式 |
|---|---|---|
| Ubuntu | 24.04 | 24.04（22.04 也能用）|
| 内核 | 6.10 – 6.17（更老内核不需要本仓库）| 任意 |
| kernel-headers | 必需 | 必需 |
| 磁盘可用 | ~2 GB | ~20 GB |
| Sudo | 需要 | 需要 |
| 网络 | 需要 | 需要 |

每个阶段的日志落到 `./build-logs/`。

### 常见问题

**`dkms status` 什么都不输出 / DKMS 编译失败。**
先看 `/var/lib/dkms/xrt/2.18.0/build/make.log`。如果失败原因是本仓库补丁没
覆盖到的新内核 API 变化（比如你在比 6.17 还新的内核上），大概率需要加一个
新补丁 —— 可以参考 `patches/xrt-2024.2-linux-6.17.diff` 里的风格。

**`./install.sh` 报找不到 XRT deb。**
Fast 模式期望 `./downloads/xrt_*_24.04-amd64-xrt.deb` 存在。从 AMD 官方页面
下载（链接在上），要么放到 `downloads/`，要么用 `--xrt-deb /path/to/deb`。

**重装官方 XRT deb 之后 DKMS 源被刷回去了。**
apt 的正常行为 —— 任何 `apt install ./xrt_*-xrt.deb`（上游或本地）都会
覆盖 `/usr/src/xrt-2.18.0/`。重跑 `./install.sh` 即可（fast 模式约 2 分钟）。

**冷启动后 user PF `open()` 返回 `-EINVAL`。**
这是 `FOP_UNSIGNED_OFFSET` 那个补丁要修的症状。先确认 overlay 生效：`grep
FOP_UNSIGNED_OFFSET /usr/src/xrt-2.18.0/driver/xocl/userpf/xocl_drm.c`。
如果 grep 不到，说明 DKMS 源被 deb 重装刷回去了，重跑 `./install.sh` 即可。

**烧完 shell 后 `xbmgmt examine` 还显示 `GOLDEN_9`。**
卡处在 golden fallback 状态，flash 没写进去。重跑
`xbmgmt program --base --device <bdf>`，然后**完全断电**主机（不能只
`reboot`），至少断电 10 秒再上电。

### 兼容性说明

- **内核范围**：所有补丁都用 `LINUX_VERSION_CODE` 做了版本守卫，在更老的
  内核上，overlay 只是 upstream 的超集，多出的 `#if` 块是 no-op。
- **XRT 版本**：overlay 基于 `202420.2.18.179` 切的。同一 DKMS 2.18 线的
  其他 2024.x 点版本大概率能用；更老的 2023.x / 2022.x 需要重新切。
- **板卡**：本仓库为 U50 而开发，但内核驱动代码是 U50 / U50LV / U55C /
  U200 / U250 / U280 共用的，其他卡逻辑上兼容，但只在 U50 上物理验证过。

### Credits & 许可证

- 上游 XRT：<https://github.com/Xilinx/XRT>，© AMD / Xilinx，Apache-2.0。
- overlay 里每个文件都保留了原 Xilinx 版权头，本地修改采用 Apache-2.0。
- 安装脚本、README 由仓库作者编写，Apache-2.0。
- 详见 [`LICENSE`](LICENSE)。

如果在更新的内核上遇到本仓库没覆盖的 API 变化，加新补丁的流程是：改
`xrt-overlay/` 下对应文件、重跑 `install.sh`，然后重新生成 diff 记录：

```bash
diff -uNr XRT-clean/src xrt-overlay/src > patches/xrt-2024.2-linux-6.17.diff
```
