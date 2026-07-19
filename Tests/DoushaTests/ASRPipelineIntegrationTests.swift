import XCTest
import ASRSupport

/// Issue #42: cross-layer integration tests for the ASR final path.
/// `TranscriptCorrector` (QUA-264) and `TranscriptFormatter` have their own
/// unit suites; these tests pin the *composition* exactly as `handleFinal`
/// applies it. (The QUA-263/QUA-265 composition tests left with those
/// components — see ARCHITECTURE.md §7.)
final class ASRPipelineIntegrationTests: XCTestCase {
    // MARK: - Final path: formatter → corrector (QUA-264)

    /// The composed text transform applied to a Doubao/Soniox terminal
    /// `.final`: those engines pre-normalize via `TranscriptFormatter`, then
    /// `handleFinal` runs the snapshotted `sessionCorrect` once. The
    /// controller *wiring* (corrected text → HUD/refiner/injector, one call,
    /// config snapshotted at start) is covered by `RecordingControllerTests`;
    /// these tests pin the text contract of the composition.
    ///
    /// Caveat: this is NOT the Apple Speech path — Apple passes raw text and
    /// `handleFinal` only trims + corrects, so with correction *disabled* an
    /// Apple final is NOT normalized. Do not assert that here.
    private func finalPath(_ raw: String, corrector: TranscriptCorrector) -> String {
        corrector.correct(TranscriptFormatter.normalize(raw))
    }

    func testFinalPathComposesFormatterAndCorrector() {
        let corrector = TranscriptCorrector(
            replacements: ["嗯=>", "阿派=>API"].compactMap(TranscriptCorrector.Replacement.parse),
            casingTerms: TranscriptCorrector.builtinCasingTerms)

        // Filler removal + user fix + casing + 盘古 spacing + doubled-mark tail.
        XCTAssertEqual(finalPath("嗯用阿派解析json数据。。", corrector: corrector),
                       "用 API 解析 JSON 数据。")
        XCTAssertEqual(finalPath("先打开claude code,然后看readme.", corrector: corrector),
                       "先打开 Claude Code，然后看 readme.")
    }

    func testFormatterPassOrderIsObservable() {
        // A user rule written against formatter output (full-width ，) fires
        // only because normalization runs BEFORE the corrector: rule 1 sees
        // pre-normalized text (the corrector's own normalize runs after its
        // replacements). This distinguishes the composition from `correct`
        // alone.
        let corrector = TranscriptCorrector(
            replacements: ["，然后=>。然后"].compactMap(TranscriptCorrector.Replacement.parse))
        XCTAssertEqual(finalPath("好的,然后走", corrector: corrector), "好的。然后走")
        XCTAssertNotEqual(corrector.correct("好的,然后走"), "好的。然后走")
    }
}
