#if DEBUG
import Foundation

/// Test fixture data for streaming UI tests. Isolated from app code.
enum StreamingFixtures {

    struct StreamingStep {
        let content: String
        let thinking: String?
    }

    static let historyRound1 = """
    # Swift 泛型系统深度解析

    ## 1. 关联类型与类型擦除

    ```swift
    protocol DataStore {
        associatedtype Item: Codable & Identifiable
        associatedtype Query

        func fetch(matching query: Query) async throws -> [Item]
        func save(_ items: [Item]) async throws
        func delete(where predicate: (Item) -> Bool) async throws -> Int
    }

    // 类型擦除包装器
    struct AnyDataStore<T: Codable & Identifiable>: DataStore {
        typealias Item = T
        typealias Query = any Sendable

        private let _fetch: (any Sendable) async throws -> [T]
        private let _save: ([T]) async throws -> Void
        private let _delete: (@Sendable (T) -> Bool) async throws -> Int

        init<S: DataStore>(_ store: S) where S.Item == T {
            _fetch = { query in try await store.fetch(matching: query as! S.Query) }
            _save = { items in try await store.save(items) }
            _delete = { predicate in try await store.delete(where: predicate) }
        }

        func fetch(matching query: any Sendable) async throws -> [T] { try await _fetch(query) }
        func save(_ items: [T]) async throws { try await _save(items) }
        func delete(where predicate: (T) -> Bool) async throws -> Int { try await _delete(predicate) }
    }
    ```

    ## 2. 条件一致性与泛型特化

    ```swift
    extension Array: DataStoreConvertible where Element: Codable & Identifiable {
        func asDataStore() -> AnyDataStore<Element> {
            AnyDataStore(InMemoryStore(initial: self))
        }
    }

    // 条件一致性链
    extension Optional: CustomStringConvertible where Wrapped: CustomStringConvertible {
        public var description: String {
            switch self {
            case .some(let value): return value.description
            case .none: return "nil"
            }
        }
    }

    // 泛型特化 - 编译器优化热路径
    @_specialize(where T == Int)
    @_specialize(where T == String)
    func binarySearch<T: Comparable>(_ array: [T], for value: T) -> Int? {
        var low = 0, high = array.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if array[mid] == value { return mid }
            else if array[mid] < value { low = mid + 1 }
            else { high = mid - 1 }
        }
        return nil
    }
    ```

    ## 3. 不透明类型与存在类型对比

    | 特性 | `some Protocol` | `any Protocol` | 泛型 `<T: Protocol>` |
    |------|----------------|----------------|---------------------|
    | 类型确定性 | 编译期固定 | 运行时动态 | 调用点确定 |
    | 性能开销 | 零（静态分派） | 存在容器开销 | 可特化优化 |
    | 自引用约束 | 支持 | 不支持 | 支持 |
    | 集合异构 | 不支持 | 支持 | 不支持 |
    | 返回值使用 | 隐藏实现 | 协议转换 | 类型推导 |

    ## 4. Result Builder 与泛型组合

    ```swift
    @resultBuilder
    struct PipelineBuilder<Input, Output> {
        static func buildBlock<T0: Transform, T1: Transform>(
            _ t0: T0, _ t1: T1
        ) -> ChainedTransform<T0, T1>
        where T0.Input == Input, T0.Output == T1.Input, T1.Output == Output {
            ChainedTransform(first: t0, second: t1)
        }

        static func buildOptional<T: Transform>(_ component: T?) -> OptionalTransform<T> {
            OptionalTransform(wrapped: component)
        }

        static func buildEither<First: Transform, Second: Transform>(
            first: First
        ) -> EitherTransform<First, Second> {
            .first(first)
        }
    }

    // 使用
    @PipelineBuilder<String, Data>
    var exportPipeline: some Transform<String, Data> {
        TrimWhitespace()
        ValidateLength(max: 10000)
        if useCompression {
            CompressTransform()
        }
        EncodeUTF8()
    }
    ```

    > **要点**: 泛型系统的核心价值在于让编译器在编译期验证类型正确性，同时保持运行时零开销。关联类型 + 条件一致性 + 不透明返回类型三者组合，能构建出既类型安全又高性能的抽象层。
    """

