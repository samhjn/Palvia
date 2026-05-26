#if DEBUG
import Foundation
import SwiftData

extension Notification.Name {
    static let uiTestStreamingSessionDidAppear = Notification.Name("PalviaUITestStreamingSessionDidAppear")
}

/// UI test seed data — separated from PalviaApp to keep the main app file clean.
/// Contains all markdown fixtures and streaming simulation logic.
extension PalviaApp {

    // MARK: - Markdown Display Mode Test Data

    @MainActor
    static func seedMarkdownTestData(in container: ModelContainer) {
        let context = container.mainContext

        let agent = Agent(name: "MarkdownTestAgent")
        agent.isVerbose = true
        context.insert(agent)

        let session = Session(title: "Markdown Test Session")
        session.agent = agent
        context.insert(session)

        let userMsg1 = Message(role: .user, content: "请用 Markdown 格式详细介绍 Swift 语言的特性")
        userMsg1.session = session

        let longMarkdown1 = """
        # Swift 语言特性概述

        Swift 是由 Apple 开发的现代编程语言，具有以下核心特性：

        ## 1. 类型安全

        Swift 是一门**强类型语言**，在编译期就能捕获大部分类型错误。

        ```swift
        let name: String = "Hello"
        let count: Int = 42
        // let error: Int = "not a number" // 编译错误
        ```

        ## 2. 可选类型 (Optionals)

        Swift 的可选类型系统优雅地处理了空值问题：

        ```swift
        var nickname: String? = nil
        if let unwrapped = nickname {
            print("昵称: \\(unwrapped)")
        } else {
            print("没有设置昵称")
        }
        ```

        ## 3. 协议导向编程

        | 特性 | 描述 | 示例 |
        |------|------|------|
        | 协议扩展 | 为协议提供默认实现 | `extension Collection` |
        | 协议组合 | 多个协议约束 | `Codable & Sendable` |
        | 关联类型 | 泛型协议 | `associatedtype Element` |
        | 条件遵循 | 有条件的协议遵循 | `where Element: Equatable` |

        ## 4. 并发模型

        Swift 5.5+ 引入了结构化并发：

        ```swift
        func fetchData() async throws -> Data {
            let (data, _) = try await URLSession.shared.data(from: url)
            return data
        }

        // Actor 隔离
        actor Counter {
            private var value = 0
            func increment() { value += 1 }
        }
        ```

        ## 5. 值类型 vs 引用类型

        - **Struct** (值类型): 拷贝语义, 线程安全
        - **Class** (引用类型): 共享引用, 需注意线程安全
        - **Enum**: 强大的关联值, 模式匹配

        > Swift 的设计哲学：安全、快速、表达力强。
        > 通过编译器强制的安全保障，减少运行时错误。

        ---

        ### 总结

        1. Swift 兼顾了安全性与性能
        2. 现代化的语法让代码更易读
        3. 丰富的标准库减少了第三方依赖
        """

        let assistantMsg1 = Message(role: .assistant, content: longMarkdown1)
        assistantMsg1.session = session

        let toolCallData = try? JSONEncoder().encode([
            LLMToolCall(id: "call_001", name: "file_read", arguments: "{\"path\": \"/docs/swift.md\"}")
        ])
        let toolMsg = Message(role: .assistant, content: nil, toolCallsData: toolCallData)
        toolMsg.session = session

        let toolResult = Message(role: .tool, content: "File content read successfully.", toolCallId: "call_001", name: "file_read")
        toolResult.session = session

        let userMsg2 = Message(role: .user, content: "继续展开 SwiftUI 的声明式 UI 编程")
        userMsg2.session = session

        let longMarkdown2 = """
        # SwiftUI 声明式 UI 编程

        SwiftUI 彻底改变了 Apple 平台的 UI 开发方式。

        ## 核心概念

        ### 视图即函数

        ```swift
        struct ContentView: View {
            @State private var count = 0

            var body: some View {
                VStack(spacing: 16) {
                    Text("计数: \\(count)")
                        .font(.largeTitle)
                        .bold()

                    Button("增加") {
                        withAnimation(.spring) {
                            count += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
        ```

        ### 数据流

        | 属性包装器 | 用途 | 所有权 |
        |-----------|------|--------|
        | `@State` | 视图本地状态 | 视图拥有 |
        | `@Binding` | 父子视图双向绑定 | 父视图拥有 |
        | `@Observable` | 外部可观察对象 | 外部拥有 |
        | `@Environment` | 环境值注入 | 系统/父级 |
        | `@Query` | SwiftData 查询 | 数据库 |

        ### 布局系统

        SwiftUI 使用三步布局协议：

        1. **父视图提议**尺寸给子视图
        2. **子视图返回**自身需要的尺寸
        3. **父视图放置**子视图到具体位置

        ```swift
        HStack(alignment: .center, spacing: 8) {
            ForEach(items) { item in
                ItemCard(item: item)
                    .frame(minWidth: 100, maxWidth: .infinity)
            }
        }
        .padding()
        ```

        ### 动画与过渡

        ```swift
        // 隐式动画
        Circle()
            .scaleEffect(isExpanded ? 2.0 : 1.0)
            .animation(.spring(dampingFraction: 0.6), value: isExpanded)

        // 显式动画
        withAnimation(.easeInOut(duration: 0.3)) {
            showDetail.toggle()
        }

        // 过渡效果
        if showDetail {
            DetailView()
                .transition(.asymmetric(
                    insertion: .slide.combined(with: .opacity),
                    removal: .scale.combined(with: .opacity)
                ))
        }
        ```

        ## 最佳实践

        > **性能准则**: 保持 `body` 计算轻量，将重型逻辑移至 ViewModel 或 `task {}` 修饰符。

        - [x] 使用 `@Observable` 代替 `ObservableObject`
        - [x] 将大视图拆分为小组件
        - [ ] 对列表使用 `LazyVStack` / `LazyHStack`
        - [ ] 用 `equatable()` 优化不必要的重绘

        ---

        *SwiftUI 让 UI 开发回归到描述"是什么"而非"怎么做"。*
        """

        let assistantMsg2 = Message(role: .assistant, content: longMarkdown2)
        assistantMsg2.session = session

        let userMsg3 = Message(role: .user, content: "再详细说说 Swift 的错误处理和结果类型")
        userMsg3.session = session

        let longMarkdown3 = """
        # Swift 错误处理与 Result 类型

        ## 传统 throws 模式

        ```swift
        enum NetworkError: Error {
            case invalidURL
            case timeout(seconds: Int)
            case serverError(statusCode: Int, body: String)
        }

        func fetchUser(id: Int) throws -> User {
            guard let url = URL(string: "https://api.example.com/users/\\(id)") else {
                throw NetworkError.invalidURL
            }
            // ...
        }
        ```

        ## Result 类型

        `Result<Success, Failure>` 适合异步回调场景：

        ```swift
        func loadImage(from url: URL, completion: @escaping (Result<UIImage, Error>) -> Void) {
            URLSession.shared.dataTask(with: url) { data, _, error in
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let data, let image = UIImage(data: data) else {
                    completion(.failure(NetworkError.invalidData))
                    return
                }
                completion(.success(image))
            }.resume()
        }
        ```

        ## 对比表

        | 方式 | 同步/异步 | 错误传播 | 适用场景 |
        |------|----------|---------|---------|
        | `throws` | 两者皆可 | 自动向上 | 大多数场景 |
        | `Result` | 主要异步 | 手动处理 | 回调API |
        | `Optional` | 两者皆可 | 信息丢失 | 简单失败 |
        | `async throws` | 异步 | 自动向上 | 现代异步 |

        ## Typed Throws (Swift 6.0+)

        ```swift
        func parse(_ input: String) throws(ParseError) -> AST {
            // 编译器保证只会抛出 ParseError
        }
        ```

        > 类型化 throws 让错误处理更精确，编译器能验证所有错误路径已被覆盖。

        ---

        **总结**: 选择错误处理策略时，优先考虑 `async throws`；只在需要回调兼容性时使用 `Result`。
        """

        let assistantMsg3 = Message(role: .assistant, content: longMarkdown3)
        assistantMsg3.session = session

        let allMessages = [userMsg1, assistantMsg1, toolMsg, toolResult, userMsg2, assistantMsg2, userMsg3, assistantMsg3]
        for (i, msg) in allMessages.enumerated() {
            msg.timestamp = Date(timeIntervalSinceNow: Double(-allMessages.count + i) * 10)
            context.insert(msg)
        }

        session.messages = allMessages
        try? context.save()
    }

