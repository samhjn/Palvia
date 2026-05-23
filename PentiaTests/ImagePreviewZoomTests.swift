import XCTest
@testable import iClaw

final class ImagePreviewZoomTests: XCTestCase {

    private let viewport = CGSize(width: 400, height: 800)
    private let accuracy: CGFloat = 0.001

    // MARK: - Zoom Anchor Offset

    func testZoomAtCenterProducesZeroOffset() {
        let fitted = CGSize(width: 400, height: 200)
        let offset = ImagePreviewMath.zoomAnchorOffset(
            anchorUnitX: 0.5, anchorUnitY: 0.5,
            fittedSize: fitted,
            lastScale: 1.0, newScale: 2.0,
            lastPanOffset: .zero
        )
        XCTAssertEqual(offset.width, 0, accuracy: accuracy)
        XCTAssertEqual(offset.height, 0, accuracy: accuracy)
    }

    func testZoomAtTopLeftShiftsImageTowardTopLeft() {
        // Pinch at top-left corner (0, 0) of fitted image (400×200)
        let fitted = CGSize(width: 400, height: 200)
        let offset = ImagePreviewMath.zoomAnchorOffset(
            anchorUnitX: 0.0, anchorUnitY: 0.0,
            fittedSize: fitted,
            lastScale: 1.0, newScale: 2.0,
            lastPanOffset: .zero
        )
        // p = (-200, -100); O = p * (1-2) + 0 = (200, 100)
        XCTAssertEqual(offset.width, 200, accuracy: accuracy)
        XCTAssertEqual(offset.height, 100, accuracy: accuracy)
    }

    func testZoomAtBottomRightShiftsImageTowardBottomRight() {
        let fitted = CGSize(width: 400, height: 200)
        let offset = ImagePreviewMath.zoomAnchorOffset(
            anchorUnitX: 1.0, anchorUnitY: 1.0,
            fittedSize: fitted,
            lastScale: 1.0, newScale: 2.0,
            lastPanOffset: .zero
        )
        // p = (200, 100); O = p * (1-2) = (-200, -100)
        XCTAssertEqual(offset.width, -200, accuracy: accuracy)
        XCTAssertEqual(offset.height, -100, accuracy: accuracy)
    }

    func testZoomPreservesExistingPanOffset() {
        let fitted = CGSize(width: 400, height: 200)
        let existing = CGSize(width: 50, height: -30)
        let offset = ImagePreviewMath.zoomAnchorOffset(
            anchorUnitX: 0.5, anchorUnitY: 0.5,
            fittedSize: fitted,
            lastScale: 1.0, newScale: 2.0,
            lastPanOffset: existing
        )
        // Center anchor: layoutPos = (0,0); ratio = 2
        // O = 0*(1-2) + existing*2 = existing*2
        XCTAssertEqual(offset.width, 100, accuracy: accuracy)
        XCTAssertEqual(offset.height, -60, accuracy: accuracy)
    }

    func testZoomOutTowardsScale1ReducesOffset() {
        let fitted = CGSize(width: 400, height: 800)
        let offset = ImagePreviewMath.zoomAnchorOffset(
            anchorUnitX: 0.25, anchorUnitY: 0.25,
            fittedSize: fitted,
            lastScale: 2.0, newScale: 1.0,
            lastPanOffset: CGSize(width: 100, height: 200)
        )
        // p = (-100, -200); O = p * (2-1) + (100,200) = (-100,-200) + (100,200) = (0,0)
        XCTAssertEqual(offset.width, 0, accuracy: accuracy)
        XCTAssertEqual(offset.height, 0, accuracy: accuracy)
    }

    func testZoomNoChangeReturnsLastPanOffset() {
        let fitted = CGSize(width: 400, height: 800)
        let existing = CGSize(width: 42, height: -17)
        let offset = ImagePreviewMath.zoomAnchorOffset(
            anchorUnitX: 0.3, anchorUnitY: 0.7,
            fittedSize: fitted,
            lastScale: 2.0, newScale: 2.0,
            lastPanOffset: existing
        )
        // (lastScale - newScale) = 0, so offset = 0 + existing = existing
        XCTAssertEqual(offset.width, existing.width, accuracy: accuracy)
        XCTAssertEqual(offset.height, existing.height, accuracy: accuracy)
    }

