# 发布流程（GitHub Release）

本仓库使用「打 tag → GitHub Actions 自动构建并发布 Release」的方式。

## 版本命名

建议使用 SemVer + 测试后缀：
- `v0.1.0-test.1`
- `v0.1.0-test.2`

## 发布步骤

1. 确认本地测试通过：
   - `swift test`

2. 更新变更记录：
   - 编辑 `CHANGELOG.md`，补充本次版本条目。

3. 创建并推送 tag：
   - `git tag v0.1.0-test.1`
   - `git push origin v0.1.0-test.1`

4. 等待 GitHub Actions 完成：
   - 工作流会在 GitHub Releases 自动创建同名 Release，并上传构建产物。

## 产物说明

Release 会包含一个 zip 包：
- `YunqiMacApp`：macOS 可执行程序（从终端运行即可启动 UI）
- `README.md` / `README.en.md` / `CHANGELOG.md`
- 示例工程：`demo.project.json`（如果存在）

> 目前为测试版，暂未做签名/公证（Gatekeeper 可能提示）。