    static let historyRound2 = """
    # 面向协议编程设计模式

    ## 1. 协议组合与依赖注入

    ```swift
    // 细粒度协议定义
    protocol NetworkClient: Sendable {
        func data(from url: URL) async throws -> (Data, URLResponse)
        func upload(_ data: Data, to url: URL) async throws -> (Data, URLResponse)
    }

    protocol CacheProvider: Sendable {
        func get<T: Decodable>(key: String, as type: T.Type) async -> T?
        func set<T: Encodable>(key: String, value: T, ttl: TimeInterval) async
        func invalidate(key: String) async
        func invalidateAll() async
    }

    protocol AnalyticsTracker: Sendable {
        func track(event: String, properties: [String: any Sendable])
        func identify(userId: String, traits: [String: any Sendable])
        func flush() async
    }

    // 协议组合作为依赖容器
    typealias AppServices = NetworkClient & CacheProvider & AnalyticsTracker

    actor ServiceContainer: AppServices {
        private let urlSession: URLSession
        private let cache: NSCache<NSString, CacheEntry>
        private let analyticsQueue: [AnalyticsEvent]

        func data(from url: URL) async throws -> (Data, URLResponse) {
            if let cached = await get(key: url.absoluteString, as: CachedResponse.self) {
                return (cached.data, cached.response)
            }
            let result = try await urlSession.data(from: url)
            await set(key: url.absoluteString, value: CachedResponse(data: result.0, response: result.1), ttl: 300)
            return result
        }

        // ... 其他实现
    }
    ```

    ## 2. 协议见证表与动态分派

    ```swift
    protocol Drawable {
        func draw(in context: GraphicsContext, bounds: CGRect)
        var boundingBox: CGRect { get }
        func hitTest(point: CGPoint) -> Bool
    }

    // 默认实现提供基础行为
    extension Drawable {
        func hitTest(point: CGPoint) -> Bool {
            boundingBox.contains(point)
        }

        func draw(in context: GraphicsContext, bounds: CGRect) {
            let scale = min(bounds.width / boundingBox.width,
                           bounds.height / boundingBox.height)
            var transform = CGAffineTransform(scaleX: scale, y: scale)
            context.concatenate(transform)
            drawContent(in: context)
        }

        func drawContent(in context: GraphicsContext) {}
    }

    // 协议继承链
    protocol Animatable: Drawable {
        var animationDuration: TimeInterval { get }
        func interpolate(from start: Self, to end: Self, progress: Double) -> Self
    }

    protocol Interactive: Drawable {
        func onTap(at point: CGPoint)
        func onDrag(from start: CGPoint, to end: CGPoint)
        func onLongPress(at point: CGPoint, duration: TimeInterval)
    }
    ```

    ## 3. 协议扩展的策略模式

    ```swift
    protocol SortStrategy {
        associatedtype Element
        func sort(_ array: inout [Element])
    }

    struct QuickSort<T: Comparable>: SortStrategy {
        func sort(_ array: inout [T]) {
            guard array.count > 1 else { return }
            quickSort(&array, low: 0, high: array.count - 1)
        }

        private func quickSort(_ array: inout [T], low: Int, high: Int) {
            guard low < high else { return }
            let pivot = partition(&array, low: low, high: high)
            quickSort(&array, low: low, high: pivot - 1)
            quickSort(&array, low: pivot + 1, high: high)
        }

        private func partition(_ array: inout [T], low: Int, high: Int) -> Int {
            let pivot = array[high]
            var i = low
            for j in low..<high {
                if array[j] <= pivot {
                    array.swapAt(i, j)
                    i += 1
                }
            }
            array.swapAt(i, high)
            return i
        }
    }

    struct MergeSort<T: Comparable>: SortStrategy {
        func sort(_ array: inout [T]) {
            array = mergeSort(array)
        }

        private func mergeSort(_ array: [T]) -> [T] {
            guard array.count > 1 else { return array }
            let mid = array.count / 2
            let left = mergeSort(Array(array[..<mid]))
            let right = mergeSort(Array(array[mid...]))
            return merge(left, right)
        }

        private func merge(_ left: [T], _ right: [T]) -> [T] {
            var result: [T] = []
            var i = 0, j = 0
            while i < left.count && j < right.count {
                if left[i] <= right[j] { result.append(left[i]); i += 1 }
                else { result.append(right[j]); j += 1 }
            }
            result.append(contentsOf: left[i...])
            result.append(contentsOf: right[j...])
            return result
        }
    }
    ```

    ## 4. 性能对比

    | 模式 | 静态分派 | 动态分派 | 内存开销 | 适用场景 |
    |------|---------|---------|---------|---------|
    | 泛型约束 | 是 | 否 | 最小 | 性能关键路径 |
    | 协议扩展 | 可能 | 编译器决定 | 无额外 | 默认实现 |
    | 存在类型 | 否 | 是 | 24-40字节容器 | 异构集合 |
    | 类继承 | 否 | 是（vtable） | 引用计数 | UIKit 兼容 |
    | @objc 协议 | 否 | 是（消息转发） | isa指针 | OC 互操作 |

    > **核心理念**: 面向协议编程的本质是"组合优于继承"。通过协议组合 + 条件一致性，可以构建出比类继承树更灵活、更可测试的架构。
    """

    static let historyRound3 = """
    # SwiftUI 大型项目架构设计

    ## 1. 状态管理分层架构

    ```swift
    // Layer 1: App State - 全局单例
    @Observable
    final class AppState {
        var currentUser: User?
        var authToken: String?
        var featureFlags: FeatureFlags = .default
        var networkStatus: NetworkStatus = .connected

        static let shared = AppState()
        private init() {}
    }

    // Layer 2: Feature State - 按功能模块隔离
    @Observable
    final class FeedState {
        var posts: [Post] = []
        var isLoading = false
        var error: FeedError?
        var pagination: PaginationState = .initial
        var filters: FeedFilters = .default

        private let repository: PostRepository
        private let analytics: AnalyticsTracker

        init(repository: PostRepository, analytics: AnalyticsTracker) {
            self.repository = repository
            self.analytics = analytics
        }

        func loadNextPage() async {
            guard !isLoading, pagination.hasMore else { return }
            isLoading = true
            defer { isLoading = false }

            do {
                let newPosts = try await repository.fetchPosts(
                    page: pagination.currentPage + 1,
                    filters: filters
                )
                posts.append(contentsOf: newPosts)
                pagination = pagination.advanced(by: newPosts.count)
                analytics.track(event: "feed_page_loaded", properties: [
                    "page": pagination.currentPage,
                    "count": newPosts.count
                ])
            } catch {
                self.error = .loadFailed(error)
            }
        }

        func refresh() async {
            pagination = .initial
            posts = []
            await loadNextPage()
        }
    }

    // Layer 3: View State - 视图局部状态
    @Observable
    final class PostDetailViewState {
        var post: Post
        var comments: [Comment] = []
        var isLiked: Bool
        var showShareSheet = false
        var replyText = ""

        // 派生状态
        var canSubmitReply: Bool {
            !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    ```

    ## 2. 导航架构 - Coordinator 模式

    ```swift
    @Observable
    final class NavigationCoordinator {
        var rootPath = NavigationPath()
        var sheetItem: SheetDestination?
        var fullScreenCover: FullScreenDestination?
        var alertState: AlertState?

        enum Route: Hashable {
            case postDetail(Post.ID)
            case userProfile(User.ID)
            case settings
            case search(query: String?)
            case thread(Post.ID, Comment.ID)
        }

        enum SheetDestination: Identifiable {
            case compose
            case editProfile
            case imageViewer([URL], selected: Int)
            case share(URL)

            var id: String { String(describing: self) }
        }

        func push(_ route: Route) {
            rootPath.append(route)
        }

        func pop() {
            guard !rootPath.isEmpty else { return }
            rootPath.removeLast()
        }

        func popToRoot() {
            rootPath = NavigationPath()
        }

        func present(_ sheet: SheetDestination) {
            sheetItem = sheet
        }

        func handleDeepLink(_ url: URL) {
            guard let route = DeepLinkParser.parse(url) else { return }
            popToRoot()
            push(route)
        }
    }

    struct AppNavigationView: View {
        @State private var coordinator = NavigationCoordinator()
        @State private var feedState: FeedState

        var body: some View {
            NavigationStack(path: $coordinator.rootPath) {
                FeedView(state: feedState)
                    .navigationDestination(for: NavigationCoordinator.Route.self) { route in
                        switch route {
                        case .postDetail(let id):
                            PostDetailView(postId: id)
                        case .userProfile(let id):
                            UserProfileView(userId: id)
                        case .settings:
                            SettingsView()
                        case .search(let query):
                            SearchView(initialQuery: query)
                        case .thread(let postId, let commentId):
                            ThreadView(postId: postId, focusedComment: commentId)
                        }
                    }
            }
            .sheet(item: $coordinator.sheetItem) { destination in
                switch destination {
                case .compose: ComposeView()
                case .editProfile: EditProfileView()
                case .imageViewer(let urls, let idx): ImageViewerView(urls: urls, selected: idx)
                case .share(let url): ShareSheet(url: url)
                }
            }
            .environment(coordinator)
        }
    }
    ```

    ## 3. 依赖注入容器

    ```swift
    @Observable
    final class DependencyContainer {
        // Singletons
        lazy var networkClient: NetworkClient = URLSessionNetworkClient()
        lazy var cacheProvider: CacheProvider = DiskCacheProvider(directory: .cachesDirectory)
        lazy var analyticsTracker: AnalyticsTracker = MixpanelTracker(token: Config.mixpanelToken)
        lazy var imageLoader: ImageLoader = CachingImageLoader(cache: cacheProvider, network: networkClient)

        // Factories
        func makePostRepository() -> PostRepository {
            RemotePostRepository(network: networkClient, cache: cacheProvider)
        }

        func makeFeedState() -> FeedState {
            FeedState(repository: makePostRepository(), analytics: analyticsTracker)
        }

        func makeAuthService() -> AuthService {
            OAuth2AuthService(network: networkClient, storage: KeychainStorage())
        }
    }

    // SwiftUI Environment integration
    struct DependencyContainerKey: EnvironmentKey {
        static let defaultValue = DependencyContainer()
    }

    extension EnvironmentValues {
        var dependencies: DependencyContainer {
            get { self[DependencyContainerKey.self] }
            set { self[DependencyContainerKey.self] = newValue }
        }
    }
    ```

    ## 4. 架构决策对比

    | 方案 | 状态管理 | 导航 | 测试性 | 学习曲线 | 适用规模 |
    |------|---------|------|--------|---------|---------|
    | 纯 SwiftUI | @State/@Binding | NavigationStack | 中等 | 低 | 小型 |
    | MVVM + Coordinator | @Observable VM | Coordinator | 高 | 中 | 中大型 |
    | TCA | Store/Reducer | NavigationStack | 极高 | 高 | 大型 |
    | 本方案 | 分层 Observable | Coordinator | 高 | 中 | 中大型 |
    | Redux-like | 单一 Store | 中间件 | 高 | 高 | 大型 |

    > **架构不是银弹**: 选择架构时最重要的是团队熟悉度和项目实际需求。过度设计比设计不足更危险。
    """

