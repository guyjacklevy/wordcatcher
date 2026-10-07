import SwiftUI

// Colors from the mockups.
extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    static let ink = Color(hex: 0x15171C)
    static let body = Color(hex: 0x2A2E36)
    static let muted = Color(hex: 0x5B606B)
    static let line = Color(hex: 0xECEEF2)
    static let chipBorder = Color(hex: 0xC5CCD7)
    static let footer = Color(hex: 0xF4F6F9)
    static let brand = Color(hex: 0x2346D1)
    static let marker = Color(hex: 0xFFE066)
    static let markerBorder = Color(hex: 0xC9A400)
    static let saved = Color(hex: 0x1E7A46)
}

struct PopupView: View {
    @ObservedObject var model: PopupModel

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .idle: EmptyView()
            case .loading: LoadingCard(model: model)
            case .picker: PickerCard(model: model)
            case .results:
                if model.rows.count == 1 {
                    SingleResultCard(model: model, row: model.rows[0])
                } else {
                    MultiResultCard(model: model)
                }
            case .compose: ComposeCard(model: model)
            case .error: ErrorCard(model: model)
            }
        }
        .frame(width: 360)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.black.opacity(0.08), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.22), radius: 20, x: 0, y: 12)
        .padding(EdgeInsets(top: 8, leading: 28, bottom: 40, trailing: 28))
        .environment(\.colorScheme, .light)
    }
}

// MARK: - Pieces

private struct RoundIconButton: View {
    let systemName: String
    let label: String
    var bordered = true
    var size: CGFloat = 32
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundColor(bordered ? .brand : .muted)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white))
                .overlay(Circle().stroke(bordered ? Color(hex: 0xDDE1E7) : .clear, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .kerning(0.6)
            .foregroundColor(.muted)
    }
}

private struct LinkButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.brand)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
    }
}

private struct SavedFooter: View {
    @ObservedObject var model: PopupModel
    let note: String

    var body: some View {
        HStack(spacing: 8) {
            if model.isSaved {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.saved)
                Text(note)
                    .font(.system(size: 12.5))
                    .foregroundColor(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if model.canChangeWords {
                    LinkButton(title: "Change words") { model.onChangeWords() }
                }
                LinkButton(title: "Undo") { model.onToggleSaved() }
            } else {
                Text("Removed. It's not in your words.")
                    .font(.system(size: 12.5))
                    .foregroundColor(.muted)
                Spacer(minLength: 4)
                LinkButton(title: "Save it") { model.onToggleSaved() }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(minHeight: 46)
        .background(Color.footer)
        .overlay(Rectangle().fill(Color.line).frame(height: 1), alignment: .top)
    }
}

// MARK: - Cards

private struct LoadingCard: View {
    @ObservedObject var model: PopupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.marked.joined(separator: " · "))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.ink)
                    .lineLimit(2)
                Spacer()
                RoundIconButton(systemName: "xmark", label: "Close", bordered: false, size: 28) { model.onClose() }
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.loadingText)
                    .font(.system(size: 13))
                    .foregroundColor(.muted)
            }
            if model.writing {
                EmptyView()
            } else if let sentence = model.sentence {
                Text(sentence)
                    .font(.system(size: 13, design: .serif).italic())
                    .foregroundColor(.muted)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Tip: in this app, select the whole sentence for a better meaning.")
                    .font(.system(size: 12))
                    .foregroundColor(.muted)
            }
        }
        .padding(18)
    }
}

private struct SingleResultCard: View {
    @ObservedObject var model: PopupModel
    let row: ResultRow

    private var info: WordInfo { row.info }
    private var formNote: String? {
        let marked = info.marked.trimmed
        guard marked.lowercased() != info.lemma.lowercased() else { return nil }
        return "You marked “\(marked)” · saved as “\(info.lemma)”"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(info.lemma)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.ink)
                            Text(info.partOfSpeech)
                                .font(.system(size: 13))
                                .foregroundColor(.muted)
                        }
                        Text(info.ipa)
                            .font(.system(size: 13))
                            .foregroundColor(.muted)
                    }
                    Spacer()
                    RoundIconButton(systemName: "speaker.wave.2", label: "Play pronunciation") { Speaker.say(info.lemma) }
                    RoundIconButton(systemName: "xmark", label: "Close", bordered: false) { model.onClose() }
                }
                if let formNote {
                    Text(formNote)
                        .font(.system(size: 12))
                        .foregroundColor(.muted)
                        .padding(.top, -4)
                }
                Text(info.hebrew)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.ink)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .environment(\.locale, Locale(identifier: "he"))
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: model.sentence == nil ? "Meaning" : "Meaning in this sentence")
                    Text(info.meaningInContext)
                        .font(.system(size: 14.5))
                        .foregroundColor(.ink)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
                .overlay(Rectangle().fill(Color.line).frame(height: 1), alignment: .top)
            }
            .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 14))

            SavedFooter(model: model, note: row.outcome.note)
        }
    }
}

