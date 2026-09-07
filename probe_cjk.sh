#!/bin/bash
set -e
cat > /tmp/cjktest.m <<'M'
#import <Foundation/Foundation.h>
int main(){ @autoreleasepool { NSLog(@"填 %@ ok-marker-ascii", @"x"); } return 0; }
M
xcrun -sdk iphoneos clang -arch arm64 -fobjc-arc -dynamiclib -framework Foundation -o /tmp/cjktest.dylib /tmp/cjktest.m
ls -la /tmp/cjktest.dylib
python3 - <<'PY'
d=open('/tmp/cjktest.dylib','rb').read()
print('utf8 填 count', d.count('填'.encode()))
print('ok-marker-ascii', d.count(b'ok-marker-ascii'))
PY