    static let historyRound4 = """
    # Swift 并发性能优化完整指南

    ## 1. Instruments 并发分析

    ```swift
    // 关键 signpost 用于 Instruments 分析
    import os

    let performanceLog = OSLog(subsystem: "com.app.performance", category: .pointsOfInterest)

    func processLargeDataset(_ data: [Record]) async throws -> [ProcessedRecord] {
        let signpostID = OSSignpostID(log: performanceLog)
        os_signpost(.begin, log: performanceLog, name: "ProcessDataset", signpostID: signpostID,
                    "count: %d", data.count)
        defer {
            os_signpost(.end, log: performanceLog, name: "ProcessDataset", signpostID: signpostID)
        }

        return try await withThrowingTaskGroup(of: [ProcessedRecord].self) { group in
            let chunkSize = max(1, data.count / ProcessInfo.processInfo.activeProcessorCount)
            for chunk in data.chunked(into: chunkSize) {
                group.addTask {
                    os_signpost(.begin, log: performanceLog, name: "ProcessChunk",
                               "size: %d", chunk.count)
                    defer { os_signpost(.end, log: performanceLog, name: "ProcessChunk") }
                    return chunk.map { ProcessedRecord(from: $0) }
                }
            }
            var results: [ProcessedRecord] = []
            results.reserveCapacity(data.count)
            for try await chunk in group {
                results.append(contentsOf: chunk)
            }
            return results
        }
    }
    ```

    ## 2. Actor 调优策略

    ```swift
    // 问题：Actor 串行化导致瓶颈
    actor NaiveImageCache {
        private var cache: [URL: UIImage] = [:]

        // 所有调用排队等待，即使是简单读取
        func image(for url: URL) async -> UIImage? {
            cache[url]
        }

        func store(_ image: UIImage, for url: URL) async {
            cache[url] = image
        }
    }

    // 优化：读写分离 + 批量操作
    actor OptimizedImageCache {
        private var cache: [URL: UIImage] = [:]
        private var pendingLoads: [URL: Task<UIImage?, Never>] = [:]

        // nonisolated 读取已知不可变数据
        nonisolated func cachedImage(for url: URL) -> UIImage? {
            // 使用 concurrent-safe 的独立副本进行读取
            nil // 实际实现使用 lock-free 读
        }

        func loadImage(for url: URL, loader: ImageLoader) async -> UIImage? {
            if let cached = cache[url] { return cached }

            // 合并重复请求
            if let pending = pendingLoads[url] {
                return await pending.value
            }

            let task = Task<UIImage?, Never> {
                guard let image = await loader.load(url) else { return nil }
                cache[url] = image
                pendingLoads.removeValue(forKey: url)
                return image
            }
            pendingLoads[url] = task
            return await task.value
        }

        // 批量预热减少 actor hop 次数
        func preload(urls: [URL], loader: ImageLoader) async {
            await withTaskGroup(of: Void.self) { group in
                for url in urls where cache[url] == nil {
                    group.addTask { [weak self] in
                        _ = await self?.loadImage(for: url, loader: loader)
                    }
                }
            }
        }
    }
    ```

    ## 3. TaskGroup 性能模式

    ```swift
    // 模式1：有界并发
    func downloadWithConcurrencyLimit(
        urls: [URL],
        maxConcurrent: Int = 6
    ) async throws -> [Data] {
        var results = Array<Data?>(repeating: nil, count: urls.count)

        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var index = 0

            // 初始填充
            for _ in 0..<min(maxConcurrent, urls.count) {
                let i = index
                group.addTask { (i, try await URLSession.shared.data(from: urls[i]).0) }
                index += 1
            }

            // 完成一个，启动下一个
            for try await (i, data) in group {
                results[i] = data
                if index < urls.count {
                    let nextIndex = index
                    group.addTask { (nextIndex, try await URLSession.shared.data(from: urls[nextIndex]).0) }
                    index += 1
                }
            }
        }

        return results.compactMap { $0 }
    }

    // 模式2：超时与重试
    func resilientParallelFetch<T: Sendable>(
        tasks: [(id: String, work: @Sendable () async throws -> T)],
        timeout: Duration = .seconds(30),
        retries: Int = 2
    ) async -> [(id: String, result: Result<T, Error>)] {
        await withTaskGroup(of: (String, Result<T, Error>).self) { group in
            for task in tasks {
                group.addTask {
                    var lastError: Error = CancellationError()
                    for attempt in 0...retries {
                        do {
                            let value = try await withTimeout(timeout) {
                                try await task.work()
                            }
                            return (task.id, .success(value))
                        } catch {
                            lastError = error
                            if attempt < retries {
                                try? await Task.sleep(for: .milliseconds(100 * (attempt + 1)))
                            }
                        }
                    }
                    return (task.id, .failure(lastError))
                }
            }

            var results: [(id: String, result: Result<T, Error>)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }
    ```

    ## 4. 性能基准对比

    | 操作 | 无优化 | Actor优化 | TaskGroup优化 | 综合优化 |
    |------|--------|----------|-------------|---------|
    | 100张图片加载 | 12.3s | 8.1s | 2.4s | 1.8s |
    | 1000条JSON解析 | 3.2s | 3.0s | 0.9s | 0.7s |
    | 数据库批量写入 | 5.6s | 4.2s | 1.5s | 1.1s |
    | 文件系统扫描 | 8.9s | 7.5s | 2.1s | 1.6s |
    | 网络请求聚合 | 15.0s | 12.0s | 3.0s | 2.2s |
    | 内存峰值(MB) | 45 | 38 | 120 | 65 |
    | CPU利用率 | 25% | 30% | 85% | 78% |

    ## 5. 关键性能陷阱清单

    - Actor 重入导致状态不一致 → 使用检查点模式
    - Task 泄漏（未取消的后台任务） → 使用 withTaskCancellationHandler
    - 过度 actor hop（频繁跨 actor 调用） → 批量操作 + nonisolated
    - MainActor 阻塞（在主线程做计算） → Task.detached + 回调主线程
    - 内存峰值（并行产生大量中间数据） → 有界并发 + 流式处理
    - Sendable 逃逸检查绕过（@unchecked） → 仅在确认安全时使用

    > **性能优化的第一法则**: 先测量，再优化。Instruments 的 Swift Concurrency 模板可以可视化 Task 的创建、挂起、恢复全生命周期，是定位并发瓶颈的最佳工具。
    """