private struct MultiResultCard: View {
    @ObservedObject var model: PopupModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.rows.count) words from this sentence")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.ink)
                    Text("Each one is saved with this sentence and gets its own review card.")
                        .font(.system(size: 12.5))
                        .foregroundColor(.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                RoundIconButton(systemName: "xmark", label: "Close", bordered: false, size: 28) { model.onClose() }
            }
            .padding(EdgeInsets(top: 14, leading: 18, bottom: 10, trailing: 12))

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(row.info.lemma)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.ink)
                                Text(row.info.partOfSpeech)
                                    .font(.system(size: 12))
                                    .foregroundColor(.muted)
                                RoundIconButton(systemName: "speaker.wave.2", label: "Play pronunciation", size: 26) { Speaker.say(row.info.lemma) }
                                Spacer()
                                Text(row.info.hebrew)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.ink)
                                    .multilineTextAlignment(.trailing)
                            }
                            Text(row.info.meaningInContext)
                                .font(.system(size: 12.5))
                                .foregroundColor(.body)
                                .fixedSize(horizontal: false, vertical: true)
                            if row.outcome.kind != .added {
                                Text(row.outcome.note)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundColor(.brand)
                            }
                        }
                        .padding(EdgeInsets(top: 11, leading: 18, bottom: 11, trailing: 14))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(Rectangle().fill(Color.line).frame(height: 1), alignment: .top)
                    }
                }
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)

            SavedFooter(model: model, note: "All \(model.rows.count) saved to your words")
        }
    }
}

private struct PickerCard: View {
    @ObservedObject var model: PopupModel

    private var buttonTitle: String {
        switch model.pickedWords.count {
        case 0: return "Tap the words you don't know"
        case 1: return "Translate 1 word"
        default: return "Translate \(model.pickedWords.count) words"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Which words don't you know?")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.ink)
                    Text("Tap as many as you want. Each one is saved with this sentence.")
                        .font(.system(size: 12.5))
                        .foregroundColor(.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                RoundIconButton(systemName: "xmark", label: "Close", bordered: false, size: 28) { model.onClose() }
            }

            ScrollView {
                FlowLayout(spacing: 6) {
                    ForEach(model.tokens) { token in
                        if token.word != nil {
                            let on = model.picked.contains(token.id)
                            Button { model.togglePick(token) } label: {
                                Text(token.text)
                                    .font(.system(size: 14, weight: on ? .semibold : .regular))
                                    .foregroundColor(.ink)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.marker : Color.white))
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? Color.markerBorder : Color.chipBorder, lineWidth: 1))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(token.text)
                                .font(.system(size: 14))
                                .foregroundColor(.muted)
                                .padding(.vertical, 6)
                        }
                    }
                }
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)

            Button { model.onTranslatePicked() } label: {
                Text(buttonTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(model.pickedWords.isEmpty ? .muted : .white)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background(RoundedRectangle(cornerRadius: 9).fill(model.pickedWords.isEmpty ? Color(hex: 0xE6E9EE) : Color.brand))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.pickedWords.isEmpty)
        }
        .padding(18)
    }
}

/// Writing helper: the English for the Hebrew you typed, ready to put into your sentence.
private struct ComposeCard: View {
    @ObservedObject var model: PopupModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "pencil.line")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.brand)
                    Text("Say it in English")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.muted)
                    Spacer()
                    RoundIconButton(systemName: "xmark", label: "Close", bordered: false, size: 28) { model.onClose() }
                }

                Text(model.composedSentence)
                    .font(.system(size: 16, design: .serif))
                    .foregroundColor(.ink)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                ForEach(Array(model.composeItems.enumerated()), id: \.offset) { index, item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .center, spacing: 8) {
                            Text(item.hebrew)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.ink)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.muted)
                            FlowLayout(spacing: 6) {
                                ForEach(Array(item.choices.enumerated()), id: \.offset) { choiceIndex, choice in
                                    let on = (model.composeChoice.indices.contains(index) ? model.composeChoice[index] : 0) == choiceIndex
                                    Button { model.onChoose(index, choiceIndex) } label: {
                                        Text(choice.word)
                                            .font(.system(size: 14, weight: on ? .semibold : .regular))
                                            .foregroundColor(.ink)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.marker : Color.white))
                                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? Color.markerBorder : Color.chipBorder, lineWidth: 1))
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help(choice.note)
                                }
                            }
                        }
                        if let choice = model.chosen(index) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(choice.note.isEmpty ? choice.meaning : "\(choice.note) · \(choice.meaning)")
                                    .font(.system(size: 12.5))
                                    .foregroundColor(.body)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                RoundIconButton(systemName: "speaker.wave.2", label: "Say \(choice.word)", size: 24) { Speaker.say(choice.word) }
                            }
                        }
                    }
                    .padding(.top, 10)
                    .overlay(Rectangle().fill(Color.line).frame(height: 1), alignment: .top)
                }

                HStack(spacing: 8) {
                    Button { model.onUseIt() } label: {
                        Text("Use it")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.brand))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Put this English into your text")
                    Button { model.onCopy() } label: {
                        Text(model.copied ? "Copied" : "Copy")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.ink)
                            .frame(width: 96, height: 36)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.chipBorder, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(EdgeInsets(top: 12, leading: 18, bottom: 16, trailing: 12))

            if !model.composeItems.isEmpty {
                SavedFooter(model: model, note: model.composeNote)
            }
        }
    }
}

private struct ErrorCard: View {
    @ObservedObject var model: PopupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 18))
                    .foregroundColor(.muted)
                Text(model.errorMessage)
                    .font(.system(size: 13.5))
                    .foregroundColor(.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                RoundIconButton(systemName: "xmark", label: "Close", bordered: false, size: 28) { model.onClose() }
            }
            if let action = model.errorAction {
                Button {
                    model.onErrorAction(action)
                } label: {
                    Text(action == .apiKey ? "Add API key" : "Open Accessibility settings")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.brand))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
    }
}

/// Wraps chips onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