    func testZoomAnchorOffsetIsLinearInMagnification() {
        // Zooming from 1→3 should give the same result regardless of how we
        // express it, as long as anchor and initial offset are the same.
        let fitted = CGSize(width: 400, height: 800)
        let anchorX: CGFloat = 0.25
        let anchorY: CGFloat = 0.75

        let step1 = ImagePreviewMath.zoomAnchorOffset(
            anchorUnitX: anchorX, anchorUnitY: anchorY,
            fittedSize: fitted,
            lastScale: 1.0, newScale: 3.0,
            lastPanOffset: .zero
        )

        let direct = ImagePreviewMath.zoomAnchorOffset(
            anchorUnitX: anchorX, anchorUnitY: anchorY,
            fittedSize: fitted,
            lastScale: 1.0, newScale: 3.0,
            lastPanOffset: .zero
        )

        XCTAssertEqual(step1.width, direct.width, accuracy: accuracy)
        XCTAssertEqual(step1.height, direct.height, accuracy: accuracy)
    }

    // MARK: - Non-1:1 aspect ratio images

    func testZoomAnchorForWideImage() {
        // Wide image (4:1) on portrait viewport → fitted 400×100
        let fitted = CGSize(width: 400, height: 100)
        let offset = ImagePreviewMath.zoomAnchorOffset(
            anchorUnitX: 0.0, anchorUnitY: 0.0,
            fittedSize: fitted,
            lastScale: 1.0, newScale: 2.0,
            lastPanOffset: .zero
        )
        // p = (-200, -50); O = p * (1-2) = (200, 50)
        XCTAssertEqual(offset.width, 200, accuracy: accuracy)
        XCTAssertEqual(offset.height, 50, accuracy: accuracy)
    }

    func testZoomAnchorForTallImage() {
        // Tall image (1:4) on portrait viewport → fitted 200×800
        let fitted = CGSize(width: 200, height: 800)
        let offset = ImagePreviewMath.zoomAnchorOffset(
            anchorUnitX: 0.0, anchorUnitY: 0.0,
            fittedSize: fitted,
            lastScale: 1.0, newScale: 2.0,
            lastPanOffset: .zero
        )
        // p = (-100, -400); O = p * (1-2) = (100, 400)
        XCTAssertEqual(offset.width, 100, accuracy: accuracy)
        XCTAssertEqual(offset.height, 400, accuracy: accuracy)
    }

    func testZoomAnchorScreenPositionStaysFixed() {
        // The anchor's screen position (= layoutPos) must not change.
        // layoutPos = (ux-0.5)*fitted (the touch point in screen space).
        // The actual image point: p = (layoutPos - lastPan) / lastScale.
        // Invariant: p * newScale + O_new == layoutPos.
        let fitted = CGSize(width: 300, height: 150)
        let lastScale: CGFloat = 1.5
        let newScale: CGFloat = 3.0
        let lastPan = CGSize(width: 20, height: -10)
        let anchorUX: CGFloat = 0.3
        let anchorUY: CGFloat = 0.8

        let layoutPos = CGSize(
            width: (anchorUX - 0.5) * fitted.width,
            height: (anchorUY - 0.5) * fitted.height
        )
        let pReal = CGSize(
            width: (layoutPos.width - lastPan.width) / lastScale,
            height: (layoutPos.height - lastPan.height) / lastScale
        )

        let newOffset = ImagePreviewMath.zoomAnchorOffset(
            anchorUnitX: anchorUX, anchorUnitY: anchorUY,
            fittedSize: fitted,
            lastScale: lastScale, newScale: newScale,
            lastPanOffset: lastPan
        )

        let afterX = pReal.width * newScale + newOffset.width
        let afterY = pReal.height * newScale + newOffset.height

        XCTAssertEqual(afterX, layoutPos.width, accuracy: accuracy)
        XCTAssertEqual(afterY, layoutPos.height, accuracy: accuracy)
    }

