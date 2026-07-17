import XCTest
import ASRSupport
import DoubaoASR
import SonioxASR

/// Issue #42: cross-layer integration tests for the recent ASR additions.
/// Each layer (ASRSegmentModel QUA-265, StreamingTextReconciler QUA-263,
/// TranscriptCorrector QUA-264, DoubaoResultState #38) has its own unit
/// suite; these tests exercise the *compositions* the pipeline runs (or will
/// run once the dormant layers are wired): segment snapshots through the
/// reconciler, one engine trace through both Doubao result models, and the
/// formatter→corrector final path exactly as `handleFinal` applies it.
/// Everything stays offline and deterministic — timestamps are scripted.
final class ASRPipelineIntegrationTests: XCTestCase {
    private let config = ASRSegmentModel.Config(pauseBoundary: 1.5, revisionWindow: 3.0)

    // MARK: - Segment model → reconciler

    /// Replays a scripted event timeline, reconciling consecutive `fullText`
    /// snapshots after every event and enforcing the two cross-layer
    /// invariants:
    ///   1. Convergence — applying each operation to the previous snapshot
    ///      reproduces the new one, so a typewriter consumer tracks
    ///      `fullText` exactly.
    ///   2. Committed stability — no edit ever reaches into text that was
    ///      already committed at the previous snapshot (the revision floor
    ///      holds across the layer boundary).
    private func replay(_ events: [(ASRSegmentModel) -> ASRSegmentModel])
        -> (model: ASRSegmentModel, visible: String) {
        var model = ASRSegmentModel(config: config)
        var visible = ""
        for (i, event) in events.enumerated() {
            let committedBefore = model.committedText
            model = event(model)
            let op = StreamingTextReconciler.reconcile(previous: visible,
                                                       candidate: model.fullText)
            XCTAssertGreaterThanOrEqual(
                op.stablePrefixCount, committedBefore.count,
                "event \(i): edit reached into committed text")
            visible = op.apply(to: visible)
            XCTAssertEqual(visible, model.fullText, "event \(i): snapshots diverged")
        }
        return (model, visible)
    }

    func testStreamingSessionDrivesReconcilerWithinCommittedFloor() {
        var flushed = ""
        let (model, visible) = replay([
            { var m = $0; m.observePartial("今天", at: 0.0); return m },
            { var m = $0; m.observePartial("今天天气", at: 0.5); return m },
            { var m = $0; m.observePartial("今天天气不错", at: 1.0); return m },
            { var m = $0; m.tick(at: 2.6); return m },                       // pause parks
            { var m = $0; m.observeFinal("今天天气不错。", at: 3.0); return m },
            { var m = $0; m.observePartial("我们", at: 3.5); return m },      // next utterance
            { var m = $0; m.observePartial("我们去公园", at: 4.0); return m },
            { var m = $0; m.observeRevision("今天天气很不错。", at: 4.5); return m },
            { var m = $0; m.observePartial("我们去公园玩", at: 6.5); return m }, // lazy tick commits #1
            { var m = $0; m.observeFinal("我们去公园玩。", at: 7.0); return m },
            // Revision of utterance #2 while #1 is committed — the one step
            // where the committed floor is nonzero AND the text changes, so
            // the floor invariant in replay() is exercised for real.
            { var m = $0; m.observeRevision("我们去公园玩耍。", at: 7.2); return m },
            { var m = $0; flushed = m.flushOnStop(at: 7.5); return m },
        ])

        XCTAssertEqual(visible, "今天天气很不错。我们去公园玩耍。")
        XCTAssertEqual(flushed, visible)
        XCTAssertEqual(model.committedText, visible)
    }

    func testLateRevisionReconcilesAsTailEditAfterCommittedPrefix() {
        // A revision replaces finalized (not yet committed) text while an
        // older utterance is already committed and a newer one is active —
        // the reconciler must express it as one tail edit whose stable prefix
        // covers the whole committed floor.
        var model = ASRSegmentModel(config: config)
        model.observeFinal("第一句。", at: 0.0)
        model.observeFinal("今天天气不错。", at: 3.5)   // lazy tick commits 第一句。
        model.observePartial("我们去公园", at: 4.0)
        XCTAssertEqual(model.committedText, "第一句。")
        let before = model.fullText
        model.observeRevision("今天天气很不错。", at: 4.5)

        let op = StreamingTextReconciler.reconcile(previous: before, candidate: model.fullText)
        XCTAssertEqual(op.kind, .replaceTail)
        XCTAssertEqual(op.stablePrefixCount, 8) // "第一句。今天天气" survives
        XCTAssertGreaterThanOrEqual(op.stablePrefixCount, model.committedText.count)
        XCTAssertEqual(op.apply(to: before), "第一句。今天天气很不错。我们去公园")
    }

