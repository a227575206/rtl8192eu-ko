#!/bin/bash
# 编译静态链接、无 HIDL 依赖的 wpa_supplicant，用于替换 E900V22D 上崩溃的 Android HIDL 版
# 全部输出 tee 到 build.log，失败时也能从 artifact 看到
set -o pipefail
exec > >(tee -a build.log) 2>&1

CC=arm-linux-gnueabihf-gcc
PREFIX=/opt/arm-static
mkdir -p out_wpa "$PREFIX"
cd out_wpa

echo "=== 1. 下载 libnl 源码（静态编译，供 nl80211 使用） ==="
if [ ! -d libnl-3.5.0 ]; then
  (curl -fsSL --max-time 120 -o libnl.tar.gz "https://www.infradead.org/~tgr/libnl/files/libnl-3.5.0.tar.gz" \
    || curl -fsSL --max-time 120 -o libnl.tar.gz "https://github.com/thom311/libnl/releases/download/libnl3_5_0/libnl-3.5.0.tar.gz") \
    && tar xzf libnl.tar.gz
fi
if [ -d libnl-3.5.0 ] && [ ! -f "$PREFIX/lib/libnl-3.a" ]; then
  cd libnl-3.5.0
  ./configure --host=arm-linux-gnueabihf --prefix="$PREFIX" \
      --enable-static --disable-shared --disable-python 2>&1 | tail -15
  make -j4 2>&1 | tail -10
  make install 2>&1 | tail -10
  cd ..
fi
echo "LIBNL_A=$(ls -l $PREFIX/lib/libnl-3.a 2>&1)"

echo "=== 2. 下载 wpa_supplicant 源码 ==="
if [ ! -d wpa_supplicant ]; then
  curl -fsSL --max-time 120 -o wpa.tar.gz "https://w1.fi/releases/wpa_supplicant-2.10.tar.gz" \
    || curl -fsSL --max-time 120 -o wpa.tar.gz "https://github.com/hostap/wpa_supplicant/archive/refs/tags/wpa_supplicant-2.10.tar.gz"
  tar xzf wpa.tar.gz
  if [ -d wpa_supplicant-2.10 ]; then mv wpa_supplicant-2.10 wpa_supplicant; fi
fi
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

echo "=== 4. 交叉编译（全静态） ==="
export CFLAGS="-O2 -march=armv7-a -I$PREFIX/include -static -static-libgcc"
export LDFLAGS="-static -static-libgcc -L$PREFIX/lib"
make CC=$CC -j4 2>&1 | tail -50
RC=${PIPESTATUS[0]}
echo "MAKE_RC=$RC"

echo "=== 5. 校验产物 ==="
if [ -f wpa_supplicant ]; then
  $(${CC%-gcc}-strip wpa_supplicant 2>/dev/null || true)
  ls -lh wpa_supplicant
  file wpa_supplicant
  cp wpa_supplicant ../wpa_supplicant_static
  echo "BUILD_OK"
else
  echo "BUILD_FAIL: no binary"
  exit 1
fi
