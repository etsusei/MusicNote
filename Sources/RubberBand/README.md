# Rubber Band Library（随仓库带的第三方源码）

`vendor/` 里是 [Rubber Band Library](https://breakfastquay.com/rubberband/) 4.0.0 的源码，原样复制，没有改动：

- `vendor/single/RubberBandSingle.cpp`：单文件编译入口，SwiftPM 只编译这一个文件，它再把 `vendor/src` 里的源码包含进来
- `vendor/rubberband/`：库的头文件
- `vendor/src/`：库的源码（去掉了用不到的 `jni` 和 `test`）
- `vendor/COPYING`：GPL v2 许可证全文

`include/rubberband-c.h` 是 `vendor/rubberband/rubberband-c.h` 的副本，Swift 通过它调用 C 接口。

## 许可证

Rubber Band Library 以 GNU GPL（第 2 版或更新）发布，版权属于 Particular Programs Ltd。Musicnote 链接了它，所以带着它一起编译出来的程序整体也要按 GPL 的条件使用和分发。

## 升级

从 <https://github.com/breakfastquay/rubberband/releases> 下载新版本，按上面的目录替换 `vendor/` 里的内容，再把 `rubberband-c.h` 复制到 `include/`。
