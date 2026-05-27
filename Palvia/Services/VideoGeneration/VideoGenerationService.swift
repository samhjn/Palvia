import Foundation
import AVFoundation
import UIKit

// MARK: - Error Types

enum VideoGenerationError: LocalizedError {
    case noProviderConfigured
    case invalidURL(String)
    case apiError(statusCode: Int, message: String)
    case noTaskIdReturned
    case generationFailed(String)
    case timeout
    case downloadFailed(String)
    case invalidVideoData

    var errorDescription: String? {
        switch self {
        case .noProviderConfigured:
            return "No video generation provider configured."
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .apiError(let code, let msg):
            return "API error (\(code)): \(msg)"
        case .noTaskIdReturned:
            return "No task ID returned by the API."
        case .generationFailed(let reason):
            return "Video generation failed: \(reason)"
        case .timeout:
            return "Video generation timed out."
        case .downloadFailed(let url):
            return "Failed to download video from: \(url)"
        case .invalidVideoData:
            return "Invalid video data received."
        }
    }
}

// MARK: - Poll Status

enum PollStatus: Sendable {
    case pending(detail: String?)
    case processing(progress: String?)
    case completed(videoURL: String)
    case failed(reason: String)
}

// MARK: - Video Generation Phase (progress reporting)

/// Describes the current phase of a video generation request, used for UI progress reporting.
enum VideoGenerationPhase: Sendable {
    case submitting
    case submitted(taskId: String)
    case polling(status: PollStatus, elapsed: TimeInterval)
    case downloading
    case completed
    case failed(String)
}

// MARK: - VideoGenProvider (closure-driven multi-provider adapter)

struct VideoGenProvider: @unchecked Sendable {
    /// Build the URLRequest for submitting a video generation task.
    let buildSubmitRequest: (
        _ endpoint: String, _ apiKey: String, _ model: String,
        _ prompt: String, _ duration: String?, _ aspectRatio: String?,
        _ imageData: Data?
    ) throws -> URLRequest

    /// Parse the task ID / operation name from the submit response.
    /// `imageData` indicates whether this was an I2V request (non-nil) or T2V (nil),
    /// allowing providers that use separate endpoints (e.g. Kling) to encode the mode.
    let parseTaskId: (_ responseData: Data, _ imageData: Data?) throws -> String

    /// Build the URLRequest for polling task status.
    let buildPollRequest: (
        _ endpoint: String, _ apiKey: String, _ taskId: String
    ) throws -> URLRequest

    /// Parse the poll response into a PollStatus.
    let parsePollResponse: (_ responseData: Data) throws -> PollStatus

    /// Build the URLRequest for downloading the completed video.
    /// Some APIs (e.g. Google Veo) require auth headers for download.
    let buildDownloadRequest: (
        _ videoURL: String, _ apiKey: String
    ) throws -> URLRequest

    // MARK: - Provider Resolution

    /// Resolve the video provider adapter based on the provider's API style.
    static func resolve(apiStyle: APIStyle) -> VideoGenProvider {
        switch apiStyle {
        case .googleVeo:
            return googleVeoProvider()
        case .dashScope:
            return dashScopeProvider()
        case .kling:
            return klingProvider()
        case .seedance:
            return seedanceProvider()
        case .openAI, .openAIResponses, .anthropic:
            // OpenAI-compatible REST polling (Sora, Runway, Luma, etc.)
            return restPollingProvider()
        }
    }
}

// MARK: - REST Polling Provider (Sora, Runway, Luma)

