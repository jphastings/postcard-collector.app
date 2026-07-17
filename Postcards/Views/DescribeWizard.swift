import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// The "Describe & transcribe" mini-wizard inside `CreatePostcardForm`'s fields pane: one
/// step per `CreatePostcardModel.DescribeStep`, each showing a prompt above a `TextEditor`.
/// Thin over the model — step structure, text, and skip flags all live there
/// (`describeSteps`, `textKeyPath`, `skipKeyPath`); this view owns only presentation state:
/// the current step index, the OCR-prefill bookkeeping, and which step's editor has focus.
///
/// Rather than duplicating the side's image next to the editor, a focused editor sets
/// `model.spotlightSide` (via `focusedStep`, below) so `PostcardStage` zooms the left pane to
/// that side instead — one picture of the card on screen at a time, not two.
///
/// OCR prefill: when a transcription step becomes current with no text yet, the side's scan
/// runs through `HandwritingRecognizer` (cancelled if the user moves on). Text found while
/// the step is active prefills the editor with a "Detected automatically" caption; text found
/// while the step is skipped only surfaces a hint — never unchecks the box for the user.
struct DescribeWizard: View {
    @Bindable var model: CreatePostcardModel

    @State private var stepIndex = 0
    /// Which step's `TextEditor` currently has keyboard focus, if any — drives
    /// `model.spotlightSide` (set on focus, cleared on blur or on skipping the focused step).
    @FocusState private var focusedStep: CreatePostcardModel.DescribeStep?
    /// Recognized handwriting per `ProbedImage.id` — cached so toggling skip or revisiting a
    /// step never re-runs Vision over the same scan. A completed run that found nothing is
    /// recorded in `ocrCheckedImages` with no text here.
    @State private var ocrTextByImage: [UUID: String] = [:]
    @State private var ocrCheckedImages: Set<UUID> = []
    @State private var autoFilledSteps: Set<CreatePostcardModel.DescribeStep> = []

    private var steps: [CreatePostcardModel.DescribeStep] { model.describeSteps }

    /// Always-valid current step: `describeSteps` recomputes when a back is added/removed, so
    /// the stored index is clamped on read (and re-stored via `onChange` below).
    private var currentStep: CreatePostcardModel.DescribeStep {
        steps[min(stepIndex, steps.count - 1)]
    }

    var body: some View {
        let step = currentStep
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt(for: step))
                .font(.subheadline.weight(.medium))

            editor(for: step)

            Toggle(skipLabel(for: step), isOn: skipBinding(for: step))
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
                .font(.callout)

            statusLine(for: step)

