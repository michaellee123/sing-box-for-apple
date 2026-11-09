# sing-box-for-apple (SFM fork)

这是 [SagerNet/sing-box-for-apple](https://github.com/SagerNet/sing-box-for-apple) 的分支，保留上游的 iOS、macOS 和 tvOS 客户端代码，主要维护 macOS 的 **SFM** 独立分发版本。

## 本分支相对上游的扩展

- **独立版分发**：提供 Developer ID 签名、公证的 `SFM.app`，使用 macOS 系统扩展和 root helper，支持按应用路由。
- **智能分组**：支持自动/手动选择节点、按域名和按应用指定分组、分组测速、拖动排序、删除确认，以及策略导入/导出。
- **高级路由**：支持按域名、应用和 IP 段强制接管或强制放行，并提供正在运行应用的图形化选择器。
- **白名单模式**：只代理强制接管列表中的应用和域名，其余流量全部直连。
- **更可靠的按应用路由**：改进 macOS 进程归属查询，通过用户态 XPC 处理用户应用，并由 root helper 兜底 root 进程。
- **固定隧道策略**：Packet Tunnel 参数按既定默认值固定，设置页开关只读，不提供重置操作。
- **手动 DMG 更新**：检查本仓库 GitHub Releases 中的 DMG，下载后打开 DMG，由用户手动拖入 Applications，不再自动安装 PKG。
- **macOS 界面优化**：采用原生 Liquid Glass 样式，修复侧边栏宽度和透明材质，并在配置变更后显示重连提示。

## 下载

已签名和公证的安装包发布在：

<https://github.com/michaellee123/sing-box-for-apple/releases>

## 上游文档

[SFI](https://sing-box.sagernet.org/installation/clients/sfi/) | [SFM](https://sing-box.sagernet.org/installation/clients/sfm/)

## 构建

构建和签名配置沿用上游工程。macOS 独立版使用 `SFM.System` scheme 和 `Release` 配置构建。

## License

```
Copyright (C) 2022 by nekohasekai <contact-sagernet@sekai.icu>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <http://www.gnu.org/licenses/>.
```
