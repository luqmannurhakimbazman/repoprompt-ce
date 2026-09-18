import Foundation

/// The single seam between the app and a System One model.
///
/// One method, so a test double is two lines and no consumer can reach the network
/// another way.
protocol SystemOneJudging: Sendable {
    func judge(state: JudgmentState, questions: [JudgmentQuestion]) async throws -> JudgmentResult
}
