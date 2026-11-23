import Foundation
import Observation

@Observable
final class SleepTimerManager {
    var remainingSeconds: Int = 0
    private var timerTask: Task<Void, Never>?

    var isActive: Bool {
        remainingSeconds > 0
    }

    var formattedRemaining: String {
        MediaTimeFormatter.format(Double(remainingSeconds))
    }

    deinit {
        timerTask?.cancel()
    }

    func startTimer(minutes: Int, onExpire: @escaping () -> Void) {
        cancelTimer()
        guard minutes > 0 else { return }

        let totalSeconds = minutes * 60
        let endDate = Date().addingTimeInterval(TimeInterval(totalSeconds))
        remainingSeconds = totalSeconds

        timerTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }

                let remaining = max(0, Int(ceil(endDate.timeIntervalSinceNow)))
                self.remainingSeconds = remaining

                if remaining <= 0 {
                    self.timerTask = nil
                    onExpire()
                    return
                }
            }
        }
    }

    func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
        remainingSeconds = 0
    }
}