extension VideoGenProvider {
    static func restPollingProvider() -> VideoGenProvider {
        VideoGenProvider(
            buildSubmitRequest: { endpoint, apiKey, model, prompt, duration, aspectRatio, imageData in
                let baseURL = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
                let urlStr = "\(baseURL)/videos/generations"
                guard let url = URL(string: urlStr) else {
                    throw VideoGenerationError.invalidURL(urlStr)
                }

                var body: [String: Any] = ["model": model, "prompt": prompt]
                if let duration { body["duration"] = duration }
                if let aspectRatio { body["aspect_ratio"] = aspectRatio }
                if let imageData {
                    body["image"] = "data:image/png;base64,\(imageData.base64EncodedString())"
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.addValue("application/json", forHTTPHeaderField: "Content-Type")
                request.addValue(APIRequestBuilder.userAgent, forHTTPHeaderField: "User-Agent")
                if !apiKey.isEmpty {
                    request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                return request
            },
            parseTaskId: { data, _ in
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let taskId = json["id"] as? String else {
                    throw VideoGenerationError.noTaskIdReturned
                }
                return taskId
            },
            buildPollRequest: { endpoint, apiKey, taskId in
                let baseURL = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
                let urlStr = "\(baseURL)/videos/generations/\(taskId)"
                guard let url = URL(string: urlStr) else {
                    throw VideoGenerationError.invalidURL(urlStr)
                }
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                if !apiKey.isEmpty {
                    request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }
                return request
            },
            parsePollResponse: { data in
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw VideoGenerationError.generationFailed("Invalid poll response")
                }
                let status = (json["status"] as? String)?.lowercased() ?? ""
                if status == "completed" || status == "succeeded" {
                    // Try common output paths
                    if let output = json["output"] as? [String: Any], let url = output["video"] as? String {
                        return .completed(videoURL: url)
                    }
                    if let assets = json["assets"] as? [String: Any], let url = assets["video"] as? String {
                        return .completed(videoURL: url)
                    }
                    if let url = json["video_url"] as? String {
                        return .completed(videoURL: url)
                    }
                    // Fallback: search for any URL-like string in output
                    if let output = json["output"] as? String, output.hasPrefix("http") {
                        return .completed(videoURL: output)
                    }
                    throw VideoGenerationError.generationFailed("Completed but no video URL found in response")
                }
                if status == "failed" || status == "error" {
                    let reason = (json["error"] as? [String: Any])?["message"] as? String
                        ?? json["message"] as? String ?? "Unknown error"
                    return .failed(reason: reason)
                }
                if status == "processing" || status == "running" || status == "in_progress" {
                    return .processing(progress: json["progress"] as? String)
                }
                return .pending(detail: status.isEmpty ? nil : status)
            },
            buildDownloadRequest: { videoURL, _ in
                guard let url = URL(string: videoURL) else {
                    throw VideoGenerationError.downloadFailed(videoURL)
                }
                return URLRequest(url: url)
            }
        )
    }
}

// MARK: - Google Veo Provider (Gemini API)

extension VideoGenProvider {
    static func googleVeoProvider() -> VideoGenProvider {
        VideoGenProvider(
            buildSubmitRequest: { endpoint, apiKey, model, prompt, duration, aspectRatio, imageData in
                let baseURL = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
                let urlStr = "\(baseURL)/models/\(model):predictLongRunning"
                guard let url = URL(string: urlStr) else {
                    throw VideoGenerationError.invalidURL(urlStr)
                }

                var instance: [String: Any] = ["prompt": prompt]
                if let imageData {
                    instance["image"] = [
                        "inlineData": [
                            "mimeType": "image/png",
                            "data": imageData.base64EncodedString()
                        ]
                    ]
                }

                var parameters: [String: Any] = [:]
                if let aspectRatio { parameters["aspectRatio"] = aspectRatio }
                if let duration {
                    let seconds = duration.replacingOccurrences(of: "s", with: "")
                    parameters["durationSeconds"] = seconds
                }
                parameters["personGeneration"] = "allow_adult"

                let body: [String: Any] = [
                    "instances": [instance],
                    "parameters": parameters
                ]

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.addValue("application/json", forHTTPHeaderField: "Content-Type")
                request.addValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                return request
            },
            parseTaskId: { data, _ in
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let name = json["name"] as? String else {
                    throw VideoGenerationError.noTaskIdReturned
                }
                return name
            },
            buildPollRequest: { endpoint, apiKey, taskId in
                // taskId is the full operation name (e.g. "operations/generate-video-abc123")
                let baseURL = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
                let urlStr = "\(baseURL)/\(taskId)"
                guard let url = URL(string: urlStr) else {
                    throw VideoGenerationError.invalidURL(urlStr)
                }
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.addValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                return request
            },
            parsePollResponse: { data in
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw VideoGenerationError.generationFailed("Invalid poll response")
                }
                let done = json["done"] as? Bool ?? false
                if done {
                    // Navigate: response.generateVideoResponse.generatedSamples[0].video.uri
                    if let response = json["response"] as? [String: Any],
                       let videoResponse = response["generateVideoResponse"] as? [String: Any],
                       let samples = videoResponse["generatedSamples"] as? [[String: Any]],
                       let firstSample = samples.first,
                       let video = firstSample["video"] as? [String: Any],
                       let uri = video["uri"] as? String {
                        return .completed(videoURL: uri)
                    }
                    // Check for error in completed operation
                    if let error = json["error"] as? [String: Any],
                       let message = error["message"] as? String {
                        return .failed(reason: message)
                    }
                    throw VideoGenerationError.generationFailed("Operation completed but no video found in response")
                }
                // Check for error before done
                if let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    return .failed(reason: message)
                }
                return .processing(progress: nil)
            },
            buildDownloadRequest: { videoURL, apiKey in
                guard let url = URL(string: videoURL) else {
                    throw VideoGenerationError.downloadFailed(videoURL)
                }
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                // Google Veo requires API key for download
                request.addValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                return request
            }
        )
    }
}