    func testZoomAnchorScreenPositionStaysFixedForWideImage() {
        // Same invariant for a very wide (16:1) image at 1× (simplifies to
        // p == layoutPos since lastScale=1 and lastPan=0).
        let fitted = CGSize(width: 400, height: 25)
        let lastScale: CGFloat = 1.0
        let newScale: CGFloat = 4.0
        let lastPan: CGSize = .zero
        let ux: CGFloat = 0.75
        let uy: CGFloat = 0.9

        let layoutPos = CGSize(
            width: (ux - 0.5) * fitted.width,
            height: (uy - 0.5) * fitted.height
        )
        let pReal = layoutPos // lastScale=1, lastPan=0

        let newOffset = ImagePreviewMath.zoomAnchorOffset(
            anchorUnitX: ux, anchorUnitY: uy,
            fittedSize: fitted,
            lastScale: lastScale, newScale: newScale,
            lastPanOffset: lastPan
        )

        let afterX = pReal.width * newScale + newOffset.width
        let afterY = pReal.height * newScale + newOffset.height

        XCTAssertEqual(afterX, layoutPos.width, accuracy: accuracy)
        XCTAssertEqual(afterY, layoutPos.height, accuracy: accuracy)
    }

    func testZoomAnchorScreenPositionStaysFixedForTallImage() {
        // Same invariant for a very tall (1:10) image already at 2× zoom.
        let fitted = CGSize(width: 80, height: 800)
        let lastScale: CGFloat = 2.0
        let newScale: CGFloat = 5.0
        let lastPan = CGSize(width: -15, height: 60)
        let ux: CGFloat = 0.1
        let uy: CGFloat = 0.6

        let layoutPos = CGSize(
            width: (ux - 0.5) * fitted.width,
            height: (uy - 0.5) * fitted.height
        )
        let pReal = CGSize(
            width: (layoutPos.width - lastPan.width) / lastScale,
            height: (layoutPos.height - lastPan.height) / lastScale
        )

        let newOffset = ImagePreviewMath.zoomAnchorOffset(
            anchorUnitX: ux, anchorUnitY: uy,
            fittedSize: fitted,
            lastScale: lastScale, newScale: newScale,
            lastPanOffset: lastPan
        )

        let afterX = pReal.width * newScale + newOffset.width
        let afterY = pReal.height * newScale + newOffset.height

        XCTAssertEqual(afterX, layoutPos.width, accuracy: accuracy)
        XCTAssertEqual(afterY, layoutPos.height, accuracy: accuracy)
    }

    func testZoomAnchorWithExistingPanForNonSquareImage() {
        // Off-center anchor + existing pan on a non-square fitted image
        let fitted = CGSize(width: 400, height: 100)
        let offset = ImagePreviewMath.zoomAnchorOffset(
            anchorUnitX: 0.25, anchorUnitY: 0.75,
            fittedSize: fitted,
            lastScale: 2.0, newScale: 3.0,
            lastPanOffset: CGSize(width: 30, height: -10)
        )
        // layoutPos = (-100, 25); ratio = 1.5
        // O = (-100)*(1-1.5) + 30*1.5 = 50+45 = 95
        //     25*(1-1.5) + (-10)*1.5 = -12.5-15 = -27.5
        XCTAssertEqual(offset.width, 95, accuracy: accuracy)
        XCTAssertEqual(offset.height, -27.5, accuracy: accuracy)
    }

    func testZoomAnchorZoomOutFullyResetsForNonSquareImage() {
        // Zoom out to 1× from an off-center anchor.
        let fitted = CGSize(width: 400, height: 100)
        let offset = ImagePreviewMath.zoomAnchorOffset(
            anchorUnitX: 0.0, anchorUnitY: 1.0,
            fittedSize: fitted,
            lastScale: 3.0, newScale: 1.0,
            lastPanOffset: CGSize(width: 400, height: 100)
        )
        // layoutPos = (-200, 50); ratio = 1/3
        // O.w = -200*(1-1/3) + 400*(1/3) = -200*2/3 + 400/3 = -400/3+400/3 = 0
        // O.h = 50*(1-1/3) + 100*(1/3) = 50*2/3 + 100/3 = 100/3+100/3 = 200/3
        XCTAssertEqual(offset.width, 0, accuracy: accuracy)
        XCTAssertEqual(offset.height, 200.0 / 3.0, accuracy: accuracy)
    }

    func testZoomAnchorMinimalScaleChange() {
        // Very small scale delta shouldn't cause large offset jumps
        let fitted = CGSize(width: 400, height: 100)
        let offset = ImagePreviewMath.zoomAnchorOffset(
            anchorUnitX: 0.0, anchorUnitY: 0.0,
            fittedSize: fitted,
            lastScale: 1.0, newScale: 1.01,
            lastPanOffset: .zero
        )
        // p = (-200, -50); delta = 1-1.01 = -0.01
        // O = (-200 * -0.01, -50 * -0.01) = (2, 0.5)
        XCTAssertEqual(offset.width, 2, accuracy: accuracy)
        XCTAssertEqual(offset.height, 0.5, accuracy: accuracy)
    }

