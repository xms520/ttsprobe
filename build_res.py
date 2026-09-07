#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
TTSFloat 资源头生成器（CI 上跑，避免把 100KB+ 的 C 数组写进源码）
输入：pm_res_ball2.jpg（悬浮球/面板头像，居中正方形裁切 192px）
      pm_res_tip2.jpg （打赏二维码，1024px）
输出：tts_res_ball.h / tts_res_tip.h
"""
import os
import sys


def gen(src, dst, name):
    with open(src, 'rb') as f:
        data = f.read()
    tokens = [str(b) for b in data]
    with open(dst, 'w') as f:
        f.write('/* auto-generated from %s (%d bytes) by build_res.py */\n' % (src, len(data)))
        f.write('static const unsigned char %s[] = {\n' % name)
        for i in range(0, len(tokens), 24):
            f.write(','.join(tokens[i:i + 24]) + ',\n')
        f.write('};\n')
        f.write('static const unsigned int %s_LEN = %d;\n' % (name, len(data)))
    print('%s <- %s (%d bytes)' % (dst, src, len(data)))


if __name__ == '__main__':
    ok = True
    for src, dst, name in [('pm_res_ball2.jpg', 'tts_res_ball.h', 'TTS_RES_BALL'),
                           ('pm_res_tip2.jpg', 'tts_res_tip.h', 'TTS_RES_TIP')]:
        if not os.path.exists(src):
            print('!! missing %s' % src)
            ok = False
            continue
        gen(src, dst, name)
    sys.exit(0 if ok else 1)
