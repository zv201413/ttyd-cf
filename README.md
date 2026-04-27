# ProjectName

{一句话描述}

**版本**: v1.0.0
**技术栈**: Node.js 22

## 🌟 核心特色



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

### 多实例部署

```bash
export TTYD_P1=7681:root1:pass1:token1
export TTYD_P2=7682:root2:pass2:token2

bash <(curl -Ls https://raw.githubusercontent.com/zv201413/ttyd-cf/main/ttyd-cf.sh)
```

### 参数说明

| 环境变量 | 默认值 | 说明 |
|:---|:---:|:---|
| TTYD_PORT | 7681 | ttyd 端口（单实例） |
| TTYD_USER | ttyd | 登录用户名 |
| TTYD_PASS | password | 登录密码 |
| CF_TOKEN | - | Cloudflare Token |
| TTYD_P1/P2... | - | 多实例配置（格式: 端口:用户:密码:Token） |

---

## ❓ 常见问题

### Q: 如何获取 CF Token？
A: 在 Cloudflare Zero Trust 控制台 → Access → Tunnels 创建隧道，获取 Token。

---

**文档更新时间**: 2026-04-27
