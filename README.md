# RTL8192EU 驱动编译（创维 E900V22D / Amlogic p291）

给一台 Android 9 电视盒子（`p291_iptv`，armv7l，内核 `Linux 4.9.113`）补上
RTL8192EU（`USB\VID_0BDA&PID_818B`）USB 无线网卡的驱动模块。

盒子 `/vendor/lib/modules/` 里自带 60 多个原厂 .ko，唯独没有 `8192eu.ko`，
所以网卡插上能识别出硬件，但没有网卡接口可用。

## 为什么不能直接下个现成的 .ko

盒子内核编译时开了 `CONFIG_MODVERSIONS=y`，模块加载时内核会逐个核对它引用的
每个符号的 CRC 值。随便找来的 `8192eu.ko` 一定会在
`disassociates about version of symbol xxx` 这一步被拒绝，没有例外。

所以必须按这个内核自己编。

## 关键做法：跳过"编译整个内核"

正常流程要编一遍完整的 4.9.113 内核来生成 `Module.symvers`，非常慢，而且
运营商标定的内核源码根本拿不到，编出来的 CRC 也未必对得上。

这里换了个路子：

1. 把盒子里 **66 个原厂 .ko 全抓下来**，解析每个模块的 `__versions` 段；
2. 每个原厂模块的 `__versions` 里都记录着"它引用的符号 → 本内核的真实 CRC"；
3. 66 个模块合并去重得到 **1212 条真实符号 CRC**（已交叉验证一致，无矛盾）；
4. 把这 1212 条直接写成 `Module.symvers` 喂给 modpost。

这样编出来的 `8192eu.ko`，`__versions` 段一开始就是正确的，不需要事后打补丁，
也完全绕开了"要有一份一模一样的内核源码"这个死结。

`config/kernel.config` 是直接从盒子 `/proc/config.gz` 抓的，所以 SMP、PREEMPT、
CFG80211、MAC80211 这些影响 vermagic 和结构体布局的选项都和真机一致。

vermagic 目标值：`4.9.y SMP preempt mod_unload modversions ARMv7`

## 目录

```
.github/workflows/build.yml   GitHub Actions 流水线
config/kernel.config          真机内核配置（/proc/config.gz 解压）
config/Module.symvers         1212 条真机符号 CRC
scripts/build.sh              编译主脚本
scripts/check_versions.py     产物校验（vermagic / CRC / 缺失符号）
```

## 怎么跑

在 GitHub 上建一个 **Public** 空仓库，把本目录推上去，然后：

- 打开仓库的 **Actions** 标签页
- 左边选 `build-8192eu`，右侧点 **Run workflow**
- 等 10～20 分钟（首次要下载内核源码）
- 跑完后在该次运行页面底部下载 **rtl8192eu-ko** 这个 artifact

日志里会打印校验结果，正常应该看到：

```
  vermagic : 4.9.y SMP preempt mod_unload modversions ARMv7
  CRC 比对 : 全部一致
  依赖符号 : 全部命中真机符号表
  结论     : 通过，可直接部署
```

如果出现「真机符号表中缺失 N 条」，把那几条符号名发回来，补进
`config/Module.symvers` 后重跑即可（补的值需要从盒子其他模块或内核里取）。

## 拿到 ko 之后怎么装

先手动试加载，别急着做开机自启：

```bash
adb push 8192eu.ko /data/local/tmp/
adb shell su -c "mount -o rw,remount /vendor"
adb shell su -c "cp /data/local/tmp/8192eu.ko /vendor/lib/modules/8192eu.ko"
adb shell su -c "chmod 644 /vendor/lib/modules/8192eu.ko"
adb shell su -c "insmod /vendor/lib/modules/8192eu.ko"
adb shell su -c "dmesg | tail -30"
adb shell su -c "ifconfig -a"
```

加载成功的话 `ifconfig -a` 里会多出一个 `wlan1`，`dmesg` 里能看到
`usbcore: registered new interface driver rtl8192eu`。

失败了 `dmesg` 会明确写原因，常见几种：

| 报错 | 含义 |
|---|---|
| `disagrees about version of symbol X` | 该符号 CRC 不对，补符号表 |
| `no symbol version for X` | 符号表缺这一条 |
| `Unknown symbol X` | 内核根本没导出这个符号 |
| `-12` / `ENOMEM` | 内存不够，与本方案无关 |

## 已知前提

- 内核 `CONFIG_MODULE_SIG` 未开，不需要签名
- `CONFIG_RTL8XXXU` 未开，不会和主线驱动抢设备
- 网卡固件由驱动内嵌，不依赖 `/vendor/firmware`
- 盒子 shell 直接是 root，`/vendor` 是 ext4，可以 remount 成可写