// MARK: - DashScope Provider (Alibaba / Tongyi Wan)

extension VideoGenProvider {
    static func dashScopeProvider() -> VideoGenProvider {
        VideoGenProvider(
            buildSubmitRequest: { endpoint, apiKey, model, prompt, duration, aspectRatio, imageData in
                let baseURL = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
                let urlStr = "\(baseURL)/services/aigc/video-generation/video-synthesis"
                guard let url = URL(string: urlStr) else {
                    throw VideoGenerationError.invalidURL(urlStr)
                }

                var input: [String: Any] = ["prompt": prompt]

                // Image-to-video: use img_url with base64 data URI
                if let imageData {
                    input["img_url"] = "data:image/png;base64,\(imageData.base64EncodedString())"
                }

                var parameters: [String: Any] = [
                    "prompt_extend": true,
                    "watermark": false
                ]

                // Duration
                if let duration {
                    let seconds = Int(duration.replacingOccurrences(of: "s", with: "")) ?? 5
                    parameters["duration"] = seconds
                }

                // Resolution / aspect ratio
                if let aspectRatio {
                    // Map common aspect ratios to DashScope size format
                    let size: String
                    switch aspectRatio {
                    case "16:9": size = "1280*720"
                    case "9:16": size = "720*1280"
                    case "1:1": size = "960*960"
                    case "4:3": size = "1088*832"
                    case "3:4": size = "832*1088"
                    default: size = "1280*720"
                    }
                    // T2V uses "size", I2V uses "resolution"
                    if imageData != nil {
                        parameters["resolution"] = "720P"
                    } else {
                        parameters["size"] = size
                    }
                }

                let body: [String: Any] = [
                    "model": model,
                    "input": input,
                    "parameters": parameters
                ]

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.addValue("application/json", forHTTPHeaderField: "Content-Type")
                request.addValue("enable", forHTTPHeaderField: "X-DashScope-Async")
                if !apiKey.isEmpty {
                    request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                return request
            },
            parseTaskId: { data, _ in
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let output = json["output"] as? [String: Any],
                      let taskId = output["task_id"] as? String else {
                    throw VideoGenerationError.noTaskIdReturned
                }
                return taskId
            },
            buildPollRequest: { endpoint, apiKey, taskId in
                let baseURL = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
                let urlStr = "\(baseURL)/tasks/\(taskId)"
                guard let url = URL(string: urlStr) else {
                    throw VideoGenerationError.invalidURL(urlStr)
                }
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                if !apiKey.isEmpty {
                    request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }
                return request
            },
            parsePollResponse: { data in
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let output = json["output"] as? [String: Any] else {
                    throw VideoGenerationError.generationFailed("Invalid poll response")
                }
                let status = (output["task_status"] as? String)?.uppercased() ?? ""
                switch status {
                case "SUCCEEDED":
                    if let videoURL = output["video_url"] as? String {
                        return .completed(videoURL: videoURL)
                    }
                    throw VideoGenerationError.generationFailed("Completed but no video_url found")
                case "FAILED":
                    let reason = output["message"] as? String ?? "Unknown error"
                    return .failed(reason: reason)
                case "RUNNING":
                    return .processing(progress: nil)
                default:
                    return .pending(detail: status.isEmpty ? nil : status)
                }
            },
            buildDownloadRequest: { videoURL, _ in
                // DashScope provides a pre-signed OSS URL, no auth needed
                guard let url = URL(string: videoURL) else {
                    throw VideoGenerationError.downloadFailed(videoURL)
                }
                return URLRequest(url: url)
            }
        )
    }
}

// MARK: - Kling Provider (Kuaishou)

extension VideoGenProvider {
    static func klingProvider() -> VideoGenProvider {
        VideoGenProvider(
            buildSubmitRequest: { endpoint, apiKey, model, prompt, duration, aspectRatio, imageData in
                let baseURL = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
                let path = imageData != nil ? "image2video" : "text2video"
                let urlStr = "\(baseURL)/v1/videos/\(path)"
                guard let url = URL(string: urlStr) else {
                    throw VideoGenerationError.invalidURL(urlStr)
                }

                var body: [String: Any] = [
                    "model_name": model,
                    "prompt": prompt
                ]
                if let duration { body["duration"] = duration }
                if let aspectRatio { body["aspect_ratio"] = aspectRatio }
                if let imageData {
                    body["image"] = "data:image/png;base64,\(imageData.base64EncodedString())"
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.addValue("application/json", forHTTPHeaderField: "Content-Type")
                if !apiKey.isEmpty {
                    request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                return request
            },
            parseTaskId: { data, imageData in
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw VideoGenerationError.noTaskIdReturned
                }
                // Try common Kling response paths
                let rawId: String
                if let dataObj = json["data"] as? [String: Any], let taskId = dataObj["task_id"] as? String {
                    rawId = taskId
                } else if let taskId = json["task_id"] as? String {
                    rawId = taskId
                } else if let taskId = json["id"] as? String {
                    rawId = taskId
                } else {
                    throw VideoGenerationError.noTaskIdReturned
                }
                // Encode T2V/I2V mode so buildPollRequest can reconstruct the correct URL path.
                let prefix = imageData != nil ? "i2v" : "t2v"
                return "\(prefix):\(rawId)"
            },
            buildPollRequest: { endpoint, apiKey, taskId in
                let baseURL = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
                // Parse mode prefix from encoded taskId
                let (mode, actualId): (String, String)
                if taskId.hasPrefix("i2v:") {
                    mode = "image2video"
                    actualId = String(taskId.dropFirst(4))
                } else if taskId.hasPrefix("t2v:") {
                    mode = "text2video"
                    actualId = String(taskId.dropFirst(4))
                } else {
                    mode = "text2video"
                    actualId = taskId
                }
                let urlStr = "\(baseURL)/v1/videos/\(mode)/\(actualId)"
                guard let url = URL(string: urlStr) else {
                    throw VideoGenerationError.invalidURL(urlStr)
                }
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                if !apiKey.isEmpty {
                    request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }
                return request
            },
            parsePollResponse: { data in
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw VideoGenerationError.generationFailed("Invalid poll response")
                }
                let dataObj = json["data"] as? [String: Any] ?? json
                let status = (dataObj["task_status"] as? String)?.lowercased() ?? ""
                if status == "succeed" || status == "completed" || status == "succeeded" {
                    if let works = dataObj["task_result"] as? [String: Any],
                       let videos = works["videos"] as? [[String: Any]],
                       let url = videos.first?["url"] as? String {
                        return .completed(videoURL: url)
                    }
                    if let url = dataObj["video_url"] as? String {
                        return .completed(videoURL: url)
                    }
                    throw VideoGenerationError.generationFailed("Completed but no video URL found")
                }
                if status == "failed" {
                    let reason = dataObj["task_status_msg"] as? String ?? "Unknown error"
                    return .failed(reason: reason)
                }
                return .processing(progress: nil)
            },
            buildDownloadRequest: { videoURL, _ in
                guard let url = URL(string: videoURL) else {
                    throw VideoGenerationError.downloadFailed(videoURL)
                }
                return URLRequest(url: url)
            }
        )
    }
}

// MARK: - Seedance Provider (ByteDance Volcengine Ark)

extension VideoGenProvider {
    static func seedanceProvider() -> VideoGenProvider {
        VideoGenProvider(
            buildSubmitRequest: { endpoint, apiKey, model, prompt, duration, aspectRatio, imageData in
                let baseURL = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
                let urlStr = "\(baseURL)/contents/generations/tasks"
                guard let url = URL(string: urlStr) else {
                    throw VideoGenerationError.invalidURL(urlStr)
                }

                var content: [[String: Any]] = []
                content.append(["type": "text", "text": prompt])
                if let imageData {
                    content.append([
                        "type": "image_url",
                        "image_url": ["url": "data:image/png;base64,\(imageData.base64EncodedString())"]
                    ])
                }

                var body: [String: Any] = [
                    "model": model,
                    "content": content
                ]
                if let duration, let durationInt = Int(duration) {
                    body["duration"] = durationInt
                }
                if let aspectRatio {
                    body["ratio"] = aspectRatio
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.addValue("application/json", forHTTPHeaderField: "Content-Type")
                if !apiKey.isEmpty {
                    request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                return request
            },
            parseTaskId: { data, _ in
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let taskId = json["id"] as? String else {
                    throw VideoGenerationError.noTaskIdReturned
                }
                return taskId
            },
            buildPollRequest: { endpoint, apiKey, taskId in
                let baseURL = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
                let urlStr = "\(baseURL)/contents/generations/tasks/\(taskId)"
                guard let url = URL(string: urlStr) else {
                    throw VideoGenerationError.invalidURL(urlStr)
                }
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                if !apiKey.isEmpty {
                    request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }
                return request
            },
            parsePollResponse: { data in
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw VideoGenerationError.generationFailed("Invalid poll response")
                }
                let status = (json["status"] as? String)?.lowercased() ?? ""
                if status == "succeeded" {
                    if let content = json["content"] as? [String: Any],
                       let url = content["video_url"] as? String {
                        return .completed(videoURL: url)
                    }
                    throw VideoGenerationError.generationFailed("Completed but no video URL found in response")
                }
                if status == "failed" || status == "expired" || status == "cancelled" {
                    let reason = (json["error"] as? [String: Any])?["message"] as? String ?? status
                    return .failed(reason: reason)
                }
                if status == "running" {
                    return .processing(progress: nil)
                }
                // queued or other
                return .pending(detail: status.isEmpty ? nil : status)
            },
            buildDownloadRequest: { videoURL, _ in
                guard let url = URL(string: videoURL) else {
                    throw VideoGenerationError.downloadFailed(videoURL)
                }
                return URLRequest(url: url)
            }
        )
    }
}

// MARK: - Polling Configuration

struct VideoPollingConfig {
    /// Seconds to wait before the first poll.
    var initialDelay: TimeInterval = 10.0
    /// Seconds between subsequent polls.
    var pollInterval: TimeInterval = 10.0
    /// Maximum total time to wait for completion.
    var maxPollDuration: TimeInterval = 600.0
}

// MARK: - VideoGenerationService

final class VideoGenerationService: @unchecked Sendable {
    private let provider: LLMProvider
    private let modelName: String

