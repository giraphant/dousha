import XCTest
@testable import Dousha

final class FloatingHUDLayoutTests: XCTestCase {
    @MainActor
    func testCompactCardHeightUnchanged() {
        // The empty/no-text card keeps its original design + height.
        XCTAssertEqual(FloatingHUDView.compactHeight, 71)
    }

    @MainActor
    func testCompactContentUsesQuarterAxes() {
        // Compact (empty) layout positions are preserved.
        XCTAssertEqual(FloatingHUDView.contextRowCenterYRatio, 0.30)
        XCTAssertEqual(FloatingHUDView.levelMeterCenterYRatio, 0.70)
    }

    @MainActor
    func testCardCanGrowFromCompactToCap() {
        // Once transcript text arrives the card grows beyond compact.
        XCTAssertGreaterThan(FloatingHUDView.maxHeight, FloatingHUDView.compactHeight)
    }

    @MainActor
    func testTranscriptViewportCapsAtFiveVisibleLines() {
        XCTAssertEqual(FloatingHUDView.maxTranscriptLines, 5)
        XCTAssertEqual(
            FloatingHUDView.transcriptViewportHeight,
            FloatingHUDView.transcriptTopPadding
                + FloatingHUDView.transcriptTextBandHeight
                + FloatingHUDView.transcriptBottomPadding
        )
        XCTAssertEqual(
            FloatingHUDView.maxHeight,
            FloatingHUDView.transcriptViewportHeight + FloatingHUDView.meterRegionHeight
        )
    }

    @MainActor
    func testCardHeightUsesCompactHeightWithoutTranscript() {
        XCTAssertEqual(
            FloatingHUDView.resolvedCardHeight(hasTranscript: false, measuredTextHeight: 10_000),
            FloatingHUDView.compactHeight
        )
    }

    @MainActor
    func testCardHeightAddsTranscriptPaddingAndMeterRegion() {
        let measuredTextHeight = FloatingHUDView.transcriptLineHeight
        let expected = max(
            FloatingHUDView.compactHeight,
            measuredTextHeight
                + FloatingHUDView.transcriptTopPadding
                + FloatingHUDView.transcriptBottomPadding
                + FloatingHUDView.meterRegionHeight
        )

        XCTAssertEqual(
            FloatingHUDView.resolvedCardHeight(hasTranscript: true, measuredTextHeight: measuredTextHeight),
            expected
        )
    }

    @MainActor
    func testCardHeightClampsAtMeasuredTranscriptCapWithinStaticPanelCap() {
        let measuredFiveLineCap: CGFloat = 93
        let expected = min(
            FloatingHUDView.maxHeight,
            FloatingHUDView.transcriptTopPadding
                + measuredFiveLineCap
                + FloatingHUDView.transcriptBottomPadding
                + FloatingHUDView.meterRegionHeight
        )

        XCTAssertEqual(
            FloatingHUDView.resolvedCardHeight(
                hasTranscript: true,
                measuredTextHeight: 10_000,
                capHeight: measuredFiveLineCap
            ),
            expected
        )
    }

    @MainActor
    func testTranscriptViewportHeightClampsAtMeasuredFiveLineCap() {
        let measuredFiveLineCap: CGFloat = 93
        XCTAssertEqual(
            FloatingHUDView.resolvedTranscriptViewportHeight(
                measuredTextHeight: 10_000,
                capHeight: measuredFiveLineCap
            ),
            FloatingHUDView.transcriptTopPadding + measuredFiveLineCap + FloatingHUDView.transcriptBottomPadding
        )
    }

    @MainActor
    func testTranscriptViewportUsesNaturalHeightBeforeCap() {
        let measuredTextHeight = FloatingHUDView.transcriptLineHeight
        let expected = FloatingHUDView.transcriptTopPadding
            + measuredTextHeight
            + FloatingHUDView.transcriptBottomPadding

        XCTAssertEqual(
            FloatingHUDView.resolvedTranscriptViewportHeight(measuredTextHeight: measuredTextHeight),
            expected
        )
    }

    @MainActor
    func testTranscriptRowsStayCompactWhileMeterGapIsPreserved() {
        XCTAssertEqual(FloatingHUDView.transcriptLineHeight, 16)
        XCTAssertEqual(FloatingHUDView.transcriptBottomPadding, 6)
        XCTAssertEqual(FloatingHUDView.meterRegionHeight, 28)
    }

    @MainActor
    func testTranscriptTopBreathingRoomIsReservedOutsideTextBand() {
        XCTAssertEqual(FloatingHUDView.transcriptTopPadding, 12)
        XCTAssertGreaterThan(FloatingHUDView.transcriptTopPadding, FloatingHUDView.transcriptBottomPadding)
        XCTAssertGreaterThan(
            FloatingHUDView.transcriptTextBandHeight,
            FloatingHUDView.transcriptLineHeight * CGFloat(FloatingHUDView.maxTranscriptLines)
        )
        XCTAssertEqual(
            FloatingHUDView.transcriptTextBandHeight,
            FloatingHUDView.transcriptRenderedLinePitch * CGFloat(FloatingHUDView.maxTranscriptLines)
        )
    }

    @MainActor
    func testTranscriptTextBandDefaultsToConservativeFallbackUntilMeasured() {
        XCTAssertEqual(FloatingHUDView.transcriptRenderedLinePitch, 17.5)
        XCTAssertEqual(
            FloatingHUDView.transcriptTextBandHeight,
            FloatingHUDView.transcriptRenderedLinePitch * CGFloat(FloatingHUDView.maxTranscriptLines)
        )
    }

    @MainActor
    func testBorderBeamUsesReferenceStyleInverseMaskGlow() {
        XCTAssertEqual(FloatingHUDView.borderBeamLineWidth, 0.9)
        XCTAssertEqual(FloatingHUDView.borderBeamGlowRadius, 15.0)
        XCTAssertEqual(FloatingHUDView.borderBeamPadding, 0.5)
        XCTAssertEqual(HUDBorderBeam.baseStrokeOpacity, 0.30)
        XCTAssertEqual(HUDBorderBeam.beamMaskBlurDivisor, 1.5)
        XCTAssertEqual(HUDBorderBeam.beamMaskPaddingMultiplier, -2.0)
        XCTAssertEqual(HUDBorderBeam.beamVisibleStartLocation, 0.52)
        XCTAssertEqual(HUDBorderBeam.beamVisibleEndLocation, 0.97)
        XCTAssertEqual(HUDBorderBeam.glowOpacity, 0.54)
        XCTAssertEqual(HUDBorderBeam.sameColorHotspotOpacity, 0.92)
    }

    @MainActor
    func testLayoutRevisionMarksInstalledBuild() {
        XCTAssertEqual(
            FloatingHUDView.layoutRevision,
            "QUA-147-HUD-SCROLLVIEW-MEASUREDCAP-20260531-1519"
        )
    }
}
