import UIKit

final class KeyboardViewController: UIInputViewController {
    private let store = KeyboardCompanionStore.shared

    private let rootStack = UIStackView()
    private let typingContainer = UIStackView()
    private let accessoryBar = UIStackView()
    private let keyboardStack = UIStackView()
    private let statusLabel = UILabel()

    private let dictationPanel = UIView()
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

    private let keyBackground = UIColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1)
    private let modifierBackground = UIColor(red: 0.84, green: 0.85, blue: 0.88, alpha: 1)
    private let keyboardBackground = UIColor(red: 0.81, green: 0.82, blue: 0.85, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        reloadData()
        renderDictationState()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        preferredContentSize = CGSize(width: view.bounds.width, height: 300)
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        reloadData()
    }

    deinit {
        stopTranscriptPolling()
    }

    private func setupUI() {
        view.backgroundColor = keyboardBackground

        rootStack.axis = .vertical
        rootStack.spacing = 8
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])

        configureTypingContainer()
        configureDictationPanel()

        rootStack.addArrangedSubview(typingContainer)
        rootStack.addArrangedSubview(dictationPanel)
    }

    private func configureTypingContainer() {
        typingContainer.axis = .vertical
        typingContainer.spacing = 8

        configureAccessoryBar()
        configureKeyboardArea()

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = UIColor.black.withAlphaComponent(0.58)
        statusLabel.numberOfLines = 2
        statusLabel.textAlignment = .center
        statusLabel.text = "Tap the mic button above the keyboard to open listening, then confirm when your transcript is ready."
        typingContainer.addArrangedSubview(statusLabel)
    }

    private func configureDictationPanel() {
        dictationPanel.backgroundColor = UIColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1)
        dictationPanel.layer.cornerRadius = 16
        dictationPanel.translatesAutoresizingMaskIntoConstraints = false
        dictationPanel.heightAnchor.constraint(equalToConstant: 224).isActive = true

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
        dictationStateLabel.textColor = .white
        dictationStateLabel.text = "Listening"

        waveformStack.axis = .horizontal
        waveformStack.spacing = 6
        waveformStack.alignment = .bottom
        waveformStack.translatesAutoresizingMaskIntoConstraints = false
        for index in 0..<7 {
            let bar = UIView()
            bar.backgroundColor = UIColor.white.withAlphaComponent(0.92)
            bar.layer.cornerRadius = 2
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 5).isActive = true
            let baseHeight = CGFloat(14 + (index % 3) * 6)
            bar.heightAnchor.constraint(equalToConstant: baseHeight).isActive = true
            waveformStack.addArrangedSubview(bar)
        }

        dictationHintLabel.font = .systemFont(ofSize: 13, weight: .regular)
        dictationHintLabel.textColor = UIColor.white.withAlphaComponent(0.74)
        dictationHintLabel.numberOfLines = 2
        dictationHintLabel.textAlignment = .center

        dictationCenterStack.addArrangedSubview(dictationStateLabel)
        dictationCenterStack.addArrangedSubview(waveformStack)
        dictationCenterStack.addArrangedSubview(dictationHintLabel)

        dictationPanel.addSubview(dictationTopBar)
        dictationPanel.addSubview(dictationCenterStack)

        NSLayoutConstraint.activate([
            dictationTopBar.leadingAnchor.constraint(equalTo: dictationPanel.leadingAnchor, constant: 14),
            dictationTopBar.trailingAnchor.constraint(equalTo: dictationPanel.trailingAnchor, constant: -14),
            dictationTopBar.topAnchor.constraint(equalTo: dictationPanel.topAnchor, constant: 12),

            dictationCenterStack.leadingAnchor.constraint(equalTo: dictationPanel.leadingAnchor, constant: 20),
            dictationCenterStack.trailingAnchor.constraint(equalTo: dictationPanel.trailingAnchor, constant: -20),
            dictationCenterStack.centerYAnchor.constraint(equalTo: dictationPanel.centerYAnchor, constant: 6)
        ])
    }

    private func configureAccessoryBar() {
        accessoryBar.axis = .horizontal
        accessoryBar.spacing = 6
        accessoryBar.distribution = .fillProportionally

        configureAccessoryButton(insertLatestButton, title: "Insert Latest")
        insertLatestButton.addTarget(self, action: #selector(insertLatestTapped), for: .touchUpInside)

        configureMicAccessoryButton(accessoryMicButton)
        accessoryMicButton.addTarget(self, action: #selector(dictateTapped), for: .touchUpInside)

        accessoryBar.addArrangedSubview(insertLatestButton)
        accessoryBar.addArrangedSubview(accessoryMicButton)
        typingContainer.addArrangedSubview(accessoryBar)
    }

    private func configureKeyboardArea() {
        keyboardStack.axis = .vertical
        keyboardStack.spacing = 6
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
            statusLabel.text = "Tap the mic button above the keyboard to open listening, then confirm when your transcript is ready."
        case .dictationWaiting:
            typingContainer.isHidden = true
            dictationPanel.isHidden = false
            dictationStateLabel.text = "Listening"
            dictationHintLabel.text = "WhisperSmart app captures audio. Speak there, then return here to insert; latest transcript auto-detects."
            confirmDictationButton.isEnabled = false
            confirmDictationButton.alpha = 0.4
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
    }

    private func rebuildKeyboardRows() {
        keyboardStack.arrangedSubviews.forEach {
            keyboardStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let rows = KeyboardLayoutHelper.rows(for: layoutMode, isShiftEnabled: isShiftEnabled)

        keyboardStack.addArrangedSubview(makeLetterRow(letters: rows[0], leadingInset: 0, trailingInset: 0))
        keyboardStack.addArrangedSubview(makeLetterRow(letters: rows[1], leadingInset: 12, trailingInset: 12))

        let thirdRow = UIStackView()
        thirdRow.axis = .horizontal
        thirdRow.spacing = 6

        styleModifierKey(shiftButton, title: layoutMode == .letters ? (isShiftEnabled ? "⇪" : "⇧") : "#+=")
        shiftButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        shiftButton.removeTarget(nil, action: nil, for: .allEvents)
        shiftButton.addTarget(self, action: #selector(shiftTapped), for: .touchUpInside)
        thirdRow.addArrangedSubview(shiftButton)

        for key in rows[2] {
            thirdRow.addArrangedSubview(makeLetterKey(key))
        }

        styleModifierKey(backspaceButton, title: "⌫")
        backspaceButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        backspaceButton.removeTarget(nil, action: nil, for: .allEvents)
        backspaceButton.addTarget(self, action: #selector(backspaceTapped), for: .touchUpInside)
        thirdRow.addArrangedSubview(backspaceButton)

        keyboardStack.addArrangedSubview(thirdRow)

        let bottomRow = UIStackView()
        bottomRow.axis = .horizontal
        bottomRow.spacing = 6

        styleModifierKey(modeToggleButton, title: layoutMode == .letters ? "123" : "ABC")
        modeToggleButton.widthAnchor.constraint(equalToConstant: 54).isActive = true
        modeToggleButton.removeTarget(nil, action: nil, for: .allEvents)
        modeToggleButton.addTarget(self, action: #selector(modeToggleTapped), for: .touchUpInside)

        styleKey(spaceButton, title: "space")
        spaceButton.removeTarget(nil, action: nil, for: .allEvents)
        spaceButton.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)

        styleModifierKey(returnButton, title: "return")
        returnButton.widthAnchor.constraint(equalToConstant: 68).isActive = true
        returnButton.removeTarget(nil, action: nil, for: .allEvents)
        returnButton.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)

        bottomRow.addArrangedSubview(modeToggleButton)
        bottomRow.addArrangedSubview(spaceButton)
        bottomRow.addArrangedSubview(returnButton)
        keyboardStack.addArrangedSubview(bottomRow)
    }

    private func makeLetterRow(letters: [String], leadingInset: CGFloat, trailingInset: CGFloat) -> UIView {
        let rowStack = UIStackView()
        rowStack.axis = .horizontal
        rowStack.spacing = 6

        if leadingInset > 0 {
            let spacer = UIView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.widthAnchor.constraint(equalToConstant: leadingInset).isActive = true
            rowStack.addArrangedSubview(spacer)
        }

        for letter in letters {
            rowStack.addArrangedSubview(makeLetterKey(letter))
        }

        if trailingInset > 0 {
            let spacer = UIView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.widthAnchor.constraint(equalToConstant: trailingInset).isActive = true
            rowStack.addArrangedSubview(spacer)
        }

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
        button.setTitleColor(.black, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 20, weight: .regular)
        button.backgroundColor = keyBackground
        button.layer.cornerRadius = 6
        button.layer.shadowColor = UIColor.black.withAlphaComponent(0.22).cgColor
        button.layer.shadowOpacity = 0.18
        button.layer.shadowRadius = 0.5
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 6, bottom: 10, right: 6)
    }

    private func styleModifierKey(_ button: UIButton, title: String) {
        styleKey(button, title: title)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.backgroundColor = modifierBackground
    }

    private func stylePanelControl(_ button: UIButton, symbolName: String) {
        button.setImage(UIImage(systemName: symbolName), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        button.layer.cornerRadius = 16
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
    }

    private func configureAccessoryButton(_ button: UIButton, title: String) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(.black.withAlphaComponent(0.82), for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        button.backgroundColor = UIColor.white.withAlphaComponent(0.66)
        button.layer.cornerRadius = 14
        button.contentEdgeInsets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
    }

    private func configureMicAccessoryButton(_ button: UIButton) {
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "mic.fill")
        config.imagePlacement = .leading
        config.imagePadding = 6
        config.baseForegroundColor = UIColor.black.withAlphaComponent(0.82)
        config.baseBackgroundColor = UIColor.white.withAlphaComponent(0.66)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
        config.title = "Mic"
        button.configuration = config
    }

    private func reloadData() {
        let latest = store.latestTranscript
        insertLatestButton.isEnabled = latest != nil
        insertLatestButton.alpha = latest == nil ? 0.55 : 1.0

        accessoryMicButton.isEnabled = true
        accessoryMicButton.alpha = 1.0
    }

    @objc private func dictateTapped() {
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
                self.dictationHintLabel.text = "Couldn’t launch WhisperSmart. Open the app manually, dictate, then return to insert."
                self.statusLabel.text = "If launch fails, open WhisperSmart manually and come back to tap ✓."
            }
        }
    }

    @objc private func cancelDictationTapped() {
        dictationState = KeyboardMicFlowStateMachine.reduce(state: dictationState, event: .cancel)
    }

    @objc private func confirmDictationTapped() {
        guard case .dictationReady(let transcript, _) = dictationState else { return }
        textDocumentProxy.insertText(transcript)
        reloadData()
        dictationState = KeyboardMicFlowStateMachine.reduce(state: dictationState, event: .confirm)
        statusLabel.text = "Inserted latest dictation."
    }

    @objc private func modeToggleTapped() {
        layoutMode = layoutMode == .letters ? .numbersAndSymbols : .letters
    }

    @objc private func insertLatestTapped() {
        guard let text = store.latestTranscript else {
            statusLabel.text = "No saved dictation yet. Tap Mic above the keyboard to open listening mode first."
            reloadData()
            return
        }
        textDocumentProxy.insertText(text)
        statusLabel.text = "Inserted latest dictation."
    }

    @objc private func letterTapped(_ sender: UIButton) {
        guard let key = sender.currentTitle else { return }
        textDocumentProxy.insertText(key)
        if layoutMode == .letters, isShiftEnabled {
            isShiftEnabled = false
        }
    }

    @objc private func shiftTapped() {
        if layoutMode == .letters {
            isShiftEnabled.toggle()
        }
    }

    @objc private func backspaceTapped() {
        textDocumentProxy.deleteBackward()
    }

    @objc private func spaceTapped() {
        textDocumentProxy.insertText(" ")
    }

    @objc private func returnTapped() {
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
}
