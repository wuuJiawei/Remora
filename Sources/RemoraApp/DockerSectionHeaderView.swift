import AppKit

@MainActor
final class DockerSectionHeaderView: NSTableCellView {
    private let titleField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(title: String) {
        titleField.stringValue = title
    }

    private func setup() {
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        titleField.textColor = .secondaryLabelColor
        addSubview(titleField)
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: DockerListMetrics.contentHorizontalPadding
            ),
            titleField.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -DockerListMetrics.actionTrailingPadding
            ),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}
