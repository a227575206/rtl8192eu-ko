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

# 驱动的 Makefile 末尾有一行 EXTRA_CFLAGS += $(ccflags-y)，
# 与内核 scripts/Makefile.lib 里的 ccflags-y += $(EXTRA_CFLAGS) 互为引用。
# 编译阶段只 include 一次不报错，但 stage 2 重新 include 时会抛
# "Recursive variable 'ccflags-y' references itself"，导致 .ko 链接不出来。
# 所有编译选项本来就都在 ccflags-y 里，注释掉这行不影响编译结果。
step "修补驱动 Makefile 中的循环引用"
python3 - "$DRVDIR/Makefile" <<'PATCHEOF'
import sys, re
p = sys.argv[1]
src = open(p, encoding='utf-8', errors='replace').read()
new, n = re.subn(r'(?m)^(\s*EXTRA_CFLAGS\s*\+=\s*\$\(ccflags-y\)\s*)$',
                 r'# disabled-by-buildsh: \1', src)
open(p, 'w', encoding='utf-8').write(new)
print('  已注释 %d 处 EXTRA_CFLAGS += $(ccflags-y)' % n)
PATCHEOF
grep -n 'disabled-by-buildsh' "$DRVDIR/Makefile" | head -3

# ---------- 5.5 老内核兼容层 ----------
# 驱动代码按 6.x/7.x 内核维护，用到 5.0 才引入的 strscpy，4.9 内核没有。
# 用 -include 注入一个等价实现，避免逐个文件打补丁。
step "生成 4.9 兼容头"
COMPAT="$ROOT/kernel_compat.h"
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
		if (count) {
			memcpy(dest, src, count - 1);
			dest[count - 1] = '\0';
		}
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
echo "兼容头: $COMPAT"

# ---------- 6. 编译 ----------
step "编译 8192eu.ko"
mkdir -p "$OUT"
# 直接调用内核构建系统并显式传入 CONFIG_RTL8192EU=m：
#   - 走驱动 Makefile 的 else 分支会让它再递归一次 make，造成
#     "Recursive variable 'ccflags-y' references itself"；
#   - 完全不传该变量则 obj- 展开为空，得到 "MODPOST 0 modules"。
# -fno-stack-protector：内核没有向模块导出 __stack_chk_* 符号。
DRV_CFLAGS="-fno-stack-protector -include $COMPAT"
set +e
make -C "$KDIR" M="$DRVDIR" ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE \
     CONFIG_RTL8192EU=m USER_EXTRA_CFLAGS="$DRV_CFLAGS" \
     modules -j"$JOBS" 2>&1 | tee "$ROOT/build.log"
RC=${PIPESTATUS[0]}
set -e
if [ "$RC" -ne 0 ]; then
    echo "--- 编译错误摘要 ---"
    grep -iE 'error:|Error [0-9]|undefined!' "$ROOT/build.log" | head -30 || true
    if ! ls "$DRVDIR"/*.ko >/dev/null 2>&1; then
        die "驱动编译失败且无产物（build.log 已保留）"
    fi
    echo "[注意] make 返回非 0，但已产出 .ko，继续校验"
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
