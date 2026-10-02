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
- [管理后台界面](#管理后台界面)
- [安全设计](#安全设计)
- [本地演示页](#本地演示页)
- [关于 .hbs 弃用](#关于-hbs-弃用)
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
| **可视化管理后台** | 配置状态总览、场景开关直接操作、一键连通性测试、验证数据统计 |
| **现代组件格式** | 前端使用 `.gjs`（非弃用的 `.hbs`），符合 Discourse 迁移方向 |


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
| `validator.rb` | 编排层：参数校验 → 防重放消费 → 调极验 → 容灾降级策略 → 统计埋点 |
| `verified_store.rb` | 基于 `Discourse.redis` 的 `lot_number` 一次性消费存储（TTL 10 分钟） |
| `stats.rb` | 按天分桶的验证结果计数（通过/失败/降级/参数缺失），TTL 90 天 |
| `connectivity_test.rb` | 管理后台的连通性探针：发一次故意非法的请求，判断接口是否可达 |
| `controller_extension.rb` | 把 4 个自定义参数加入 strong parameters，并提供 `verify_geetest!` |
| `guard.rb` | 把校验挂到 `SignupController` / `SessionController` / `PostsController` |
| `admin_controller.rb` | 管理后台 JSON API：状态、统计、测试、开关切换 |


---

## 目录结构

```
discourse-geetest-captcha/
├── plugin.rb                              # 插件入口（含管理路由）
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
│   ├── stats.rb                           # 验证数据统计
│   ├── settings_registry.rb               # 设置注册表（单一事实来源）
│   ├── connectivity_test.rb               # 连通性探针
│   ├── controller_extension.rb            # 参数白名单 + 控制器 helper
│   ├── guard.rb                           # 各端点挂载
│   └── admin_controller.rb                # 管理后台 API
├── assets/
│   ├── javascripts/discourse/
│   │   ├── geetest-captcha-route-map.js   # 注册 /admin/plugins/geetest-captcha 路由
│   │   ├── initializers/geetest-captcha.js
│   │   ├── components/
│   │   │   └── geetest-captcha-admin.gjs  # 管理界面：统一配置表单（.gjs）
│   │   ├── templates/admin/
│   │   │   └── plugins-geetest-captcha.gjs# 管理页模板（.gjs）
│   │   └── lib/
│   │       ├── geetest-loader.js
│   │       └── geetest-widget.js
│   └── stylesheets/
│       ├── common/geetest-captcha.scss
│       └── admin/geetest-captcha-admin.scss
├── demo/index.html                        # 独立前端演示页
└── spec/lib/                              # RSpec 测试
    ├── gt4_client_spec.rb
    ├── gt4_validator_spec.rb
    ├── gt4_stats_spec.rb
    ├── gt4_settings_registry_spec.rb
    └── gt4_admin_controller_spec.rb
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

全部 11 项设置都可以在**管理后台 → 插件 → 极验验证**的统一表单里一次改完
（见下文「管理后台界面」）。内置的 **管理后台 → 设置 → 插件** 页搜索 `geetest`
同样可用，两处修改的是同一份数据。

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

> 设置的**类型、分组、枚举取值与校验规则**统一定义在
> `lib/gt4/settings_registry.rb`，管理页表单与服务端校验都由它驱动。

### 获取 captcha_id / captcha_key

1. 登录 [极验产品后台](https://www.geetest.com/Register)，选择【行为验】。
2. 【创建业务模块】填写应用名称、地址、行业。
3. 【新增业务场景】选择客户端类型（Web）与业务类型，生成 `captcha_id` 和 `captcha_key`。
4. 建议不同业务场景单独创建 id/key，便于区分数据与策略。

---

## 管理后台界面

**入口**：管理后台 → 插件 → **极验验证**，或直接访问
`/admin/plugins/geetest-captcha`。

管理页是这个插件**唯一的配置入口**：全部 11 项设置都在这里分组呈现，一次保存。
Discourse 内置的站点设置页仍然保留（`管理后台 → 设置 → 插件` 搜索 `geetest`），
两处改的是同一份数据，无论用哪个都不会脱节。

页面包含五块内容：

### 1. 配置状态总览

一眼看清配置是否可用，逐项打勾/打叉：

- 插件总开关是否开启
- 是否已填写 `captcha_id`
- 是否已填写 `captcha_key`
- 是否至少启用了一个验证场景

### 2. 统一配置表单

所有设置按三组排列，改完点一次「保存配置」即可：

| 分组 | 包含设置 |
| --- | --- |
| 基础配置 | 总开关、`captcha_id`、`captcha_key`、展现形式、界面语言 |
| 验证场景 | 注册、登录、发帖 / 回复 |
| 高级选项 | API 域名、容灾降级、显示失败原因 |

表单的几个行为细节：

- **合并保存**：只提交真正改动过的字段，未改动的不会被写回。
- **`captcha_key` 留空即不改**：密钥字段永远是空的密码框，placeholder 显示
  `已配置（647f…bb71），留空则不修改`。这样重新保存其它设置时不需要重新输入密钥，
  密钥也从不回传到浏览器。
- **未保存提示**：顶部有「N 项未保存」标记，底部有「撤销更改」按钮可一键还原为
  服务端当前值。
- **校验失败不落库**：任一字段非法（例如 `captcha_id` 含空格、枚举值不存在），
  整批都不会写入，错误信息直接标在对应字段下方。
- **启用前置校验**：勾选总开关时若 `captcha_id` / `captcha_key` 为空，会拒绝保存并
  提示先填写——避免出现「插件已启用但从未生效」的静默故障。

### 3. 连通性测试

点击「开始测试」后，服务端拿当前配置向极验接口发一次**故意非法**的校验请求。
由于载荷是伪造的，一个**可达**的接口会返回校验失败而不是成功——我们真正验证的是
DNS、TLS、路由是否通畅，以及请求格式是否被接受。页面会显示耗时与结果详情。

### 4. 验证数据统计

展示最近 1 / 7 / 30 天的四类计数：

| 指标 | 含义 |
| --- | --- |
| 验证通过 | 极验确认验证成功 |
| 验证失败 | 极验拒绝 |
| 降级放行 | 极验接口不可达，走了容灾放行策略 |
| 参数缺失 | 客户端未携带（或只携带部分）验证参数 |

> **安全提示**：管理页返回的 `captcha_id` 会做脱敏处理（只显示前 4 位和后 4 位），
> `captcha_key` 永不回显，只告知「已配置 / 未配置」。

### 5. 管理 API

所有接口都要求管理员权限（`StaffConstraint`）：

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/admin/plugins/geetest-captcha/settings.json` | 读取全部设置（含表单元数据） |
| PUT | `/admin/plugins/geetest-captcha/settings.json` | 批量保存设置 |
| GET | `/admin/plugins/geetest-captcha/status.json` | 配置状态与健康检查（精简版） |
| GET | `/admin/plugins/geetest-captcha/stats.json?days=7` | 统计数据 |
| DELETE | `/admin/plugins/geetest-captcha/stats.json` | 清空统计 |
| POST | `/admin/plugins/geetest-captcha/test.json` | 连通性测试 |
| PUT | `/admin/plugins/geetest-captcha/toggle.json` | 切换单个场景开关（兼容保留） |

批量保存示例：

```bash
curl -X PUT https://your-forum.com/admin/plugins/geetest-captcha/settings.json \
  -H "Content-Type: application/json" \
  -H "Api-Key: <admin-api-key>" \
  -H "Api-Username: system" \
  -d '{"settings":{"geetest_captcha_product":"popup","geetest_captcha_on_post":true}}'
```

成功响应会回传最新的完整设置，`changed` 里只列出真正变动的键：

```json
{ "success": true, "changed": {"geetest_captcha_on_post": true}, "settings": { }, "health": { } }
```

校验失败时返回 `422`，`errors` 是 `{设置名: [错误码]}`：

```json
{ "success": false, "errors": {"geetest_captcha_id": ["invalid_format"]} }
```

#### 设置注册表（单一事实来源）

`lib/gt4/settings_registry.rb` 是这 11 项设置的唯一定义处：类型、分组、枚举取值、
正则校验、是否脱敏，全部集中在这里。服务端据此做校验与强制转换，前端据此渲染表单，
因此两侧永远不会对「有哪些设置、各是什么类型」产生分歧。`config/settings.yml` 仍然
负责声明**默认值**，并有 spec 断言两者覆盖的设置项完全一致。

---

## 关于 .hbs 弃用

Discourse 正在弃用主题/插件中 `.hbs` 模板文件扩展名，控制台会输出如下提示：

```
DEPRECATION NOTICE: The file '.../templates/xxx.hbs' uses the deprecated
.hbs extension. Refactor it to use '.gjs' instead.
[deprecation id: discourse.hbs-extension]
```

参考：<https://meta.discourse.org/t/deprecating-hbs-file-extension-in-themes-and-plugins/398896>

本插件**不使用** `.hbs`，管理界面全部以现代的 **`.gjs`** 单文件组件格式编写：

- 模板内联在 `<template>...</template>` 中；
- 所有 helper（`i18n`、`fn`、`eq`、`concat`、`if` 等）显式 import，不再依赖隐式全局；
- 组件状态用 `@glimmer/tracking` 的 `@tracked` 声明，`@action` 处理交互。

因此插件不会触发该弃用警告，也符合 Discourse 的迁移方向。

如果你此前用的是老式写法，迁移要点大致是：

| 老写法（`.hbs`） | 新写法（`.gjs`） |
| --- | --- |
| 单独的 `templates/xxx.hbs` 文件 | 单文件 `.gjs`，模板内联 |
| `this.foo` 访问组件状态 | `@controller.foo` / `@model` / 组件自有字段 |
| helper 隐式全局（如 `{{i18n}}`） | 显式 `import { i18n } from "discourse-i18n"` |
| 需要配套 Controller 文件 | 组件内 `@tracked` + `@action` 自洽 |

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
容灾降级开关、统计计数与聚合、设置注册表（类型/枚举/正则/脱敏/交叉校验）、
管理 API 的权限校验与脱敏、批量保存的原子性。

具体到统一配置这块的测试：

- `spec/lib/gt4_settings_registry_spec.rb` —— 断言注册表与 `config/settings.yml`
  覆盖的设置项完全一致，并逐项验证布尔强制转换、枚举白名单、正则校验、
  空白密钥跳过、启用时凭据必填等规则。
- `spec/lib/gt4_admin_controller_spec.rb` —— 验证 `GET/PUT /settings.json`
  的权限、脱敏、批量落库、**非法输入不落库**（同请求中的合法字段也不会被写入）、
  场景变更后重装拦截器。

### 离线自检（不需要 Discourse 环境）

仓库里还带了一个不依赖完整 Discourse 的自检脚本，用于在本地或 CI 的早期阶段
捕获低级错误：

```bash
bash scripts/verify.sh
```

它会依次检查：Ruby 语法、YAML 可解析、`.gjs` 能被 `content-tag` 解析（Discourse
实际使用的 swc 解析器）、SCSS 能被 dart-sass 编译、JS 语法、**i18n key 在全部语言
文件中的覆盖率**，以及一个**裸启动模拟**——故意不加载任何 Discourse 控制器来加载
`plugin.rb`，确保插件的加载路径引用不到应用常量，从而不会让 `rake db:migrate`
在启动阶段崩溃。

其中 `.gjs` / SCSS / i18n / 启动模拟这几项需要辅助工具；缺失时脚本会标记为 SKIP
而不是失败。工具的路径可以用环境变量覆盖：

```bash
VERIFY_TOOLS=/path/to/tools GJS_HELPERS=/path/to/helpers bash scripts/verify.sh
```

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

**Q：管理页打不开 / 提示 404？**
确认当前账号是管理员。管理路由挂了 `StaffConstraint`，非管理员一律 404（这是
Discourse 管理接口的惯例，避免泄露路由是否存在）。另外 `/admin/plugins` 菜单里的
入口文案来自 `geetest_captcha.admin.nav_label`，若显示为 key 说明语言文件未加载，
重启一次应用即可。

**Q：连通性测试显示「接口不可达」但实际验证能用？**
该测试发的是**非法**请求，只用于探测网络与请求格式。若你的服务器无法直连
`gcaptcha4.geetest.com`（如内网限制），测试会失败，但只要有其他出口能到达，
实际验证可能仍然正常。反之若测试可达而验证总失败，请重点检查 `captcha_key` 是否正确。

**Q：统计数据会是 0 吗？**
统计只从插件启用后开始累积，且按天分桶保留 90 天。刚安装时没有数据是正常的，
可在管理页点击「重置统计」清空后重新观察。

**Q：为什么插件里没有 `.hbs` 文件？**
因为 Discourse 已弃用 `.hbs` 扩展名（见上文
[关于 .hbs 弃用](#关于-hbs-弃用)）。本插件使用 `.gjs` 单文件组件，不会产生该弃用警告。

**Q：重建时报 `bundle exec rake db:migrate` 失败 / FAILED TO BOOTSTRAP？**
先看完整报错。`Pups::ExecError` 本身只是「命令退出码非 0」的外壳，
**真正的异常栈在它的上面几行**，通常是 `NameError` / `uninitialized constant`，
并且往往指向某个插件路径。

本插件从 v1.2.0 起做了启动安全加固，不会因为控制器未加载而中断 bootstrap：

- 没有任何 migration 文件（不建表、不加列，统计走 Redis、配置走 SiteSetting）
- 所有控制器常量引用都改为**运行时惰性解析**，缺失时降级为 warning 而非抛错
- 管理控制器的类定义延迟到确认父常量存在之后

如果仍失败，请按下面步骤定位：

```bash
# 1. 到宿主机上查看完整日志
cd /var/discourse
./launcher rebuild app 2>&1 | tee /tmp/rebuild.log
grep -n -B 20 -A 10 "db:migrate" /tmp/rebuild.log | head -80

# 2. 临时移除插件以确认是否与它相关
#    注释掉 app.yml 里 git clone 这个插件的那一行，再 rebuild

# 3. 若确认无关，用官方的诊断脚本
./discourse-doctor
```

常见真实原因（与本插件无关的那些）：

| 现象 | 原因 |
| --- | --- |
| `PG::UndefinedTable` / `DuplicateColumn` | 数据库状态与 migration 不一致，需人工修复 schema_migrations |
| `NameError: uninitialized constant` + 其他插件路径 | 那个插件在加载期引用了应用常量 |
| 磁盘空间不足 | `df -h` 检查，`/var/discourse/shared/standalone` 常被日志撑满 |
| 迁移中途被中断 | 上一次 rebuild 被 kill，需回滚半完成的 migration |

---

## 参考文档

- 极验行为验证第四代 · 服务端部署：<https://docs.geetest.com/gt4/deploy/server>
- 极验行为验证第四代 · Web API：<https://docs.geetest.com/gt4/apirefer/api/web>
- 极验行为验证第四代 · 快速开始：<https://docs.geetest.com/gt4/handbook>
- Discourse 开发者指南索引：<https://meta.discourse.org/t/developer-guides-index/308036>
- Discourse 插件开发 Part 5（管理界面）：<https://meta.discourse.org/t/31761>
- Discourse 弃用 .hbs 扩展名：<https://meta.discourse.org/t/398896>
- Discourse JS API：<https://meta.discourse.org/t/41281>
- Rails autoloading in plugins：<https://meta.discourse.org/t/256092>

---

## License

MIT
