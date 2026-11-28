#!/bin/bash
# 编译静态链接、无 HIDL 依赖的 wpa_supplicant，用于替换 E900V22D 上崩溃的 Android HIDL 版
set -o pipefail
mkdir -p out_wpa
cd out_wpa

echo "=== 下载 wpa_supplicant 源码 ==="
if [ ! -d wpa_supplicant ]; then
  curl -sL --max-time 120 -o wpa.tar.gz "https://w1.fi/releases/wpa_supplicant-2.10.tar.gz"
  tar xzf wpa.tar.gz
  mv wpa_supplicant-2.10 wpa_supplicant
fi
cd wpa_supplicant

echo "=== 生成 .config（nl80211 + WPA2 + 静态） ==="
cd wpa_supplicant
cp defconfig .config
cat >> .config <<'EOF'

# 静态链接，绕开 Android bionic 动态库/HIDL 依赖
CONFIG_STATIC=y
# 只需要 nl80211 驱动
CONFIG_DRIVER_NL80211=y
CONFIG_DRIVER_WEXT=n
# WPA2-PSK / RSN
CONFIG_WPA=y
CONFIG_IEEE80211W=y
# 去掉 Android/HIDL/dbus 相关
CONFIG_ANDROID=n
CONFIG_DBUS=n
CONFIG_CTRL_IFACE=y
CONFIG_CTRL_IFACE_UNIX=y
CONFIG_READLINE=n
CONFIG_WPA_CMD=n
CONFIG_EAP=y
CONFIG_TLS=internal
CONFIG_INTERNAL_LIBTOMMATH=y
EOF
cd ..

echo "=== 交叉编译（arm-linux-gnueabihf，静态） ==="
make CC=arm-linux-gnueabihf-gcc \
     CFLAGS="-O2 -static -static-libgcc -march=armv7-a" \
     LDFLAGS="-static -static-libgcc" \
     LIBS="-lnl_genl -lnl -lm" \
     -j4 2>&1 | tail -40

RC=${PIPESTATUS[0]}
echo "MAKE_RC=$RC"

if [ -f wpa_supplicant ]; then
  arm-linux-gnueabihf-strip wpa_supplicant
  cp wpa_supplicant ../wpa_supplicant_static
  ls -l ../wpa_supplicant_static
  file ../wpa_supplicant_static
  echo "BUILD_OK"
else
  echo "BUILD_FAIL: no binary"
  exit 1
fi
