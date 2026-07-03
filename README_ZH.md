# Moa

Moa 是一个专注于 Codex Desktop、Claude Desktop 和本地 Provider Bridge 工作流的 macOS 菜单栏应用。

它不包含原 Moa 的 Companion 相关功能：没有桌面宠物、AI 快捷动作、提醒事项、日记、番茄钟、MCP helper、Workflow Runner、资产上传、Dashboard、皮肤和声音资源包。

## 功能范围

- Codex 控制：Fast Mode、Remote Connections、官方账号切换、provider profile 导入导出、重启 Codex。
- Provider Bridge：本地 loopback Responses bridge，用于把 Codex 请求转发到 Chat Completions 上游，内置 DeepSeek 和常见网关 preset。
- Claude Desktop profile：写入 Claude Desktop 3P gateway profile，并复制 Claude Code 环境变量片段。
- 用量统计：基于本地 Codex / Claude session 日志估算用量，并支持每日提醒阈值。
- Moa 数据：导出/导入完整数据包、导出脱敏诊断包，并可把数据根切换到 iCloud Drive。
- 更新检查：可从主菜单检查 GitHub Releases，下载、校验并安装匹配当前 Mac 的 DMG。

## App 身份

Moa 在 bundle、数据根、provider ID 和发布产物里统一使用主 Moa 身份：

- App bundle：`Moa.app`
- Bundle ID：`com.moarliu.moa`
- SwiftPM executable product：`Moa`
- 本地数据根：`~/.moa`
- Application Support：`~/Library/Application Support/Moa`
- iCloud 数据根：`iCloud Drive/Moa`
- 数据包根目录：`MoaDataPackage/.moa`
- Provider Bridge 默认端口：`19360`
- Codex 托管 provider ID：`moa-*`
- Claude Desktop 3P config-library profile：`Moa`

Moa 在你执行切换动作时仍会写入真实的 Codex 和 Claude Desktop 配置文件；它自己的 profile 数据库、bridge token、数据包 manifest、iCloud 状态和诊断包都存放在 Moa 数据根下。

## 数据文件

Moa 的本地数据存放在：

- `~/.moa/config.toml`
- `~/.moa/auth.json`
- `~/.moa/codex_official_accounts.json`
- `~/.moa/codex-auth/accounts/*.json`
- `~/.moa/profiles.json`
- `~/.moa/provider_bridge_profiles.json`
- `~/.moa/claude_desktop_profiles.json`
- `~/.moa/usage-pricing-overrides.json`
- `~/.moa/backups`

开启 iCloud 存储后，Moa 会直接读写 `iCloud Drive/Moa`，不再读写 `~/.moa`。

## 构建

```bash
swift build
./scripts/run-tests.sh
CODE_SIGN_IDENTITY=- ./scripts/build-menu-bar-app.sh
```

构建结果会输出到 `Moa.app`。

生成 DMG：

```bash
CODE_SIGN_IDENTITY=- ./scripts/package-dmg.sh
```

DMG 会输出到 `dist/Moa-<version>-macos-<arch>.dmg`，并生成匹配的 SHA-256 文件。

## Codex 本地运行按钮

Codex app 的 Run 按钮通过以下文件接入：

- `script/build_and_run.sh`
- `.codex/environments/environment.toml`

脚本会构建 `Moa.app`，停止正在运行的 Moa 进程，然后启动新 bundle。

## 安全说明

- Provider API key 和 bridge token 只保存在本地。
- Provider Bridge 只监听 `127.0.0.1`。
- 诊断包会脱敏 auth、key、token 字段。
- 打包脚本会拒绝把 `.moa`、`.codex`、auth/config/profile 文件、环境变量文件和签名密钥打进发布包。
- Moa 不打包 `MoaMCP`，也不暴露本地 workflow tools。