    // MARK: - Drag-baseline offset adjustment (dismiss → pinch transition)

    func testDragBaselineSubtractionEliminatesPrePinchMovement() {
        // Simulate: user drags down 80pt (dismiss), then pinches.
        // dragBaseline captures the 80pt.  After pinch ends, subsequent
        // single-finger drag must subtract the baseline.
        let dragTranslation = CGSize(width: 10, height: 80)
        let dragBaseline = dragTranslation  // captured during pinch

        // Post-pinch single-finger drag moves 30pt further down
        let postPinchTranslation = CGSize(width: 15, height: 110) // cumulative from gesture start
        let delta = CGSize(
            width: postPinchTranslation.width - dragBaseline.width,
            height: postPinchTranslation.height - dragBaseline.height
        )

        // Delta should reflect only the post-pinch movement
        XCTAssertEqual(delta.width, 5, accuracy: accuracy)
        XCTAssertEqual(delta.height, 30, accuracy: accuracy)
    }

    func testDragBaselineZeroWhenNoPinchOccurred() {
        // Without a pinch, baseline is .zero, so delta == raw translation
        let dragBaseline: CGSize = .zero
        let translation = CGSize(width: 50, height: -70)
        let delta = CGSize(
            width: translation.width - dragBaseline.width,
            height: translation.height - dragBaseline.height
        )
        XCTAssertEqual(delta.width, 50, accuracy: accuracy)
        XCTAssertEqual(delta.height, -70, accuracy: accuracy)
    }

    func testDismissThresholdUsesBaselineAdjustedHeight() {
        // Simulate: user drags 120pt down then pinches, then lifts pinch.
        // The remaining drag ends with cumulative 130pt — but 120pt was
        // pre-pinch, so effective dismiss is only 10pt (below threshold).
        let savedBaseline = CGSize(width: 0, height: 120)
        let endTranslation = CGSize(width: 0, height: 130)
        let dismissH = endTranslation.height - savedBaseline.height
        XCTAssertEqual(dismissH, 10, accuracy: accuracy)
        XCTAssertTrue(abs(dismissH) < 100, "Should NOT meet dismiss threshold")
    }

    func testDismissThresholdMeetsWithLargePostPinchDrag() {
        // Same scenario but user drags 250pt after pinch → should dismiss
        let savedBaseline = CGSize(width: 0, height: 50)
        let endTranslation = CGSize(width: 0, height: 300)
        let dismissH = endTranslation.height - savedBaseline.height
        XCTAssertEqual(dismissH, 250, accuracy: accuracy)
        XCTAssertTrue(abs(dismissH) > 100, "Should meet dismiss threshold")
    }

    // MARK: - Consecutive gesture simulation

    func testConsecutiveZoomGesturesPreservePosition() {
        // Simulate: pinch 1×→2× at anchor (0.3, 0.7), then a second
        // pinch 2×→4× at anchor (0.6, 0.4).  The second anchor's screen
        // position (layoutPos2) must stay fixed.
        let fitted = CGSize(width: 400, height: 100)

        // Gesture 1: 1× → 2×
        let offset1 = ImagePreviewMath.zoomAnchorOffset(
            anchorUnitX: 0.3, anchorUnitY: 0.7,
            fittedSize: fitted,
            lastScale: 1.0, newScale: 2.0,
            lastPanOffset: .zero
        )
        // After gesture 1, clamp offset (the overlay does this in .onEnded)
        let clamped1 = ImagePreviewMath.clampedOffset(
            offset1, scale: 2.0, fittedSize: fitted, viewportSize: viewport
        )

        // Gesture 2: 2× → 4× at a different anchor
        let ux2: CGFloat = 0.6
        let uy2: CGFloat = 0.4
        let layoutPos2 = CGSize(
            width: (ux2 - 0.5) * fitted.width,
            height: (uy2 - 0.5) * fitted.height
        )
        let pReal2 = CGSize(
            width: (layoutPos2.width - clamped1.width) / 2.0,
            height: (layoutPos2.height - clamped1.height) / 2.0
        )

        let offset2 = ImagePreviewMath.zoomAnchorOffset(
            anchorUnitX: ux2, anchorUnitY: uy2,
            fittedSize: fitted,
            lastScale: 2.0, newScale: 4.0,
            lastPanOffset: clamped1
        )

        // Verify: pReal2 * newScale + offset2 == layoutPos2
        let afterX = pReal2.width * 4.0 + offset2.width
        let afterY = pReal2.height * 4.0 + offset2.height

        XCTAssertEqual(afterX, layoutPos2.width, accuracy: accuracy)
        XCTAssertEqual(afterY, layoutPos2.height, accuracy: accuracy)
    }

