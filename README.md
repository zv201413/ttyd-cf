# ttyd-cf

{一键部署 ttyd + cf隧道 实现内网穿透}

**版本**: v1.0.1
**技术栈**: ttyd cloudflared

## 🌟 核心特色

- 一键部署 ttyd Web 终端
- 支持 Cloudflare Argo Tunnel 内网穿透
- 使用 Supervisor 管理服务进程
- 支持自定义端口、用户名、密码

---

## 🚀 使用方法

### 在线配置

访问 `index.html` 可视化配置参数，生成一键部署命令。

### 手动部署

```bash
export TTYD_PORT=7681
export TTYD_USER=root
export TTYD_PASS=password
export CF_TOKEN='your_cloudflare_token'

bash <(curl -Ls https://raw.githubusercontent.com/zv201413/ttyd-cf/main/ttyd-cf.sh)
```

### 参数说明

| 环境变量 | 默认值 | 说明 |
|:---|:---:|:---|
| TTYD_PORT | 7681 | ttyd 端口 |
| TTYD_USER | ttyd | 登录用户名 |
| TTYD_PASS | password | 登录密码 |
| CF_TOKEN | - | Cloudflare Token（可选） |

---

## ❓ 常见问题

### Q: 如何配置代理？
A: 在仓库 Secrets 中添加 `PROXY_URL`。

---

**文档更新时间**: 2026-04-27 16:56
