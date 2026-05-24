import SwiftUI
import UIKit
import Photos

// MARK: - Coordinator

@Observable
final class ImagePreviewCoordinator {
    static let shared = ImagePreviewCoordinator()

    private(set) var image: UIImage?
    private(set) var isPresented = false

    func show(_ image: UIImage) {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
        self.image = image
        withAnimation(.easeOut(duration: 0.25)) {
            isPresented = true
        }
    }

    func close(animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                isPresented = false
            }
        } else {
            isPresented = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.image = nil
        }
    }
}

// MARK: - Root Overlay Modifier

struct ImagePreviewRootModifier: ViewModifier {
    private var coordinator: ImagePreviewCoordinator { .shared }

    func body(content: Content) -> some View {
        content.overlay {
            if coordinator.isPresented, let image = coordinator.image {
                ImagePreviewOverlay(image: image)
                    .transition(.opacity)
            }
        }
    }
}

extension View {
    func imagePreviewOverlay() -> some View {
        modifier(ImagePreviewRootModifier())
    }
}

// MARK: - Zoom Math (internal for testing)

enum ImagePreviewMath {

    /// Computes the offset needed to keep the pinch anchor point stationary
    /// as the scale changes.
    ///
    /// `fittedSize` is the aspect-fitted image size (the Image view's frame),
    /// **not** the viewport size.  The gesture anchor is in the image view's
    /// layout-frame coordinate space, so `(ux − 0.5) * fittedSize` gives the
    /// touch's screen position relative to parent center (not the raw image
    /// point).  To recover the actual image point we undo the current
    /// transform: `p = (layoutPos − lastPanOffset) / lastScale`, yielding
    /// the ratio-based formula below.
    static func zoomAnchorOffset(
        anchorUnitX: CGFloat,
        anchorUnitY: CGFloat,
        fittedSize: CGSize,
        lastScale: CGFloat,
        newScale: CGFloat,
        lastPanOffset: CGSize
    ) -> CGSize {
        // layoutPos = touch screen position relative to parent center.
        let anchorX = (anchorUnitX - 0.5) * fittedSize.width
        let anchorY = (anchorUnitY - 0.5) * fittedSize.height
        let ratio = newScale / lastScale
        return CGSize(
            width: anchorX * (1 - ratio) + lastPanOffset.width * ratio,
            height: anchorY * (1 - ratio) + lastPanOffset.height * ratio
        )
    }

    /// Returns the fitted image size within the viewport (aspect-fit).
    static func fittedImageSize(imageSize: CGSize, viewportSize: CGSize) -> CGSize {
        guard viewportSize.width > 0, viewportSize.height > 0,
              imageSize.width > 0, imageSize.height > 0 else {
            return viewportSize
        }
        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = viewportSize.width / viewportSize.height
        if imageAspect > viewAspect {
            return CGSize(width: viewportSize.width, height: viewportSize.width / imageAspect)
        } else {
            return CGSize(width: viewportSize.height * imageAspect, height: viewportSize.height)
        }
    }

    /// Clamps an offset so the zoomed image cannot be panned beyond its edges.
    static func clampedOffset(
        _ offset: CGSize,
        scale: CGFloat,
        fittedSize: CGSize,
        viewportSize: CGSize
    ) -> CGSize {
        let maxX = max((fittedSize.width * scale - viewportSize.width) / 2, 0)
        let maxY = max((fittedSize.height * scale - viewportSize.height) / 2, 0)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }

    /// Rubber-band formula: within `limit` moves freely; beyond it, excess is
    /// damped logarithmically so the user feels resistance.
    static func rubberBand(_ value: CGFloat, limit: CGFloat) -> CGFloat {
        let clamped = min(max(value, -limit), limit)
        let excess = value - clamped
        guard excess != 0 else { return value }
        let dim: CGFloat = 200
        let dampened = dim * (1 - exp(-abs(excess) / dim))
        return clamped + dampened * (excess > 0 ? 1 : -1)
    }
}

// MARK: - Image Preview Overlay

private struct ImagePreviewOverlay: View {
    let image: UIImage

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    @State private var dismissTranslation: CGSize = .zero
    @State private var isDismissing = false
    @State private var toastMessage: String?
    @State private var viewportSize: CGSize = .zero
    /// True while a `MagnifyGesture` is active — suppresses the drag
    /// gesture from overwriting `panOffset` during a pinch.
    @State private var isMagnifying = false
    /// Snapshot of `DragGesture.Value.translation` taken continuously while
    /// magnifying.  When the pinch ends but the drag continues (one finger
    /// still down), we subtract this baseline so the remaining single-finger
    /// drag starts from zero rather than including the pre-pinch movement.
    @State private var dragBaseline: CGSize = .zero

    private var dismissProgress: CGFloat {
        guard !isDismissing else { return 1 }
        return min(abs(dismissTranslation.height) / 280, 1)
    }