    init(provider: LLMProvider, modelName: String? = nil) {
        self.provider = provider
        self.modelName = modelName ?? provider.modelName
    }

    /// Result of submitting a video generation request, used for background continuation.
    struct SubmitResult: Sendable {
        let taskId: String
        let videoProvider: VideoGenProvider
        let endpoint: String
        let apiKey: String
        let agentId: UUID
    }

    /// Generate a video and return it as a VideoAttachment.
    ///
    /// This method handles the full async lifecycle:
    /// 1. Submit the generation request
    /// 2. Poll for completion (with cancellation support)
    /// 3. Download the resulting video
    /// 4. Store it locally and create a VideoAttachment
    ///
    /// - Parameter onProgress: Optional callback invoked at each phase transition for UI updates.
    func generate(
        prompt: String,
        duration: String? = nil,
        aspectRatio: String? = nil,
        imageURL: String? = nil,
        agentId: UUID,
        pollingConfig: VideoPollingConfig = VideoPollingConfig(),
        onProgress: (@Sendable (VideoGenerationPhase) -> Void)? = nil
    ) async throws -> VideoAttachment {
        let videoProvider = VideoGenProvider.resolve(apiStyle: provider.apiStyle)

        // Resolve image data if image_url is provided
        let imageData: Data? = try await resolveImageData(from: imageURL, agentId: agentId)

        // 1. Submit the generation request
        onProgress?(.submitting)
        let submitRequest = try videoProvider.buildSubmitRequest(
            provider.endpoint, provider.apiKey, modelName,
            prompt, duration, aspectRatio, imageData
        )

        let (submitData, submitResponse) = try await URLSession.shared.data(for: submitRequest)

        if let httpResponse = submitResponse as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            let errorBody = String(data: submitData, encoding: .utf8) ?? "Unknown error"
            let error = VideoGenerationError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
            onProgress?(.failed(errorBody))
            throw error
        }