    // MARK: - Fitted Image Size

    func testFittedSizeWiderImage() {
        let imageSize = CGSize(width: 1000, height: 500) // 2:1 aspect
        let result = ImagePreviewMath.fittedImageSize(imageSize: imageSize, viewportSize: viewport)
        // viewport is 400x800 (0.5 aspect), image is wider (2.0 aspect)
        // fits width: w=400, h=400/2=200
        XCTAssertEqual(result.width, 400, accuracy: accuracy)
        XCTAssertEqual(result.height, 200, accuracy: accuracy)
    }

    func testFittedSizeTallerImage() {
        let imageSize = CGSize(width: 200, height: 1000) // 0.2 aspect
        let result = ImagePreviewMath.fittedImageSize(imageSize: imageSize, viewportSize: viewport)
        // viewport aspect = 0.5, image aspect = 0.2, image is taller
        // fits height: h=800, w=800*0.2=160
        XCTAssertEqual(result.width, 160, accuracy: accuracy)
        XCTAssertEqual(result.height, 800, accuracy: accuracy)
    }

    func testFittedSizeMatchingAspect() {
        let imageSize = CGSize(width: 200, height: 400) // 0.5 aspect = viewport
        let result = ImagePreviewMath.fittedImageSize(imageSize: imageSize, viewportSize: viewport)
        XCTAssertEqual(result.width, 400, accuracy: accuracy)
        XCTAssertEqual(result.height, 800, accuracy: accuracy)
    }

    func testFittedSizeZeroImageReturnsViewport() {
        let result = ImagePreviewMath.fittedImageSize(imageSize: .zero, viewportSize: viewport)
        XCTAssertEqual(result.width, viewport.width, accuracy: accuracy)
        XCTAssertEqual(result.height, viewport.height, accuracy: accuracy)
    }

    func testFittedSizeZeroViewportReturnsZero() {
        let result = ImagePreviewMath.fittedImageSize(
            imageSize: CGSize(width: 100, height: 100), viewportSize: .zero
        )
        XCTAssertEqual(result.width, 0, accuracy: accuracy)
        XCTAssertEqual(result.height, 0, accuracy: accuracy)
    }

    // MARK: - Clamped Offset

    func testClampedOffsetAtScale1ReturnsZero() {
        let fitted = CGSize(width: 400, height: 200)
        let result = ImagePreviewMath.clampedOffset(
            CGSize(width: 100, height: 50),
            scale: 1.0, fittedSize: fitted, viewportSize: viewport
        )
        // At scale 1, fitted*1 - viewport <= 0 for both axes, so max = 0
        XCTAssertEqual(result.width, 0, accuracy: accuracy)
        XCTAssertEqual(result.height, 0, accuracy: accuracy)
    }

    func testClampedOffsetWithinBoundsUnchanged() {
        let fitted = CGSize(width: 400, height: 800)
        // At scale 3: 400*3=1200, maxX=(1200-400)/2=400
        //             800*3=2400, maxY=(2400-800)/2=800
        let offset = CGSize(width: 100, height: -200)
        let result = ImagePreviewMath.clampedOffset(
            offset, scale: 3.0, fittedSize: fitted, viewportSize: viewport
        )
        XCTAssertEqual(result.width, 100, accuracy: accuracy)
        XCTAssertEqual(result.height, -200, accuracy: accuracy)
    }

    func testClampedOffsetExceedingBoundsIsClamped() {
        let fitted = CGSize(width: 400, height: 800)
        // At scale 2: maxX=(800-400)/2=200, maxY=(1600-800)/2=400
        let offset = CGSize(width: 500, height: -900)
        let result = ImagePreviewMath.clampedOffset(
            offset, scale: 2.0, fittedSize: fitted, viewportSize: viewport
        )
        XCTAssertEqual(result.width, 200, accuracy: accuracy)
        XCTAssertEqual(result.height, -400, accuracy: accuracy)
    }

