#!/bin/bash
# 编译 wpa_supplicant armv7，替换 E900V22D 上崩溃的 Android HIDL 版
# 关键诊断：所有输出同时写进 $GITHUB_STEP_SUMMARY，失败也能在 Actions 页面直接看到
set -o pipefail

CC=arm-linux-gnueabihf-gcc
PREFIX=/opt/arm-static
mkdir -p out_wpa "$PREFIX"
cd out_wpa

echo "=== 1. 下载 libnl 源码 ==="
DL_OK=0
for URL in \
  "https://www.infradead.org/~tgr/libnl/files/libnl-3.5.0.tar.gz" \
  "https://github.com/thom311/libnl/releases/download/libnl3_5_0/libnl-3.5.0.tar.gz" \
  "https://src.fedoraproject.org/repo/pkgs/libnl3/libnl-3.5.0.tar.gz/sha512/libnl-3.5.0.tar.gz"; do
  echo "TRY $URL"
  if curl -fsSL --max-time 90 -o libnl.tar.gz "$URL"; then DL_OK=1; echo "DOWNLOAD_OK"; break; fi
done
if [ "$DL_OK" = 1 ]; then
  tar xzf libnl.tar.gz 2>&1 | tail -3
  cd libnl-3.5.0
  echo "=== configure libnl ==="
  ./configure --host=arm-linux-gnueabihf --prefix="$PREFIX" --enable-static --disable-shared --disable-python > cfg.log 2>&1
  echo "CFG_RC=$?"; tail -20 cfg.log; grep -iE "error|not found|cannot" cfg.log | tail -8 | while read -r L; do echo "::error::LIBNL_CFG $L"; done
  echo "=== make libnl ==="
  make -j4 > mk.log 2>&1; echo "MAKE_RC=$?"; tail -30 mk.log; grep -iE "error|undefined|cannot" mk.log | tail -8 | while read -r L; do echo "::error::LIBNL_MAKE $L"; done
  make install > inst.log 2>&1; echo "INST_RC=$?"; tail -15 inst.log
  cd ..
fi
echo "LIBNL_A=$(ls -l $PREFIX/lib/libnl-3.a 2>&1)"

echo "=== 2. 下载 wpa_supplicant 源码 ==="
for URL in \
  "https://w1.fi/releases/wpa_supplicant-2.10.tar.gz" \
  "https://github.com/hostap/wpa_supplicant/archive/refs/tags/wpa_supplicant-2.10.tar.gz"; do
  echo "TRY $URL"
  if curl -fsSL --max-time 90 -o wpa.tar.gz "$URL"; then echo "DOWNLOAD_OK"; break; fi
done
tar xzf wpa.tar.gz 2>&1 | tail -3
[ -d wpa_supplicant-2.10 ] && mv wpa_supplicant-2.10 wpa_supplicant
cd wpa_supplicant/wpa_supplicant

echo "=== 3. 生成 .config ==="
cp defconfig .config
cat >> .config <<'EOF'
CONFIG_DRIVER_NL80211=y
CONFIG_DRIVER_WEXT=n
CONFIG_WPA=y
CONFIG_IEEE80211W=y
CONFIG_CTRL_IFACE=y
CONFIG_CTRL_IFACE_UNIX=y
CONFIG_EAP=y
CONFIG_TLS=internal
CONFIG_INTERNAL_LIBTOMMATH=y
CONFIG_NO_LINUX_PACKET_SOCKET_WAR=y
EOF

echo "=== 4. 编译 ==="
export CFLAGS="-O2 -march=armv7-a -I$PREFIX/include"
export LDFLAGS="-static -static-libgcc -L$PREFIX/lib"
make CC=$CC -j4 > make.log 2>&1
RC=$?
echo "MAKE_RC=$RC"
tail -60 make.log
grep -iE "error|undefined reference|No such file|cannot find|fatal error" make.log | tail -12 | while read -r L; do echo "::error::WPA_MAKE $L"; done

echo "=== 5. 校验 ==="
if [ -f wpa_supplicant ]; then
  arm-linux-gnueabihf-strip wpa_supplicant
  ls -lh wpa_supplicant
  file wpa_supplicant
  cp wpa_supplicant ../wpa_supplicant_static
  echo "BUILD_OK"
else
  echo "BUILD_FAIL: no binary"
  exit 1
fi
