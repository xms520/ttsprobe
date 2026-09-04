# TTSProbe dylib

微信文字转语音插件的诊断探针（TrollStore/巨魔 无越狱环境用）。

## 用途

不 hook / 不发送 / 不修改，只枚举微信运行时：
- `MJSilkCodec` / `CMessageWrap` / `CMessageMgr` / `MessageService` 的真实方法和类型签名
- 当前最上层 UIViewController 层级 + ivar

日志写到微信沙盒 `Documents/TTSProbe.log`，同时输出 stderr + NSLog。

## 云编译

GitHub Actions（macos-latest）自动用 Xcode 交叉编译 arm64 dylib。

手动触发：`Actions` → `build-dylib` → `Run workflow`

产物：`Actions` 运行结束后，在 `Summary` 底部下载 `TTSProbe-dylib` artifact。

或打 tag 触发 release 自动发布 `TTSProbe.dylib`。

## 源码

- `TTSProbe.m`：诊断探针源码（路径已改为微信沙盒 Documents 可写位置）

## 本地编译（有 Mac 时）

```bash
xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=12.0 \
  -fobjc-arc -fobjc-abi-version=2 \
  -dynamiclib \
  -framework Foundation -framework UIKit \
  -o TTSProbe.dylib TTSProbe.m
```
