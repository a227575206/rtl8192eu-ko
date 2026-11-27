#!/usr/bin/env bash
# ============================================================
# 为创维 E900V22D（Amlogic p291_iptv, armv7l, Linux 4.9.113）
# 交叉编译 RTL8192EU USB 无线网卡驱动
#
# 核心思路：
#   不编译整个内核，只做 modules_prepare 拿到头文件和构建脚本；
#   然后把从真机 66 个原厂 .ko 里提取出来的 1212 条真实符号 CRC
#   写成 Module.symvers 喂给 modpost —— 这样编译出的 8192eu.ko
#   其 __versions 段天生就和真机内核匹配，无需事后打补丁。
# ============================================================
set -euo pipefail

KVER=4.9.113
UTSRELEASE="4.9.y"          # 必须与真机 vermagic 首段完全一致
# 驱动源码候选地址（按兼容性排序，逐个尝试）
DRV_URLS="https://github.com/Mange/rtl8192eu-linux-driver.git https://github.com/clnhub/rtl8192eu-linux.git"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
KDIR="$ROOT/linux-$KVER"
KCFG="$ROOT/config/kernel.config"
SYMVERS="$ROOT/config/Module.symvers"
DRVDIR="$ROOT/rtl8192eu-linux-driver"
OUT="$ROOT/out"

export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabihf-
JOBS=${JOBS:-$(nproc)}

step() { printf '\n\033[1;36m==== %s ====\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[FAIL] %s\033[0m\n' "$*" >&2; exit 1; }
# 出错时打印行号，便于远程排查
trap 'printf "\n\033[1;31m[ERROR] 第 %s 行执行失败，退出码 %s\033[0m\n" "$LINENO" "$?" >&2' ERR

# ---------- 0. 环境自检 ----------
# 注意: 这里不能用 `| head -1`。head 读完即退出会让左侧命令收到 SIGPIPE，
# 配合 set -o pipefail 会被判定为失败，导致脚本在自检阶段就退出。
step "环境自检"
${CROSS_COMPILE}gcc --version 2>&1 | sed -n 1p || true
make --version 2>&1 | sed -n 1p || true
python3 --version || true
echo "并行度: $JOBS"

# ---------- 1. 取内核源码 ----------
step "获取 Linux $KVER 源码"
if [ ! -d "$KDIR" ]; then
    curl -fL --retry 3 --retry-delay 5 -o "$ROOT/linux.tar.xz" \
        "https://cdn.kernel.org/pub/linux/kernel/v4.x/linux-$KVER.tar.xz" \
        || die "内核源码下载失败"
    tar -xJf "$ROOT/linux.tar.xz" -C "$ROOT" || die "内核源码解压失败"
fi
[ -f "$KDIR/Makefile" ] || die "内核源码目录异常: $KDIR"

# ---------- 2. 应用真机配置 ----------
step "应用真机 .config"
cp "$KCFG" "$KDIR/.config"
# 真机没开模块签名，确保这里也不开（否则 4.9 的 sign-file 在 openssl 1.1 下编不过）
( cd "$KDIR" && \
  scripts/config --file .config \
    --disable MODULE_SIG --disable MODULE_SIG_ALL --disable MODULE_SIG_FORCE \
    --disable SYSTEM_TRUSTED_KEYS --disable SYSTEM_REVOCATION_KEYS 2>/dev/null || true )

make -C "$KDIR" ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE olddefconfig \
    || die "olddefconfig 失败"

echo "--- 关键配置核对 ---"
grep -E '^CONFIG_(SMP|PREEMPT|MODVERSIONS|CFG80211|MAC80211|CFG80211_WEXT|RFKILL)=' "$KDIR/.config" || true

# ---------- 3. 只准备头文件与脚本 ----------
step "modules_prepare（不编译整个内核）"
make -C "$KDIR" ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE modules_prepare -j"$JOBS" \
    2>&1 | tail -30 || die "modules_prepare 失败"
[ -f "$KDIR/include/generated/utsrelease.h" ] || die "utsrelease.h 未生成"

# ---------- 4. 注入真机符号表 + 对齐 vermagic ----------
step "注入真机符号 CRC 表（$(wc -l < "$SYMVERS") 条）"
cp "$SYMVERS" "$KDIR/Module.symvers"

step "对齐 vermagic 为 $UTSRELEASE"
printf '#define UTS_RELEASE "%s"\n' "$UTSRELEASE" > "$KDIR/include/generated/utsrelease.h"
printf '%s\n' "$UTSRELEASE" > "$KDIR/include/config/kernel.release"
touch "$KDIR/include/generated/utsrelease.h" "$KDIR/include/config/kernel.release"
cat "$KDIR/include/generated/utsrelease.h"

# ---------- 5. 取驱动源码 ----------
step "获取 rtl8192eu 驱动源码"
if [ ! -d "$DRVDIR/.git" ]; then
    cloned=0
    for u in $DRV_URLS; do
        echo "尝试: $u"
        rm -rf "$DRVDIR"
        if git clone --depth 1 "$u" "$DRVDIR" 2>&1; then
            cloned=1
            break
        fi
        echo "  失败，换下一个源"
    done
    [ "$cloned" = 1 ] || die "所有驱动源码仓库均克隆失败"
fi
git -C "$DRVDIR" log -1 --format='commit %h  %ad  %s' --date=short
echo "源码目录内容:"
ls "$DRVDIR" | head -20

# ---------- 6. 编译 ----------
step "编译 8192eu.ko"
mkdir -p "$OUT"
set +e
make -C "$KDIR" M="$DRVDIR" ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE \
     modules -j"$JOBS" 2>&1 | tee "$ROOT/build.log"
RC=${PIPESTATUS[0]}
set -e
if [ "$RC" -ne 0 ]; then
    echo "--- 编译错误摘要 ---"
    grep -iE 'error:|Error [0-9]' "$ROOT/build.log" | head -30 || true
    die "驱动编译失败（build.log 已保留）"
fi

find "$DRVDIR" -maxdepth 1 -name '*.ko' -exec cp -v {} "$OUT/" \;
[ -n "$(ls -A "$OUT" 2>/dev/null)" ] || die "没有产出 .ko"

# ---------- 7. 校验 ----------
step "校验产物"
for ko in "$OUT"/*.ko; do
    echo "--- $(basename "$ko") ---"
    ls -lh "$ko" | awk '{print "大小:", $5}'
    command -v modinfo >/dev/null && modinfo -F vermagic "$ko" || true
    python3 "$ROOT/scripts/check_versions.py" "$ko" "$SYMVERS" || true
done

step "完成"
ls -lh "$OUT"
