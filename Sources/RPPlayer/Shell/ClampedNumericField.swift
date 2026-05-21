// Sources/RPPlayer/Shell/ClampedNumericField.swift
import SwiftUI

internal enum ClampedNumericFieldLogic {
    static func parse(_ raw: String, locale: Locale = .current) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        if let n = f.number(from: trimmed)?.doubleValue { return n }
        // Dot-as-decimal fallback for users typing the canonical form in any locale.
        return Double(trimmed)
    }

    static func isValid(_ v: Double, in range: ClosedRange<Double>) -> Bool {
        !v.isNaN && range.contains(v)
    }

    static func format(_ v: Double) -> String {
        format(v, decimals: 2)
    }

    static func format(_ v: Double, decimals: Int) -> String {
        String(format: "%.\(max(0, decimals))f", v)
    }
}

struct ClampedNumericField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let isEnabled: Bool
    var decimals: Int = 2
    var width: CGFloat = 72

    @State private var rawText: String = ""
    @State private var isInvalid: Bool = false
    @FocusState private var focused: Bool

    private var borderColor: Color {
        if isInvalid { return Color.red.opacity(0.85) }
        if focused { return Color.accentColor.opacity(0.85) }
        return Color.secondary.opacity(0.5)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            TextField("", text: $rawText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .focused($focused)
                .disabled(!isEnabled)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .frame(width: width, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(borderColor, lineWidth: isInvalid ? 1.5 : 1)
                        .animation(.easeInOut(duration: 0.15), value: isInvalid)
                        .allowsHitTesting(false)
                )
                .onChange(of: rawText) { _, newText in
                    guard let parsed = ClampedNumericFieldLogic.parse(newText),
                        ClampedNumericFieldLogic.isValid(parsed, in: range)
                    else {
                        isInvalid = true
                        return
                    }
                    isInvalid = false
                    if parsed != value { value = parsed }
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused && isInvalid {
                        rawText = ClampedNumericFieldLogic.format(value, decimals: decimals)
                        isInvalid = false
                    }
                }
                .onChange(of: value) { _, newValue in
                    if !focused {
                        rawText = ClampedNumericFieldLogic.format(newValue, decimals: decimals)
                    }
                }

            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
                .disabled(!isEnabled)
                .fixedSize()
        }
        .controlSize(.small)
        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
        .onAppear { rawText = ClampedNumericFieldLogic.format(value, decimals: decimals) }
    }
}
