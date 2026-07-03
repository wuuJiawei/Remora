import AppKit

@MainActor
final class DockerContainerRowView: NSTableCellView {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onDelete: (() -> Void)?
    var onLogs: (() -> Void)?
    var onShell: (() -> Void)?

    private let rowContentView = NSView()
    private let iconView = NSImageView()
    private let statusDot = NSView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let actionStack = NSStackView()
    private let linkButton = DockerIconButton(symbolName: "link")
    private let primaryButton = DockerIconButton(symbolName: "stop.fill")
    private let deleteButton = DockerIconButton(symbolName: "trash")
    private var leadingConstraint: NSLayoutConstraint?
    private var isRunning = false

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            updateColors()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(container: DockerContainer, isChild: Bool) {
        isRunning = container.isRunning
        titleField.stringValue = container.name
        subtitleField.stringValue = container.image
        iconView.image = NSImage(systemSymbolName: "cube.box.fill", accessibilityDescription: container.name)
        statusDot.layer?.backgroundColor = (isRunning ? NSColor.systemGreen : NSColor.clear).cgColor
        statusDot.layer?.borderColor = NSColor.windowBackgroundColor.cgColor
        linkButton.isHidden = !isRunning
        primaryButton.symbolName = isRunning ? "stop.fill" : "play.fill"
        leadingConstraint?.constant = DockerListMetrics.primaryIconLeading
            + (isChild ? DockerListMetrics.containerIndent : 0)
        updateColors()
    }

    private func setup() {
        wantsLayer = true

        rowContentView.translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = DockerListMetrics.statusDotSize / 2
        statusDot.layer?.masksToBounds = true

        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        subtitleField.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleField.lineBreakMode = .byTruncatingMiddle
        subtitleField.maximumNumberOfLines = 1

        let textStack = NSStackView(views: [titleField, subtitleField])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = DockerListMetrics.subtitleSpacing

        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = DockerListMetrics.actionButtonSpacing
        actionStack.addArrangedSubview(linkButton)
        actionStack.addArrangedSubview(primaryButton)
        actionStack.addArrangedSubview(deleteButton)
        actionStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(rowContentView)
        rowContentView.addSubview(iconView)
        rowContentView.addSubview(statusDot)
        rowContentView.addSubview(textStack)
        rowContentView.addSubview(actionStack)

        leadingConstraint = rowContentView.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: DockerListMetrics.contentHorizontalPadding
        )
        NSLayoutConstraint.activate([
            leadingConstraint!,
            rowContentView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -DockerListMetrics.actionTrailingPadding
            ),
            rowContentView.topAnchor.constraint(equalTo: topAnchor),
            rowContentView.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconView.leadingAnchor.constraint(equalTo: rowContentView.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: rowContentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: DockerListMetrics.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: DockerListMetrics.iconSize),

            statusDot.trailingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 2),
            statusDot.bottomAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 1),
            statusDot.widthAnchor.constraint(equalToConstant: DockerListMetrics.statusDotSize),
            statusDot.heightAnchor.constraint(equalToConstant: DockerListMetrics.statusDotSize),

            textStack.leadingAnchor.constraint(
                equalTo: iconView.trailingAnchor,
                constant: DockerListMetrics.titleLeadingSpacing
            ),
            textStack.centerYAnchor.constraint(equalTo: rowContentView.centerYAnchor),
            textStack.trailingAnchor.constraint(
                lessThanOrEqualTo: actionStack.leadingAnchor,
                constant: -DockerListMetrics.textActionSpacing
            ),

            actionStack.trailingAnchor.constraint(equalTo: rowContentView.trailingAnchor),
            actionStack.centerYAnchor.constraint(equalTo: rowContentView.centerYAnchor),
        ])

        linkButton.target = self
        linkButton.action = #selector(handleShell)
        primaryButton.target = self
        primaryButton.action = #selector(handlePrimary)
        deleteButton.target = self
        deleteButton.action = #selector(handleDelete)
    }

    @objc private func handleShell() {
        onShell?()
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

    private func updateColors() {
        let isSelected = backgroundStyle == .emphasized
        if isSelected {
            iconView.contentTintColor = .white
            titleField.textColor = .white
            subtitleField.textColor = NSColor.white.withAlphaComponent(0.78)
            primaryButton.contentTintColor = .white
            deleteButton.contentTintColor = .white
            linkButton.contentTintColor = .white
        } else {
            iconView.contentTintColor = isRunning ? .systemTeal : .tertiaryLabelColor
            titleField.textColor = isRunning ? .labelColor : .tertiaryLabelColor
            subtitleField.textColor = isRunning ? .secondaryLabelColor : .tertiaryLabelColor
            primaryButton.contentTintColor = isRunning ? .secondaryLabelColor : .tertiaryLabelColor
            deleteButton.contentTintColor = isRunning ? .secondaryLabelColor : .tertiaryLabelColor
            linkButton.contentTintColor = isRunning ? .secondaryLabelColor : .tertiaryLabelColor
        }
    }
}
