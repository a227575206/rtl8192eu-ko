#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
校验编出来的 8192eu.ko 是否真能被目标内核接受。

检查三件事：
  1. vermagic 是否等于真机的 "4.9.y SMP preempt mod_unload modversions ARMv7"
  2. __versions 段里每条 CRC 是否与真机符号表一致
  3. 模块引用了、但真机符号表里没有的符号 —— 这类符号缺 CRC，
     内核加载时必然报 "no symbol version for xxx"

退出码: 0 全通过 / 1 有问题
"""
import struct
import sys

MODULE_NAME_LEN = 60          # 4.9: 64 - sizeof(unsigned long)，32 位下为 60
REC = 4 + MODULE_NAME_LEN     # 64

SHN_UNDEF = 0


def read_sections(data):
    if data[:4] != b'\x7fELF':
        raise SystemExit('不是 ELF 文件')
    if data[4] != 1:
        raise SystemExit('不是 32 位 ELF（class=%d）' % data[4])
    e_shoff = struct.unpack_from('<I', data, 0x20)[0]
    e_shentsize = struct.unpack_from('<H', data, 0x2E)[0]
    e_shnum = struct.unpack_from('<H', data, 0x30)[0]
    e_shstrndx = struct.unpack_from('<H', data, 0x32)[0]
    shs = []
    for i in range(e_shnum):
        f = struct.unpack_from('<IIIIIIIIII', data, e_shoff + i * e_shentsize)
        shs.append(dict(name_off=f[0], type=f[1], offset=f[4], size=f[5],
                        link=f[6], entsize=f[9], name=''))
    if e_shstrndx < len(shs):
        base = shs[e_shstrndx]['offset']
        for s in shs:
            end = data.index(b'\0', base + s['name_off'])
            s['name'] = data[base + s['name_off']:end].decode('utf-8', 'replace')
    return shs


def parse_versions(data, sec):
    out = {}
    if not sec:
        return out
    for p in range(sec['offset'], sec['offset'] + sec['size'] - REC + 1, REC):
        crc = struct.unpack_from('<I', data, p)[0]
        name = data[p + 4:p + 4 + MODULE_NAME_LEN].split(b'\0', 1)[0].decode('utf-8', 'replace')
        if name:
            out[name] = crc
    return out


def parse_modinfo(data, sec):
    out = {}
    if not sec:
        return out
    for item in data[sec['offset']:sec['offset'] + sec['size']].split(b'\0'):
        if not item:
            continue
        s = item.decode('utf-8', 'replace')
        if '=' in s:
            k, v = s.split('=', 1)
            out[k] = v
        else:
            out[s] = ''
    return out


def parse_undef(data, shs):
    """取出模块引用但未定义（外部依赖）的全局符号"""
    symtab = next((s for s in shs if s['name'] == '.symtab'), None)
    if not symtab:
        return set()
    strtab = shs[symtab['link']]
    base = strtab['offset']
    out = set()
    for i in range(symtab['size'] // 16):
        p = symtab['offset'] + i * 16
        st_name, st_value, st_size, st_info, st_other, st_shndx = \
            struct.unpack_from('<IIIBBH', data, p)
        if st_shndx != SHN_UNDEF:
            continue
        bind = st_info >> 4
        if bind not in (1, 2):        # 只关心 GLOBAL / WEAK
            continue
        end = data.index(b'\0', base + st_name)
        name = data[base + st_name:end].decode('utf-8', 'replace')
        if name:
            out.add(name)
    return out


def load_symvers(path):
    out = {}
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            parts = line.split('\t')
            if len(parts) >= 4:
                try:
                    out[parts[1]] = int(parts[0], 16)
                except ValueError:
                    pass
    return out


def main():
    if len(sys.argv) < 3:
        print('用法: check_versions.py <xxx.ko> <Module.symvers>')
        return 2
    ko_path, sv_path = sys.argv[1], sys.argv[2]
    with open(ko_path, 'rb') as f:
        data = f.read()
    shs = read_sections(data)
    sec = {s['name']: s for s in shs}

    info = parse_modinfo(data, sec.get('.modinfo'))
    vermagic = info.get('vermagic', '(无)')
    versions = parse_versions(data, sec.get('__versions'))
    undef = parse_undef(data, shs)
    real = load_symvers(sv_path)

    ok = True
    print('  vermagic : %s' % vermagic)
    if vermagic.strip() != '4.9.y SMP preempt mod_unload modversions ARMv7':
        print('  [警告] vermagic 与真机不一致！真机为: 4.9.y SMP preempt mod_unload modversions ARMv7')
        ok = False

    print('  __versions 条目: %d' % len(versions))
    mismatch = []
    for sym, crc in versions.items():
        if sym in real and real[sym] != crc:
            mismatch.append((sym, crc, real[sym]))
    if mismatch:
        ok = False
        print('  [错误] CRC 与真机不符 %d 条:' % len(mismatch))
        for sym, a, b in mismatch[:15]:
            print('      %-30s 编出=0x%08x 真机=0x%08x' % (sym, a, b))
    else:
        print('  CRC 比对 : 全部一致')

    # 关键：引用了但真机表里没有的符号
    missing = sorted(undef - set(real))
    # 模块自己内部定义的符号不算
    missing = [m for m in missing if not m.startswith('__this_module')]
    if missing:
        print('  [风险] 真机符号表中缺失 %d 条（加载会因缺 CRC 失败）:' % len(missing))
        for m in missing[:40]:
            print('      %s' % m)
        ok = False
    else:
        print('  依赖符号 : 全部命中真机符号表（%d 条外部引用）' % len(undef))

    print('  结论     : %s' % ('通过，可直接部署' if ok else '有问题，见上'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
