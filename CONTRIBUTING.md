# 参与 Hej’s Pets

欢迎报告问题、提出想法或提交改进。

1. 先查看现有 Issues，避免重复。
2. 报告问题时写明 macOS 或 Windows 版本、操作步骤、预期效果和实际效果。
3. 修改代码后在 Apple Silicon Mac 上运行 `./build.sh`，确认可以构建。
4. 提交尽量聚焦于一个问题，并说明改动与验证方法。

## 在 VS Code 中提交修改

1. 用 VS Code 打开本仓库文件夹。开始修改前，在「源代码管理」的 `…` 菜单中选择「拉取」（Pull）。
2. 编辑并保存文件。打开左侧「源代码管理」，点击文件名查看修改前后的对比。
3. 点击要提交的文件旁边的 `+` 暂存修改，填写简短的提交说明，再点击「提交」（Commit）。
4. 在 `…` 菜单中选择「推送」（Push），把本地提交上传到 GitHub。提交只保存在本机，推送后才会出现在 GitHub。

如果没有仓库写入权限，请先在 GitHub 上 Fork 仓库，在自己的分支修改并推送，然后向本仓库发起 Pull Request。

请不要在 Issues、Pull Requests、日志或测试文件中上传真人照片、裁切结果、`~/Library/Application Support/HejPets/` 中的数据，以及任何账号或设备敏感信息。需要演示时请使用你有权公开的测试图片。

## Windows 开发验证

请按 [Windows 说明](windows/README.md) 安装依赖并运行测试。GitHub Actions 在 Windows x64 上运行单元/界面测试、真实窗口启动、打包后 exe 启动，以及静默安装/卸载检查。所有测试使用可公开的合成图片，不使用个人照片。动作渲染沿用原 Swift 路径，涉及人物识别时需要同时说明 Windows/OpenCV 与 macOS/Vision 的算法差异。
