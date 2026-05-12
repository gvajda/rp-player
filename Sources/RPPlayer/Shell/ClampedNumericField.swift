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
        String(format: "%.2f", v)
    }
}

struct ClampedNumericField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let isEnabled: Bool

    @State private var rawText: String = ""
    @State private var isInvalid: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            TextField("", text: $rawText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .disabled(!isEnabled)
                .onChange(of: rawText) { newText in
                    guard let parsed = ClampedNumericFieldLogic.parse(newText),
                          ClampedNumericFieldLogic.isValid(parsed, in: range) else {
                        isInvalid = true
                        return
                    }
                    isInvalid = false
                    if parsed != value { value = parsed }
                }
                .onChange(of: focused) { isFocused in
                    if !isFocused && isInvalid {
                        rawText = ClampedNumericFieldLogic.format(value)
                        isInvalid = false
                    }
                }
                .onChange(of: value) { newValue in
                    if !focused {
                        rawText = ClampedNumericFieldLogic.format(newValue)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.red.opacity(isInvalid ? 0.85 : 0), lineWidth: 1.5)
                        .animation(.easeInOut(duration: 0.15), value: isInvalid)
                        .allowsHitTesting(false)
                )

            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
                .disabled(!isEnabled)
                .fixedSize()
        }
        .onAppear { rawText = ClampedNumericFieldLogic.format(value) }
    }
}