    var body: some View {
        let bgOpacity: Double = isDismissing ? 0 : 1 - Double(dismissProgress) * 0.55
        let imageScale = scale > 1 ? scale : scale * (1 - dismissProgress * 0.12)
        let imageOffset = CGSize(
            width: panOffset.width + (scale <= 1 ? dismissTranslation.width * 0.4 : 0),
            height: panOffset.height + (scale <= 1 ? dismissTranslation.height : 0)
        )
        let controlsVisible = !isDismissing && dismissProgress < 0.3

        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(bgOpacity)
                    .ignoresSafeArea()
                    .onTapGesture {
                        if scale <= 1 {
                            ImagePreviewCoordinator.shared.close()
                        }
                    }

                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(imageScale)
                    .offset(imageOffset)
                    .gesture(dragGesture)
                    .simultaneousGesture(magnificationGesture)
                    .onTapGesture(count: 2) { toggleZoom() }

                if controlsVisible {
                    VStack {
                        HStack {
                            Spacer()
                            Button { ImagePreviewCoordinator.shared.close() } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .white.opacity(0.35))
                            }
                            .padding()
                        }
                        Spacer()
                        toolbar
                            .padding(.bottom, 48)
                    }
                }

                if let message = toastMessage {
                    VStack {
                        Spacer()
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(.black.opacity(0.7)))
                            .padding(.bottom, 110)
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }
            .onAppear { viewportSize = geometry.size }
            .onChange(of: geometry.size) { _, newSize in viewportSize = newSize }
        }
        .ignoresSafeArea()
        .statusBar(hidden: true)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 36) {
            Button {
                UIPasteboard.general.image = image
                flashToast(L10n.Common.copied)
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "doc.on.doc")
                        .font(.title3)
                    Text(L10n.Chat.copyImage)
                        .font(.caption)
                }
                .foregroundStyle(.white)
                .frame(minWidth: 60, minHeight: 44)
            }

            Button {
                saveImageToPhotos(image)
                flashToast(L10n.Chat.imageSaved)
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.title3)
                    Text(L10n.Chat.saveImageToPhotos)
                        .font(.caption)
                }
                .foregroundStyle(.white)
                .frame(minWidth: 60, minHeight: 44)
            }
        }
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                // While magnifying, record the drag's cumulative translation
                // as a baseline so the post-pinch single-finger drag doesn't
                // include the pre-pinch movement.
                if isMagnifying {
                    dragBaseline = value.translation
                    return
                }

                let delta = CGSize(
                    width: value.translation.width - dragBaseline.width,
                    height: value.translation.height - dragBaseline.height
                )

                if scale > 1 {
                    let raw = CGSize(
                        width: lastPanOffset.width + delta.width,
                        height: lastPanOffset.height + delta.height
                    )
                    panOffset = rubberBandOffset(raw, for: scale)
                } else {
                    dismissTranslation = delta
                }
            }
            .onEnded { value in
                let savedBaseline = dragBaseline
                dragBaseline = .zero

                if isMagnifying { return }

                if scale > 1 {
                    let clamped = clampedOffset(panOffset, for: scale)
                    withAnimation(.interpolatingSpring(stiffness: 350, damping: 30)) {
                        panOffset = clamped
                    }
                    lastPanOffset = clamped
                    return
                }

                let vy = value.predictedEndTranslation.height - value.translation.height
                let dismissH = value.translation.height - savedBaseline.height
                if abs(dismissH) > 100 || abs(vy) > 600 {
                    isDismissing = true
                    let flyY: CGFloat = dismissH > 0 ? 600 : -600
                    withAnimation(.easeOut(duration: 0.15)) {
                        dismissTranslation = CGSize(
                            width: dismissTranslation.width,
                            height: flyY
                        )
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        ImagePreviewCoordinator.shared.close(animated: false)
                    }
                } else {
                    withAnimation(.interpolatingSpring(stiffness: 350, damping: 30)) {
                        dismissTranslation = .zero
                    }
                }
            }
    }

    private var magnificationGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if !isMagnifying {
                    isMagnifying = true
                    // Cancel any in-progress / animating dismiss state so it
                    // doesn't bleed into the zoom (background opacity, controls).
                    dismissTranslation = .zero
                }
                let newScale = max(0.5, lastScale * value.magnification)
                panOffset = ImagePreviewMath.zoomAnchorOffset(
                    anchorUnitX: value.startAnchor.x,
                    anchorUnitY: value.startAnchor.y,
                    fittedSize: fittedImageSize(),
                    lastScale: lastScale,
                    newScale: newScale,
                    lastPanOffset: lastPanOffset
                )
                scale = newScale
            }
            .onEnded { _ in
                isMagnifying = false
                let clamped = max(1.0, min(scale, 5.0))
                withAnimation(.interpolatingSpring(stiffness: 300, damping: 28)) {
                    scale = clamped
                    if clamped <= 1 {
                        panOffset = .zero
                        lastPanOffset = .zero
                    } else {
                        panOffset = clampedOffset(panOffset, for: clamped)
                        lastPanOffset = panOffset
                    }
                }
                lastScale = clamped
            }
    }

    private func toggleZoom() {
        withAnimation(.interpolatingSpring(stiffness: 280, damping: 26)) {
            if scale > 1 {
                scale = 1
                lastScale = 1
                panOffset = .zero
                lastPanOffset = .zero
            } else {
                scale = 2.5
                lastScale = 2.5
            }
        }
    }

    private func saveImageToPhotos(_ image: UIImage) {
        let imageToSave = image
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAsset(from: imageToSave)
            }
        }
    }

    private func fittedImageSize() -> CGSize {
        ImagePreviewMath.fittedImageSize(imageSize: image.size, viewportSize: viewportSize)
    }

    private func clampedOffset(_ offset: CGSize, for currentScale: CGFloat) -> CGSize {
        ImagePreviewMath.clampedOffset(offset, scale: currentScale,
                                       fittedSize: fittedImageSize(), viewportSize: viewportSize)
    }

    private func rubberBandOffset(_ offset: CGSize, for currentScale: CGFloat) -> CGSize {
        let fitted = fittedImageSize()
        let maxX = max((fitted.width * currentScale - viewportSize.width) / 2, 0)
        let maxY = max((fitted.height * currentScale - viewportSize.height) / 2, 0)
        return CGSize(
            width: ImagePreviewMath.rubberBand(offset.width, limit: maxX),
            height: ImagePreviewMath.rubberBand(offset.height, limit: maxY)
        )
    }

    private func flashToast(_ message: String) {
        withAnimation { toastMessage = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { toastMessage = nil }
        }
    }
}
