#!/usr/bin/env bash
#
# fix-wemeet-virtual-cam.sh
#
# 修复:Linux 下 OBS Studio 虚拟摄像机(v4l2loopback)在腾讯会议(wemeet)中
#       黑屏 / 画面闪烁 / wemeet 崩溃的问题。
#
# 原因 1:wemeet 调用 VIDIOC_DQBUF / VIDIOC_QBUF 时不设置 v4l2_buffer.memory
#         字段(传 0),v4l2loopback 严格校验返回 EINVAL -> 每帧失败 -> 黑屏。
# 原因 2:v4l2loopback 强制所有打开者共用同一套缓冲区;若 max_buffers 与
#         wemeet 申请的缓冲区数(4)不一致(如 8),wemeet 只映射 4 个却收到
#         超范围索引 -> 越界 -> 段错误。
#
# 支持的发行版:Debian/Ubuntu 系(apt)与 Arch 系(pacman,含 Manjaro/
#               EndeavourOS/CachyOS 等)。其他发行版若已装好 v4l2loopback
#               DKMS 源码,脚本同样可以工作(只是不会自动装包)。
#
# 本脚本做的事(全部幂等,可重复执行):
#   1. 检查/安装 v4l2loopback-dkms 及内核头文件(按发行版自动选择包管理器)
#   2. 给 v4l2loopback 源码打补丁(接受 memory=0),保留原始备份 .orig
#   3. 写入 /etc/modprobe.d 配置(exclusive_caps=1 max_buffers=4 video_nr=2)
#   4. DKMS 重编译并重载模块
#   5. 验证参数并给出后续操作提示
#
# 用法:
#   sudo ./fix-wemeet-virtual-cam.sh            # 安装/修复(重复执行安全)
#   sudo ./fix-wemeet-virtual-cam.sh --restore  # 回滚补丁,恢复原版驱动
#
# 已知维护点:今后升级 v4l2loopback-dkms 软件包会覆盖补丁,
#            重新执行本脚本即可恢复。
#
set -euo pipefail

# ========================= 可按需修改的配置 =========================
CONF_FILE="/etc/modprobe.d/v4l2loopback-obs.conf"
# video_nr=2 把虚拟摄像机固定为 /dev/video2;若与其他摄像头冲突,
# 改成其他编号或 -1(自动分配)
CONF_OPTIONS='options v4l2loopback exclusive_caps=1 max_buffers=4 video_nr=2 card_label="OBS Virtual Camera"'
# ====================================================================

RESTORE=0
[[ "${1:-}" == "--restore" ]] && RESTORE=1

C_G="\033[32m"; C_Y="\033[33m"; C_R="\033[31m"; C_B="\033[36m"; C_0="\033[0m"
info()  { echo -e "${C_G}[✓]${C_0} $*"; }
step()  { echo -e "${C_B}[»]${C_0} $*"; }
warn()  { echo -e "${C_Y}[!]${C_0} $*"; }
die()   { echo -e "${C_R}[✗]${C_0} $*" >&2; exit 1; }

# ------------------------------------------------------------ root 检查
if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"      # 没用 sudo 时,自动带 sudo 重新执行
fi
info "以 root 运行"

# ------------------------------------------------------------ 发行版检测
DISTRO=""
if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    case "${ID:-}${ID_LIKE:+ ${ID_LIKE}}" in
        *debian*|*ubuntu*)  DISTRO="deb"   ;;
        *arch*|*manjaro*|*cachyos*|*endeavouros*|*garuda*|*artix*) DISTRO="arch" ;;
    esac
fi
case "$DISTRO" in
    deb)  PKG_MGR="apt";   info "发行版: Debian/Ubuntu 系(apt)" ;;
    arch) PKG_MGR="pacman"; info "发行版: Arch 系(pacman)" ;;
    *)    warn "未能识别发行版(仅支持 Debian/Ubuntu/Arch 系)"
          warn "若已手动装好 v4l2loopback DKMS 源码,可继续尝试" ;;
esac

pkg_installed() {
    case "$DISTRO" in
        deb)  dpkg -s "$1" >/dev/null 2>&1 ;;
        arch) pacman -Qi "$1" >/dev/null 2>&1 ;;
        *)    return 1 ;;
    esac
}
install_pkg() {
    case "$DISTRO" in
        deb)  export DEBIAN_FRONTEND=noninteractive
              apt-get update -qq
              apt-get install -y -qq "$@" ;;
        arch) pacman -Sy --needed --noconfirm "$@" ;;
        *)    die "未知发行版,无法自动安装 $*;请手动安装后重跑本脚本" ;;
    esac
}

