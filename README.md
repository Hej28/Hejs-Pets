# Hej’s Pets

Hej’s Pets 是一个轻量、原生的 macOS 桌面宠物。把照片变成会沿 Dock 和屏幕边缘爬行、可以拖拽并会做表情的小宠物。

## 功能

- 拖入 JPG、PNG 或 HEIC，也可以使用文件选择器添加照片
- 自动识别人脸，或使用矩形范围、自由圈选调整头部
- 自动检测衣服，也可以手动选择衣料纹理
- 沿 Dock 或屏幕四周爬行，支持拖拽、坠落、跳跃和舞蹈动作
- 自定义随机消息气泡、触发时间和动画帧率
- 主窗口与菜单栏均提供暂停、显示隐藏及退出入口

## 隐私

照片和生成的宠物资料仅保存在用户自己的 Mac 上，不联网、不上传。运行数据位于：

```text
~/Library/Application Support/HejPets/
```

这些本地照片和数据不会被包含在本仓库中。

## 系统要求

- macOS 13 或更高版本
- 当前构建脚本输出 Apple Silicon（arm64）版本
- 已安装 Xcode Command Line Tools

## 本地构建

```bash
./build.sh
```

生成的应用位于 `build/HejsPets.app`。应用使用临时签名，公开分发时建议使用 Apple Developer ID 签名并完成公证。

## 开源许可

MIT License。详见 [LICENSE](LICENSE)。
