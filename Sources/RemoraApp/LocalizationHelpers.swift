import Foundation

@inline(__always)
func tr(_ key: String) -> String {
    L10n.tr(key, fallback: key)
}

func localizedConnectionState(_ state: String) -> String {
    if state == "Idle" {
        return tr("Idle")
    }
    if state == "Connecting" {
        return tr("Connecting")
    }
    if state == "Disconnected" {
        return tr("Disconnected")
    }
    if state.hasPrefix("Connected ("), let mode = state.split(separator: "(").last?.dropLast() {
        return "\(tr("Connected")) (\(tr(String(mode))))"
    }
    if state.hasPrefix("Failed: ") {
        return "\(tr("Failed")): \(state.dropFirst("Failed: ".count))"
    }
    if state.hasPrefix("Write failed: ") {
        return "\(tr("Write failed")): \(state.dropFirst("Write failed: ".count))"
    }
    if state.hasPrefix("Resize failed: ") {
        return "\(tr("Resize failed")): \(state.dropFirst("Resize failed: ".count))"
    }
    if state == "Waiting (host-key)" {
        return tr("Waiting (host-key)")
    }
    if state == "Waiting (password)" {
        return tr("Waiting (password)")
    }
    if state == "Waiting (otp)" {
        return tr("Waiting (otp)")
    }
    if state == "Waiting (passphrase)" {
        return tr("Waiting (passphrase)")
    }
    return state
}