    /// 50 aggressive streaming steps with large chunks, simulating rapid output
    static var streamingSteps: [StreamingStep] {
        var steps: [StreamingStep] = []

        // Steps 1-3: thinking (long CoT)
        steps.append(StreamingStep(content: "", thinking: """
        用户要求一份综合文档，涵盖泛型、协议、SwiftUI 架构和并发四大主题。这是一个非常大的请求，我需要系统性地组织内容。

        先拆解目标：泛型部分解释关联类型、类型擦除和条件一致性；协议部分覆盖组合、依赖注入和测试替身；SwiftUI 部分说明状态所有权、导航与模块边界；并发部分则需要 Actor、TaskGroup、取消和性能分析。每个主题都应有可运行的代码，而不是只列概念。
        """))
        steps.append(StreamingStep(content: "", thinking: """

        接下来安排章节之间的依赖顺序。先用协议定义领域边界，再用泛型实现可复用的数据层，之后把这些能力注入 SwiftUI 的状态容器，最后使用结构化并发串起数据加载。这样后面的示例可以复用前面已经建立的类型，读者不会面对彼此割裂的代码片段。

        对比表格要聚焦真实取舍，例如静态分派与动态分派、值语义与共享状态、串行隔离与任务并行度。性能数字必须明确是示例基准，避免让读者把它们误认为适用于所有设备的结论。
        """))
        steps.append(StreamingStep(content: "", thinking: """

        最后检查文档的可读性和完整性：每节先给结论，再解释机制，然后给代码和常见陷阱；长代码示例需要保持命名一致；并发示例必须处理错误传播与取消；SwiftUI 示例要确保 UI 状态只在 MainActor 更新。结尾再提供从小型项目到大型项目的渐进式采用路径和决策清单。

        这些约束已经足够明确，可以开始生成完整文档。
        """))

        // Steps 4-8: title + architecture overview (large chunks)
        steps.append(StreamingStep(content: """
        # Swift 项目架构最佳实践完整指南

        ## 目录

        1. 架构总览与设计原则
        2. 泛型系统在架构中的应用
        3. 面向协议的模块化设计
        4. SwiftUI 状态与导航架构
        5. 并发层设计与性能保障
        6. 综合实践：完整项目模板

        ---

        ## 1. 架构总览与设计原则

        现代 Swift 项目架构的核心目标是**类型安全**、**可测试性**和**性能**三者兼得。

        """, thinking: nil))

        steps.append(StreamingStep(content: """
        ### 1.1 分层架构模型

        ```
        ┌─────────────────────────────────────────────┐
        │              Presentation Layer              │
        │    SwiftUI Views / ViewModels / Coordinators │
        ├─────────────────────────────────────────────┤
        │               Domain Layer                   │
        │    Protocols / Use Cases / Entities          │
        ├─────────────────────────────────────────────┤
        │                Data Layer                    │
        │    Repositories / Network / Persistence     │
        ├─────────────────────────────────────────────┤
        │             Infrastructure Layer            │
        │    DI Container / Logging / Analytics       │
        └─────────────────────────────────────────────┘
        ```

        """, thinking: nil))

        steps.append(StreamingStep(content: """
        ### 1.2 核心设计原则

        | 原则 | 描述 | Swift 实现方式 |
        |------|------|---------------|
        | 依赖倒置 | 高层不依赖低层实现 | Protocol + DI Container |
        | 单一职责 | 每个类型只做一件事 | 细粒度 Protocol 分离 |
        | 开闭原则 | 对扩展开放对修改关闭 | Protocol Extension + 泛型 |
        | 接口隔离 | 不强制依赖无用接口 | Protocol Composition |
        | 里氏替换 | 子类型必须可替换 | associatedtype 约束 |
        | 组合优于继承 | 避免深层继承树 | Protocol + struct |

        """, thinking: nil))

        steps.append(StreamingStep(content: """
        ## 2. 泛型系统在架构中的应用

        ### 2.1 泛型仓储模式

        ```swift
        protocol Repository<Entity> {
            associatedtype Entity: Identifiable & Sendable
            associatedtype Filter

            func fetchAll(filter: Filter?) async throws -> [Entity]
            func fetch(id: Entity.ID) async throws -> Entity?
            func create(_ entity: Entity) async throws -> Entity
            func update(_ entity: Entity) async throws -> Entity
            func delete(id: Entity.ID) async throws
            func count(filter: Filter?) async throws -> Int
        }

        // 默认实现提供分页支持
        extension Repository {
            func fetchPaginated(
                page: Int,
                pageSize: Int = 20,
                filter: Filter? = nil
            ) async throws -> PaginatedResult<Entity> {
                let all = try await fetchAll(filter: filter)
                let start = page * pageSize
                let end = min(start + pageSize, all.count)
                guard start < all.count else {
                    return PaginatedResult(items: [], total: all.count, hasMore: false)
                }
                return PaginatedResult(
                    items: Array(all[start..<end]),
                    total: all.count,
                    hasMore: end < all.count
                )
            }
        }
        ```

        """, thinking: nil))

        steps.append(StreamingStep(content: """
        ### 2.2 泛型网络层

        ```swift
        protocol APIEndpoint {
            associatedtype Request: Encodable & Sendable
            associatedtype Response: Decodable & Sendable

            var path: String { get }
            var method: HTTPMethod { get }
            var headers: [String: String] { get }
            var requiresAuth: Bool { get }
        }

        extension APIEndpoint {
            var headers: [String: String] { [:] }
            var requiresAuth: Bool { true }
        }

        struct APIClient {
            private let session: URLSession
            private let baseURL: URL
            private let tokenProvider: () async -> String?
            private let decoder: JSONDecoder
            private let encoder: JSONEncoder

            func execute<E: APIEndpoint>(
                _ endpoint: E,
                body: E.Request
            ) async throws -> E.Response {
                var request = URLRequest(url: baseURL.appending(path: endpoint.path))
                request.httpMethod = endpoint.method.rawValue
                request.httpBody = try encoder.encode(body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                for (key, value) in endpoint.headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }

                if endpoint.requiresAuth, let token = await tokenProvider() {
                    request.setValue("Bearer \\(token)", forHTTPHeaderField: "Authorization")
                }

                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw APIError.invalidResponse
                }

                switch httpResponse.statusCode {
                case 200...299:
                    return try decoder.decode(E.Response.self, from: data)
                case 401:
                    throw APIError.unauthorized
                case 429:
                    throw APIError.rateLimited(retryAfter: httpResponse.value(forHTTPHeaderField: "Retry-After"))
                default:
                    throw APIError.httpError(statusCode: httpResponse.statusCode, body: data)
                }
            }
        }
        ```

        """, thinking: nil))

        // Steps 9-18: SwiftUI architecture section (large chunks with tables)
        steps.append(StreamingStep(content: """
        ## 3. 面向协议的模块化设计

        ### 3.1 Feature Module 协议

        ```swift
        protocol FeatureModule {
            associatedtype State: Observable
            associatedtype Coordinator: NavigationCoordinating

            var state: State { get }
            var coordinator: Coordinator { get }

            func bootstrap(with container: DependencyContainer) async
            func teardown() async
        }

        protocol NavigationCoordinating: Observable {
            associatedtype Route: Hashable
            var path: [Route] { get set }
            func handle(deepLink: URL) -> Bool
        }

        // 模块注册表
        actor ModuleRegistry {
            private var modules: [String: any FeatureModule] = [:]

            func register<M: FeatureModule>(_ module: M, key: String) {
                modules[key] = module
            }

            func module<M: FeatureModule>(for key: String, as type: M.Type) -> M? {
                modules[key] as? M
            }

            func bootstrapAll(with container: DependencyContainer) async {
                await withTaskGroup(of: Void.self) { group in
                    for (_, module) in modules {
                        group.addTask { await module.bootstrap(with: container) }
                    }
                }
            }
        }
        ```

        """, thinking: nil))

        steps.append(StreamingStep(content: """
        ### 3.2 测试替身协议

        ```swift
        // 所有外部依赖通过协议抽象
        protocol TimeProvider: Sendable {
            var now: Date { get }
            func sleep(for duration: Duration) async throws
        }

        struct SystemTimeProvider: TimeProvider {
            var now: Date { Date() }
            func sleep(for duration: Duration) async throws {
                try await Task.sleep(for: duration)
            }
        }

        actor MockTimeProvider: TimeProvider {
            private var _now: Date
            var now: Date { _now }

            init(fixed: Date = Date()) { _now = fixed }

            func advance(by interval: TimeInterval) { _now.addTimeInterval(interval) }
            func sleep(for duration: Duration) async throws { /* instant */ }
        }

        protocol UUIDGenerator: Sendable {
            func generate() -> UUID
        }

        struct SystemUUIDGenerator: UUIDGenerator {
            func generate() -> UUID { UUID() }
        }

        struct DeterministicUUIDGenerator: UUIDGenerator {
            let ids: [UUID]
            private let counter = ManagedAtomic<Int>(0)

            func generate() -> UUID {
                let idx = counter.loadThenWrappingIncrement(ordering: .relaxed)
                return ids[idx % ids.count]
            }
        }
        ```

        """, thinking: nil))

        steps.append(StreamingStep(content: """
        ## 4. SwiftUI 状态与导航架构

        ### 4.1 响应式状态流

        ```swift
        @Observable
        final class ViewModelBase<State, Action> {
            private(set) var state: State
            private let reducer: (inout State, Action) -> Effect<Action>
            private var effectTasks: [UUID: Task<Void, Never>] = [:]

            init(initialState: State, reducer: @escaping (inout State, Action) -> Effect<Action>) {
                self.state = initialState
                self.reducer = reducer
            }

            func send(_ action: Action) {
                let effect = reducer(&state, action)
                switch effect {
                case .none:
                    break
                case .task(let work):
                    let id = UUID()
                    effectTasks[id] = Task { [weak self] in
                        defer { self?.effectTasks.removeValue(forKey: id) }
                        if let nextAction = await work() {
                            self?.send(nextAction)
                        }
                    }
                case .cancel(let id):
                    effectTasks[id]?.cancel()
                    effectTasks.removeValue(forKey: id)
                }
            }

            deinit {
                effectTasks.values.forEach { $0.cancel() }
            }
        }

        enum Effect<Action> {
            case none
            case task(@Sendable () async -> Action?)
            case cancel(UUID)
        }
        ```

        """, thinking: nil))

        steps.append(StreamingStep(content: """
        ### 4.2 导航状态机

        ```swift
        @Observable
        final class TabCoordinator {
            enum Tab: String, CaseIterable {
                case feed, search, notifications, profile
            }

            var selectedTab: Tab = .feed
            var feedPath = NavigationPath()
            var searchPath = NavigationPath()
            var notificationsPath = NavigationPath()
            var profilePath = NavigationPath()

            var currentPath: Binding<NavigationPath> {
                switch selectedTab {
                case .feed: return Binding(get: { self.feedPath }, set: { self.feedPath = $0 })
                case .search: return Binding(get: { self.searchPath }, set: { self.searchPath = $0 })
                case .notifications: return Binding(get: { self.notificationsPath }, set: { self.notificationsPath = $0 })
                case .profile: return Binding(get: { self.profilePath }, set: { self.profilePath = $0 })
                }
            }

            func resetCurrentTab() {
                switch selectedTab {
                case .feed: feedPath = NavigationPath()
                case .search: searchPath = NavigationPath()
                case .notifications: notificationsPath = NavigationPath()
                case .profile: profilePath = NavigationPath()
                }
            }

            func handleDeepLink(_ url: URL) -> Bool {
                guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      let host = components.host else { return false }

                switch host {
                case "post":
                    guard let id = components.queryItems?.first(where: { $0.name == "id" })?.value else { return false }
                    selectedTab = .feed
                    feedPath.append(FeedRoute.postDetail(id))
                    return true
                case "user":
                    guard let id = components.queryItems?.first(where: { $0.name == "id" })?.value else { return false }
                    selectedTab = .profile
                    profilePath.append(ProfileRoute.user(id))
                    return true
                default:
                    return false
                }
            }
        }
        ```

        """, thinking: nil))

        steps.append(StreamingStep(content: """
        ### 4.3 大型列表性能优化

        | 技术 | 场景 | 收益 | 复杂度 |
        |------|------|------|--------|
        | LazyVStack | 长列表 | 减少初始渲染 | 低 |
        | .id() 稳定性 | 数据更新 | 避免全量重建 | 低 |
        | equatable() | 复杂Cell | 跳过无变化重绘 | 中 |
        | drawingGroup() | 大量图形 | GPU 合成 | 低 |
        | 预加载 | 无限滚动 | 消除加载等待 | 中 |
        | 虚拟化 | 万级列表 | 恒定内存 | 高 |
        | 增量 diff | 实时更新 | 动画流畅 | 高 |

        """, thinking: nil))

        // Steps 19-30: Concurrency architecture (rapid output)
        steps.append(StreamingStep(content: """
        ## 5. 并发层设计与性能保障

        ### 5.1 并发架构分层

        ```swift
        // 基础设施层：Actor 池
        actor WorkerPool<T: Sendable> {
            private let workers: [Worker<T>]
            private var nextIndex = 0

            init(count: Int, factory: @Sendable (Int) -> Worker<T>) {
                workers = (0..<count).map { factory($0) }
            }

            func execute(_ work: @Sendable () async throws -> T) async rethrows -> T {
                let worker = workers[nextIndex % workers.count]
                nextIndex += 1
                return try await worker.execute(work)
            }
        }

        actor Worker<T: Sendable> {
            private var currentTask: Task<T, Error>?
            private var queuedWork: [@Sendable () async throws -> T] = []

            func execute(_ work: @Sendable () async throws -> T) async rethrows -> T {
                try await work()
            }
        }

        // 业务层：有背压的数据管道
        actor DataPipeline<Input: Sendable, Output: Sendable> {
            private let bufferSize: Int
            private var buffer: [Input] = []
            private let transform: @Sendable ([Input]) async throws -> [Output]
            private var outputContinuation: AsyncStream<[Output]>.Continuation?

            init(bufferSize: Int, transform: @escaping @Sendable ([Input]) async throws -> [Output]) {
                self.bufferSize = bufferSize
                self.transform = transform
            }

            func push(_ items: [Input]) async throws {
                buffer.append(contentsOf: items)
                if buffer.count >= bufferSize {
                    let batch = Array(buffer.prefix(bufferSize))
                    buffer.removeFirst(min(bufferSize, buffer.count))
                    let output = try await transform(batch)
                    outputContinuation?.yield(output)
                }
            }

            func flush() async throws {
                guard !buffer.isEmpty else { return }
                let output = try await transform(buffer)
                buffer.removeAll()
                outputContinuation?.yield(output)
            }
        }
        ```

        """, thinking: nil))

        steps.append(StreamingStep(content: """
        ### 5.2 任务生命周期管理

        ```swift
        @Observable
        final class TaskLifecycleManager {
            private var activeTasks: [String: Task<Void, Never>] = [:]
            private var taskMetrics: [String: TaskMetrics] = [:]

            struct TaskMetrics {
                var startTime: ContinuousClock.Instant
                var completionCount: Int = 0
                var errorCount: Int = 0
                var averageDuration: Duration = .zero
            }

            func start(
                id: String,
                priority: TaskPriority = .medium,
                operation: @escaping @Sendable () async throws -> Void
            ) {
                cancel(id: id)
                let metrics = TaskMetrics(startTime: .now)
                taskMetrics[id] = metrics

                activeTasks[id] = Task(priority: priority) { [weak self] in
                    do {
                        try await operation()
                        self?.recordCompletion(id: id)
                    } catch is CancellationError {
                        // Expected, no-op
                    } catch {
                        self?.recordError(id: id)
                    }
                    self?.activeTasks.removeValue(forKey: id)
                }
            }

            func cancel(id: String) {
                activeTasks[id]?.cancel()
                activeTasks.removeValue(forKey: id)
            }

            func cancelAll() {
                activeTasks.values.forEach { $0.cancel() }
                activeTasks.removeAll()
            }

            private func recordCompletion(id: String) {
                guard var m = taskMetrics[id] else { return }
                m.completionCount += 1
                m.averageDuration = (ContinuousClock.now - m.startTime) / m.completionCount
                taskMetrics[id] = m
            }

            private func recordError(id: String) {
                taskMetrics[id]?.errorCount += 1
            }
        }
        ```

        """, thinking: nil))

        steps.append(StreamingStep(content: """
        ### 5.3 MainActor 调度优化

        ```swift
        // 避免不必要的 MainActor hop
        @MainActor
        final class UIStateManager {
            private(set) var items: [DisplayItem] = []
            private(set) var isUpdating = false

            // 批量更新减少 UI 刷新次数
            func batchUpdate(with rawItems: [RawItem]) async {
                isUpdating = true
                defer { isUpdating = false }

                // 在后台处理数据转换
                let processed = await Task.detached(priority: .userInitiated) {
                    rawItems.map { raw in
                        DisplayItem(
                            id: raw.id,
                            title: Self.formatTitle(raw.title),
                            subtitle: Self.formatSubtitle(raw.metadata),
                            image: Self.resolveImage(raw.imageURL),
                            accessory: Self.buildAccessory(raw.status)
                        )
                    }
                }.value

                // 增量 diff 只更新变化的项
                let changes = DiffEngine.diff(old: items, new: processed)
                if changes.isEmpty { return }

                withAnimation(.easeInOut(duration: 0.25)) {
                    items = processed
                }
            }

            // nonisolated 计算不需要主线程
            nonisolated private static func formatTitle(_ raw: String) -> AttributedString {
                var attr = AttributedString(raw)
                if let range = attr.range(of: #/\\b\\d+\\b/#) {
                    attr[range].foregroundColor = .blue
                    attr[range].font = .monospacedDigit(.body)()
                }
                return attr
            }

            nonisolated private static func formatSubtitle(_ metadata: [String: String]) -> String {
                metadata.sorted(by: { $0.key < $1.key })
                    .map { "\\($0.key): \\($0.value)" }
                    .joined(separator: " · ")
            }
        }
        ```

        """, thinking: nil))

        steps.append(StreamingStep(content: """
        ## 6. 综合实践：完整项目模板

        ### 6.1 项目结构

        ```
        MyApp/
        ├── App/
        │   ├── MyAppApp.swift
        │   ├── DependencyContainer.swift
        │   └── AppDelegate.swift
        ├── Core/
        │   ├── Protocols/
        │   │   ├── Repository.swift
        │   │   ├── UseCase.swift
        │   │   └── NetworkClient.swift
        │   ├── Models/
        │   │   ├── User.swift
        │   │   ├── Post.swift
        │   │   └── Comment.swift
        │   └── Extensions/
        │       ├── Collection+Async.swift
        │       └── Task+Timeout.swift
        ├── Features/
        │   ├── Feed/
        │   │   ├── FeedModule.swift
        │   │   ├── FeedState.swift
        │   │   ├── FeedView.swift
        │   │   └── PostCardView.swift
        │   ├── Profile/
        │   │   ├── ProfileModule.swift
        │   │   ├── ProfileState.swift
        │   │   └── ProfileView.swift
        │   └── Search/
        │       ├── SearchModule.swift
        │       ├── SearchState.swift
        │       └── SearchView.swift
        ├── Infrastructure/
        │   ├── Network/
        │   │   ├── APIClient.swift
        │   │   └── Endpoints/
        │   ├── Persistence/
        │   │   ├── SwiftDataStore.swift
        │   │   └── Migrations/
        │   └── Concurrency/
        │       ├── WorkerPool.swift
        │       ├── TaskManager.swift
        │       └── DataPipeline.swift
        └── Tests/
            ├── UnitTests/
            ├── IntegrationTests/
            └── UITests/
        ```

        """, thinking: nil))

        steps.append(StreamingStep(content: """
        ### 6.2 启动流程与性能预算

        ```swift
        @main
        struct MyAppApp: App {
            @State private var container = DependencyContainer()
            @State private var isReady = false

            var body: some Scene {
                WindowGroup {
                    if isReady {
                        RootView()
                            .environment(container)
                    } else {
                        LaunchScreen()
                    }
                }
                .task {
                    await bootstrap()
                }
            }

            private func bootstrap() async {
                // 阶段1: 关键路径 (< 100ms)
                await container.initializeCritical()

                // 阶段2: 显示UI
                isReady = true

                // 阶段3: 后台初始化 (不阻塞UI)
                Task.detached(priority: .background) {
                    await container.initializeNonCritical()
                }
            }
        }
        ```

        """, thinking: nil))

        steps.append(StreamingStep(content: """
        ### 6.3 完整性能预算表

        | 阶段 | 目标时间 | 关键指标 | 优化手段 |
        |------|---------|---------|---------|
        | 冷启动 | < 400ms | Time to First Frame | 延迟加载 + 最小化 didFinishLaunching |
        | 首屏渲染 | < 200ms | Time to Interactive | 骨架屏 + 异步数据加载 |
        | 列表滚动 | 16ms/帧 | Frame Drop Rate < 1% | LazyVStack + 预计算布局 |
        | 网络请求 | < 2s P95 | TTFB + 解析时间 | 缓存 + 预加载 + 压缩 |
        | 内存峰值 | < 150MB | Dirty Memory | 图片降采样 + 对象池 |
        | 动画帧率 | 60fps | Hitches < 5ms | Metal + drawingGroup |
        | 后台任务 | < 30s | BGTaskScheduler | 分批处理 + 检查点 |
        | 数据库查询 | < 50ms | 单次查询时间 | 索引 + 批量读取 |

        """, thinking: nil))

        // Steps 31-40: More rapid content with complex markdown
        steps.append(StreamingStep(content: """
        ### 6.4 错误处理架构

        ```swift
        // 分层错误类型
        enum AppError: Error, LocalizedError {
            case network(NetworkError)
            case persistence(PersistenceError)
            case business(BusinessError)
            case system(SystemError)

            var errorDescription: String? {
                switch self {
                case .network(let e): return e.userMessage
                case .persistence(let e): return e.userMessage
                case .business(let e): return e.userMessage
                case .system(let e): return e.userMessage
                }
            }

            var isRetryable: Bool {
                switch self {
                case .network(let e): return e.isRetryable
                case .persistence: return false
                case .business: return false
                case .system: return true
                }
            }

            var analyticsProperties: [String: any Sendable] {
                ["error_domain": domain, "error_code": code, "is_retryable": isRetryable]
            }

            private var domain: String {
                switch self {
                case .network: return "network"
                case .persistence: return "persistence"
                case .business: return "business"
                case .system: return "system"
                }
            }
        }

        enum NetworkError: Error {
            case timeout(Duration)
            case noConnection
            case serverError(statusCode: Int, body: Data?)
            case decodingFailed(DecodingError)
            case certificatePinningFailed

            var isRetryable: Bool {
                switch self {
                case .timeout, .noConnection, .serverError(let code, _) where code >= 500:
                    return true
                default:
                    return false
                }
            }

            var userMessage: String {
                switch self {
                case .timeout: return "请求超时，请检查网络后重试"
                case .noConnection: return "网络未连接"
                case .serverError: return "服务器繁忙，请稍后重试"
                case .decodingFailed: return "数据解析失败"
                case .certificatePinningFailed: return "安全验证失败"
                }
            }
        }
        ```

        """, thinking: nil))

        steps.append(StreamingStep(content: """
        ### 6.5 监控与可观测性

        ```swift
        actor PerformanceMonitor {
            static let shared = PerformanceMonitor()

            struct Trace: Sendable {
                let name: String
                let start: ContinuousClock.Instant
                var checkpoints: [(name: String, time: ContinuousClock.Instant)] = []
                var metadata: [String: String] = [:]
            }

            private var activeTraces: [String: Trace] = [:]
            private var completedTraces: [Trace] = []
            private let maxHistory = 1000

            func beginTrace(_ name: String) -> String {
                let id = UUID().uuidString
                activeTraces[id] = Trace(name: name, start: .now)
                return id
            }

            func checkpoint(traceId: String, name: String) {
                activeTraces[traceId]?.checkpoints.append((name, .now))
            }

            func endTrace(id: String) {
                guard var trace = activeTraces.removeValue(forKey: id) else { return }
                trace.checkpoints.append(("end", .now))
                completedTraces.append(trace)
                if completedTraces.count > maxHistory {
                    completedTraces.removeFirst(completedTraces.count - maxHistory)
                }

                // 报告慢操作
                let duration = ContinuousClock.now - trace.start
                if duration > .seconds(2) {
                    reportSlowOperation(trace: trace, duration: duration)
                }
            }

            private func reportSlowOperation(trace: Trace, duration: Duration) {
                let checkpointInfo = trace.checkpoints.enumerated().map { i, cp in
                    let elapsed = i == 0
                        ? cp.time - trace.start
                        : cp.time - trace.checkpoints[i-1].time
                    return "  [\\(cp.name)] +\\(elapsed)"
                }.joined(separator: "\\n")

                Logger.performance.warning(\"\"\"
                Slow operation detected: \\(trace.name) took \\(duration)
                Checkpoints:
                \\(checkpointInfo)
                \"\"\")
            }
        }
        ```

        """, thinking: nil))

        steps.append(StreamingStep(content: """
        ### 6.6 全局并发配置

        ```swift
        struct ConcurrencyConfig {
            /// 网络请求最大并发数
            static let maxNetworkConcurrency = 8

            /// 图片解码最大并发数（CPU密集，限制为核心数）
            static let maxDecodeConcurrency = ProcessInfo.processInfo.activeProcessorCount

            /// 数据库写入队列（串行保证一致性）
            static let dbWriteConcurrency = 1

            /// 后台同步间隔
            static let backgroundSyncInterval: Duration = .seconds(30)

            /// Task 超时默认值
            static let defaultTimeout: Duration = .seconds(15)

            /// 请求重试配置
            static let retryPolicy = RetryPolicy(
                maxAttempts: 3,
                baseDelay: .milliseconds(200),
                maxDelay: .seconds(5),
                backoffMultiplier: 2.0,
                jitter: 0.1
            )
        }

        struct RetryPolicy: Sendable {
            let maxAttempts: Int
            let baseDelay: Duration
            let maxDelay: Duration
            let backoffMultiplier: Double
            let jitter: Double

            func delay(for attempt: Int) -> Duration {
                let exponential = baseDelay * pow(backoffMultiplier, Double(attempt))
                let clamped = min(exponential, maxDelay)
                let jitterRange = clamped * jitter
                let randomJitter = Duration.milliseconds(Int.random(in: 0...Int(jitterRange.components.attoseconds / 1_000_000_000_000_000)))
                return clamped + randomJitter
            }
        }
        ```

        """, thinking: nil))

        steps.append(StreamingStep(content: """
        ---

        ## 总结

        ### 架构选择决策树

        ```
        项目规模评估
        ├── 小型（< 10 screens）
        │   └── 纯 SwiftUI + @Observable → 简单直接
        ├── 中型（10-50 screens）
        │   └── 分层 Observable + Coordinator → 本文推荐方案
        └── 大型（50+ screens，多团队）
            └── 模块化 + 严格协议边界 + Feature Flags
        ```

        ### 核心要点回顾

        | 主题 | 关键收获 | 最常见错误 |
        |------|---------|-----------|
        | 泛型 | 编译期安全 + 零运行时开销 | 过度泛化导致可读性差 |
        | 协议 | 组合优于继承 + 可测试性 | 协议滥用（万物皆协议） |
        | SwiftUI | 状态分层 + 单向数据流 | 在 View 中放业务逻辑 |
        | 并发 | 有界并发 + Actor 隔离 | 忽略取消 + 无背压控制 |

        """, thinking: nil))

        steps.append(StreamingStep(content: """
        ### 最终建议

        > **架构的目标不是展示技术能力，而是让团队能快速、安全地交付功能。** 选择你的团队能理解和维护的最简单方案，在确实遇到瓶颈时再引入更复杂的抽象。

        1. **从简单开始** — 不要过早架构化
        2. **持续重构** — 让架构随项目增长演进
        3. **测试驱动** — 如果难以测试，说明耦合过紧
        4. **性能预算** — 定义并监控关键指标
        5. **文档即代码** — 用 Protocol 和类型系统表达架构意图
        """, thinking: nil))

        return steps
    }
}
#endif
