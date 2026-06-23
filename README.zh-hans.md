<p align="center">
  <img src="icon.PNG" width="128" height="128" alt="Palvia Logo" />
</p>

<h1 align="center">Palvia</h1>

<p align="center">
  <strong>把 AI Agent 装进口袋，随时随地释放智能</strong><br/>
  一款原生 iOS AI Agent 应用，让你在手机上拥有多个可定制的 AI 助手
</p>

<p align="center">
  <a href="https://palvia.net">官网</a> ·
  <a href="#features">功能特性</a> ·
  <a href="#quick-start">快速开始</a> ·
  <a href="LICENSE">MIT License</a> ·
  <a href="README.md">English</a>
</p>

<p align="center">
  <a href="https://apps.apple.com/us/app/palvia-ai-agents-in-your-palm/id6761302827">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="App Store 下载" height="40" />
  </a>
</p>

---

## 为什么选择 Palvia？

市面上的 AI 聊天应用只是对话框。**Palvia 不一样**——它是一个完整的 **AI Agent 平台**，每个 Agent 都有自己的灵魂、记忆和技能，还能直接在手机上运行代码。

| 维度 | 普通 AI 聊天 | Palvia |
|------|------------|-------|
| **多角色** | 单一对话 | 多 Agent，各有独立人格与记忆 |
| **代码执行** | 不支持 | 内置 JavaScript 解释器 |
| **网页自动化** | 不支持 | 内置浏览器 + Agent 驱动的网页自动化 |
| **上下文管理** | 超长对话丢失上下文 | 自动压缩 + 摘要注入 + 会话 RAG，永不遗忘 |
| **可扩展性** | 封闭 | 技能系统 + 定时任务 + 子 Agent |
| **数据隐私** | 云端存储 | 全部数据存于本地 SwiftData |

---

## 产品定位

Palvia 是一款 **原生 iOS AI Agent 应用**，核心方向是自主能力、可扩展性与隐私。

- **原生 iOS 优先**：基于 Swift + SwiftUI 构建，针对 iPhone / iPad 交互深度优化
- **端侧架构**：会话、记忆与向量检索数据通过 SwiftData 本地持久化
- **可执行型 Agent**：支持代码执行、网页自动化、工具调用、定时任务和子 Agent
- **高度可定制**：每个 Agent 都可拥有独立 SOUL.md / MEMORY.md / USER.md 与自定义技能

**一句话总结**：Palvia 把强大的 AI Agent 能力直接装进口袋，无需额外服务器基础设施。

---

<a id="features"></a>
## 核心功能

### 🧠 多 Agent 架构
- 创建多个 AI Agent，每个都有独立的 **SOUL.md**（人格）、**MEMORY.md**（记忆）、**USER.md**（用户画像）
- Agent 可以生成 **子 Agent**，子 Agent 继承父级人格配置
- 灵活的 Markdown 配置空间，完全由你定义 Agent 的行为

### ⚡ 端侧代码执行
- **JavaScript 解释器** — 在 WKWebView 沙盒中执行，支持崩溃自动恢复
- 两种执行模式：`repl`（表达式求值）与 `script`（完整脚本）
- 代码片段保存与复用，打造你的移动代码库

### 💬 智能会话管理
- 以会话为中心的交互体验
- SwiftData 持久化，数据安全不丢失
- **自动上下文压缩**——超出 Token 阈值时自动压缩历史消息，摘要注入系统提示

### 🔍 会话 RAG & 搜索
Agent 不只是聊天——它们还能**回忆**。Palvia 内置了一套检索增强生成（RAG）框架，将历史会话转化为可搜索的知识库，让 Agent 能够回顾和推理过往对话。

- **端侧向量嵌入** — 基于 Apple NaturalLanguage 框架（句子级嵌入，词向量兜底），全部在本地计算，零云端依赖
- **混合搜索** — 向量相似度搜索（余弦相似度，阈值 >0.3）+ 关键词自动兜底，即使没有嵌入也能保证返回结果
- **Agent 可调用的工具** — 通过 Function Calling 向 Agent 暴露两个工具：
  - `search_sessions` — 在 Agent 的会话历史中进行语义搜索
  - `recall_session` — 检索并分页浏览特定会话的消息（Token 感知，上限 4 000 tokens）
- **自动上下文注入** — 会话开始时自动发现关联会话并注入系统提示词，无需主动询问即可获得相关历史
- **后台索引** — 应用启动时以批量、CPU 节流的方式惰性补全嵌入，确保 UI 流畅不卡顿
- **隐私 & 权限隔离** — 嵌入数据保存在本地；每个 Agent 只能搜索自己的会话；自动排除当前会话以避免自引用

