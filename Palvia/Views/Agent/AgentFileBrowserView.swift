import SwiftUI
import UIKit
import AVFoundation
import AVKit
import UniformTypeIdentifiers

struct AgentFileBrowserView: View {
    let agent: Agent
    /// Relative path within the agent's folder (`""` = root).
    var currentPath: String = ""

    @State private var files: [FileInfo] = []
    @State private var showDocumentPicker = false
    @State private var showDeleteConfirm: FileInfo?
    @State private var showDeleteAlert = false
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var errorMessage: String?

    private var agentId: UUID {
        AgentFileManager.shared.resolveAgentId(for: agent)
    }

    private var isRoot: Bool { currentPath.isEmpty }

    var body: some View {
        List {
            if files.isEmpty {
                ContentUnavailableView(
                    L10n.AgentFiles.empty,
                    systemImage: "folder",
                    description: Text(L10n.AgentFiles.emptyDescription)
                )
            } else {
                ForEach(files) { file in
                    rowForFile(file)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                showDeleteConfirm = file
                                showDeleteAlert = true
                            } label: {
                                Label(L10n.Common.delete, systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            if !file.isDirectory {
                                Button {
                                    shareFile(file)
                                } label: {
                                    Label(L10n.Chat.share, systemImage: "square.and.arrow.up")
                                }
                            }
                            Button(role: .destructive) {
                                showDeleteConfirm = file
                                showDeleteAlert = true
                            } label: {
                                Label(L10n.Common.delete, systemImage: "trash")
                            }
                        }
                }
            }
        }
        .navigationTitle(isRoot ? L10n.AgentFiles.title : (currentPath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showDocumentPicker = true
                    } label: {
                        Label(L10n.Common.import, systemImage: "square.and.arrow.down")
                    }
                    Button {
                        newFolderName = ""
                        showNewFolderAlert = true
                    } label: {
                        Label(L10n.AgentFiles.newFolder, systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .onAppear { refreshFiles() }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerView { urls in
                importFiles(urls)
            }
        }
        .alert(L10n.AgentFiles.newFolder, isPresented: $showNewFolderAlert) {
            TextField(L10n.AgentFiles.folderName, text: $newFolderName)
                .textInputAutocapitalization(.never)
            Button(L10n.Common.cancel, role: .cancel) { }
            Button(L10n.Common.confirm) { createFolder() }
        }
        .alert(L10n.AgentFiles.deleteConfirmTitle, isPresented: $showDeleteAlert) {
            Button(L10n.Common.delete, role: .destructive) {
                if let file = showDeleteConfirm {
                    deleteItem(file)
                }
                showDeleteConfirm = nil
            }
            Button(L10n.Common.cancel, role: .cancel) { showDeleteConfirm = nil }
        } message: {
            if let file = showDeleteConfirm {
                Text(L10n.AgentFiles.deleteConfirmMessage(file.name))
            }
        }
        .overlay {
            if let msg = errorMessage {
                VStack {
                    Spacer()
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(.red.opacity(0.8)))
                        .padding(.bottom, 24)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        withAnimation { errorMessage = nil }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowForFile(_ file: FileInfo) -> some View {
        if file.isDirectory {
            NavigationLink {
                AgentFileBrowserView(agent: agent, currentPath: join(currentPath, file.name))
            } label: {
                FileRowView(file: file, agentId: agentId, parentPath: currentPath)
            }
        } else {
            FileRowView(file: file, agentId: agentId, parentPath: currentPath)
        }
    }

    private func refreshFiles() {
        let allFiles = AgentFileManager.shared.listFiles(agentId: agentId, path: currentPath)
        if isRoot {
            let draftFilenames = collectDraftFilenames()
            files = draftFilenames.isEmpty ? allFiles : allFiles.filter { !draftFilenames.contains($0.name) }
        } else {
            files = allFiles
        }
    }

    /// Collect filenames referenced by unsent draft images across all sessions of this agent.
    /// Only applied at root because drafts always live at the root of the agent folder.
    private func collectDraftFilenames() -> Set<String> {
        var names = Set<String>()
        for session in agent.sessions {
            for attachment in ChatViewModel.cachedPendingImages(for: session.id) {
                if let ref = attachment.fileReference,
                   let (_, filename) = AgentFileManager.parseFileReference(ref) {
                    names.insert(filename)
                }
            }
            if let data = session.draftImagesData,
               let images = try? JSONDecoder().decode([ImageAttachment].self, from: data) {
                for img in images {
                    if let ref = img.fileReference,
                       let (_, filename) = AgentFileManager.parseFileReference(ref) {
                        names.insert(filename)
                    }
                }
            }
        }
        return names
    }

    private func deleteItem(_ file: FileInfo) {
        do {
            try AgentFileManager.shared.deleteFile(agentId: agentId, name: join(currentPath, file.name))
            refreshFiles()
        } catch {
            withAnimation { errorMessage = error.localizedDescription }
        }
    }

    private func createFolder() {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard AgentFileManager.isSafeFilename(trimmed) else {
            withAnimation { errorMessage = L10n.AgentFiles.invalidFolderName }
            return
        }
        do {
            try AgentFileManager.shared.makeDirectory(agentId: agentId, path: join(currentPath, trimmed))
            refreshFiles()
        } catch {
            withAnimation { errorMessage = error.localizedDescription }
        }
    }

    private func importFiles(_ urls: [URL]) {
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let name = url.lastPathComponent
            do {
                try AgentFileManager.shared.writeFile(agentId: agentId, name: join(currentPath, name), data: data)
            } catch {
                withAnimation { errorMessage = error.localizedDescription }
            }
        }
        refreshFiles()
    }

    private func shareFile(_ file: FileInfo) {
        let url = AgentFileManager.shared.fileURL(agentId: agentId, name: join(currentPath, file.name))
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            var topVC = rootVC
            while let presented = topVC.presentedViewController { topVC = presented }
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = topVC.view
                popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            topVC.present(activityVC, animated: true)
        }
    }

    private func join(_ base: String, _ component: String) -> String {
        base.isEmpty ? component : "\(base)/\(component)"
    }
}

// MARK: - File Row

private struct FileRowView: View {
    let file: FileInfo
    let agentId: UUID
    let parentPath: String
    @State private var showVideoPlayer = false
    @State private var videoThumbnail: UIImage?

    private var relativePath: String {
        parentPath.isEmpty ? file.name : "\(parentPath)/\(file.name)"
    }

    private var fileURL: URL {
        AgentFileManager.shared.fileURL(agentId: agentId, name: relativePath)
    }

    var body: some View {
        Button {
            guard !file.isDirectory else { return }
            if file.isImage, let data = try? AgentFileManager.shared.readFile(agentId: agentId, name: relativePath),
               let img = UIImage(data: data) {
                ImagePreviewCoordinator.shared.show(img)
            } else if file.isVideo {
                showVideoPlayer = true
            } else if file.isHTML {
                Task {
                    await BrowserService.shared.loadAgentFile(fileURL: fileURL, agentId: agentId)
                }
            } else if file.isTextPreviewable {
                Task {
                    guard let document = await TextFilePreviewDocument.load(
                        fileURL: fileURL,
                        filename: file.name
                    ) else { return }
                    TextFilePreviewCoordinator.shared.show(
                        content: document.content,
                        filename: document.filename,
                        lineCount: document.lineCount
                    )
                }
            }
        } label: {
            HStack(spacing: 12) {
                fileIcon
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    HStack(spacing: 8) {
                        Text(file.formattedSize)
                        Text(file.modifiedAt, style: .relative)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
        .buttonStyle(.plain)
        .fullScreenCover(isPresented: $showVideoPlayer) {
            VideoFilePlayerView(url: fileURL)
        }
        .task(id: file.name) {
            if file.isVideo { videoThumbnail = await generateThumbnail() }
        }
    }

    @ViewBuilder
    private var fileIcon: some View {
        if file.isDirectory {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.systemGray5))
                Image(systemName: "folder.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
            }
        } else if file.isImage, let data = try? AgentFileManager.shared.readFile(agentId: agentId, name: relativePath),
           let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if file.isVideo {
            ZStack {
                if let thumb = videoThumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(.systemGray5))
                }
                Image(systemName: "play.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.systemGray5))
                Image(systemName: iconForExtension(file.name))
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func iconForExtension(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "txt", "md", "log": return "doc.text"
        case "json", "xml", "csv", "yaml", "yml": return "doc.badge.gearshape"
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tar", "rar": return "archivebox"
        case "js", "py", "swift", "html", "css": return "chevron.left.forwardslash.chevron.right"
        case "mp4", "mov", "m4v", "webm", "avi", "mkv": return "film"
        default: return "doc"
        }
    }

    private func generateThumbnail() async -> UIImage? {
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 80, height: 80)
        let time = CMTimeMakeWithSeconds(0.5, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Video File Player

private struct VideoFilePlayerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            Group {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    Color.black
                }
            }
            .ignoresSafeArea()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.Common.done) { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .onAppear {
            player = AVPlayer(url: url)
            player?.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

// MARK: - Document Picker

struct DocumentPickerView: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPickerView
        init(_ parent: DocumentPickerView) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls)
            parent.dismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }
    }
}
