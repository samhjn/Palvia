import SwiftUI
import PhotosUI
import UIKit

struct InputBarView: View {
    @Binding var text: String
    let isLoading: Bool
    var isCompressing: Bool = false
    var isBlocked: Bool = false
    var isCancelling: Bool = false
    var canRetry: Bool = false
    var cancelFailureReason: String?
    var pendingImages: [ImageAttachment] = []
    var pendingVideos: [VideoAttachment] = []
    var pendingFiles: [FileAttachment] = []
    var isImageDisabled: Bool = false
    var isVideoDisabled: Bool = false
    let onSend: () -> Void
    var onStop: (() -> Void)?
    var onStopCompression: (() -> Void)?
    var onRetry: (() -> Void)?
    var onDismissKeyboard: (() -> Void)?
    var onAddImage: ((UIImage) -> Void)?
    var onRemoveImage: ((UUID) -> Void)?
    var onAddVideo: ((URL) -> Void)?
    var onRemoveVideo: ((UUID) -> Void)?
    var onAddFile: ((URL) -> Void)?
    var onRemoveFile: ((UUID) -> Void)?

    @State private var isInputFocused = false
    @State private var showImageSourcePicker = false
    @State private var showImageDisabledToast = false
    @State private var showMediaPicker = false
    @State private var showCamera = false
    @State private var showFilePicker = false

    private var isBusy: Bool { isLoading || isCompressing }

    private var canSendMessage: Bool {
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
         || !pendingImages.isEmpty
         || !pendingVideos.isEmpty
         || !pendingFiles.isEmpty) && !isBusy && !isBlocked
    }

    var body: some View {
        VStack(spacing: 0) {
            if let reason = cancelFailureReason {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !pendingImages.isEmpty {
                ImageAttachmentBar(images: pendingImages) { id in
                    onRemoveImage?(id)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !pendingVideos.isEmpty {
                VideoAttachmentBar(videos: pendingVideos) { id in
                    onRemoveVideo?(id)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !pendingFiles.isEmpty {
                FileAttachmentBar(files: pendingFiles) { id in
                    onRemoveFile?(id)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: 8) {
                if isInputFocused {
                    Button {
                        onDismissKeyboard?()
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                        isInputFocused = false
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 36)
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }

                Button {
                    if isImageDisabled {
                        showImageDisabledToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            showImageDisabledToast = false
                        }
                    } else {
                        showImageSourcePicker = true
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 24))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isImageDisabled ? .quaternary : .secondary)
                        .frame(width: 32, height: 36)
                }
                .disabled(isBusy && !isImageDisabled)

                PasteableTextInput(
                    text: $text,
                    placeholder: L10n.Chat.messagePlaceholder,
                    maxLines: 6,
                    onPasteImage: { onAddImage?($0) }
                )
                .accessibilityIdentifier(AccessibilityID.Chat.inputField)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(isBlocked ? Color.orange.opacity(0.08) : Color(.systemGray6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(isInputFocused ? Color.accentColor.opacity(0.4) :
                                isBlocked ? Color.orange.opacity(0.3) : Color.clear,
                                lineWidth: 1)
                )

                actionButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
        .animation(.easeInOut(duration: 0.2), value: isInputFocused)
        .animation(.easeInOut(duration: 0.2), value: isLoading)
        .animation(.easeInOut(duration: 0.2), value: cancelFailureReason != nil)
        .animation(.easeInOut(duration: 0.2), value: pendingImages.count)
        .animation(.easeInOut(duration: 0.2), value: pendingVideos.count)
        .animation(.easeInOut(duration: 0.2), value: pendingFiles.count)
        .animation(.easeInOut(duration: 0.2), value: canRetry)
        .confirmationDialog(L10n.Chat.addMedia, isPresented: $showImageSourcePicker) {
            Button(L10n.Chat.photosAndVideos) {
                showMediaPicker = true
            }
            Button(L10n.Chat.camera) {
                showCamera = true
            }
            if onAddFile != nil {
                Button(L10n.Chat.chooseFile) {
                    showFilePicker = true
                }
            }
            if UIPasteboard.general.hasImages {
                Button(L10n.Chat.pasteFromClipboard) {
                    if let img = UIPasteboard.general.image {
                        onAddImage?(img)
                    }
                }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                onAddFile?(url)
            }
        }
        .fullScreenCover(isPresented: $showMediaPicker) {
            MediaPickerView(
                includeVideos: !isVideoDisabled,
                onImagePicked: { image in onAddImage?(image) },
                onVideoPicked: { url in onAddVideo?(url) }
            )
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPickerView(
                includeVideo: !isVideoDisabled,
                onImagePicked: { image in onAddImage?(image) },
                onVideoPicked: { url in onAddVideo?(url) }
            )
            .ignoresSafeArea()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isInputFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isInputFocused = false
        }
        .overlay(alignment: .top) {
            if showImageDisabledToast {
                Text(L10n.AgentFiles.imagePermissionDisabled)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.black.opacity(0.75)))
                    .offset(y: -44)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.2), value: showImageDisabledToast)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if isLoading, let onStop {
            Button {
                onStop()
            } label: {
                ZStack {
                    Circle()
                        .fill(isCancelling ? Color.gray.opacity(0.15) : Color.red.opacity(0.12))
                        .frame(width: 36, height: 36)

                    if isCancelling {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.red)
                    }
                }
            }
            .disabled(isCancelling)
            .accessibilityIdentifier(AccessibilityID.Chat.stopButton)
            .transition(.scale.combined(with: .opacity))
        } else if isCompressing, let onStopCompression {
            Button {
                onStopCompression()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.12))
                        .frame(width: 36, height: 36)

                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.orange)
                }
            }
            .transition(.scale.combined(with: .opacity))
        } else if canRetry && !canSendMessage, let onRetry {
            Button {
                onRetry()
            } label: {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .overlay {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
            .transition(.scale.combined(with: .opacity))
        } else {
            Button {
                onSend()
            } label: {
                Circle()
                    .fill(canSendMessage ? Color.accentColor : isBlocked ? Color.orange.opacity(0.3) : Color(.systemGray4))
                    .frame(width: 36, height: 36)
                    .overlay {
                        Image(systemName: isBlocked ? "lock.fill" : "arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(canSendMessage ? .white : isBlocked ? .orange : Color(.systemGray2))
                    }
            }
            .disabled(!canSendMessage)
            .accessibilityIdentifier(AccessibilityID.Chat.sendButton)
            .transition(.scale.combined(with: .opacity))
        }
    }
}

// MARK: - Pasteable Text Input

class ImagePasteTextView: UITextView {
    var onPasteImage: ((UIImage) -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) && UIPasteboard.general.hasImages {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if let image = UIPasteboard.general.image {
            onPasteImage?(image)
        }
        if UIPasteboard.general.hasStrings {
            super.paste(sender)
        }
    }
}

struct PasteableTextInput: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var maxLines: Int = 6
    var onPasteImage: ((UIImage) -> Void)?

    func makeUIView(context: Context) -> ImagePasteTextView {
        let textView = ImagePasteTextView()
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.delegate = context.coordinator
        textView.onPasteImage = onPasteImage
        return textView
    }

    func updateUIView(_ uiView: ImagePasteTextView, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text {
            uiView.text = text
        }
        uiView.onPasteImage = onPasteImage
        context.coordinator.updatePlaceholder(uiView, text: text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ImagePasteTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        let lineHeight = uiView.font?.lineHeight ?? 20
        let maxHeight = lineHeight * CGFloat(maxLines)
        let fittingSize = uiView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        let clampedHeight = min(max(fittingSize.height, lineHeight), maxHeight)
        uiView.isScrollEnabled = fittingSize.height > maxHeight
        return CGSize(width: width, height: clampedHeight)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: PasteableTextInput
        private var placeholderLabel: UILabel?

        init(_ parent: PasteableTextInput) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            updatePlaceholder(textView, text: textView.text)
            textView.invalidateIntrinsicContentSize()
        }

        func updatePlaceholder(_ textView: UITextView, text: String) {
            if placeholderLabel == nil {
                let label = UILabel()
                label.text = parent.placeholder
                label.font = textView.font
                label.textColor = .placeholderText
                label.translatesAutoresizingMaskIntoConstraints = false
                textView.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
                    label.topAnchor.constraint(equalTo: textView.topAnchor),
                ])
                placeholderLabel = label
            }
            placeholderLabel?.isHidden = !text.isEmpty
        }
    }
}