    func testClampedOffsetForWideImageAtScale2() {
        // Wide image fitted 400×100 in 400×800 viewport
        let fitted = CGSize(width: 400, height: 100)
        // scale 2: maxX=(800-400)/2=200, maxY=(200-800)/2 → clamp 0
        let offset = CGSize(width: 300, height: 50)
        let result = ImagePreviewMath.clampedOffset(
            offset, scale: 2.0, fittedSize: fitted, viewportSize: viewport
        )
        XCTAssertEqual(result.width, 200, accuracy: accuracy)
        XCTAssertEqual(result.height, 0, accuracy: accuracy) // can't pan vertically
    }

    func testClampedOffsetForWideImageNeedsHighScaleToAllowVerticalPan() {
        // Wide image fitted 400×100 in 400×800 viewport
        // Vertical pan only possible when 100 * scale > 800 → scale > 8
        let fitted = CGSize(width: 400, height: 100)
        let atScale8 = ImagePreviewMath.clampedOffset(
            CGSize(width: 0, height: 50), scale: 8.0,
            fittedSize: fitted, viewportSize: viewport
        )
        // 100*8=800, maxY=(800-800)/2=0 → still no vertical pan
        XCTAssertEqual(atScale8.height, 0, accuracy: accuracy)

        let atScale9 = ImagePreviewMath.clampedOffset(
            CGSize(width: 0, height: 50), scale: 9.0,
            fittedSize: fitted, viewportSize: viewport
        )
        // 100*9=900, maxY=(900-800)/2=50 → can pan up to 50
        XCTAssertEqual(atScale9.height, 50, accuracy: accuracy)
    }

    func testClampedOffsetForTallImageAtScale2() {
        // Tall image fitted 80×800 in 400×800 viewport
        let fitted = CGSize(width: 80, height: 800)
        // scale 2: maxX=(160-400)/2 → 0, maxY=(1600-800)/2=400
        let offset = CGSize(width: 100, height: 500)
        let result = ImagePreviewMath.clampedOffset(
            offset, scale: 2.0, fittedSize: fitted, viewportSize: viewport
        )
        XCTAssertEqual(result.width, 0, accuracy: accuracy)  // can't pan horizontally
        XCTAssertEqual(result.height, 400, accuracy: accuracy)
    }

    func testClampedOffsetNegativeValues() {
        let fitted = CGSize(width: 400, height: 400)
        // scale 2: maxX=(800-400)/2=200, maxY=(800-800)/2=0
        let result = ImagePreviewMath.clampedOffset(
            CGSize(width: -300, height: -100), scale: 2.0,
            fittedSize: fitted, viewportSize: viewport
        )
        XCTAssertEqual(result.width, -200, accuracy: accuracy)
        XCTAssertEqual(result.height, 0, accuracy: accuracy)
    }

    // MARK: - Rubber Band

    func testRubberBandWithinLimitReturnsValue() {
        XCTAssertEqual(ImagePreviewMath.rubberBand(50, limit: 100), 50, accuracy: accuracy)
        XCTAssertEqual(ImagePreviewMath.rubberBand(-80, limit: 100), -80, accuracy: accuracy)
        XCTAssertEqual(ImagePreviewMath.rubberBand(0, limit: 100), 0, accuracy: accuracy)
    }

    func testRubberBandBeyondLimitIsDamped() {
        let result = ImagePreviewMath.rubberBand(200, limit: 100)
        // Should be > 100 (beyond limit) but < 200 (damped)
        XCTAssertGreaterThan(result, 100)
        XCTAssertLessThan(result, 200)
    }

    func testRubberBandBeyondNegativeLimitIsDamped() {
        let result = ImagePreviewMath.rubberBand(-200, limit: 100)
        XCTAssertLessThan(result, -100)
        XCTAssertGreaterThan(result, -200)
    }

    func testRubberBandSymmetric() {
        let pos = ImagePreviewMath.rubberBand(150, limit: 80)
        let neg = ImagePreviewMath.rubberBand(-150, limit: 80)
        XCTAssertEqual(pos, -neg, accuracy: accuracy)
    }