# ------------------------------------------------------------ 定位源码
KVER="$(uname -r)"
command -v dkms    >/dev/null || die "缺少 dkms(安装: $PKG_MGR install dkms)"
command -v python3 >/dev/null || die "缺少 python3"

SRC_DIR="$(echo /usr/src/v4l2loopback-*)"
if [[ ! -d "$SRC_DIR" ]]; then
    step "未找到 v4l2loopback DKMS 源码,正在安装 v4l2loopback-dkms…"
    case "$DISTRO" in
        deb)  install_pkg v4l2loopback-dkms ;;
        arch) install_pkg v4l2loopback-dkms ;;
        *)    die "请手动安装 v4l2loopback-dkms(或从 AUR/Git 编译)后重跑本脚本" ;;
    esac
    SRC_DIR="$(echo /usr/src/v4l2loopback-*)"
    [[ -d "$SRC_DIR" ]] || die "安装后仍未找到源码目录,请手动检查"
fi
SRC_C="$SRC_DIR/v4l2loopback.c"
MODVER="$(basename "$SRC_DIR" | sed 's/v4l2loopback-//')"
step "检测到 v4l2loopback $MODVER(源码: $SRC_C,内核: $KVER)"

# ------------------------------------------------------------ 内核头文件
# DKMS 编译需要 /lib/modules/$KVER/build
if [[ ! -e "/lib/modules/$KVER/build" ]]; then
    step "缺少内核头文件,正在安装…"
    case "$DISTRO" in
        deb)  install_pkg "linux-headers-$KVER" || die "安装 linux-headers-$KVER 失败" ;;
        arch) install_pkg linux-headers        || die "安装 linux-headers 失败" ;;
        *)    die "请手动安装 $KVER 对应的内核头文件后重跑本脚本" ;;
    esac
    [[ -e "/lib/modules/$KVER/build" ]] || die "头文件安装后仍缺 /lib/modules/$KVER/build"
else
    info "内核头文件已就绪"
fi

rebuild_and_reload() {
    step "DKMS 重编译模块…"
    dkms remove -m v4l2loopback -v "$MODVER" --all >/dev/null 2>&1 || true
    dkms install -m v4l2loopback -v "$MODVER" -k "$KVER" || die "DKMS 编译失败"
    info "编译完成"

    step "重载模块…"
    if lsmod | grep -qw v4l2loopback; then
        modprobe -r v4l2loopback 2>/dev/null || {
            warn "模块被以下进程占用,无法卸载:"
            fuser -v /dev/video* 2>/dev/null || true
            die "请先关闭占用摄像头的程序(OBS/腾讯会议/其他),然后重新执行本脚本"
        }
    fi
    modprobe v4l2loopback || die "加载 v4l2loopback 失败"
    info "模块已加载"
}

# ------------------------------------------------------------ 回滚模式
if (( RESTORE )); then
    step "回滚模式:恢复原始 v4l2loopback.c"
    [[ -f "$SRC_C.orig" ]] || die "找不到备份 $SRC_C.orig,无需回滚"
    cp -f "$SRC_C.orig" "$SRC_C"
    info "源码已恢复(配置文件 $CONF_FILE 保留,如需删除请手动 rm)"
    rebuild_and_reload
    info "回滚完成"
    exit 0
fi

# ------------------------------------------------------------ 1. 依赖安装
if pkg_installed v4l2loopback-dkms; then
    info "v4l2loopback-dkms 已安装"
else
    step "v4l2loopback-dkms 未注册到包管理器(可能为手动编译),尝试安装…"
    install_pkg v4l2loopback-dkms || warn "自动安装失败,但源码已存在,继续使用现有源码"
    SRC_DIR="$(echo /usr/src/v4l2loopback-*)"
    [[ -d "$SRC_DIR" ]] || die "未找到源码目录,请手动检查"
    SRC_C="$SRC_DIR/v4l2loopback.c"
    MODVER="$(basename "$SRC_DIR" | sed 's/v4l2loopback-//')"
fi