        // 2. Parse the task ID
        let taskId = try videoProvider.parseTaskId(submitData, imageData)
        onProgress?(.submitted(taskId: taskId))

        // 3. Poll for completion
        let result = try await pollUntilComplete(
            taskId: taskId,
            videoProvider: videoProvider,
            agentId: agentId,
            pollingConfig: pollingConfig,
            onProgress: onProgress
        )

        onProgress?(.completed)
        return result
    }

    /// Submit a video generation request and return the context needed for polling.
    /// Used by `FunctionCallRouter` for background continuation on cancellation.
    func submit(
        prompt: String,
        duration: String? = nil,
        aspectRatio: String? = nil,
        imageURL: String? = nil,
        agentId: UUID
    ) async throws -> SubmitResult {
        let videoProvider = VideoGenProvider.resolve(apiStyle: provider.apiStyle)

        let imageData: Data? = try await resolveImageData(from: imageURL, agentId: agentId)

        let submitRequest = try videoProvider.buildSubmitRequest(
            provider.endpoint, provider.apiKey, modelName,
            prompt, duration, aspectRatio, imageData
        )

        let (submitData, submitResponse) = try await URLSession.shared.data(for: submitRequest)

        if let httpResponse = submitResponse as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            let errorBody = String(data: submitData, encoding: .utf8) ?? "Unknown error"
            throw VideoGenerationError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        let taskId = try videoProvider.parseTaskId(submitData, imageData)

        return SubmitResult(
            taskId: taskId,
            videoProvider: videoProvider,
            endpoint: provider.endpoint,
            apiKey: provider.apiKey,
            agentId: agentId
        )
    }

