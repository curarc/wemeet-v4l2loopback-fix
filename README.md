# 修复腾讯会议 Linux 版中 OBS 虚拟摄像机黑屏 / 崩溃

在 Ubuntu / Arch 等 Linux 发行版上,OBS Studio 的虚拟摄像机(v4l2loopback)在 VLC、
Cheese、Zoom 等几乎所有软件中都能正常显示画面,**唯独在腾讯会议(Wemeet)中是黑屏**;
某些配置下还会出现画面闪烁,甚至直接把腾讯会议整个搞崩(段错误)。

本仓库提供一个**一键修复脚本**,并对问题根因做了完整的技术分析。

**修复后效果**(腾讯会议视频设置中,「OBS Virtual Camera」实时预览正常):

![修复后腾讯会议中 OBS 虚拟摄像机正常显示](docs/wemeet-after-fix.png)

> 🇬🇧 [English summary at the bottom](#english-summary)

## 问题现象

- ✅ OBS「启动虚拟摄像机」正常,`v4l2-ctl` / ffmpeg / VLC 读取 `/dev/videoN` 有画面
- ❌ 腾讯会议中选择「OBS Virtual Camera」→ **纯黑画面**
- ❌ 将 v4l2loopback 的 `max_buffers` 调大(如 8)后 → 有画面,但**闪烁**,且预览/入会
  一段时间后**腾讯会议崩溃**:

  ```
  kernel: traps: device-thread[...] general protection fault ... in libxcast.so
  kernel: device-thread[...]: segfault at 1f00000001 ... in libxcast.so
  ```

## 根因分析(两个叠加的问题)

通过腾讯会议的 xcast 视频引擎日志(`~/.local/share/wemeetapp/Saas/Logs/xcast_*.log`)、
`strace -e trace=ioctl` 跟踪其系统调用、以及 v4l2loopback 源码,定位到:

### 问题 1:黑屏 —— wemeet 的 DQBUF/QBUF 不设置 `memory` 字段

腾讯会议取帧时传入的 `v4l2_buffer.memory == 0`(未设置),而 v4l2loopback 的
`vidioc_dqbuf()` / `vidioc_qbuf()` **严格校验**该字段必须为 `V4L2_MEMORY_MMAP`:

```c
if (buf->memory != V4L2_MEMORY_MMAP)   // memory=0 在此被拒绝
    return -EINVAL;
```

标准驱动(uvcvideo/vb2)并不校验这个字段,所以 wemeet 配所有真摄像头都没问题;
v4l2loopback 却每帧返回 `-EINVAL`。会议日志中的对应表现是:

```
E|v4l2.c:320|Not enough buffer on device:/dev/video2
E|v4l2.c:333|Could not requeue buffer on device:/dev/video2
```

(该日志措辞 "Not enough buffer" 极具误导性——并非缓冲区数量不足,而是 DQBUF 失败。)

用 `tools/test_dqbuf.c` 可直接复现:`memory=MMAP` 取帧成功,`memory=0` 返回 EINVAL。

### 问题 2:闪烁 + 段错误 —— `max_buffers` 与 wemeet 申请数不一致

v4l2loopback 强制**所有**打开者共用同一套设备缓冲区(`used_buffer_count` 由第一个
申请者决定)。若写端(OBS)申请了 8 个缓冲区,腾讯会议虽只申请 4 个、也只映射 4 个,
但 DQBUF 会返回 0~7 的设备级索引。腾讯会议直接拿索引访问自己 4 元素的 mmap 数组:

- 索引 0~3 → 画面正常(偶尔)→ **闪烁**
- 索引 4~7 → 数组越界 → **libxcast.so 段错误崩溃**

因此 `max_buffers` 必须等于 wemeet 实际申请的数量(**4**)。

## 快速开始

```bash
git clone https://github.com/zezhengjiang/wemeet-v4l2loopback-fix.git
cd wemeet-v4l2loopback-fix
sudo ./fix-wemeet-virtual-cam.sh
```

或免克隆直接执行:

```bash
curl -fsSL https://raw.githubusercontent.com/zezhengjiang/wemeet-v4l2loopback-fix/main/fix-wemeet-virtual-cam.sh -o fix.sh && sudo bash fix.sh
```

脚本会自动完成:

1. 识别发行版(Debian/Ubuntu 系 `apt` / Arch 系 `pacman`),缺 `v4l2loopback-dkms`
   和内核头文件时自动安装
2. 给 v4l2loopback 源码打补丁(首次自动备份原版为 `.orig`,重复执行自动跳过)
3. 写入持久配置 `/etc/modprobe.d/v4l2loopback-obs.conf`:
   `options v4l2loopback exclusive_caps=1 max_buffers=4 video_nr=2 card_label="OBS Virtual Camera"`
4. DKMS 重编译内核模块并重载
5. 验证参数

之后:打开 OBS → 「启动虚拟摄像机」→ 腾讯会议选择「OBS Virtual Camera」即可。

## 手动修复(不想跑脚本)

1. 备份并打补丁(基于 v4l2loopback 0.15.3):

   ```bash
   sudo cp /usr/src/v4l2loopback-0.15.3/v4l2loopback.c{,.orig}
   sudo patch -d /usr/src/v4l2loopback-0.15.3 -p1 < patches/v4l2loopback-wemeet-compat.patch
   ```

2. 固定模块参数:

   ```bash
   echo 'options v4l2loopback exclusive_caps=1 max_buffers=4 video_nr=2 card_label="OBS Virtual Camera"' \
     | sudo tee /etc/modprobe.d/v4l2loopback-obs.conf
   ```

3. 重编译并重载(先退出 OBS):

   ```bash
   sudo dkms remove -m v4l2loopback -v 0.15.3 --all
   sudo dkms install -m v4l2loopback -v 0.15.3 -k "$(uname -r)"
   sudo modprobe -r v4l2loopback && sudo modprobe v4l2loopback
   ```

## 验证 / 复现工具

```bash
# OBS 虚拟摄像机保持运行,编译并运行:
gcc -o test_dqbuf tools/test_dqbuf.c
./test_dqbuf /dev/video2
```

**打补丁前**(2026-10-27 在本机实测,黑屏根源被直接复现):

```
S_FMT  (YUYV)      : 0 (OK)
REQBUFS(4, MMAP)   : 0 (driver gave 4) (OK)
STREAMON           : 0 (OK)
DQBUF memory=MMAP  : 0 (OK)
DQBUF memory=0     : -1 (Invalid argument)      ← 腾讯会议黑屏的根源
QBUF requeue mem=0 : -1 (Invalid argument)
```

**打补丁后**(本仓库修复脚本应用后的真实输出):

```
open(/dev/video2)           : OK
S_FMT  (YUYV)      : 0 (OK)
REQBUFS(4, MMAP)  : 0 (driver gave 4) (OK)
QBUF(0) proper    : 0 (OK)
QBUF(1) proper    : 0 (OK)
QBUF(2) proper    : 0 (OK)
QBUF(3) proper    : 0 (OK)
STREAMON           : 0 (OK)
DQBUF memory=MMAP       : 0 (OK)
DQBUF memory=0(wemeet)  : 0 (OK)
QBUF requeue mem=0      : 0 (OK)
QBUF requeue mem=MMAP   : 0 (OK)
```

## 回滚与维护

```bash
sudo ./fix-wemeet-virtual-cam.sh --restore   # 恢复原版驱动源码并重编译
```

- 配置持久化在 `/etc/modprobe.d/v4l2loopback-obs.conf`,重启后依然有效
- **升级 `v4l2loopback-dkms` 软件包会覆盖 `/usr/src` 里的补丁**,重新执行脚本即可
- `video_nr=2` 将设备固定为 `/dev/video2`;若与其他摄像头冲突,编辑配置文件改成
  其他编号或 `-1`

## 已测试环境

| 项目 | 版本 |
|---|---|
| 发行版 | Ubuntu 25.10 (resolute) |
| 内核 | 7.0.0-38-generic |
| OBS Studio | 32.2.0 (obsproject 官方 PPA 构建) |
| v4l2loopback | 0.15.3 (v4l2loopback-dkms) |
| 腾讯会议 | 3.26.10.401 (官方 deb) |
| 摄像头 | FaceTime HD Camera (Built-in) + OBS Virtual Camera |

其他环境(Debian / Arch / Manjaro / 不同版本)理论上同样适用——脚本自带版本检测,
源码不匹配时会明确报错而不会打歪。**欢迎提交 PR 补充你的测试环境!**

## FAQ

- **为什么 VLC 有画面、腾讯会议没有?**
  VLC 每次都完整设置 `v4l2_buffer` 各字段;腾讯会议是少数不设置 `memory` 字段的
  程序,恰好踩中 v4l2loopback 的严格校验。
- **为什么不能只调 `max_buffers`?**
  只调大 `max_buffers` 会从"黑屏"变成"闪烁 + 段错误"(见问题 2);只有同时打
  memory 补丁并把 `max_buffers` 收敛到 4,才能同时解决。
- **影响其他使用虚拟摄像机的软件吗?**
  不影响。补丁仅接受 `memory=0` 并按 MMAP 处理,其他程序传 `MMAP` 的行为不变。
- **腾讯会议将来会修吗?**
  这是 wemeet 与 v4l2loopback 双方的"合谋 bug";若新版 wemeet 修复了 `memory`
  字段,补丁变得多余但无害。也欢迎上游参考本分析:v4l2loopback 可以考虑宽容处理
  `memory=0`,与内核 vb2 的行为保持一致。
- **为啥打完补丁还是看到黑色的画面？**
  有可能是因为刚装完obs和腾讯会议软件，然后直接打了补丁。重启一下系统就可以啦！

## English summary

OBS Studio's virtual camera (v4l2loopback) works in VLC but shows a **black screen
in Tencent Meeting (Wemeet) on Linux**, and with larger `max_buffers` it flickers
and eventually **segfaults** (`libxcast.so`).

Root causes:

1. Wemeet does not set `v4l2_buffer.memory` in `VIDIOC_DQBUF`/`VIDIOC_QBUF`
   (passes 0). Standard drivers ignore this field, but v4l2loopback strictly
   requires `V4L2_MEMORY_MMAP` and returns `EINVAL` for every frame → black video.
   Wemeet's own log prints a misleading `Not enough buffer on device:...`.
2. v4l2loopback forces all openers to share one buffer set. If the writer
   allocated 8 buffers (`max_buffers=8`), wemeet maps only 4 but receives device
   buffer indices 0..7 → out-of-bounds array access → flicker, then SIGSEGV in
   wemeet's `device-thread`.

Fix: patch v4l2loopback to accept `memory=0` (treat as MMAP), and set
`max_buffers=4` (matching wemeet's request) in `/etc/modprobe.d/`. Run
`sudo ./fix-wemeet-virtual-cam.sh` — it auto-detects Debian/Ubuntu vs Arch,
installs missing packages/headers, patches, rebuilds via DKMS and reloads the
module. `sudo ./fix-wemeet-virtual-cam.sh --restore` reverts the patch.

## 许可证

MIT License — 详见 [LICENSE](LICENSE)。
