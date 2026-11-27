#!/usr/bin/env bash
# ============================================================
# 为创维 E900V22D（Amlogic p291_iptv, armv7l, Linux 4.9.113）
# 编译 Linux 主线 mt7601u 驱动，驱动腾讯全民WiFi (2a5f:1000)。
#
# 为什么要换主线驱动：
#   盒子自带的 mt7601usta.ko 是 MediaTek 原厂 v1.11，
#   加载后卡在 RTMPReadParametersHook failed 并退出。
#   主线 mt7601u 原生支持 2a5f:1000，且是内核树内代码，
#   与 4.9.113 结构体布局天然一致，不会出现 8192eu 那种崩溃。
#
# 复用 8192eu 已验证的环境：Amlogic BSP 4.9.20 内核源码 +
# 真机 config + 从原厂模块提取的 1212 条符号 CRC。
# ============================================================
set -euo pipefail

KVER=4.9.113
UTSRELEASE="4.9.y"
K_GIT="https://github.com/CoreELEC/linux-amlogic.git"
K_BRANCH="amlogic-4.9-20"
# 主线固件，云端下载
FW_URL="https://raw.githubusercontent.com/kernel-firmware/linux-firmware/main/mt7601u.bin"
FW_URL2="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mt7601u.bin"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
KDIR="$ROOT/linux-$KVER"
KCFG="$ROOT/config/kernel.config"
SYMVERS="$ROOT/config/Module.symvers"
DRVDIR="$KDIR/drivers/net/wireless/mediatek/mt7601u"
OUT="$ROOT/out_mt7601u"

export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabihf-
JOBS=${JOBS:-$(nproc)}

step() { printf '\n\033[1;36m==== %s ====\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[FAIL] %s\033[0m\n' "$*" >&2; exit 1; }
trap 'printf "\n\033[1;31m[ERROR] 第 %s 行执行失败，退出码 %s\033[0m\n" "$LINENO" "$?" >&2' ERR

step "环境自检"
${CROSS_COMPILE}gcc --version 2>&1 | sed -n 1p || true
make --version 2>&1 | sed -n 1p || true
python3 --version || true
echo "并行度: $JOBS"

step "获取 Amlogic BSP 4.9 内核源码"
if [ ! -d "$KDIR" ]; then
    echo "克隆 $K_GIT ($K_BRANCH)"
    git clone --depth 1 -b "$K_BRANCH" "$K_GIT" "$KDIR" 2>&1 | tail -5 \
        || die "内核源码克隆失败"
fi
[ -f "$KDIR/Makefile" ] || die "内核源码目录异常"
[ -d "$DRVDIR" ] || die "内核源码里没有 mt7601u 驱动目录: $DRVDIR"
echo "驱动源码文件:"
ls "$DRVDIR" | tr '\n' ' '; echo
# 确认 ID 表里有 2a5f:1000
grep -q '2a5f' "$DRVDIR/usb.c" || die "内核源码的 usb.c 不含 2a5f:1000"

step "应用真机 .config"
cp "$KCFG" "$KDIR/.config"
( cd "$KDIR" && \
  scripts/config --file .config \
    --disable MODULE_SIG --disable MODULE_SIG_ALL --disable MODULE_SIG_FORCE \
    --disable SYSTEM_TRUSTED_KEYS --disable SYSTEM_REVOCATION_KEYS \
    --enable MT7601U 2>/dev/null || true )
# 真机是 =y（编进内核），这里让驱动单独编成模块
( cd "$KDIR" && scripts/config --file .config --module MT7601U 2>/dev/null || true )
make -C "$KDIR" ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE olddefconfig \
    || die "olddefconfig 失败"
echo "--- 关键配置核对 ---"
grep -E '^CONFIG_(SMP|PREEMPT|MODVERSIONS|CFG80211|MAC80211|MT7601U|FW_LOADER)=' "$KDIR/.config" || true

step "modules_prepare"
make -C "$KDIR" ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE modules_prepare -j"$JOBS" \
    2>&1 | tail -30 || die "modules_prepare 失败"
[ -f "$KDIR/include/generated/utsrelease.h" ] || die "utsrelease.h 未生成"

step "注入真机符号 CRC 表（$(wc -l < "$SYMVERS") 条）"
cp "$SYMVERS" "$KDIR/Module.symvers"

step "对齐 vermagic 为 $UTSRELEASE"
printf '#define UTS_RELEASE "%s"\n' "$UTSRELEASE" > "$KDIR/include/generated/utsrelease.h"
printf '%s\n' "$UTSRELEASE" > "$KDIR/include/config/kernel.release"
touch "$KDIR/include/generated/utsrelease.h" "$KDIR/include/config/kernel.release"
cat "$KDIR/include/generated/utsrelease.h"

# 4.9 内核的 mt7601u 用到 strscpy 吗？注入兼容头以防万一
COMPAT="$ROOT/kernel_compat.h"
if [ ! -f "$COMPAT" ]; then
cat > "$COMPAT" <<'EOF'
#ifndef _KERNEL_COMPAT_49_H
#define _KERNEL_COMPAT_49_H
#include <linux/types.h>
#include <linux/string.h>
#include <linux/errno.h>
#include <linux/version.h>
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)
#ifndef strscpy
static inline ssize_t __kcompat_strscpy(char *dest, const char *src, size_t count)
{
	size_t len = strnlen(src, count);
	if (len >= count) {
		if (count) { memcpy(dest, src, count - 1); dest[count - 1] = '\0'; }
		return -E2BIG;
	}
	memcpy(dest, src, len + 1);
	return (ssize_t)len;
}
#define strscpy __kcompat_strscpy
#endif
#endif
#endif
EOF
fi