    /// Poll for video completion and download the result.
    /// Can be used independently for background continuation after cancellation.
    func pollUntilComplete(
        taskId: String,
        videoProvider: VideoGenProvider,
        agentId: UUID,
        pollingConfig: VideoPollingConfig = VideoPollingConfig(),
        onProgress: (@Sendable (VideoGenerationPhase) -> Void)? = nil
    ) async throws -> VideoAttachment {
        let startTime = Date()

        try await Task.sleep(for: .seconds(pollingConfig.initialDelay))

        let deadline = Date().addingTimeInterval(pollingConfig.maxPollDuration)
        while Date() < deadline {
            try Task.checkCancellation()

            let pollRequest = try videoProvider.buildPollRequest(
                provider.endpoint, provider.apiKey, taskId
            )
            let (pollData, _) = try await URLSession.shared.data(for: pollRequest)
            let status = try videoProvider.parsePollResponse(pollData)

            let elapsed = Date().timeIntervalSince(startTime)
            onProgress?(.polling(status: status, elapsed: elapsed))

            switch status {
            case .completed(let videoURL):
                onProgress?(.downloading)
                return try await downloadAndStore(
                    videoURL: videoURL,
                    apiKey: provider.apiKey,
                    videoProvider: videoProvider,
                    agentId: agentId
                )
            case .failed(let reason):
                onProgress?(.failed(reason))
                throw VideoGenerationError.generationFailed(reason)
            case .pending, .processing:
                try await Task.sleep(for: .seconds(pollingConfig.pollInterval))
            }
        }

        onProgress?(.failed("Timed out"))
        throw VideoGenerationError.timeout
    }

