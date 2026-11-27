<div align="center">

# App Download Binder

**Android Root 应用下载目录统一归类模块**

[![Android](https://img.shields.io/badge/Android-11%2B-3DDC84?logo=android&logoColor=white)](https://developer.android.com)
[![Root](https://img.shields.io/badge/Root-KernelSU%20%7C%20APatch%20%7C%20Magisk-orange)](https://kernelsu.org)
[![Version](https://img.shields.io/badge/Release-v3.2.0-blue)](https://github.com/beichen123-hub/app-download-binder/releases)
[![Offline](https://img.shields.io/badge/Network-Offline%20Only-brightgreen)](#特性)
[![License](https://img.shields.io/badge/License-GPL--3.0-lightgrey)](#开源协议与免责声明)

将分散在 `Android/data` 与公共存储各处的应用下载目录，通过底层 `mount --bind` 统一映射到 `/sdcard/Download/应用下载/<软件名>/`，**不复制文件、不占用双倍空间、纯本地零联网**。

作者：**KrisWu & Antigravity**

</div>

---

## 目录

- [简介](#简介)
- [特性](#特性)
- [效果示例](#效果示例)
- [实现原理](#实现原理)
- [安装指南](#安装指南)
- [配置与进阶使用](#配置与进阶使用)
- [常见问题](#常见问题)
- [项目结构](#项目结构)
- [致谢与引用](#致谢与引用)
- [开源协议与免责声明](#开源协议与免责声明)

---

## 简介

在 Android 11 及以上版本的分区存储（Scoped Storage）机制下，微信、QQ、企业微信、Telegram 等应用的下载文件通常被限制在 `Android/data/<package>/` 私有目录中，系统自带文件管理器无法直接访问；同时各应用在内部存储中分散建立目录，检索文件极为不便。

**App Download Binder** 是一款轻量级、纯本地运行的 Root 模块（兼容 **KernelSU / KernelSU Next / APatch / Magisk**），在开机解锁后自动将各应用的纯下载目录绑定映射到统一的中文目录 `/sdcard/Download/应用下载/<软件名>/`，让任意普通文件管理器都能直接浏览与管理。

---

## 特性

- **零额外存储占用**：基于 Linux `mount --bind` 实时映射，源目录与目标目录指向同一份物理数据，不进行任何文件复制或剪贴。
- **一软件一中文文件夹**：内置大小写不敏感的名称归一化与去重机制，同一软件的多条路径自动归拢至单一中文目录，自动拦截 `com.xxx.xxx` 原始包名目录。
- **严格过滤非下载内容**：自动排除 `cache`、`thumbnails`、`log`、`tmp`、`update`、`upgrade`、系统相册及录屏等干扰目录；Telegram 仅映射 `Telegram Files` 与 `Telegram Documents`，不暴露聊天图片缓存与缩略图。
- **纯本地零联网**：无任何云端轮询或后台耗电任务；内置 **235 条开源纯下载规则库**（覆盖 104 个常见应用，含开启存储隔离后的 `sdcard/` 路径），并支持每天低功耗定时检测新增应用。
- **刷入音量键交互**：安装时提供两步音量键确认——先确认风险提示，再自由选择「全自动扫描模式」或「标准规则库模式」。
- **目录整洁与安全清理**：配置与日志完全收纳于模块目录 `/data/adb/modules/app_download_binder/`，不在普通存储中留下杂文件；覆盖升级与卸载时自动安全解除挂载并清理空挂载点，绝不误删原文件。

---

## 效果示例

```text
/sdcard/Download/应用下载/
├── 微信/
│   ├── 文件/        ← Android/data/com.tencent.mm/MicroMsg/Download
│   ├── 保存/        ← Download/WeiXin
│   └── 图片视频/    ← Pictures/WeiXin
├── QQ/              ← Android/data/com.tencent.mobileqq/Tencent/QQfile_recv
├── 企业微信/
│   ├── 文件/        ← Android/data/com.tencent.wework/files/filecache/<账号ID>
│   └── 图片视频/    ← DCIM/WeixinWork
├── Telegram/
│   ├── 文件/        ← Android/data/org.telegram.messenger/files/Telegram/Telegram Files
│   └── 文档/        ← Android/data/org.telegram.messenger/files/Telegram/Telegram Documents
├── 夸克/
├── 百度网盘/
└── ...
```

---

## 实现原理

1. **Android 11+ FUSE 底层绑定挂载（`/data/media/0`）**
   Android 11+ 使用 MediaProvider FUSE 接管 `/storage/emulated/0`。本模块直接对底层 ext4/f2fs 文件系统 `/data/media/0/` 执行 `mount --bind`，MediaProvider 读取 `/data/media/0/Download/应用下载/` 时自动穿透映射，因此无需对非 Root 文件管理器做额外授权；Android 10 等非 FUSE 设备会自动补挂 `/storage/emulated/0/`。
2. **PID 1 全局挂载命名空间**
   所有 `mount` / `umount` 操作均通过 `nsenter -t 1 -m` 在全局命名空间执行，确保无论是在开机阶段、KernelSU 模块页「操作 / Action」还是 MT 管理器中运行，挂载均对全系统持久生效且不受 KernelSU App Umount 机制影响。
3. **解锁后就绪检测**
   `service.sh` 开机后持续等待 `sys.boot_completed=1` 且 `/storage/emulated/0/Android/` 可成功创建测试文件（确保 FBE 已解锁且 FUSE 完全就绪），再延迟 3 秒执行挂载，避免开机过早挂载失效。
4. **两阶段合并归类 & 安全卸载**
   挂载前先对有效规则按软件名分组：单源目录直接挂载为 `/sdcard/Download/应用下载/<软件名>`，多源目录自动归拢到 `<软件名>/` 下的清晰子目录。更新或卸载时先 `umount -l`，校验 `! is_mounted` 后仅用 `rmdir` 删除空挂载点，杜绝误删数据风险。

---

## 安装指南

### 环境要求
- Android 11 及以上（推荐 Android 12–16）
- 已获取 Root 权限（KernelSU / KernelSU Next / APatch / Magisk）

### 安装步骤
1. 前往 [Releases](https://github.com/beichen123-hub/app-download-binder/releases) 下载最新版 `App-Download-Binder_v3.2.0.zip`。
2. 在 **KernelSU / APatch / Magisk** 模块页选择压缩包刷入：
   - **步骤 1（风险确认）**：按 **音量上键 (+)** 确认继续，按 **音量下键 (-)** 取消；
   - **步骤 2（模式选择）**：
     - **音量上键 (+)**：全自动扫描模式（刷入时自动扫描本机已识别中文名的应用目录并写入配置）；
     - **音量下键 (-)**：标准规则库模式（仅启用默认规则与内置 235 条开源规则库）。
3. **重启手机**并解锁进入桌面，等待约 3 秒后打开文件管理器进入 `Download/应用下载/` 即可查看。

---

## 配置与进阶使用

### 模块文件位置
| 文件路径 | 用途 |
| --- | --- |
| `/data/adb/modules/app_download_binder/rules.conf` | 主规则配置文件（覆盖升级自动保留并清洗） |
| `/data/adb/modules/app_download_binder/builtin_rules.db` | 内置 235 条开源纯下载规则库 |
| `/data/adb/modules/app_download_binder/一键扫描并重载挂载.sh` | MT 管理器一键扫描并热重载脚本（Root 执行） |
| `/data/adb/modules/app_download_binder/scan_report.txt` | 最近一次全机扫描报告（含未识别包名参考） |
| `/data/adb/modules/app_download_binder/bind.log` | 开机与运行日志 |

### 手动新增 / 修改规则
编辑 `/data/adb/modules/app_download_binder/rules.conf`，按以下格式添加（路径均相对于 `/sdcard/`）：

```conf
# 定时检测设置
AUTO_SCAN=1
SCAN_INTERVAL_HOURS=24

# 格式：公开目录|App原下载相对路径
Download/应用下载/我的软件|Android/data/com.example.app/files/Download
```

- **同一软件合并**：为同一个软件的多条路径填写相同的左边目录即可自动归拢；
- **屏蔽某条规则**：在行首添加 `#` 注释，后续定时扫描将永久跳过该路径；
- **立即生效**：保存后在 MT 管理器以 Root 权限运行 `一键扫描并重载挂载.sh`，或在 KernelSU 模块页点击 **操作 / Action**。

### Chrome 配合方案
Chrome 默认直接将文件保存至公共根目录 `Download/`，无法用全局 `mount --bind` 挂入子目录（会产生递归冲突）。建议配合 **[Storage Redirect X](https://github.com/Kindness-Kismet/storage-redirection-x)** 为 Chrome 配置一条路径映射：

```text
request_path: Download
final_path:   Download/应用下载/Chrome
```

---

## 常见问题

<details>
<summary><strong>1. 会占用双倍存储空间吗？</strong></summary>

不会。`mount --bind` 仅在文件系统层创建同一份物理目录的第二个访问入口，额外占用为 0 字节。部分系统自带“存储清理”按目录累加时可能会重复计入显示大小，但实际可用空间不会减少。
</details>

<details>
<summary><strong>2. 在 <code>Download/应用下载/</code> 里删除文件会影响原文件吗？</strong></summary>

**会！** 映射目录与原目录指向同一份文件，删除、重命名或修改都会实时同步到原目录。而**卸载本模块**只会安全解除挂载并清理空壳目录，不会删除原目录中的任何文件。
</details>

<details>
<summary><strong>3. 为什么某些小众 App 没有自动出现？</strong></summary>

为避免出现杂乱的 `com.xxx.xxx` 英文包名文件夹，未内置中文名的应用默认不会自动挂载，但会以注释形式记录在 `scan_report.txt` 中。你可以查看报告，将其中路径改为喜欢的中文名复制到 `rules.conf` 后重载即可。
</details>

---

## 项目结构

```text
app-download-binder/
├── module/
│   ├── META-INF/com/google/android/   # Magisk / KernelSU / APatch 安装入口
│   ├── module.prop                    # 模块元信息（运行时动态刷新生效状态）
│   ├── customize.sh                   # 安装脚本（音量键确认、模式选择、旧版清理与迁移）
│   ├── service.sh                     # 开机脚本（等待解锁与 FUSE 可读写 + 定时检测）
│   ├── action.sh                      # 模块页「操作 / Action」热重载入口
│   ├── uninstall.sh                   # 卸载脚本（停守护进程、安全卸载并删除映射目录）
│   ├── common.sh                      # 核心挂载引擎、规则解析与中文名归一化
│   ├── scan_report.sh                 # 全机应用真实存储路径极速扫描器
│   ├── 一键扫描并重载挂载.sh            # MT 管理器一键执行脚本
│   ├── default_rules.conf             # 默认规则模板
│   └── builtin_rules.db               # 内置 235 条纯下载规则库
├── README.md
└── COOLAPK_POST.md
```

---

## 致谢与引用

- 规则库筛选并同步自 **[Kindness-Net/storage-redirection-x-rules](https://github.com/Kindness-Net/storage-redirection-x-rules)**（上游 **[RikkaApps/StorageRedirect-assets](https://github.com/RikkaApps/StorageRedirect-assets)**）
- 设计思路参考 **[Kindness-Kismet/storage-redirection-x](https://github.com/Kindness-Kismet/storage-redirection-x)** 及酷安开源模块 `Third_Party_Redirect`（阿巴酱 / 落葉淒涼）

---

## 开源协议与免责声明

- 本项目采用 **GNU General Public License v3.0 (GPL-3.0)** 开源协议。
- 本模块运行于 Root 特权环境，涉及挂载命名空间与文件系统操作。使用前请知晓映射目录与原目录同步生效的特性，作者不对因误删文件、系统差异或不当修改配置造成的任何数据损失承担责任。
