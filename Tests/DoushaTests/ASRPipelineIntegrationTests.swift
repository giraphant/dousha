import XCTest
import ASRSupport
import DoubaoASR

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
            { var m = $0; flushed = m.flushOnStop(at: 7.5); return m },
        ])

        XCTAssertEqual(visible, "今天天气很不错。我们去公园玩。")
        XCTAssertEqual(flushed, visible)
        XCTAssertEqual(model.committedText, visible)
    }

    func testLateRevisionReconcilesAsTailEditAfterCommittedPrefix() {
        // The revision replaces finalized (not yet committed) text while a
        // newer utterance is already active — the reconciler must express it
        // as one tail edit whose stable prefix still covers all committed
        // text. Covered inside the invariant replay; this asserts the shape.
        var model = ASRSegmentModel(config: config)
        model.observeFinal("今天天气不错。", at: 0.0)
        model.observePartial("我们去公园", at: 0.5)
        let before = model.fullText
        model.observeRevision("今天天气很不错。", at: 1.0)

        let op = StreamingTextReconciler.reconcile(previous: before, candidate: model.fullText)
        XCTAssertEqual(op.kind, .replaceTail)
        XCTAssertEqual(op.stablePrefixCount, 4) // "今天天气" survives
        XCTAssertEqual(op.apply(to: before), "今天天气很不错。我们去公园")
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

    // MARK: - Soniox-shaped trace

    func testSonioxShapedTraceAccumulatesUtterances() {
        // Soniox mapping (ASRSegmentModel doc): growing non-final token tail →
        // observePartial; utterance text at an <end> endpoint → observeFinal.
        var model = ASRSegmentModel(config: config)
        model.observePartial("hel", at: 0.0)
        model.observePartial("hello there", at: 0.4)
        model.observeFinal("hello there. ", at: 0.8)   // <end> marker text
        model.observePartial("how are", at: 1.2)
        model.observePartial("how are you", at: 1.6)

        XCTAssertEqual(model.recentlyFinalizedText, "hello there. ")
        XCTAssertEqual(model.flushOnStop(at: 2.0), "hello there. how are you")
    }

    // MARK: - Final path: formatter → corrector (as handleFinal runs it)

    /// The terminal `.final` is formatter-normalized by the engines, then
    /// corrected once by the snapshot from `env.makeCorrector` (QUA-264).
    /// Same composition, same order, over realistic raw engine output.
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
        // Soniox-style half-width comma in Han context widens before the
        // corrector cases the multi-word term.
        XCTAssertEqual(finalPath("先打开claude code,然后看readme.", corrector: corrector),
                       "先打开 Claude Code，然后看 readme.")
    }

    func testFinalPathIsIdempotent() {
        // handleFinal runs the composition once, but partial re-entry (e.g. a
        // corrected transcript pasted back and re-dictated around) must not
        // compound: the composed pipeline is idempotent for built-in rules.
        let corrector = TranscriptCorrector(
            replacements: ["嗯=>", "阿派=>API"].compactMap(TranscriptCorrector.Replacement.parse),
            casingTerms: TranscriptCorrector.builtinCasingTerms)
        for raw in ["嗯用阿派解析json数据。。", "先打开claude code,然后看readme.", "然后，"] {
            let once = finalPath(raw, corrector: corrector)
            XCTAssertEqual(finalPath(once, corrector: corrector), once,
                           "final path not idempotent for: \(raw)")
        }
    }
}
