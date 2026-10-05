import AVFoundation

/// Says a word out loud with the system's American English voice.
@MainActor
enum Speaker {
    private static let synthesizer = AVSpeechSynthesizer()

    static func say(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        synthesizer.speak(utterance)
    }
}