    // MARK: - Heavy Markdown Test Data (for initial scroll / scroll-to-bottom bugs)

    @MainActor
    static func seedHeavyMarkdownTestData(in container: ModelContainer) {
        let context = container.mainContext

        let agent = Agent(name: "HeavyMarkdownAgent")
        agent.isVerbose = true
        context.insert(agent)

        let session = Session(title: "Heavy Markdown Session")
        session.agent = agent
        context.insert(session)

        // 6 rounds, each message 7K-15K chars.
        // Some messages combine two fixture rounds to create extremely long
        // single-message renders that stress LazyVStack + MarkdownContentView.
        let rounds: [(String, String, TimeInterval)] = [
            ("深入讲解 Swift 泛型系统的高级用法",
             StreamingFixtures.historyRound1 + "\n\n---\n\n" + StreamingFixtures.historyRound2, -600),
            ("SwiftUI 大型项目架构设计全面讲解",
             StreamingFixtures.historyRound3, -500),
            ("并发编程性能优化完整指南",
             StreamingFixtures.historyRound4 + "\n\n---\n\n" + StreamingFixtures.historyRound1, -400),
            ("面向协议编程与泛型系统的结合应用",
             StreamingFixtures.historyRound2 + "\n\n---\n\n" + StreamingFixtures.historyRound3, -300),
            ("Swift 项目架构综合对比分析",
             StreamingFixtures.historyRound4, -200),
            ("综合所有内容的完整最佳实践文档",
             StreamingFixtures.historyRound3 + "\n\n---\n\n" + StreamingFixtures.historyRound4
             + "\n\n## 📋 总结清单\n\n以上就是完整的 Swift 最佳实践文档的全部内容。", -100),
        ]

        var allMessages: [Message] = []

        for (i, (userContent, assistantContent, baseTime)) in rounds.enumerated() {
            let userMsg = Message(role: .user, content: userContent)
            userMsg.session = session
            userMsg.timestamp = Date(timeIntervalSinceNow: baseTime)
            context.insert(userMsg)
            allMessages.append(userMsg)

            // Add tool calls between rounds for extra complexity
            for t in 0..<2 {
                let callId = "call_\(i)_\(t)"
                let toolCallData = try? JSONEncoder().encode([
                    LLMToolCall(id: callId, name: "search", arguments: "{\"q\": \"\(userContent)\"}")
                ])
                let toolMsg = Message(role: .assistant, content: nil, toolCallsData: toolCallData)
                toolMsg.session = session
                toolMsg.timestamp = Date(timeIntervalSinceNow: baseTime + Double(t) + 1)
                context.insert(toolMsg)
                allMessages.append(toolMsg)

                let toolResult = Message(role: .tool, content: "Found relevant documentation.", toolCallId: callId, name: "search")
                toolResult.session = session
                toolResult.timestamp = Date(timeIntervalSinceNow: baseTime + Double(t) + 2)
                context.insert(toolResult)
                allMessages.append(toolResult)
            }

            let assistantMsg = Message(role: .assistant, content: assistantContent)
            assistantMsg.session = session
            assistantMsg.timestamp = Date(timeIntervalSinceNow: baseTime + 10)
            context.insert(assistantMsg)
            allMessages.append(assistantMsg)
        }

        session.messages = allMessages
        try? context.save()
    }