# ------------------------------------------------------------ 2. 打补丁
# 用正则(对制表符/空格不敏感)精确替换;任何一处匹配数 != 1 即中止,防止打歪。
apply_patch() {
    python3 - "$SRC_C" <<'PYEOF'
import re, os, shutil, sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()

MARKER = "WEMEET-COMPAT-PATCH"
if MARKER in src:
    print("ALREADY")
    sys.exit(0)

# patch 1: vidioc_dqbuf —— 接受 memory=0(腾讯会议未设置该字段)
p1 = re.compile(
    r"if\s*\(buf->memory != V4L2_MEMORY_MMAP\)\s*\n"
    r"\s*return -EINVAL;\s*\n"
    r"\s*if \(opener->format_token & V4L2L_TOKEN_TIMEOUT\)\s*\{")
r1 = (
    "if (buf->memory != V4L2_MEMORY_MMAP && buf->memory != 0)\n"
    "\t\treturn -EINVAL; /* " + MARKER + ": accept memory=0 */\n"
    "\tif (opener->format_token & V4L2L_TOKEN_TIMEOUT) {")

# patch 2: vidioc_qbuf —— memory switch 增加 case 0
p2 = re.compile(
    r"switch \(buf->memory\) \{\s*\n"
    r"\s*case V4L2_MEMORY_MMAP:\s*\n"
    r"\s*if \(!\(bufd->buffer\.flags & V4L2_BUF_FLAG_MAPPED\)\)")
r2 = (
    "switch (buf->memory) {\n"
    "\tcase 0: /* " + MARKER + ": Tencent Meeting leaves memory unset */\n"
    "\tcase V4L2_MEMORY_MMAP:\n"
    "\t\tif (!(bufd->buffer.flags & V4L2_BUF_FLAG_MAPPED))")

for name, pat in (("dqbuf", p1), ("qbuf", p2)):
    n = len(pat.findall(src))
    if n != 1:
        print(f"MISMATCH:{name}:{n}")
        sys.exit(2)

if not os.path.exists(path + ".orig"):
    shutil.copy2(path, path + ".orig")
    print("BACKUP", file=sys.stderr)

src = p1.sub(r1, src, count=1)
src = p2.sub(r2, src, count=1)
with open(path, "w", encoding="utf-8") as f:
    f.write(src)
print("PATCHED")
PYEOF
}

step "给 $SRC_C 打补丁…"
rc=0; result="$(apply_patch 2>&1)" || rc=$?
case "${rc}" in
    0) case "$result" in
           *ALREADY*) info "补丁已存在,跳过" ;;
           *BACKUP*)  info "补丁应用成功(原版已备份为 $SRC_C.orig)" ;;
           *PATCHED*) info "补丁应用成功(备份此前已存在)" ;;
       esac ;;
    2) die "源码与补丁不匹配: $result
    可能是 v4l2loopback 版本过新/过旧,请手动检查 $SRC_C" ;;
    *) die "补丁脚本执行失败: $result" ;;
esac

# ------------------------------------------------------------ 3. modprobe.d 配置
step "写入 $CONF_FILE"
echo "$CONF_OPTIONS" > "$CONF_FILE"
chmod 644 "$CONF_FILE"
info "配置完成"

# ------------------------------------------------------------ 4. 停止占用者
# 模块重载前不能有进程占用摄像头设备
if pgrep -x obs >/dev/null 2>&1 || pgrep -f 'wemeetapp' >/dev/null 2>&1; then
    warn "检测到 OBS / 腾讯会议正在运行,尝试退出它们…"
    pkill -x obs 2>/dev/null || true
    pkill -f wemeetapp 2>/dev/null || true
    sleep 2
fi

# ------------------------------------------------------------ 5+6. 编译、重载、验证
rebuild_and_reload

step "验证模块参数:"
MAX_BUF="$(cat /sys/module/v4l2loopback/parameters/max_buffers)"
EXC_CAP="$(cat /sys/module/v4l2loopback/parameters/exclusive_caps | cut -d, -f1)"
echo "    max_buffers    = $MAX_BUF   (应为 4)"
echo "    exclusive_caps = $EXC_CAP   (应为 Y)"
echo "    设备           = $(ls /dev/video* 2>/dev/null | tr '\n' ' ')"
[[ "$MAX_BUF" == 4 && "$EXC_CAP" == Y ]] || warn "参数与预期不符,请检查 $CONF_FILE"

# ------------------------------------------------------------ 7. 收尾提示
echo
echo -e "${C_G}════════════════════════════════════════════════${C_0}"
echo -e "${C_G} 修复完成!接下来手动操作:${C_0}"
echo "    1. 打开 OBS → 点击「启动虚拟摄像机」"
echo "    2. 打开腾讯会议 → 选择摄像头「OBS Virtual Camera」"
echo
echo " 维护说明:"
echo "    • 配置持久化在 $CONF_FILE,重启后依然有效"
echo "    • 若升级 v4l2loopback-dkms 软件包,补丁会被覆盖,重新执行本脚本即可"
echo "    • 回滚补丁: sudo $0 --restore"
echo -e "${C_G}════════════════════════════════════════════════${C_0}"