    func testRubberBandZeroLimitDampsAllMovement() {
        let result = ImagePreviewMath.rubberBand(50, limit: 0)
        XCTAssertGreaterThan(result, 0)
        XCTAssertLessThan(result, 50)
    }

    func testRubberBandLargerExcessApproachesAsymptote() {
        let small = ImagePreviewMath.rubberBand(200, limit: 100)
        let large = ImagePreviewMath.rubberBand(10000, limit: 100)
        // Both are beyond limit, but large excess should be closer to the
        // asymptote (limit + 200) than small excess
        XCTAssertGreaterThan(large, small)
        XCTAssertLessThanOrEqual(large, 100 + 200) // asymptote is limit + dim(200)
    }

    func testRubberBandAtExactLimit() {
        let result = ImagePreviewMath.rubberBand(100, limit: 100)
        XCTAssertEqual(result, 100, accuracy: accuracy)
    }

    func testRubberBandAtExactNegativeLimit() {
        let result = ImagePreviewMath.rubberBand(-100, limit: 100)
        XCTAssertEqual(result, -100, accuracy: accuracy)
    }

    // MARK: - Fitted Size + Anchor Integration

    func testFittedSizeSquareImageOnPortraitViewport() {
        // 1:1 image on 400×800 viewport → fitted 400×400
        let imageSize = CGSize(width: 600, height: 600)
        let fitted = ImagePreviewMath.fittedImageSize(imageSize: imageSize, viewportSize: viewport)
        XCTAssertEqual(fitted.width, 400, accuracy: accuracy)
        XCTAssertEqual(fitted.height, 400, accuracy: accuracy)
    }

    func testFullPipelineWideImage() {
        // End-to-end: image (1600×200) on viewport (400×800)
        // 1. Compute fitted size
        let imageSize = CGSize(width: 1600, height: 200)
        let fitted = ImagePreviewMath.fittedImageSize(imageSize: imageSize, viewportSize: viewport)
        XCTAssertEqual(fitted.width, 400, accuracy: accuracy)
        XCTAssertEqual(fitted.height, 50, accuracy: accuracy)

        // 2. Zoom 1×→3× at anchor (0.25, 0.75)
        let offset = ImagePreviewMath.zoomAnchorOffset(
            anchorUnitX: 0.25, anchorUnitY: 0.75,
            fittedSize: fitted,
            lastScale: 1.0, newScale: 3.0,
            lastPanOffset: .zero
        )
        // p = (-100, 12.5); O = p * (1-3) = (200, -25)
        XCTAssertEqual(offset.width, 200, accuracy: accuracy)
        XCTAssertEqual(offset.height, -25, accuracy: accuracy)

        // 3. Clamp: scale 3, fitted 400×50, viewport 400×800
        // maxX = (1200-400)/2 = 400, maxY = (150-800)/2 → 0
        let clamped = ImagePreviewMath.clampedOffset(
            offset, scale: 3.0, fittedSize: fitted, viewportSize: viewport
        )
        XCTAssertEqual(clamped.width, 200, accuracy: accuracy) // within 400 bound
        XCTAssertEqual(clamped.height, 0, accuracy: accuracy)  // clamped to 0
    }

    func testFullPipelineTallImage() {
        // End-to-end: image (100×2000) on viewport (400×800)
        let imageSize = CGSize(width: 100, height: 2000)
        let fitted = ImagePreviewMath.fittedImageSize(imageSize: imageSize, viewportSize: viewport)
        // aspect = 0.05, viewAspect = 0.5 → fits height: w = 800*0.05 = 40, h = 800
        XCTAssertEqual(fitted.width, 40, accuracy: accuracy)
        XCTAssertEqual(fitted.height, 800, accuracy: accuracy)

        // Zoom 1×→2× at anchor (0.5, 0.25)
        let offset = ImagePreviewMath.zoomAnchorOffset(
            anchorUnitX: 0.5, anchorUnitY: 0.25,
            fittedSize: fitted,
            lastScale: 1.0, newScale: 2.0,
            lastPanOffset: .zero
        )
        // layoutPos = (0, -200); ratio = 2; O = (0, -200)*(1-2) + 0 = (0, 200)
        XCTAssertEqual(offset.width, 0, accuracy: accuracy)
        XCTAssertEqual(offset.height, 200, accuracy: accuracy)

        // Clamp: scale 2, fitted 40×800, viewport 400×800
        // maxX = (80-400)/2 → 0, maxY = (1600-800)/2 = 400
        let clamped = ImagePreviewMath.clampedOffset(
            offset, scale: 2.0, fittedSize: fitted, viewportSize: viewport
        )
        XCTAssertEqual(clamped.width, 0, accuracy: accuracy)
        XCTAssertEqual(clamped.height, 200, accuracy: accuracy) // within 400 bound
    }

