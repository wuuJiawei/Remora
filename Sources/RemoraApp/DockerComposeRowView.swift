import AppKit

@MainActor
final class DockerComposeRowView: NSTableCellView {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onDelete: (() -> Void)?

    private let rowContentView = NSView()
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let actionStack = NSStackView()
    private let primaryButton = DockerIconButton(symbolName: "stop.fill")
    private let deleteButton = DockerIconButton(symbolName: "trash")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(node: DockerContainerNode) {
        let isRunning = node.state == .running
        titleField.stringValue = node.title
        titleField.textColor = isRunning ? .labelColor : .tertiaryLabelColor
        iconView.image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: node.title)
        iconView.contentTintColor = isRunning ? .systemIndigo : .tertiaryLabelColor
        primaryButton.symbolName = isRunning ? "stop.fill" : "play.fill"
        primaryButton.contentTintColor = isRunning ? .secondaryLabelColor : .tertiaryLabelColor
        deleteButton.contentTintColor = isRunning ? .secondaryLabelColor : .tertiaryLabelColor
    }

    private func setup() {
        rowContentView.translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1

        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = DockerListMetrics.actionButtonSpacing
        actionStack.addArrangedSubview(primaryButton)
        actionStack.addArrangedSubview(deleteButton)
        actionStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(rowContentView)
        rowContentView.addSubview(iconView)
        rowContentView.addSubview(titleField)
        rowContentView.addSubview(actionStack)

        NSLayoutConstraint.activate([
            rowContentView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: DockerListMetrics.contentHorizontalPadding + DockerListMetrics.composeIndent
            ),
            rowContentView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -DockerListMetrics.actionTrailingPadding
            ),
            rowContentView.topAnchor.constraint(equalTo: topAnchor),
            rowContentView.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconView.leadingAnchor.constraint(equalTo: rowContentView.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: rowContentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: DockerListMetrics.composeIconSize),
            iconView.heightAnchor.constraint(equalToConstant: DockerListMetrics.composeIconSize),

            titleField.leadingAnchor.constraint(
                equalTo: iconView.trailingAnchor,
                constant: DockerListMetrics.titleLeadingSpacing
            ),
            titleField.trailingAnchor.constraint(
                lessThanOrEqualTo: actionStack.leadingAnchor,
                constant: -DockerListMetrics.textActionSpacing
            ),
            titleField.centerYAnchor.constraint(equalTo: rowContentView.centerYAnchor),

            actionStack.trailingAnchor.constraint(equalTo: rowContentView.trailingAnchor),
            actionStack.centerYAnchor.constraint(equalTo: rowContentView.centerYAnchor),
        ])

        primaryButton.target = self
        primaryButton.action = #selector(handlePrimary)
        deleteButton.target = self
        deleteButton.action = #selector(handleDelete)
    }

    @objc private func handlePrimary() {
        if primaryButton.symbolName == "play.fill" {
            onStart?()
        } else {
            onStop?()
        }
    }

    @objc private func handleDelete() {
        onDelete?()
    }
}

@MainActor
final class DockerIconButton: NSButton {
    var symbolName: String {
        didSet {
            image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        }
    }

    init(symbolName: String) {
        self.symbolName = symbolName
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        self.symbolName = "circle"
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: DockerListMetrics.actionButtonSize),
            heightAnchor.constraint(equalToConstant: DockerListMetrics.actionButtonSize),
        ])
    }
}
