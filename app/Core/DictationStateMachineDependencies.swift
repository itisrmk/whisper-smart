import AVFoundation
import CoreGraphics

protocol HotkeyMonitoring: AnyObject {
    var onHoldStarted: (() -> Void)? { get set }
    var onHoldEnded: (() -> Void)? { get set }
    var onStartFailed: ((HotkeyMonitorError) -> Void)? { get set }
    var isRunning: Bool { get }
    func start()
    func stop()
}

protocol AudioCapturing: AnyObject {
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    var onAudioLevel: ((Float) -> Void)? { get set }
    var onInterruption: ((AudioCaptureService.InterruptionReason) -> Void)? { get set }
    var inputDeviceUID: String? { get set }
    func start() throws
    func stop()
}

protocol TextInjecting: AnyObject {
    func inject(text: String)
}

extension HotkeyMonitor: HotkeyMonitoring {}
extension AudioCaptureService: AudioCapturing {}
extension ClipboardInjector: TextInjecting {}
