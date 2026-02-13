import UIKit

final class KeyboardViewController: UIInputViewController, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }

    private let store = KeyboardCompanionStore.shared

    private let backgroundView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let rootStack = UIStackView()
    private let typingContainer = UIStackView()
    private let accessoryBar = UIStackView()
    private let keyboardStack = UIStackView()
    private let statusLabel = UILabel()
    private var inputViewHeightConstraint: NSLayoutConstraint?
    private var currentMetrics = KeyboardLayoutMetrics.resolve(availableHeight: 256, isCompactLandscape: false)

    private let dictationPanel = UIView()
    private var dictationPanelHeightConstraint: NSLayoutConstraint?
    private let dictationTopBar = UIStackView()
    private let dictationCenterStack = UIStackView()
    private let dictationStateLabel = UILabel()
    private let waveformStack = UIStackView()
    private let dictationHintLabel = UILabel()
    private let cancelDictationButton = UIButton(type: .system)
    private let confirmDictationButton = UIButton(type: .system)

    private let insertLatestButton = UIButton(type: .system)
    private let accessoryMicButton = UIButton(type: .system)

    private let shiftButton = UIButton(type: .system)
    private let backspaceButton = UIButton(type: .system)
    private let modeToggleButton = UIButton(type: .system)
    private let nextKeyboardButton = UIButton(type: .system)
    private let spaceButton = UIButton(type: .system)
    private let returnButton = UIButton(type: .system)

    private var isShiftEnabled = false {
        didSet { rebuildKeyboardRows() }
    }

    private var layoutMode: KeyboardLayoutMode = .letters {
        didSet {
            if layoutMode != .letters {
                isShiftEnabled = false
            }
            rebuildKeyboardRows()
        }
    }

    private var dictationState: KeyboardDictationState = .typing {
        didSet { renderDictationState() }
    }

    private var transcriptPollTimer: Timer?
    private var listeningBaselineTimestamp: Date?

    private enum Layout {
        static let horizontalInset: CGFloat = 6
        static let verticalInset: CGFloat = 6
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        inputView?.allowsSelfSizing = true
        setupUI()
        reloadData()
        renderDictationState()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updatePreferredContentSizeIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        backgroundView.frame = view.bounds
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        reloadData()
        applyCurrentTheme()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyCurrentTheme()
        updatePreferredContentSizeIfNeeded()
    }

    deinit {
        stopTranscriptPolling()
    }

    private func setupUI() {
        view.backgroundColor = .clear
        backgroundView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backgroundView)

        rootStack.axis = .vertical
        rootStack.spacing = currentMetrics.stackSpacing
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Layout.horizontalInset),
            rootStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Layout.horizontalInset),
            rootStack.topAnchor.constraint(equalTo: guide.topAnchor, constant: Layout.verticalInset),
            rootStack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -Layout.verticalInset)
        ])

        configureTypingContainer()
        configureDictationPanel()

        rootStack.addArrangedSubview(typingContainer)
        rootStack.addArrangedSubview(dictationPanel)

        applyCurrentTheme()
        updatePreferredContentSizeIfNeeded()
    }

    private func configureTypingContainer() {
        typingContainer.axis = .vertical
        typingContainer.spacing = currentMetrics.stackSpacing

        configureAccessoryBar()
        configureKeyboardArea()

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = UIColor.secondaryLabel.withAlphaComponent(0.95)
        statusLabel.numberOfLines = 1
        statusLabel.textAlignment = .center
        statusLabel.text = "Tap mic above the keyboard to listen, then confirm to insert."
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .vertical)
        typingContainer.addArrangedSubview(statusLabel)
    }

    private func configureDictationPanel() {
        dictationPanel.layer.cornerRadius = 16
        dictationPanel.layer.cornerCurve = .continuous
        dictationPanel.layer.borderWidth = 0.8
        dictationPanel.translatesAutoresizingMaskIntoConstraints = false
        dictationPanelHeightConstraint = dictationPanel.heightAnchor.constraint(equalToConstant: currentMetrics.dictationPanelHeight)
        dictationPanelHeightConstraint?.isActive = true

        dictationTopBar.axis = .horizontal
        dictationTopBar.distribution = .equalSpacing
        dictationTopBar.alignment = .center
        dictationTopBar.translatesAutoresizingMaskIntoConstraints = false

        stylePanelControl(cancelDictationButton, symbolName: "xmark")
        cancelDictationButton.addTarget(self, action: #selector(cancelDictationTapped), for: .touchUpInside)

        stylePanelControl(confirmDictationButton, symbolName: "checkmark")
        confirmDictationButton.addTarget(self, action: #selector(confirmDictationTapped), for: .touchUpInside)

        dictationTopBar.addArrangedSubview(cancelDictationButton)
        dictationTopBar.addArrangedSubview(confirmDictationButton)

        dictationCenterStack.axis = .vertical
        dictationCenterStack.spacing = 10
        dictationCenterStack.alignment = .center
        dictationCenterStack.translatesAutoresizingMaskIntoConstraints = false

        dictationStateLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        dictationStateLabel.text = "Listening"

        waveformStack.axis = .horizontal
        waveformStack.spacing = 5
        waveformStack.alignment = .bottom
        waveformStack.translatesAutoresizingMaskIntoConstraints = false
        for index in 0..<7 {
            let bar = UIView()
            bar.layer.cornerRadius = 1.8
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 4.5).isActive = true
            let baseHeight = CGFloat(12 + (index % 3) * 5)
            bar.heightAnchor.constraint(equalToConstant: baseHeight).isActive = true
            waveformStack.addArrangedSubview(bar)
        }

        dictationHintLabel.font = .systemFont(ofSize: 13, weight: .regular)
        dictationHintLabel.numberOfLines = 2
        dictationHintLabel.textAlignment = .center

        dictationCenterStack.addArrangedSubview(dictationStateLabel)
        dictationCenterStack.addArrangedSubview(waveformStack)
        dictationCenterStack.addArrangedSubview(dictationHintLabel)

        dictationPanel.addSubview(dictationTopBar)
        dictationPanel.addSubview(dictationCenterStack)

        NSLayoutConstraint.activate([
            dictationTopBar.leadingAnchor.constraint(equalTo: dictationPanel.leadingAnchor, constant: 12),
            dictationTopBar.trailingAnchor.constraint(equalTo: dictationPanel.trailingAnchor, constant: -12),
            dictationTopBar.topAnchor.constraint(equalTo: dictationPanel.topAnchor, constant: 10),

            dictationCenterStack.leadingAnchor.constraint(equalTo: dictationPanel.leadingAnchor, constant: 20),
            dictationCenterStack.trailingAnchor.constraint(equalTo: dictationPanel.trailingAnchor, constant: -20),
            dictationCenterStack.centerYAnchor.constraint(equalTo: dictationPanel.centerYAnchor, constant: 4)
        ])
    }

    private func configureAccessoryBar() {
        accessoryBar.axis = .horizontal
        accessoryBar.spacing = currentMetrics.stackSpacing
        accessoryBar.distribution = .fillEqually

        configureAccessoryButton(insertLatestButton, title: "Insert Latest")
        insertLatestButton.addTarget(self, action: #selector(insertLatestTapped), for: .touchUpInside)

        configureMicAccessoryButton(accessoryMicButton)
        accessoryMicButton.addTarget(self, action: #selector(dictateTapped), for: .touchUpInside)

        accessoryBar.addArrangedSubview(insertLatestButton)
        accessoryBar.addArrangedSubview(accessoryMicButton)
        setHeight(currentMetrics.accessoryHeight, for: insertLatestButton)
        setHeight(currentMetrics.accessoryHeight, for: accessoryMicButton)
        typingContainer.addArrangedSubview(accessoryBar)
    }

    private func configureKeyboardArea() {
        keyboardStack.axis = .vertical
        keyboardStack.spacing = currentMetrics.stackSpacing
        keyboardStack.setContentCompressionResistancePriority(.required, for: .vertical)
        keyboardStack.setContentHuggingPriority(.required, for: .vertical)
        typingContainer.addArrangedSubview(keyboardStack)
        rebuildKeyboardRows()
    }

    private func renderDictationState() {
        switch dictationState {
        case .typing:
            typingContainer.isHidden = false
            dictationPanel.isHidden = true
            stopWaveAnimation()
            stopTranscriptPolling()
            statusLabel.text = "Tap mic above the keyboard to listen, then confirm to insert."
        case .dictationWaiting:
            typingContainer.isHidden = true
            dictationPanel.isHidden = false
            dictationStateLabel.text = "Listening"
            dictationHintLabel.text = "Speak in WhisperSmart, then return here. Latest transcript appears automatically."
            confirmDictationButton.isEnabled = false
            confirmDictationButton.alpha = 0.45
            startWaveAnimation()
        case .dictationReady(let transcript, _):
            typingContainer.isHidden = true
            dictationPanel.isHidden = false
            dictationStateLabel.text = "Ready"
            dictationHintLabel.text = "Tap ✓ to insert: \(String(transcript.prefix(72)))"
            confirmDictationButton.isEnabled = true
            confirmDictationButton.alpha = 1.0
            startWaveAnimation()
        }

        updatePreferredContentSizeIfNeeded()
    }

    private func rebuildKeyboardRows() {
        keyboardStack.arrangedSubviews.forEach {
            keyboardStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let rows = KeyboardLayoutHelper.rows(for: layoutMode, isShiftEnabled: isShiftEnabled)

        keyboardStack.addArrangedSubview(makeLetterRow(letters: rows[0], leadingInset: 0, trailingInset: 0))
        keyboardStack.addArrangedSubview(makeLetterRow(letters: rows[1], leadingInset: 10, trailingInset: 10))

        let thirdRow = UIStackView()
        thirdRow.axis = .horizontal
        thirdRow.spacing = currentMetrics.stackSpacing
        thirdRow.alignment = .fill
        thirdRow.heightAnchor.constraint(greaterThanOrEqualToConstant: currentMetrics.rowMinimumHeight).isActive = true

        styleModifierKey(shiftButton, title: layoutMode == .letters ? (isShiftEnabled ? "⇪" : "⇧") : "#+=")
        setWidth(42, for: shiftButton)
        shiftButton.removeTarget(nil, action: nil, for: .allEvents)
        shiftButton.addTarget(self, action: #selector(shiftTapped), for: .touchUpInside)
        thirdRow.addArrangedSubview(shiftButton)

        let thirdLettersRow = UIStackView()
        thirdLettersRow.axis = .horizontal
        thirdLettersRow.spacing = currentMetrics.stackSpacing
        thirdLettersRow.alignment = .fill
        thirdLettersRow.distribution = .fillEqually
        for key in rows[2] {
            thirdLettersRow.addArrangedSubview(makeLetterKey(key))
        }
        thirdRow.addArrangedSubview(thirdLettersRow)

        styleModifierKey(backspaceButton, title: "⌫")
        setWidth(42, for: backspaceButton)
        backspaceButton.removeTarget(nil, action: nil, for: .allEvents)
        backspaceButton.addTarget(self, action: #selector(backspaceTapped), for: .touchUpInside)
        thirdRow.addArrangedSubview(backspaceButton)

        keyboardStack.addArrangedSubview(thirdRow)

        let bottomRow = UIStackView()
        bottomRow.axis = .horizontal
        bottomRow.spacing = currentMetrics.stackSpacing
        bottomRow.heightAnchor.constraint(greaterThanOrEqualToConstant: currentMetrics.rowMinimumHeight).isActive = true

        styleModifierKey(modeToggleButton, title: layoutMode == .letters ? "123" : "ABC")
        setWidth(52, for: modeToggleButton)
        modeToggleButton.removeTarget(nil, action: nil, for: .allEvents)
        modeToggleButton.addTarget(self, action: #selector(modeToggleTapped), for: .touchUpInside)

        styleModifierKey(nextKeyboardButton, title: "🌐")
        setWidth(42, for: nextKeyboardButton)
        nextKeyboardButton.removeTarget(nil, action: nil, for: .allEvents)
        nextKeyboardButton.addTarget(self, action: #selector(nextKeyboardTapped), for: .touchUpInside)
        nextKeyboardButton.isHidden = !needsInputModeSwitchKey

        styleKey(spaceButton, title: "space")
        spaceButton.removeTarget(nil, action: nil, for: .allEvents)
        spaceButton.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)

        styleReturnKey(returnButton)
        returnButton.removeTarget(nil, action: nil, for: .allEvents)
        returnButton.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)

        bottomRow.addArrangedSubview(modeToggleButton)
        if needsInputModeSwitchKey {
            bottomRow.addArrangedSubview(nextKeyboardButton)
        }
        bottomRow.addArrangedSubview(spaceButton)
        bottomRow.addArrangedSubview(returnButton)
        keyboardStack.addArrangedSubview(bottomRow)

        applyCurrentTheme()
    }

    private func makeLetterRow(letters: [String], leadingInset: CGFloat, trailingInset: CGFloat) -> UIView {
        let rowStack = UIStackView()
        rowStack.axis = .horizontal
        rowStack.spacing = currentMetrics.stackSpacing
        rowStack.alignment = .fill

        if leadingInset > 0 {
            let spacer = UIView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.widthAnchor.constraint(equalToConstant: leadingInset).isActive = true
            rowStack.addArrangedSubview(spacer)
        }

        let lettersStack = UIStackView()
        lettersStack.axis = .horizontal
        lettersStack.spacing = currentMetrics.stackSpacing
        lettersStack.alignment = .fill
        lettersStack.distribution = .fillEqually
        for letter in letters {
            lettersStack.addArrangedSubview(makeLetterKey(letter))
        }
        rowStack.addArrangedSubview(lettersStack)

        if trailingInset > 0 {
            let spacer = UIView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.widthAnchor.constraint(equalToConstant: trailingInset).isActive = true
            rowStack.addArrangedSubview(spacer)
        }

        rowStack.heightAnchor.constraint(greaterThanOrEqualToConstant: currentMetrics.rowMinimumHeight).isActive = true
        return rowStack
    }

    private func makeLetterKey(_ letter: String) -> UIButton {
        let button = UIButton(type: .system)
        styleKey(button, title: letter)
        button.addTarget(self, action: #selector(letterTapped(_:)), for: .touchUpInside)
        return button
    }

    private func styleKey(_ button: UIButton, title: String) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(.label, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 22, weight: .regular)
        button.backgroundColor = keyColor
        button.layer.cornerRadius = 5
        button.layer.cornerCurve = .continuous
        button.layer.shadowColor = UIColor.black.withAlphaComponent(isDark ? 0.45 : 0.16).cgColor
        button.layer.shadowOpacity = 1
        button.layer.shadowRadius = 0.0
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.layer.borderWidth = isDark ? 0.5 : 0.35
        button.layer.borderColor = UIColor.black.withAlphaComponent(isDark ? 0.4 : 0.18).cgColor
        button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 6, bottom: 10, right: 6)
        setHeight(currentMetrics.keyHeight, for: button)
        applyPressBehavior(to: button, isAccent: false)
    }

    private func styleModifierKey(_ button: UIButton, title: String) {
        styleKey(button, title: title)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.backgroundColor = modifierKeyColor
    }

    private func styleReturnKey(_ button: UIButton) {
        let title = returnKeyTitle()
        styleModifierKey(button, title: title)
        let accent = shouldAccentReturnKey()
        button.backgroundColor = accent ? accentKeyColor : modifierKeyColor
        button.setTitleColor(accent ? .white : .label, for: .normal)
        setWidth(accent ? 76 : 68, for: button)
        applyPressBehavior(to: button, isAccent: accent)
    }

    private func stylePanelControl(_ button: UIButton, symbolName: String) {
        button.setImage(UIImage(systemName: symbolName), for: .normal)
        button.tintColor = .label
        button.backgroundColor = modifierKeyColor.withAlphaComponent(0.8)
        button.layer.cornerRadius = 16
        button.layer.cornerCurve = .continuous
        button.layer.borderWidth = 0.5
        button.layer.borderColor = UIColor.black.withAlphaComponent(isDark ? 0.35 : 0.15).cgColor
        button.translatesAutoresizingMaskIntoConstraints = false
        setWidth(32, for: button)
        setHeight(min(32, currentMetrics.keyHeight), for: button)
    }

    private func configureAccessoryButton(_ button: UIButton, title: String) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(.secondaryLabel, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        button.backgroundColor = modifierKeyColor.withAlphaComponent(0.88)
        button.layer.cornerRadius = 13
        button.layer.cornerCurve = .continuous
        button.layer.borderWidth = 0.5
        button.layer.borderColor = UIColor.black.withAlphaComponent(isDark ? 0.35 : 0.14).cgColor
        applyPressBehavior(to: button, isAccent: false)
    }

    private func configureMicAccessoryButton(_ button: UIButton) {
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "mic.fill")
        config.imagePlacement = .leading
        config.imagePadding = 6
        config.baseForegroundColor = .secondaryLabel
        config.baseBackgroundColor = modifierKeyColor.withAlphaComponent(0.9)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
        config.title = "Mic"
        button.configuration = config
        applyPressBehavior(to: button, isAccent: false)
    }

    private func applyCurrentTheme() {
        backgroundView.effect = UIBlurEffect(style: isDark ? .systemThinMaterialDark : .systemThinMaterialLight)

        dictationPanel.backgroundColor = isDark ? UIColor(red: 0.16, green: 0.17, blue: 0.2, alpha: 0.92) : UIColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 0.92)
        dictationPanel.layer.borderColor = UIColor.separator.withAlphaComponent(0.45).cgColor
        dictationStateLabel.textColor = .label
        dictationHintLabel.textColor = .secondaryLabel
        waveformStack.arrangedSubviews.forEach { $0.backgroundColor = accentKeyColor.withAlphaComponent(0.88) }

        [insertLatestButton, accessoryMicButton, modeToggleButton, nextKeyboardButton, shiftButton, backspaceButton].forEach {
            $0.layer.borderColor = UIColor.black.withAlphaComponent(isDark ? 0.36 : 0.14).cgColor
        }

        keyboardStack.arrangedSubviews
            .flatMap { ($0 as? UIStackView)?.arrangedSubviews ?? [] }
            .compactMap { $0 as? UIButton }
            .forEach { btn in
                if btn === returnButton {
                    styleReturnKey(btn)
                } else if btn === shiftButton || btn === backspaceButton || btn === modeToggleButton || btn === nextKeyboardButton {
                    styleModifierKey(btn, title: btn.currentTitle ?? "")
                } else if btn === spaceButton {
                    styleKey(btn, title: "space")
                } else {
                    styleKey(btn, title: btn.currentTitle ?? "")
                }
            }

        stylePanelControl(cancelDictationButton, symbolName: "xmark")
        stylePanelControl(confirmDictationButton, symbolName: "checkmark")
        configureAccessoryButton(insertLatestButton, title: "Insert Latest")
        configureMicAccessoryButton(accessoryMicButton)
    }

    private func applyPressBehavior(to button: UIButton, isAccent: Bool) {
        button.configurationUpdateHandler = { [weak self] btn in
            guard let self else { return }
            let activeColor: UIColor
            if isAccent {
                activeColor = btn.isHighlighted ? self.accentKeyPressedColor : self.accentKeyColor
            } else {
                let base = btn.backgroundColor ?? self.keyColor
                activeColor = btn.isHighlighted ? self.pressedVariant(for: base) : base
            }
            btn.backgroundColor = activeColor
        }
    }

    private func pressedVariant(for color: UIColor) -> UIColor {
        return isDark ? color.withAlphaComponent(0.78) : color.withAlphaComponent(0.86)
    }

    private func setWidth(_ value: CGFloat, for view: UIView) {
        view.constraints
            .filter { $0.firstAttribute == .width && $0.secondItem == nil }
            .forEach { $0.isActive = false }
        view.widthAnchor.constraint(equalToConstant: value).isActive = true
    }

    private func setHeight(_ value: CGFloat, for view: UIView) {
        view.constraints
            .filter { $0.firstAttribute == .height && $0.secondItem == nil }
            .forEach { $0.isActive = false }
        view.heightAnchor.constraint(equalToConstant: value).isActive = true
    }

    private func reloadData() {
        let latest = store.latestTranscript
        insertLatestButton.isEnabled = latest != nil
        insertLatestButton.alpha = latest == nil ? 0.6 : 1.0

        accessoryMicButton.isEnabled = true
        accessoryMicButton.alpha = 1.0

        styleReturnKey(returnButton)
    }

    @objc private func dictateTapped() {
        UIDevice.current.playInputClick()
        listeningBaselineTimestamp = store.lastUpdatedAt
        dictationState = KeyboardMicFlowStateMachine.reduce(state: dictationState, event: .micTapped(now: Date()))
        startTranscriptPolling()

        if !hasFullAccess {
            dictationHintLabel.text = "Enable Allow Full Access for WhisperSmart Keyboard, then tap mic again."
            statusLabel.text = "Full Access is required for keyboard-to-app handoff and shared snippets."
            return
        }

        openContainingAppForDictation { [weak self] opened in
            guard let self else { return }
            if opened {
                self.statusLabel.text = "Opened WhisperSmart. Speak in app, then return here to insert."
            } else {
                self.dictationHintLabel.text = "Couldn’t launch WhisperSmart. Open app manually, dictate, then return."
                self.statusLabel.text = "If launch fails, open WhisperSmart manually and tap ✓ after dictation."
            }
        }
    }

    @objc private func cancelDictationTapped() {
        UIDevice.current.playInputClick()
        dictationState = KeyboardMicFlowStateMachine.reduce(state: dictationState, event: .cancel)
    }

    @objc private func confirmDictationTapped() {
        UIDevice.current.playInputClick()
        guard case .dictationReady(let transcript, _) = dictationState else { return }
        textDocumentProxy.insertText(transcript)
        reloadData()
        dictationState = KeyboardMicFlowStateMachine.reduce(state: dictationState, event: .confirm)
        statusLabel.text = "Inserted latest dictation."
    }

    @objc private func modeToggleTapped() {
        UIDevice.current.playInputClick()
        layoutMode = layoutMode == .letters ? .numbersAndSymbols : .letters
    }

    @objc private func nextKeyboardTapped() {
        UIDevice.current.playInputClick()
        advanceToNextInputMode()
    }

    @objc private func insertLatestTapped() {
        UIDevice.current.playInputClick()
        guard let text = store.latestTranscript else {
            statusLabel.text = "No saved dictation yet. Tap Mic above the keyboard first."
            reloadData()
            return
        }
        textDocumentProxy.insertText(text)
        statusLabel.text = "Inserted latest dictation."
    }

    @objc private func letterTapped(_ sender: UIButton) {
        UIDevice.current.playInputClick()
        guard let key = sender.currentTitle else { return }
        textDocumentProxy.insertText(key)
        if layoutMode == .letters, isShiftEnabled {
            isShiftEnabled = false
        }
    }

    @objc private func shiftTapped() {
        UIDevice.current.playInputClick()
        if layoutMode == .letters {
            isShiftEnabled.toggle()
        }
    }

    @objc private func backspaceTapped() {
        UIDevice.current.playInputClick()
        textDocumentProxy.deleteBackward()
    }

    @objc private func spaceTapped() {
        UIDevice.current.playInputClick()
        textDocumentProxy.insertText(" ")
    }

    @objc private func returnTapped() {
        UIDevice.current.playInputClick()
        textDocumentProxy.insertText("\n")
    }

    private func startTranscriptPolling() {
        stopTranscriptPolling()
        transcriptPollTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.pollForTranscriptUpdate()
        }
    }

    private func stopTranscriptPolling() {
        transcriptPollTimer?.invalidate()
        transcriptPollTimer = nil
    }

    private func pollForTranscriptUpdate() {
        guard case .dictationWaiting = dictationState else { return }
        guard let transcript = store.latestTranscript, !transcript.isEmpty else { return }
        guard let updatedAt = store.lastUpdatedAt else { return }

        if let baseline = listeningBaselineTimestamp, updatedAt <= baseline {
            return
        }

        dictationState = KeyboardMicFlowStateMachine.reduce(
            state: dictationState,
            event: .transcriptAvailable(text: transcript, updatedAt: updatedAt)
        )
        reloadData()
    }

    private func startWaveAnimation() {
        for (index, bar) in waveformStack.arrangedSubviews.enumerated() {
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = 0.55
            animation.toValue = 1.35
            animation.autoreverses = true
            animation.duration = 0.45 + (Double(index % 4) * 0.08)
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.layer.add(animation, forKey: "wave")
        }
    }

    private func stopWaveAnimation() {
        waveformStack.arrangedSubviews.forEach { $0.layer.removeAnimation(forKey: "wave") }
    }

    private func openContainingAppForDictation(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "whispersmart://dictate") else {
            completion(false)
            return
        }

        guard let extensionContext else {
            completion(openViaResponderChain(url: url))
            return
        }

        extensionContext.open(url, completionHandler: { [weak self] success in
            guard let self else {
                completion(success)
                return
            }

            if success {
                completion(true)
                return
            }

            completion(self.openViaResponderChain(url: url))
        })
    }

    private func openViaResponderChain(url: URL) -> Bool {
        let selector = sel_registerName("openURL:")

        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector) {
                _ = current.perform(selector, with: url)
                return true
            }
            responder = current.next
        }
        return false
    }

    private func updatePreferredContentSizeIfNeeded() {
        let isCompactLandscape = traitCollection.verticalSizeClass == .compact
        let availableHeight = max(180, view.bounds.height - (Layout.verticalInset * 2))
        let previousMetrics = currentMetrics
        currentMetrics = KeyboardLayoutMetrics.resolve(availableHeight: availableHeight, isCompactLandscape: isCompactLandscape)

        rootStack.spacing = currentMetrics.stackSpacing
        typingContainer.spacing = currentMetrics.stackSpacing
        accessoryBar.spacing = currentMetrics.stackSpacing
        keyboardStack.spacing = currentMetrics.stackSpacing

        statusLabel.isHidden = (!currentMetrics.showsStatusLabel) && !typingContainer.isHidden
        dictationPanelHeightConstraint?.constant = currentMetrics.dictationPanelHeight

        setHeight(currentMetrics.accessoryHeight, for: insertLatestButton)
        setHeight(currentMetrics.accessoryHeight, for: accessoryMicButton)

        if previousMetrics != currentMetrics {
            rebuildKeyboardRows()
        }

        let preferredHeight: CGFloat
        switch dictationState {
        case .typing:
            preferredHeight = currentMetrics.preferredTypingHeight
        case .dictationWaiting, .dictationReady:
            preferredHeight = currentMetrics.preferredDictationHeight
        }

        if inputViewHeightConstraint == nil {
            inputViewHeightConstraint = view.heightAnchor.constraint(equalToConstant: preferredHeight)
            inputViewHeightConstraint?.priority = .required
            inputViewHeightConstraint?.isActive = true
        } else {
            inputViewHeightConstraint?.constant = preferredHeight
        }

        let size = CGSize(width: view.bounds.width, height: preferredHeight)
        if preferredContentSize != size {
            preferredContentSize = size
        }

        keyboardStack.arrangedSubviews
            .flatMap { ($0 as? UIStackView)?.arrangedSubviews ?? [] }
            .compactMap { $0 as? UIButton }
            .forEach { setHeight(currentMetrics.keyHeight, for: $0) }
    }

    private var isDark: Bool {
        traitCollection.userInterfaceStyle == .dark
    }

    private var keyColor: UIColor {
        isDark ? UIColor(red: 0.35, green: 0.36, blue: 0.39, alpha: 1) : UIColor(white: 1.0, alpha: 0.92)
    }

    private var modifierKeyColor: UIColor {
        isDark ? UIColor(red: 0.27, green: 0.28, blue: 0.31, alpha: 1) : UIColor(red: 0.69, green: 0.72, blue: 0.76, alpha: 1)
    }

    private var accentKeyColor: UIColor {
        isDark ? UIColor(red: 0.23, green: 0.51, blue: 0.97, alpha: 1) : UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1)
    }

    private var accentKeyPressedColor: UIColor {
        accentKeyColor.withAlphaComponent(0.82)
    }

    private func returnKeyTitle() -> String {
        let traits = textDocumentProxy
        switch traits.returnKeyType {
        case .go: return "go"
        case .google: return "google"
        case .join: return "join"
        case .next: return "next"
        case .route: return "route"
        case .search: return "search"
        case .send: return "send"
        case .yahoo: return "yahoo"
        case .done: return "done"
        case .emergencyCall: return "SOS"
        default: return "return"
        }
    }

    private func shouldAccentReturnKey() -> Bool {
        switch textDocumentProxy.returnKeyType {
        case .go, .search, .send, .done, .join, .next, .route, .google, .yahoo:
            return true
        default:
            return false
        }
    }
}
