# discourse-geetest-captcha

基于 **极验行为验证第四代（GeeTest CAPTCHA v4，GT4）** 的 Discourse 人机验证插件。

支持在 **注册 / 登录 / 发帖回复** 三个场景接入极验验证，场景可独立开关，前端默认使用 `bind`（隐藏按钮）模式——用户点击提交按钮时才唤起验证，体验最自然。

- 仓库地址：<https://github.com/liangan772/CloudRail-loin>
- 极验 v4 接入文档：<https://docs.geetest.com/gt4/deploy/server>
- Discourse 插件开发指南：<https://meta.discourse.org/t/developer-guides-index/308036>

---

## 目录

- [功能特性](#功能特性)
- [工作原理](#工作原理)
- [目录结构](#目录结构)
- [安装](#安装)
- [配置项](#配置项)
- [安全设计](#安全设计)
- [本地演示页](#本地演示页)
- [测试](#测试)
- [常见问题](#常见问题)
- [参考文档](#参考文档)

---

## 功能特性

| 特性 | 说明 |
| --- | --- |
| 三种场景可独立开关 | 注册、登录、发帖/回复分别控制 |
| 三种展现形式 | `bind`（隐藏按钮，默认）、`popup`（弹出式）、`float`（浮动式） |
| 服务端二次校验 | 使用 `captcha_key` 生成 HMAC-SHA256 签名后调用极验 `/validate` 接口 |
| 防重放 | 基于 Redis 原子性 `SET NX EX` 消费 `lot_number`，验证结果一次性有效 |
| 容灾降级 | 极验接口超时/异常时可放行，避免验证服务故障阻断正常业务 |
| 多语言 | 验证界面语言可配，插件文案支持中英文 |
| 不暴露密钥 | `captcha_key` 标记为 `secret`，仅服务端使用，绝不下发到客户端 |

---

## 工作原理

### 整体流程（对应极验 v4 通讯流程）

```
  浏览器                        你的 Discourse 服务端                 极验服务
    │                                   │                              │
    │ 1. 加载 gt4.js，initGeetest4()    │                              │
    │───────────────────────────────────┼─────────────────────────────>│
    │                                   │                              │
    │ 2. 用户点击「提交」-> 唤起验证     │                              │
    │───────────────────────────────────┼─────────────────────────────>│
    │                                   │                              │
    │ 3. 验证通过，拿到 4 个参数：       │                              │
    │    lot_number / captcha_output    │                              │
    │    pass_token / gen_time          │                              │
    │                                   │                              │
    │ 4. 参数随业务请求一起提交          │                              │
    │──────────────────────────────────>│                              │
    │                                   │ 5. sign_token =              │
    │                                   │    HMAC-SHA256(key,lot_number)│
    │                                   │                              │
    │                                   │ 6. POST /validate            │
    │                                   │─────────────────────────────>│
    │                                   │                              │
    │                                   │ 7. {result: success/fail}    │
    │                                   │<─────────────────────────────│
    │                                   │                              │
    │ 8. 仅 result=success 才放行业务    │                              │
    │<──────────────────────────────────│                              │
```

### 前端（`assets/javascripts/`）

1. **`lib/geetest-loader.js`** —— 幂等加载 `gt4.js`，多个表单共用一次加载。
2. **`lib/geetest-widget.js`** —— 对极验实例的 Promise 封装。`show()` 唤起验证并在通过时
   resolve 出验证参数；用户关闭验证则 resolve 为 `null`。
3. **`initializers/geetest-captcha.js`** ——
   - 注册/登录：监听 `submit` 事件，先 `preventDefault()`，跑完验证再把 4 个参数写入隐藏域，
     然后 `requestSubmit()` 回放提交。
   - 发帖/回复：通过官方 `api.composerBeforeSave()` 钩子，在保存前完成验证并把参数写入
     composer 模型。

> 回放提交这一步很关键：原生 submit 会带上 CSRF token，我们只是补全隐藏域后重新触发，
> 因此不会破坏 Discourse 的鉴权链路。

### 服务端（`lib/gt4/`）

| 文件 | 职责 |
| --- | --- |
| `client.rb` | 极验 HTTP 客户端：HMAC-SHA256 签名 + `POST /validate`，并把超时/异常归一化为结果对象 |
| `validator.rb` | 编排层：参数校验 → 防重放消费 → 调极验 → 容灾降级策略 |
| `verified_store.rb` | 基于 `Discourse.redis` 的 `lot_number` 一次性消费存储（TTL 10 分钟） |
| `controller_extension.rb` | 把 4 个自定义参数加入 strong parameters，并提供 `verify_geetest!` |
| `guard.rb` | 把校验挂到 `SignupController` / `SessionController` / `PostsController` |

---

## 目录结构

```
discourse-geetest-captcha/
├── plugin.rb                              # 插件入口
├── config/
│   ├── settings.yml                       # 站点设置定义
│   └── locales/                           # 中英文文案
│       ├── client.en.yml
│       ├── client.zh_CN.yml
│       ├── server.en.yml
│       └── server.zh_CN.yml
├── lib/gt4/
│   ├── client.rb                          # 极验 API 客户端
│   ├── validator.rb                       # 二次校验编排
│   ├── verified_store.rb                  # 防重放
│   ├── controller_extension.rb            # 参数白名单 + 控制器 helper
│   └── guard.rb                           # 各端点挂载
├── assets/
│   ├── javascripts/discourse/
│   │   ├── initializers/geetest-captcha.js
│   │   └── lib/
│   │       ├── geetest-loader.js
│   │       └── geetest-widget.js
│   └── stylesheets/common/geetest-captcha.scss
├── demo/index.html                        # 独立前端演示页
└── spec/lib/                              # RSpec 测试
    ├── gt4_client_spec.rb
    └── gt4_validator_spec.rb
```

---

## 安装

### 方式一：Docker 部署（推荐）

编辑 `containers/app.yml`，在 `hooks` 之后添加：

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/liangan772/CloudRail-loin.git discourse-geetest-captcha
```

然后重建：

```bash
cd /var/discourse
./launcher rebuild app
```

### 方式二：已有插件目录

```bash
cd /var/www/discourse/plugins
git clone https://github.com/liangan772/CloudRail-loin.git discourse-geetest-captcha
```

重启 Discourse 即可。

---

## 配置项

安装后在 **管理后台 → 设置 → 插件** 中搜索 `geetest` 进行配置。

| 设置项 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `geetest_captcha_enabled` | boolean | `false` | 总开关 |
| `geetest_captcha_id` | string | — | `captcha_id`，极验后台申请 |
| `geetest_captcha_key` | secret | — | `captcha_key`，仅服务端使用 |
| `geetest_captcha_api_server` | string | `gcaptcha4.geetest.com` | 二次校验接口域名 |
| `geetest_captcha_product` | enum | `bind` | 展现形式：`bind` / `popup` / `float` |
| `geetest_captcha_language` | enum | `zho` | 验证界面语言 |
| `geetest_captcha_on_signup` | boolean | `true` | 注册时启用 |
| `geetest_captcha_on_login` | boolean | `false` | 登录时启用 |
| `geetest_captcha_on_post` | boolean | `false` | 发帖/回复时启用 |
| `geetest_captcha_fail_open` | boolean | `true` | 接口异常时放行（容灾） |
| `geetest_captcha_show_errors` | boolean | `true` | 向用户展示失败原因 |

### 获取 captcha_id / captcha_key

1. 登录 [极验产品后台](https://www.geetest.com/Register)，选择【行为验】。
2. 【创建业务模块】填写应用名称、地址、行业。
3. 【新增业务场景】选择客户端类型（Web）与业务类型，生成 `captcha_id` 和 `captcha_key`。
4. 建议不同业务场景单独创建 id/key，便于区分数据与策略。

---

## 安全设计

1. **密钥不下发前端** —— `captcha_key` 使用 `secret: true`，只存在于服务端。
2. **服务端签名** —— 二次校验的 `sign_token` 由服务端用 `captcha_key` 对 `lot_number` 做
   HMAC-SHA256 生成，前端无法伪造。
3. **防重放** —— Redis `SET NX EX` 原子占位。同一个 `lot_number` 只能成功消费一次，
   防止验证参数被脚本重放。业务层失败（如密码错误）时主动 `release`，允许用户重试。
4. **容灾降级** —— 极验接口超时或返回异常时，`fail_open` 默认放行，保证验证服务故障
   不会导致全站无法注册登录。对安全性要求极高的站点可关闭该项。
5. **只信 `result=success`** —— 只有极验明确返回成功才放行业务请求。

---

## 本地演示页

`demo/index.html` 是一个**独立**的演示页，不依赖 Discourse，可直接双击在浏览器打开：

- 支持切换 `bind` / `popup` / `float` 三种模式；
- 完整演示 bind 模式「点击提交 → 唤起验证 → 写入隐藏域 → 提交」的全过程；
- 实时打印 `onReady` / `onSuccess` / `onError` / `onClose` / `onFail` 事件与验证参数；
- 可填入自己的 `captcha_id`。

> 演示页只跑前端，不会真正调用极验二次校验接口（那需要服务端 `captcha_key`）。

启动本地静态服务：

```bash
cd demo
python -m http.server 8080
# 打开 http://localhost:8080
```

---

## 测试

```bash
cd /var/www/discourse
bundle exec rspec plugins/discourse-geetest-captcha/spec
```

覆盖点：签名算法正确性、成功/失败/异常返回解析、超时处理、参数缺失、防重放、
容灾降级开关。

---

## 常见问题

**Q：验证码不显示？**
确认 `geetest_captcha_enabled` 与对应场景开关已开启，且 `captcha_id` 已填写。
打开浏览器控制台查看 `gt4.js` 是否加载成功；若 CDN 被墙，可将
`https://static.geetest.com/v4/gt4.js` 下载后自托管，并修改
`lib/geetest-loader.js` 中的 `GT4_SCRIPT_URL`。

**Q：一直提示「人机验证未通过」？**
检查 `captcha_key` 是否填写正确。若错误信息包含 `illegal gen_time` 之类，通常是
请求体格式问题——插件已使用 `application/x-www-form-urlencoded`，无需额外处理。

**Q：用户关闭验证弹窗后无法提交？**
这是预期行为，`bind` 模式要求验证通过才能提交。用户可再次点击提交重新验证。

**Q：发帖验证挡到了机器人/系统帖？**
`PostsController` 的 guard 已跳过 `bot` 用户，系统导入与邮件回复不受影响。

**Q：Discourse 版本要求？**
插件元数据声明 `required_version: 3.2.0`。参数白名单使用了
`Discourse::ApplicationController.permitted`（3.x 引入），并在失败时降级为警告日志。

---

## 参考文档

- 极验行为验证第四代 · 服务端部署：<https://docs.geetest.com/gt4/deploy/server>
- 极验行为验证第四代 · Web API：<https://docs.geetest.com/gt4/apirefer/api/web>
- 极验行为验证第四代 · 快速开始：<https://docs.geetest.com/gt4/handbook>
- Discourse 开发者指南索引：<https://meta.discourse.org/t/developer-guides-index/308036>
- Discourse 插件开发 Part 1-7：<https://meta.discourse.org/t/30515>
- Discourse JS API：<https://meta.discourse.org/t/41281>
- Rails autoloading in plugins：<https://meta.discourse.org/t/256092>

---

## License

MIT
