import Foundation
import DoubaoASR
import SonioxASR
import ASRSupport
import TalkerCommonSync

/// 双枪老太包 (QUA-145, MVP / 实验):
///
/// 录音阶段只用豆包实时跑 —— 中文 partials 快、HUD 体验好,而且它顺手把这段
/// 音频落成 WAV。停录后,把**同一段 WAV** 分别丢给 Soniox 和豆包各重转一遍
/// (两条候选条件完全一致,对比最公平),再把两条结果一起交给 LLM 校对合并成
/// 一条最终文本。
///
/// 串行执行 —— 不并发抓麦克风,省掉 AVAudioEngine 单 tap 的那套改造。延迟换来
/// 实现简单,验证「多家转录 + LLM 融合是否比单家准」这个假设足够了。
///
/// 注意:`stop()` 返回的 `TranscriptionResult.text` 已经是 LLM 融合后的最终
/// 结果,所以 AppDelegate 在 fusion 模式下必须**跳过**单条 refine,直接粘贴
/// (否则会对融合结果再 LLM 一次)。
final class FusionBackend: SpeechBackend {
    /// 实时录音 + WAV 产出;停录后复用同一实例对 WAV 跑豆包重转。
    private let doubao = DoubaoASR()
    /// 仅用于对 WAV 跑 Soniox 重转。
    private let soniox: SonioxASR

    init(language: String) {
        _ = language // 两家都自动识别语种,这里不需要。
        self.soniox = SonioxASR(apiKey: Preferences.shared.sonioxAPIKey,
                                mode: Preferences.shared.sonioxMode)
    }

    func setLanguage(_ identifier: String) {}

    func start(onPartial: @escaping @Sendable (String) -> Void,
               onAudioLevel: @escaping @Sendable (Float) -> Void,
               onError: @escaping @Sendable (Error) -> Void) {
        doubao.start(onPartial: onPartial, onAudioLevel: onAudioLevel, onError: onError)
    }

    func cancel() {
        doubao.cancel()
    }

    func stop(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
        // 先把实时会话收尾:释放麦克风、把音频落盘成 WAV。它的实时文本我们不用
        // —— 两家都从同一段 WAV 重转才是公平对比。
        doubao.stop { [doubao, soniox] liveResult in
            let wav = liveResult.savedAudioURL ?? DoubaoASR.savedAudioURL
            guard FileManager.default.fileExists(atPath: wav.path) else {
                doushaLog("[Fusion] no WAV at \(wav.path) — returning live result len=\(liveResult.text.count)")
                completion(liveResult)
                return
            }

            // LLM 配置在(回调所在线程)先读好再带进 Task,避免在并发上下文里
            // 触碰 Preferences 单例。
            let llmBaseURL = Preferences.shared.llmBaseURL
            let llmAPIKey  = Preferences.shared.llmAPIKey
            let llmModel   = Preferences.shared.llmModel
            let traceId    = liveResult.traceId

            Task {
                let t0 = CFAbsoluteTimeGetCurrent()

                // 串行重转 —— MVP 不追求并发延迟。
                let t1 = CFAbsoluteTimeGetCurrent()
                let sonioxText = await soniox.retranscribe(wavURL: wav, parentTraceId: traceId)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let tSoniox = CFAbsoluteTimeGetCurrent() - t1

                let t2 = CFAbsoluteTimeGetCurrent()
                let doubaoText = await doubao.retranscribe(wavURL: wav, parentTraceId: traceId)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let tDoubao = CFAbsoluteTimeGetCurrent() - t2

                let candidates = [("Soniox", sonioxText), ("豆包", doubaoText)]
                    .filter { !$0.1.isEmpty }

                let t3 = CFAbsoluteTimeGetCurrent()
                let fused: String
                if candidates.isEmpty {
                    fused = ""
                } else if let merged = await LLMRefiner.fuse(candidates: candidates,
                                                             baseURL: llmBaseURL,
                                                             apiKey: llmAPIKey,
                                                             model: llmModel),
                          !merged.isEmpty {
                    fused = merged
                } else {
                    // LLM 没配 / 调用失败:退回豆包(中文为主),豆包空再退 Soniox。
                    fused = doubaoText.isEmpty ? sonioxText : doubaoText
                }
                let tLLM = CFAbsoluteTimeGetCurrent() - t3
                let tTotal = CFAbsoluteTimeGetCurrent() - t0

                FusionLog.append(soniox: sonioxText, doubao: doubaoText,
                                 fused: fused, traceId: traceId,
                                 timing: FusionLog.Timing(soniox: tSoniox, doubao: tDoubao,
                                                          llm: tLLM, total: tTotal))
                doushaLog("[Fusion] soniox.len=\(sonioxText.count) doubao.len=\(doubaoText.count) fused.len=\(fused.count) soniox=\(String(format: "%.2f", tSoniox))s doubao=\(String(format: "%.2f", tDoubao))s llm=\(String(format: "%.2f", tLLM))s total=\(String(format: "%.2f", tTotal))s")

                completion(TranscriptionResult(
                    text: fused,
                    audioDuration: liveResult.audioDuration,
                    lastResponseAge: liveResult.lastResponseAge,
                    lastTranscriptAge: liveResult.lastTranscriptAge,
                    maxSegmentGap: liveResult.maxSegmentGap,
                    savedAudioURL: liveResult.savedAudioURL,
                    traceId: traceId
                ))
            }
        }
    }

    // 融合模式不暴露手动「重新转写」入口 —— stop() 内部本来就把多家转录 + 合并
    // 做完了,没有单独可重放的语义。
    var canRetranscribe: Bool { false }

    func retranscribeLastRecording(parentTraceId: String?,
                                   completion: @escaping @Sendable (String?) -> Void) {
        completion(nil)
    }
}
