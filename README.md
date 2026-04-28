# ttyd-cf

一键部署 ttyd + cf隧道 实现内网穿透
[参数面板](https://zv201413.github.io/ttyd-cf/)
**版本**: v1.0.6
**技术栈**: ttyd, cloudflared, supervisor, bash

## 🌟 核心特色

- 一键部署 ttyd Web 终端
- 支持 Cloudflare Argo Tunnel 内网穿透
- 支持单实例/多实例部署模式
- 增加 del (卸载) 和 rep (覆盖) 功能
- 可视化 index.html 配置生成器

---

## 🚀 快速开始

### 1. 在线配置
打开项目中的 `index.html`，可视化配置参数并生成一键命令。

### 2. 手动部署
```bash
export TTYD_PORT=7681
export TTYD_USER=root
export TTYD_PASS=password
export CF_TOKEN='your_token'

bash <(curl -Ls https://raw.githubusercontent.com/zv201413/ttyd-cf/main/ttyd-cf.sh)
```

### 3. 操作模式
- **rep**: 覆盖更新 (不删用户，只更新进程和配置)
- **del**: 完全卸载 (清理进程与配置文件)

---

**文档更新时间**: 2026-04-28