// MARK: - Media Picker (PHPicker for photos & videos)

import UniformTypeIdentifiers

struct MediaPickerView: UIViewControllerRepresentable {
    var includeVideos: Bool = true
    let onImagePicked: (UIImage) -> Void
    let onVideoPicked: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = includeVideos ? .any(of: [.images, .videos]) : .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: MediaPickerView

        init(_ parent: MediaPickerView) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let result = results.first else {
                parent.dismiss()
                return
            }
            let provider = result.itemProvider

            // Check if it's a video
            let movieType = UTType.movie
            if provider.hasItemConformingToTypeIdentifier(movieType.identifier) {
                provider.loadFileRepresentation(forTypeIdentifier: movieType.identifier) { url, error in
                    if let url {
                        let tempURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString)
                            .appendingPathExtension(url.pathExtension)
                        try? FileManager.default.copyItem(at: url, to: tempURL)
                        DispatchQueue.main.async {
                            self.parent.onVideoPicked(tempURL)
                            self.parent.dismiss()
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.parent.dismiss()
                        }
                    }
                }
                return
            }

            // Otherwise treat as image
            if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    DispatchQueue.main.async {
                        if let image = object as? UIImage {
                            self.parent.onImagePicked(image)
                        }
                        self.parent.dismiss()
                    }
                }
            } else {
                parent.dismiss()
            }
        }
    }
}

// MARK: - Camera Picker (photo & video via camera)

struct CameraPickerView: UIViewControllerRepresentable {
    var includeVideo: Bool = true
    let onImagePicked: (UIImage) -> Void
    var onVideoPicked: ((URL) -> Void)?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        if includeVideo {
            picker.mediaTypes = ["public.image", "public.movie"]
            picker.videoMaximumDuration = VideoAttachment.maxDurationSeconds
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPickerView

        init(_ parent: CameraPickerView) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL {
                parent.onVideoPicked?(url)
            } else if let image = info[.originalImage] as? UIImage {
                parent.onImagePicked(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