            navigationRow
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.2), value: stepIndex)
        .animation(.easeInOut(duration: 0.2), value: steps)
        .animation(.easeInOut(duration: 0.2), value: isSkipped(step))
        .onChange(of: steps.count) { _, newCount in
            stepIndex = min(stepIndex, newCount - 1)
        }
        .onChange(of: focusedStep) { _, newValue in
            model.spotlightSide = newValue?.side
        }
        .onChange(of: isSkipped(step)) { _, skipped in
            // Checking skip collapses the editor away entirely — if it still held focus,
            // drop it (and, via the `focusedStep` handler above, the spotlight with it).
            guard skipped, focusedStep == step else { return }
            focusedStep = nil
        }
        .task(id: ocrKey(for: step)) {
            await runOCRIfNeeded(for: step)
        }
    }

    // MARK: - Step content

    /// `nil` (hidden entirely, animated) once the step is skipped — the text itself stays put
    /// in the model, so un-skipping brings the editor back with it intact.
    @ViewBuilder
    private func editor(for step: CreatePostcardModel.DescribeStep) -> some View {
        if !isSkipped(step) {
            TextEditor(text: textBinding(for: step))
                .frame(minHeight: 110)
                .contentMargins(.all, 8, for: .scrollContent)
                .focused($focusedStep, equals: step)
                .transition(.opacity)
        }
    }

    /// The one gentle line under the editor, when there's something worth saying: the OCR
    /// prefill caption, the handwriting-detected-while-skipped hint, or the alt-text nudge.
    @ViewBuilder
    private func statusLine(for step: CreatePostcardModel.DescribeStep) -> some View {
        if step.kind == .transcription, isSkipped(step), recognizedText(for: step) != nil {
            Label("Handwriting detected — uncheck to transcribe", systemImage: "text.viewfinder")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if autoFilledSteps.contains(step), !isSkipped(step) {
            Label("Detected automatically — check and edit", systemImage: "text.viewfinder")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if nudges(step) {
            Label("Add a description to make this card more discoverable — never required.", systemImage: "text.below.photo")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Navigation

    private var navigationRow: some View {
        HStack {
            Button {
                stepIndex = max(0, stepIndex - 1)
            } label: {
                Label("Back", systemImage: "chevron.backward")
            }
            .disabled(stepIndex == 0)

            Spacer()
            progressDots
            Spacer()

            Button {
                stepIndex = min(steps.count - 1, stepIndex + 1)
            } label: {
                Label("Next", systemImage: "chevron.forward")
            }
            .disabled(stepIndex >= steps.count - 1)
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    private var progressDots: some View {
        HStack(spacing: 7) {
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                Circle()
                    .fill(index == stepIndex ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 7, height: 7)
                    .overlay {
                        // The alt-text nudge, as a gentle ring — informative, never blocking.
                        if nudges(step) {
                            Circle()
                                .strokeBorder(.orange.opacity(0.6), lineWidth: 1)
                                .padding(-2.5)
                        }
                    }
                    .contentShape(Circle().inset(by: -4))
                    .onTapGesture { stepIndex = index }
                    .accessibilityLabel("Step \(index + 1) of \(steps.count)")
            }
        }
    }

    // MARK: - Step copy

    private func prompt(for step: CreatePostcardModel.DescribeStep) -> String {
        switch step {
        case .frontDescription: "Describe this side of the postcard, to make it easy to search for"
        case .frontTranscription: "Is there a message on this side?"
        case .backTranscription: "Transcribe the handwritten message"
        case .backDescription: "Describe this side of the postcard"
        }
    }

    private func skipLabel(for step: CreatePostcardModel.DescribeStep) -> String {
        let side = step.side == .front ? "front" : "back"
        return switch step.kind {
        case .description: "Nothing worth describing on the postcard's \(side)"
        case .transcription: "No handwritten text on the postcard's \(side)"
        }
    }

    // MARK: - Model plumbing

    private func textBinding(for step: CreatePostcardModel.DescribeStep) -> Binding<String> {
        Binding(
            get: { model[keyPath: step.textKeyPath] },
            set: { model[keyPath: step.textKeyPath] = $0 }
        )
    }

    private func skipBinding(for step: CreatePostcardModel.DescribeStep) -> Binding<Bool> {
        Binding(
            get: { model[keyPath: step.skipKeyPath] },
            set: { model[keyPath: step.skipKeyPath] = $0 }
        )
    }

    private func isSkipped(_ step: CreatePostcardModel.DescribeStep) -> Bool {
        model[keyPath: step.skipKeyPath]
    }

    /// Per-step version of `CreatePostcardModel.altTextNudge`: an unskipped description step
    /// whose text is still empty.
    private func nudges(_ step: CreatePostcardModel.DescribeStep) -> Bool {
        guard step.kind == .description, !isSkipped(step) else { return false }
        return model[keyPath: step.textKeyPath].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func probedImage(for side: CreatePostcardModel.DescribeStep.Side) -> ProbedImage? {
        switch side {
        case .front: model.front
        case .back: model.back
        }
    }

    // MARK: - OCR prefill

    /// `task(id:)` key for the OCR pass: changes when the current step, its side's image, or
    /// its skip flag changes — so moving on cancels an in-flight pass, and unchecking skip
    /// after a "handwriting detected" hint re-fires it (which then prefills from the cache).
    private struct OCRKey: Equatable {
        var step: CreatePostcardModel.DescribeStep
        var imageID: UUID?
        var skipped: Bool
    }

    private func ocrKey(for step: CreatePostcardModel.DescribeStep) -> OCRKey {
        OCRKey(step: step, imageID: probedImage(for: step.side)?.id, skipped: isSkipped(step))
    }

    private func runOCRIfNeeded(for step: CreatePostcardModel.DescribeStep) async {
        guard step.kind == .transcription, let probed = probedImage(for: step.side) else { return }
        guard model[keyPath: step.textKeyPath].isEmpty else { return }

        if !ocrCheckedImages.contains(probed.id) {
            let text = await HandwritingRecognizer.recognizeText(in: probed.data)
            guard !Task.isCancelled else { return }
            ocrCheckedImages.insert(probed.id)
            if let text {
                ocrTextByImage[probed.id] = text
            }
        }

        guard let text = ocrTextByImage[probed.id] else { return }
        // Re-read the live flags: skip may have been toggled while Vision ran. A skipped
        // step keeps its text untouched — `statusLine` shows the hint instead.
        if !model[keyPath: step.skipKeyPath], model[keyPath: step.textKeyPath].isEmpty {
            model[keyPath: step.textKeyPath] = text
            autoFilledSteps.insert(step)
        }
    }

    private func recognizedText(for step: CreatePostcardModel.DescribeStep) -> String? {
        probedImage(for: step.side).flatMap { ocrTextByImage[$0.id] }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Front only") {
    describeWizardPreview(hasBack: false)
}

#Preview("Front and back") {
    describeWizardPreview(hasBack: true)
}

/// A `#Preview` closure is a `ViewBuilder`, where the model-configuring statements below
/// wouldn't compile as bare expressions — so the setup lives here instead (the
/// `PostcardStage` previews' pattern).
@MainActor
private func describeWizardPreview(hasBack: Bool) -> some View {
    let model = CreatePostcardModel()
    try? model.setFront(data: wizardPreviewImageData(tint: (0.93, 0.90, 0.83)), filename: "front.png")
    if hasBack {
        try? model.setBack(data: wizardPreviewImageData(tint: (0.85, 0.88, 0.93)), filename: "back.png")
    }
    return Form {
        Section("Describe & transcribe") {
            DescribeWizard(model: model)
        }
    }
    .formStyle(.grouped)
    .frame(width: 420, height: 360)
}

/// A generated postcard-ish placeholder (border, "stamp" corner) so this preview needs no
/// bundled fixture image — `tint` differentiates front/back at a glance.
private func wizardPreviewImageData(width: Int = 900, height: Int = 600, tint: (Double, Double, Double)) -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return Data() }

    let w = CGFloat(width)
    let h = CGFloat(height)

    context.setFillColor(CGColor(red: tint.0, green: tint.1, blue: tint.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: w, height: h))

    context.setStrokeColor(CGColor(red: 0.55, green: 0.42, blue: 0.3, alpha: 1))
    context.setLineWidth(6)
    context.stroke(CGRect(x: 20, y: 20, width: w - 40, height: h - 40))

    context.setFillColor(CGColor(red: 0.75, green: 0.2, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: w - 160, y: 40, width: 100, height: 130))

    guard let cgImage = context.makeImage() else { return Data() }
    let mutableData = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(mutableData, "public.png" as CFString, 1, nil) else {
        return Data()
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    CGImageDestinationFinalize(destination)
    return mutableData as Data
}
#endif
