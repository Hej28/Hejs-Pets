# Hej’s Pets · Windows

Windows 10/11 x64 客户端，移植自同仓库 macOS 4.1 版。主窗口沿用原版 560×610 布局、奶油与鼠尾草绿配色；宠物沿用 214×214 透明窗口、身体曲线路径、动作与物理参数、默认气泡文字。Dock 爬行对应 Windows 任务栏上沿，菜单栏对应系统托盘。

## 使用

正式构建提供两种形式：

- `HejsPets-4.1.0-Windows-Setup.exe`：按用户安装，不需要管理员权限，建立开始菜单入口，可选桌面快捷方式。
- `HejsPets-4.1.0-Windows-Portable.zip`：完整解压后运行文件夹内 `HejsPets.exe`。不能只复制其中的 exe；旁边的 `_internal` 是运行库。无需安装 Python。

关闭宠物屋会退出应用和所有宠物。最小化窗口后可通过系统托盘恢复。没有开机自启、联网服务或账户。

## 功能与平台差异

照片多选/拖入（每次最多 8 张）、多宠物、显示/隐藏、删除、自动头部裁切、可移动/缩放的矩形选区、填满内部的自由圈选、补选涂抹、橡皮擦、撤销、衣服纹理、五种动作、拖拽/掉落/回弹/点击反馈、五官表情、气泡与 15/24/30/45/60 FPS 设置均已移植。

原版使用 Apple Vision 做人像分割和五官检测。Windows 使用随应用携带的 OpenCV 人脸/眼睛检测与 GrabCut 分割，嘴部位置依人脸估算；此处算法不同，不能承诺新导入照片的自动裁切与 macOS 逐像素一致。可用手动选区修正。照片和处理过程均留在本机。系统字体、标题栏和任务栏也存在系统差异。当前版本不声称已经完成实体 Windows 电脑上的逐项验收；构建和自动检查记录见 GitHub Actions。

## 数据与从 Mac 迁移

Windows 保存位置：`%LOCALAPPDATA%\HejPets\`，内有 `pets.json`、`settings.json` 和 `Images\`。卸载默认保留照片与宠物数据。删除宠物仅删除应用副本。

要保留 Mac 上已经修好的头部和衣服：退出两端应用，复制 Mac 的 `~/Library/Application Support/HejPets/` 整个目录到上述 Windows 路径。现有 `pets.json` 与头部/纹理图片可直接读取，原有透明裁切不会重新生成。互动设置在 Mac 的系统偏好中，需在 Windows「互动设置」中重新填写。复制私人数据时不要放入 GitHub。

## 开发

要求 Python 3.11（Windows x64），建议独立环境：

```powershell
cd windows
py -3.11 -m venv .venv
.venv\Scripts\python -m pip install -r requirements.txt
.venv\Scripts\python run.py
.venv\Scripts\python -m unittest discover -s tests -v
```

`HEJPETS_DATA_DIR` 或 `--data-dir` 可指定隔离数据目录。开发预览支持 macOS，默认使用 `HejPets-Windows-Preview`，不会写入原 Mac 宠物数据。

UI 自动测试只使用生成的几何图案与纯色 HEIC，不含真人照片。HEIC 测试覆盖解码导入；应用不编码 HEIC。