    // MARK: - Re-zoom from already-zoomed state

    func testReZoomAtTopOfAlreadyZoomedImage() {
        // The original bug: pinch at the top/bottom of a 2× zoomed image
        // produced wrong centering.
        // Image fitted 400×200, zoomed to 2×, panned to top (offset.y = -200).
        let fitted = CGSize(width: 400, height: 200)
        let lastScale: CGFloat = 2.0
        let lastPan = CGSize(width: 0, height: -200)

        // Touch at the center of the visible area.  At scale 2 with
        // offset -200, the visible center's layoutPos.y should be:
        //   p_center * lastScale + lastPan.y = 0 * 2 + (-200) = -200
        // But layoutPos = (ux - 0.5) * fitted.h.  If user touches at
        // ux = ..., we can reverse-engineer: ux = layoutPos/fitted + 0.5
        //   ux_y = -200/200 + 0.5 = -0.5  (outside [0,1], meaning the
        //   touch is at the layout-frame top edge, uy=0).
        //
        // A more realistic touch: user touches at uy=0.3 in the zoomed view.
        let uy: CGFloat = 0.3
        let layoutPosY = (uy - 0.5) * fitted.height  // = -40
        let pReal = (layoutPosY - lastPan.height) / lastScale  // (-40 - (-200)) / 2 = 80

        let offset = ImagePreviewMath.zoomAnchorOffset(
            anchorUnitX: 0.5, anchorUnitY: uy,
            fittedSize: fitted,
            lastScale: lastScale, newScale: 4.0,
            lastPanOffset: lastPan
        )

        // Verify: pReal * 4 + O_new == layoutPos
        let afterY = pReal * 4.0 + offset.height
        XCTAssertEqual(afterY, layoutPosY, accuracy: accuracy)
    }

    func testReZoomAtBottomOfAlreadyZoomedImage() {
        let fitted = CGSize(width: 400, height: 200)
        let lastScale: CGFloat = 2.0
        let lastPan = CGSize(width: 0, height: 200)  // panned to bottom

        let uy: CGFloat = 0.7
        let layoutPosY = (uy - 0.5) * fitted.height  // 40
        let pReal = (layoutPosY - lastPan.height) / lastScale  // (40 - 200) / 2 = -80

        let offset = ImagePreviewMath.zoomAnchorOffset(
            anchorUnitX: 0.5, anchorUnitY: uy,
            fittedSize: fitted,
            lastScale: lastScale, newScale: 3.0,
            lastPanOffset: lastPan
        )

        let afterY = pReal * 3.0 + offset.height
        XCTAssertEqual(afterY, layoutPosY, accuracy: accuracy)
    }

    func testReZoomFromScale3WithLargePan() {
        // Extreme case: 3× zoom, large pan, zoom to 5× at corner.
        let fitted = CGSize(width: 400, height: 100)
        let lastScale: CGFloat = 3.0
        let lastPan = CGSize(width: -300, height: 0)
        let ux: CGFloat = 0.1
        let uy: CGFloat = 0.9

        let layoutPos = CGSize(
            width: (ux - 0.5) * fitted.width,
            height: (uy - 0.5) * fitted.height
        )
        let pReal = CGSize(
            width: (layoutPos.width - lastPan.width) / lastScale,
            height: (layoutPos.height - lastPan.height) / lastScale
        )

        let offset = ImagePreviewMath.zoomAnchorOffset(
            anchorUnitX: ux, anchorUnitY: uy,
            fittedSize: fitted,
            lastScale: lastScale, newScale: 5.0,
            lastPanOffset: lastPan
        )

        let afterX = pReal.width * 5.0 + offset.width
        let afterY = pReal.height * 5.0 + offset.height
        XCTAssertEqual(afterX, layoutPos.width, accuracy: accuracy)
        XCTAssertEqual(afterY, layoutPos.height, accuracy: accuracy)
    }
}