    // MARK: - Private Helpers

    private func resolveImageData(from imageURL: String?, agentId: UUID) async throws -> Data? {
        guard let imageURL, !imageURL.isEmpty else { return nil }

        // agentfile:// reference
        if imageURL.hasPrefix("agentfile://") {
            return AgentFileManager.shared.loadImageData(from: imageURL)
        }

        // Regular URL
        if let url = URL(string: imageURL) {
            let (data, _) = try await URLSession.shared.data(from: url)
            return data
        }

        return nil
    }

    private func downloadAndStore(
        videoURL: String,
        apiKey: String,
        videoProvider: VideoGenProvider,
        agentId: UUID
    ) async throws -> VideoAttachment {
        let downloadRequest = try videoProvider.buildDownloadRequest(videoURL, apiKey)
        let (videoData, downloadResponse) = try await URLSession.shared.data(for: downloadRequest)

        if let httpResponse = downloadResponse as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw VideoGenerationError.downloadFailed(videoURL)
        }

        guard !videoData.isEmpty else {
            throw VideoGenerationError.invalidVideoData
        }

        // Save to agent files
        guard let fileRef = AgentFileManager.shared.saveVideo(videoData, agentId: agentId) else {
            throw VideoGenerationError.invalidVideoData
        }

        // Generate thumbnail and extract metadata
        let parsed = AgentFileManager.parseFileReference(fileRef)
        let parsedAgentId = parsed?.0 ?? agentId
        let parsedFilename = parsed?.1 ?? ""
        let fileURL = AgentFileManager.shared.fileURL(agentId: parsedAgentId, name: parsedFilename)

        let (thumbnail, width, height, duration) = await extractVideoMetadata(from: fileURL)

        return VideoAttachment(
            id: UUID(),
            thumbnailData: thumbnail,
            mimeType: "video/mp4",
            width: width,
            height: height,
            duration: duration,
            fileSize: Int64(videoData.count),
            fileReference: fileRef
        )
    }

    private func extractVideoMetadata(from fileURL: URL) async -> (Data, Int, Int, TimeInterval) {
        let asset = AVURLAsset(url: fileURL)

        // Default values
        var width = 720
        var height = 480
        var duration: TimeInterval = 0
        var thumbnailData = Data()

        // Load duration
        if let durationVal = try? await asset.load(.duration) {
            duration = CMTimeGetSeconds(durationVal)
        }

        // Load video dimensions
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await track.load(.naturalSize) {
                width = Int(size.width)
                height = Int(size.height)
            }
        }

        // Generate thumbnail at halfway point
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)

        let thumbnailTime = CMTimeMakeWithSeconds(max(duration / 2.0, 0.5), preferredTimescale: 600)
        if let cgImage = try? generator.copyCGImage(at: thumbnailTime, actualTime: nil) {
            let uiImage = UIImage(cgImage: cgImage)
            thumbnailData = uiImage.jpegData(compressionQuality: 0.5) ?? Data()
        }

        return (thumbnailData, width, height, duration)
    }
}
