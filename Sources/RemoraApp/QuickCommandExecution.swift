import RemoraCore

extension HostQuickCommand {
    struct ExecutionRequest: Equatable {
        let text: String
        let usesBracketedPaste: Bool
    }

    func executionRequest() -> ExecutionRequest? {
        let body = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return ExecutionRequest(
            text: body,
            usesBracketedPaste: body.contains("\n")
        )
    }
}