step "编译 mt7601u.ko"
mkdir -p "$OUT"
DRV_CFLAGS="-fno-stack-protector -include $COMPAT"
set +e
make -C "$KDIR" M="$DRVDIR" ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE \
     CONFIG_MT7601U=m USER_EXTRA_CFLAGS="$DRV_CFLAGS" \
     modules -j"$JOBS" 2>&1 | tee "$ROOT/build_mt7601u.log"
RC=${PIPESTATUS[0]}
set -e
if [ "$RC" -ne 0 ]; then
    echo "--- 编译错误摘要 ---"
    grep -iE 'error:|Error [0-9]|undefined!|Unknown symbol' "$ROOT/build_mt7601u.log" | head -40 || true
    if ! ls "$DRVDIR"/*.ko >/dev/null 2>&1; then
        die "驱动编译失败且无产物"
    fi
    echo "[注意] make 返回非 0，但已产出 .ko，继续校验"
fi

find "$DRVDIR" -maxdepth 1 -name '*.ko' -exec cp -v {} "$OUT/" \;
[ -n "$(ls -A "$OUT" 2>/dev/null)" ] || die "没有产出 .ko"

step "获取固件 mt7601u.bin"
# 只接受格式校验通过的固件；失败不阻断 ko 的发布
FW_OK=0
check_fw() {
    python3 - "$1" <<'FWCHK'
import sys, struct
p = sys.argv[1]
try:
    d = open(p,'rb').read()
    if len(d) < 100: raise ValueError('too small')
    ilm, dlm, bv, fv = struct.unpack('<IIHH', d[:12])
    expect = 12 + ilm + dlm
    ok = (len(d) == expect and 4000 < len(d) < 200000)
    print("固件候选 %s: size=%d ilm=%d dlm=%d expect=%d %s" % (
        p, len(d), ilm, dlm, expect, "OK" if ok else "BAD"))
    sys.exit(0 if ok else 1)
except Exception as e:
    print("固件候选 %s 无效: %s" % (p, e))
    sys.exit(1)
FWCHK
}

# 候选1: apt 安装 linux-firmware
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq linux-firmware >/dev/null 2>&1 || true
for d in /lib/firmware /usr/lib/firmware; do
    if [ -f "$d/mt7601u.bin" ] && check_fw "$d/mt7601u.bin"; then
        cp "$d/mt7601u.bin" "$OUT/mt7601u.bin" && FW_OK=1 && break
    fi
done

# 候选2: 网络下载（逐个验证）
if [ "$FW_OK" -eq 0 ]; then
    for u in "$FW_URL" "$FW_URL2"; do
        curl -fL --retry 2 --max-time 90 -o /tmp/fw_candidate.bin "$u" 2>/dev/null || continue
        if check_fw /tmp/fw_candidate.bin; then
            cp /tmp/fw_candidate.bin "$OUT/mt7601u.bin" && FW_OK=1 && break
        fi
    done
fi

# 候选3: git clone 官方 linux-firmware 仓库（云端网络好），只取单个文件
if [ "$FW_OK" -eq 0 ]; then
    echo "尝试 git clone 官方 firmware 仓库..."
    rm -rf /tmp/linux-firmware
    if git clone --depth 1 --filter=blob:none --sparse \
        https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git \
        /tmp/linux-firmware 2>/dev/null; then
        ( cd /tmp/linux-firmware && git sparse-checkout set mt7601u.bin 2>/dev/null ) || true
        if [ -f /tmp/linux-firmware/mt7601u.bin ] && check_fw /tmp/linux-firmware/mt7601u.bin; then
            cp /tmp/linux-firmware/mt7601u.bin "$OUT/mt7601u.bin" && FW_OK=1
        fi
    fi
fi

# 候选4: 从 MediaTek 原厂驱动源码仓库取（embedded firmware）
if [ "$FW_OK" -eq 0 ]; then
    echo "尝试从 openwrt mt76 仓库取固件..."
    for p in "mt7601u.bin" "firmware/mt7601u.bin"; do
        curl -fL --retry 2 --max-time 90 -o /tmp/fw_candidate.bin \
            "https://raw.githubusercontent.com/openwrt/mt76/master/$p" 2>/dev/null || continue
        if check_fw /tmp/fw_candidate.bin; then
            cp /tmp/fw_candidate.bin "$OUT/mt7601u.bin" && FW_OK=1 && break
        fi
    done
fi

if [ "$FW_OK" -eq 0 ]; then
    echo "[警告] 未获取到有效固件，本次只发布 ko；固件将单独处理。"
    rm -f "$OUT/mt7601u.bin"
else
    echo "固件已就绪: $(stat -c %s "$OUT/mt7601u.bin") 字节"
fi

step "校验产物"
for ko in "$OUT"/*.ko; do
    echo "--- $(basename "$ko") ---"
    ls -lh "$ko" | awk '{print "大小:", $5}'
    command -v modinfo >/dev/null && modinfo -F vermagic "$ko" || true
    python3 "$ROOT/scripts/check_versions.py" "$ko" "$SYMVERS" || true
done

step "完成"
ls -lh "$OUT"
