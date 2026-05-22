# Changelog

## [Unreleased]

### Changed

- **help_panel：action 名 snake_case → 空格分隔**：渲染时自动将 `cd_to` 显示为 `cd to`，不影响 actions 表查表逻辑
- **help_panel：`<C-X>` → `<C-x>` 归一化**：Neovim 对 Ctrl 键统一存大写，渲染时还原为小写（Ctrl 不区分大小写）；`<M->`/`<S->` 保持原样

### Added

- **fs.load_json / fs.save_json**：通用 JSON 持久化工具，支持文件路径读写和 JSON 字符串解析，文件不存在自动返回空表，父目录不存在自动创建