### 🔌 多 LLM 提供商支持
- 兼容任何 **OpenAI API** 格式的接口
- 完整的 **SSE 流式响应** 支持，打字机效果实时输出
- 内置预设：OpenAI / DeepSeek / OpenRouter / Ollama（本地部署）
- 自由配置多个 Provider，一键切换

### 🌐 内置浏览器 & 网页自动化
- 基于 WKWebView 的内置浏览器，无需离开 App 即可浏览网页
- **Agent 驱动的自动化**：Agent 可以导航页面、点击元素、填写表单、提取数据、执行 JavaScript——全部通过 Function Calling 实现
- 9 个浏览器工具：`browser_navigate`、`browser_click`、`browser_input`、`browser_extract`、`browser_execute_js`、`browser_get_page_info`、`browser_select`、`browser_wait`、`browser_scroll`
- **互斥锁机制**确保同一时间只有一个 Agent 会话可以控制浏览器；用户可实时看到控制状态横幅，并随时手动接管
- 简化 DOM 提取为 Agent 提供页面结构的可读视图（链接、表单、按钮、文本）

### 🛠 强大的 Function Calling
- `read_config` / `write_config` — 读写 Agent 心智文件
- `execute_javascript` — 执行代码
- `save_code` / `load_code` / `list_code` — 管理代码片段
- `create_sub_agent` / `message_sub_agent` — 子 Agent 生命周期管理
- `schedule_cron` / `unschedule_cron` — 定时任务调度
- `search_sessions` / `recall_session` — 会话 RAG 与跨会话检索
- `browser_*` — 9 个浏览器自动化工具（详见上方内置浏览器章节）

### 📦 技能系统
- 可安装的技能库，为 Agent 赋予新能力
- 灵活挂载，一个技能可服务多个 Agent

### ⏰ 定时任务（Cron Jobs）
- 为 Agent 创建定时任务，后台自动执行
- 基于 `BGTaskScheduler`，系统级可靠调度
- 支持 Deep Link 触发：`iclaw://cron/trigger/{jobId}`

---

<a id="quick-start"></a>
## 快速开始

### 环境要求

- Xcode 15+
- iOS 17.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

### 构建 & 运行

```bash
# 安装 XcodeGen
brew install xcodegen

# 生成 Xcode 工程
cd Palvia
xcodegen generate

# 打开项目
open Palvia.xcodeproj
```

### 首次使用

1. 打开 App → **设置** → 添加一个 LLM 提供商（填入 API 端点、密钥、模型名称）
2. 前往 **Agents** → 创建你的第一个 Agent
3. 前往 **Sessions** → 新建会话 → 开始对话！

---

## 项目结构

```
Palvia/
├── project.yml              # XcodeGen 配置
├── Palvia/
│   ├── App/                 # 应用入口和根导航
│   ├── Models/              # SwiftData 数据模型
│   ├── Services/
│   │   ├── LLM/            # LLM API 客户端、SSE 解析
│   │   ├── Agent/           # Agent 管理
│   │   ├── Session/         # 会话服务、上下文压缩
│   │   ├── Prompt/          # 系统提示词构建
│   │   ├── FunctionCall/    # 工具定义与路由
│   │   ├── CodeExecution/   # 代码执行引擎
│   │   ├── Browser/         # 内置浏览器服务与自动化
│   │   ├── CronJob/         # 定时任务调度
│   │   └── Skill/           # 技能管理
│   ├── ViewModels/          # Observable 视图模型
│   ├── Views/               # SwiftUI 视图层
│   └── Resources/           # Assets、默认模板
```

## 技术栈

| 层级 | 技术选型 |
|------|---------|
| UI | SwiftUI + Declarative Navigation |
| 状态管理 | Observation Framework (`@Observable`) |
| 数据持久化 | SwiftData |
| 代码执行 | WKWebView 沙盒 |
| 网页自动化 | WKWebView + Agent 驱动的 Function Calling |
| 网络 | URLSession + SSE Streaming |
| 工程管理 | XcodeGen |

---

## 开源协议

本项目基于 [MIT License](LICENSE) 开源。

Copyright (c) 2026 ShadowMov

---

<p align="center">
  <strong>Palvia</strong> — 把 AI Agent 装进口袋<br/>
  <a href="https://palvia.net">palvia.net</a>
</p>