    // MARK: - Streaming Stress Test Data

    @MainActor
    static func seedStreamingTestData(in container: ModelContainer) {
        let context = container.mainContext

        let agent = Agent(name: "StreamingTestAgent")
        agent.isVerbose = true
        context.insert(agent)

        let session = Session(title: "Streaming Test Session")
        session.agent = agent
        context.insert(session)

        var allMessages: [Message] = []

        let rounds: [(String, String, TimeInterval)] = [
            ("深入讲解 Swift 泛型系统的高级用法", StreamingFixtures.historyRound1, -300),
            ("详细讲解面向协议编程的设计模式，要有完整代码", StreamingFixtures.historyRound2, -240),
            ("SwiftUI 大型项目架构设计：状态管理、导航、依赖注入全面讲解", StreamingFixtures.historyRound3, -180),
            ("并发编程性能优化完整指南，包括 Instruments 分析、Actor 调优、TaskGroup 最佳实践", StreamingFixtures.historyRound4, -120),
        ]

        for (userContent, assistantContent, baseTime) in rounds {
            let userMsg = Message(role: .user, content: userContent)
            userMsg.session = session
            userMsg.timestamp = Date(timeIntervalSinceNow: baseTime)
            context.insert(userMsg)
            allMessages.append(userMsg)

            let assistantMsg = Message(role: .assistant, content: assistantContent)
            assistantMsg.session = session
            assistantMsg.timestamp = Date(timeIntervalSinceNow: baseTime + 10)
            context.insert(assistantMsg)
            allMessages.append(assistantMsg)
        }

        let user5 = Message(role: .user, content: "综合前面所有内容，给出一份完整的 Swift 项目架构最佳实践文档，要求包含泛型、协议、SwiftUI架构、并发全部内容的代码示例和对比表格")
        user5.session = session
        user5.timestamp = Date(timeIntervalSinceNow: -5)
        context.insert(user5)
        allMessages.append(user5)

        session.messages = allMessages
        session.isActive = true
        try? context.save()

        ChatViewModel._simulateActiveGeneration(for: session.id)
        let relay = ChatViewModel._simulateStreamingRelay(for: session.id)

        Task { @MainActor in
            for await note in NotificationCenter.default.notifications(named: .uiTestStreamingSessionDidAppear) {
                guard let sessionId = note.userInfo?["sessionId"] as? UUID,
                      sessionId == session.id else { continue }
                break
            }

            try? await Task.sleep(for: .milliseconds(500))

            let steps = StreamingFixtures.streamingSteps
            var accumulated = ""
            var thinkingAccumulated = ""

            for (i, step) in steps.enumerated() {
                try? await Task.sleep(for: .milliseconds(150))

                if let thinking = step.thinking {
                    thinkingAccumulated += thinking
                }
                accumulated += step.content
                relay.send(content: accumulated, thinking: thinkingAccumulated)

                if i % 8 == 0 || i == steps.count - 1 {
                    session.pendingStreamingContent = accumulated
                }
            }

            try? await Task.sleep(for: .milliseconds(200))
            let finalMsg = Message(role: .assistant, content: accumulated)
            finalMsg.session = session
            finalMsg.timestamp = Date()
            context.insert(finalMsg)
            session.messages.append(finalMsg)
            session.pendingStreamingContent = nil
            session.isActive = false
            try? context.save()

            relay.finish()
            ChatViewModel._clearActiveGeneration(for: session.id)
            ChatViewModel._clearStreamingRelay(for: session.id)
        }
    }
}
#endif