    func testShrinkRescueIsAppendOnlyAtFullTextLevel() {
        // Raw hypotheses shrink dramatically at a silent utterance switch;
        // the segment model turns that into pure growth of `fullText`, so the
        // reconciler sees an append — no visible text jump, which is the
        // whole point of composing the two layers.
        var model = ASRSegmentModel(config: config)
        model.observePartial("这是很长的第一句话啊", at: 0.0)
        let before = model.fullText
        model.observePartial("然后", at: 0.5)

        let op = StreamingTextReconciler.reconcile(previous: before, candidate: model.fullText)
        XCTAssertEqual(op.kind, .appendOnly)
        XCTAssertEqual(op.insertion, "然后")
    }

    // MARK: - Doubao trace agreement

    /// `DoubaoResultState` (shipping) and `ASRSegmentModel` (QUA-265, fed via
    /// the adapter mapping documented on the model) implement the same
    /// rescue-on-shrink accounting. One realistic trace — interims, a silent
    /// new-utterance shrink, a VAD final — must yield the same transcript
    /// from both, or the two have drifted.
    func testDoubaoTraceYieldsSameTranscriptFromBothModels() {
        func result(_ text: String, interim: Bool = true, vad: Bool = false) -> [String: Any] {
            ["results": [["text": text, "is_interim": interim, "is_vad_finished": vad]]]
        }
        let trace: [(object: [String: Any], at: TimeInterval)] = [
            (result("今天天气"), 0.0),
            (result("今天天气不错呀"), 0.5),
            (result("我们"), 1.0),          // shrink: silent new utterance
            (result("我们去公园"), 1.5),
            (result("我们去公园。", interim: false, vad: true), 2.0),
        ]

        var doubao = DoubaoResultState()
        var segments = ASRSegmentModel(config: config)
        var commits: [DoubaoResultState.Commit] = []
        for (object, at) in trace {
            guard let update = doubao.ingest(object: object) else {
                return XCTFail("trace event at t=\(at) was dropped")
            }
            if let commit = update.commit { commits.append(commit) }
            // Adapter mapping (ASRSegmentModel doc): cumulative hypothesis →
            // observePartial; VAD commit → observeFinal.
            if update.vadFinished, !update.isInterim {
                segments.observeFinal(update.text, at: at)
            } else {
                segments.observePartial(update.text, at: at)
            }
        }

        XCTAssertEqual(commits, [.rescued("今天天气不错呀"), .final("我们去公园。")])
        XCTAssertEqual(doubao.rawText, "今天天气不错呀我们去公园。")
        XCTAssertEqual(segments.flushOnStop(at: 3.0), doubao.rawText)
    }

    // MARK: - Soniox trace agreement

    /// One realistic Soniox token-batch trace drives both the shipping
    /// `SonioxResponseParser` and, via the adapter mapping documented on
    /// `ASRSegmentModel` (cumulative utterance text → observePartial, the
    /// utterance's text at an `<end>` endpoint → observeFinal), the segment
    /// model. Both accumulations must agree on the transcript.
    func testSonioxTraceAgreesBetweenParserAndSegmentModel() {
        let trace: [(tokens: [(text: String, isFinal: Bool)], finished: Bool, at: TimeInterval)] = [
            ([("hel", false)], false, 0.0),
            ([("hello", true), (" there", false)], false, 0.4),
            ([(" there", true), (".", true), ("<end>", true)], false, 0.8),
            ([(" how", false)], false, 1.2),
            ([(" how are you", false)], false, 1.6),   // interim replaced per batch
            ([(" how are you", true), ("<end>", true)], true, 2.0),
        ]

        var parser = SonioxResponseParser()
        var model = ASRSegmentModel(config: config)
        var priorUtterancesLength = 0
        for (tokens, finished, at) in trace {
            var object: [String: Any] =
                ["tokens": tokens.map { ["text": $0.text, "is_final": $0.isFinal] }]
            if finished { object["finished"] = true }
            guard parser.ingest(object: object) != nil else {
                return XCTFail("batch at t=\(at) not recognised")
            }
            // Adapter: the current utterance is what the parser accumulated
            // past the previous endpoint (finalized delta + live interim).
            let utterance = String(parser.finalText.dropFirst(priorUtterancesLength))
                + parser.interimText
            if tokens.contains(where: { $0.text == "<end>" }) {
                model.observeFinal(utterance, at: at)
                priorUtterancesLength = parser.finalText.count
            } else {
                model.observePartial(utterance, at: at)
            }
        }

        XCTAssertEqual(parser.finalText, "hello there. how are you")
        XCTAssertEqual(model.flushOnStop(at: 3.0), parser.finalText)
    }

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
