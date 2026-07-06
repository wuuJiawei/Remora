import Foundation

enum CommandPolicyDecision: String, Codable, Equatable, Sendable {
    case allowAutoRun
    case requireConfirmation
    case deny
}

struct CommandPolicyHostContext: Equatable, Sendable {
    var sessionMode: String?
    var hostLabel: String?
    var hostId: String?
    var workingDirectory: String?

    static let empty = CommandPolicyHostContext(
        sessionMode: nil,
        hostLabel: nil,
        hostId: nil,
        workingDirectory: nil
    )
}

struct CommandPolicyResult: Equatable, Sendable {
    var command: String
    var risk: TerminalAICommandRisk
    var decision: CommandPolicyDecision
    var reason: String
    var mode: AIInteractionMode
}

struct CommandPolicyEngine: Sendable {
    func evaluate(
        command: String,
        hostContext: CommandPolicyHostContext = .empty,
        mode: AIInteractionMode
    ) -> CommandPolicyResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CommandPolicyResult(
                command: trimmed,
                risk: .danger,
                decision: .deny,
                reason: "Empty commands cannot be executed.",
                mode: mode
            )
        }

        let risk = classifyRisk(trimmed)
        let decision = decision(for: risk, command: trimmed, mode: mode)
        return CommandPolicyResult(
            command: trimmed,
            risk: risk,
            decision: decision,
            reason: reason(for: risk, decision: decision, mode: mode),
            mode: mode
        )
    }

    private func decision(
        for risk: TerminalAICommandRisk,
        command: String,
        mode: AIInteractionMode
    ) -> CommandPolicyDecision {
        if risk == .danger {
            return .deny
        }

        switch mode {
        case .suggest, .review, .runbook:
            return .requireConfirmation
        case .intervention:
            return risk == .safe && isExplicitReadOnlyDiagnostic(command)
                ? .allowAutoRun
                : .requireConfirmation
        }
    }

    private func classifyRisk(_ command: String) -> TerminalAICommandRisk {
        let normalized = normalizedCommand(command)
        if matchesDangerousCommand(normalized) {
            return .danger
        }
        if matchesConfirmationCommand(normalized) {
            return .review
        }
        if isExplicitReadOnlyDiagnostic(normalized), !containsShellControlOperator(normalized) {
            return .safe
        }
        return .review
    }

    private func matchesDangerousCommand(_ command: String) -> Bool {
        let patterns = [
            #"(^|\s)rm\s+(-[^\n;]*[rf][^\n;]*|-[^\n;]*[fr][^\n;]*)\s+(/|/\*|~|~/?\*|\$HOME|"\$HOME")(\s|$)"#,
            #"(^|\s)rm\s+(-[^\n;]*[rf][^\n;]*|-[^\n;]*[fr][^\n;]*).*(--no-preserve-root)"#,
            #"(^|\s)mkfs(\.[A-Za-z0-9_-]+)?\s+"#,
            #"(^|\s)dd\s+.*\bof=/dev/(sd|vd|xvd|nvme|disk|rdisk)"#,
            #"(^|\s):\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;"#,
        ]
        return patterns.contains { command.range(of: $0, options: .regularExpression) != nil }
    }

    private func matchesConfirmationCommand(_ command: String) -> Bool {
        let patterns = [
            #"(^|\s)sudo(\s|$)"#,
            #"(^|\s)rm(\s|$)"#,
            #"(^|\s)dd(\s|$)"#,
            #"(^|\s)chmod\s+(-[^\n;]*R|--recursive)(\s|$)"#,
            #"(^|\s)chown\s+(-[^\n;]*R|--recursive)(\s|$)"#,
            #"(^|\s)(iptables|ip6tables|ufw)(\s|$)"#,
            #"(^|\s)docker\s+compose\s+down(\s|$)"#,
            #"(^|\s)systemctl\s+(restart|reload|stop|start|enable|disable)(\s|$)"#,
            #"(^|\s)service\s+\S+\s+(restart|reload|stop|start)(\s|$)"#,
            #"(^|\s)(shutdown|reboot|halt|poweroff)(\s|$)"#,
        ]
        if patterns.contains(where: { command.range(of: $0, options: .regularExpression) != nil }) {
            return true
        }
        return containsShellControlOperator(command)
    }

    private func isExplicitReadOnlyDiagnostic(_ command: String) -> Bool {
        let normalized = normalizedCommand(command)
        let patterns = [
            #"^whoami$"#,
            #"^pwd$"#,
            #"^uname(\s+-[A-Za-z]+)?$"#,
            #"^uptime$"#,
            #"^df\s+-h(\s+\S+)?$"#,
            #"^free\s+-h$"#,
            #"^ps(\s+[-A-Za-z0-9]+)*$"#,
            #"^systemctl\s+status\s+\S+(\s+--no-pager)?$"#,
            #"^journalctl\s+(-n\s+\d+|--lines(=|\s+)\d+)(\s+(-u|--unit)\s+\S+)?(\s+--no-pager)?$"#,
            #"^docker\s+ps(\s+-a)?(\s+--format\s+.+)?$"#,
            #"^docker\s+logs\s+(--tail(=|\s+)\d+\s+)?[A-Za-z0-9_.:/@-]+$"#,
        ]
        return patterns.contains { normalized.range(of: $0, options: .regularExpression) != nil }
    }

    private func containsShellControlOperator(_ command: String) -> Bool {
        let operators = ["&&", "||", ";", "|", "`", "$(", ">", "<"]
        return operators.contains { command.contains($0) }
    }

    private func normalizedCommand(_ command: String) -> String {
        command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }

    private func reason(
        for risk: TerminalAICommandRisk,
        decision: CommandPolicyDecision,
        mode: AIInteractionMode
    ) -> String {
        switch decision {
        case .allowAutoRun:
            return "Read-only diagnostic command allowed in intervention mode."
        case .requireConfirmation:
            switch mode {
            case .suggest:
                return "Suggest mode never auto-runs AI commands."
            case .review, .runbook:
                return "This mode requires user confirmation before execution."
            case .intervention:
                return risk == .safe
                    ? "Safe command still requires confirmation because it is not in the read-only auto-run allowlist."
                    : "Command can change system state or needs operator review."
            }
        case .deny:
            return "Command is too destructive or broad for AI-assisted execution."
        }
    }
}
