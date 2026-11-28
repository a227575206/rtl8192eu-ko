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
# 关键：defconfig 默认开 DBus，必须彻底删除，否则缺 dbus.h 编译失败
sed -i '/DBUS/d' .config
cat >> .config <<'EOF'
CONFIG_DRIVER_NL80211=y
CONFIG_DRIVER_WEXT=n
CONFIG_LIBNL32=y
CONFIG_WPA=y
CONFIG_IEEE80211W=y
CONFIG_CTRL_IFACE=y
CONFIG_CTRL_IFACE_UNIX=y
CONFIG_EAP=y
CONFIG_TLS=internal
CONFIG_INTERNAL_LIBTOMMATH=y
CONFIG_NO_LINUX_PACKET_SOCKET_WAR=y
EOF
echo "DBUS_LINES=$(grep -c DBUS .config)"
echo "CONFIG_SUMMARY:"; grep -E "^CONFIG_(DRIVER|TLS|CTRL_IFACE|LIBNL)" .config

echo "=== 4. 编译 ==="
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PKG_CONFIG_PATH"
export CFLAGS="-O2 -march=armv7-a -I$PREFIX/include -I$PREFIX/include/libnl3"
export LDFLAGS="-static -static-libgcc -L$PREFIX/lib"
export LIBS="-lnl-3 -lnl-genl-3"
make CC=$CC -j4 > make.log 2>&1
RC=$?
echo "MAKE_RC=$RC"
tail -60 make.log
grep -iE "error|undefined reference|No such file|cannot find|fatal error" make.log | tail -12 | while read -r L; do echo "::error::WPA_MAKE $L"; done
# 把完整日志写进 Release body（curl 调 GitHub API，无需第三方 action）
{
  echo "BUILD FAILED - diagnostic log"
  echo ""
  echo '```'
  echo "--- cfg.log ---"; tail -30 cfg.log 2>/dev/null
  echo "--- mk.log ---"; tail -30 mk.log 2>/dev/null
  echo "--- make.log ---"; tail -80 make.log 2>/dev/null
  echo '```'
} > /tmp/wpa_diag.txt 2>/dev/null || true
if [ -n "$GITHUB_TOKEN" ]; then
  python3 - <<'PY2'
import json,os,urllib.request
token=os.environ.get('GITHUB_TOKEN','')
repo=os.environ.get('GITHUB_REPOSITORY','')
body=open('/tmp/wpa_diag.txt').read() if os.path.exists('/tmp/wpa_diag.txt') else 'no log'
data=json.dumps({'tag_name':'wpa-diag-latest','name':'wpa build diagnostic','body':body[:60000]}).encode()
req=urllib.request.Request(f'https://api.github.com/repos/{repo}/releases',data=data,
  headers={'Authorization':f'Bearer {token}','Accept':'application/vnd.github+json','Content-Type':'application/json'})
try:
    r=urllib.request.urlopen(req,timeout=30); print('DIAG_RELEASE_OK',r.status)
except Exception as e:
    # tag 已存在则更新
    try:
        rr=urllib.request.urlopen(urllib.request.Request(f'https://api.github.com/repos/{repo}/releases/tags/wpa-diag-latest',
          headers={'Authorization':f'Bearer {token}','Accept':'application/vnd.github+json'}),timeout=20)
        rel=json.load(rr); rid=rel['id']
        req2=urllib.request.Request(f'https://api.github.com/repos/{repo}/releases/{rid}',data=json.dumps({'body':body[:60000]}).encode(),
          method='PATCH',headers={'Authorization':f'Bearer {token}','Accept':'application/vnd.github+json','Content-Type':'application/json'})
        urllib.request.urlopen(req2,timeout=30); print('DIAG_UPDATE_OK')
    except Exception as e2: print('DIAG_FAIL',e,e2)
PY2
fi

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
