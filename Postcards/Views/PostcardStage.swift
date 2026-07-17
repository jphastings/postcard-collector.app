import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The visual heart of "Create a Postcard": one drop zone covering the whole pane that becomes
/// a front/back pair of postcard-like cards stacked vertically, a swap control between them,
/// and a dimensions chip on the front. Thin over `CreatePostcardModel`: every piece of state
/// (which image is which side, secrets, the cm fields, the wizard's `spotlightSide`) is
/// read/written through it; this file only decodes display thumbnails and wires gestures. The
/// flip-axis picker and its rotating demo live in the fields pane instead (`FlipAxisDemo.swift`).
struct PostcardStage: View {
    @Bindable var model: CreatePostcardModel
    /// Surfaced by `CreatePostcardForm` after a failed create — shown right where the user
    /// would fix it, on the dimensions chip. A failed flip now surfaces next to
    /// `FlipAxisPicker` in the fields pane instead, since that's where the picker itself lives.
    let dimensionsError: String?

    @State private var isImporting = false
    @State private var isTargeted = false
    @State private var importError: String?

    @Namespace private var swapNamespace

    private static let allowedTypes: [UTType] = [.tiff, .png, .jpeg, .webP]

    /// `model.spotlightSide`, but defused if it names a side that doesn't actually exist —
    /// defensive against the wizard's focus/model updates racing a clear/swap.
    private var effectiveSpotlight: CreatePostcardModel.DescribeStep.Side? {
        switch model.spotlightSide {
        case .front: model.front != nil ? .front : nil
        case .back: model.back != nil ? .back : nil
        case nil: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.front == nil {
                dropZone
            } else {
                sidesStack
                if effectiveSpotlight == nil {
                    if let warning = model.physicalMismatchWarning {
                        warningLabel(warning, systemImage: "exclamationmark.triangle.fill", color: .yellow)
                    }
                    if let dimensionsError {
                        warningLabel(dimensionsError, systemImage: "exclamationmark.circle.fill", color: .red)
                    }
                }
            }
            if let importError {
                warningLabel(importError, systemImage: "exclamationmark.circle.fill", color: .red)
            }
        }
        .animation(.default, value: model.front == nil)
        .animation(.default, value: model.back == nil)
        .animation(.easeInOut(duration: 0.3), value: effectiveSpotlight)
        .contentShape(Rectangle())
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isTargeted ? Color.accentColor : .clear, lineWidth: 2)
                .allowsHitTesting(false)
        }
        // The whole pane is the drop target — filled or empty, dropping anywhere adds/replaces
        // via `model.addImage`, not just an inner widget.
        .dropDestination(for: URL.self) { urls, _ in
            importURLs(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: Self.allowedTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): importURLs(urls)
            case .failure(let error): importError = error.localizedDescription
            }
        }
    }

    // MARK: - Empty state

    private var dropZone: some View {
        Button {
            isImporting = true
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 40, weight: .light))
                Text("Drop scans of your postcard here")
                    .font(.headline)
                Text("or browse files…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .foregroundStyle(.secondary)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Filled state

    /// Front above back — each renders larger than a side-by-side layout would allow. Zoomed
    /// (`effectiveSpotlight != nil`, set while a wizard editor has focus — see
    /// `CreatePostcardModel.spotlightSide`) shows only that one side, filling the pane; the
    /// swap button, the other side, and the empty-back slot all drop out of the stack rather
    /// than just fading, so the visible card actually grows into the freed space.
    private var sidesStack: some View {
        VStack(spacing: 14) {
            if let front = model.front, effectiveSpotlight != .back {
                SideCard(
                    title: "Front", probed: front, secrets: $model.frontSecrets,
                    namespace: swapNamespace, isZoomed: effectiveSpotlight == .front
                ) {
                    model.clearFront()
                }
                .overlay(alignment: .bottomLeading) {
                    if effectiveSpotlight == nil {
                        DimensionsChip(model: model, dimensionsError: dimensionsError)
                            .padding(8)
                    }
                }
            }

            if effectiveSpotlight == nil, model.back != nil {
                swapButton
            }

            if effectiveSpotlight != .front {
                if let back = model.back {
                    SideCard(
                        title: "Back", probed: back, secrets: $model.backSecrets,
                        namespace: swapNamespace, isZoomed: effectiveSpotlight == .back
                    ) {
                        model.clearBack()
                    }
                } else if effectiveSpotlight == nil {
                    quietAddBackSlot
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var quietAddBackSlot: some View {
        Button {
            isImporting = true
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus.rectangle.on.folder")
                    .font(.title2)
                Text("Add the back")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 90)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private var swapButton: some View {
        Button {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                model.swapSides()
            }
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.body.weight(.semibold))
                .frame(width: 30, height: 30)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Swap front and back")
    }

    // MARK: - Import

    private func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        importError = nil
        Task {
            for url in urls.prefix(2) {
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        try Self.readSecurityScopedData(at: url)
                    }.value
                    try model.addImage(data: data, filename: url.lastPathComponent)
                } catch {
                    importError = error.localizedDescription
                    return
                }
            }
        }
    }

    /// Reads a picked/dropped file's bytes immediately, retaining nothing scoped — mirrors
    /// `LibraryModel.copyIntoContainer`'s security-scope + coordinated-read bracketing, minus
    /// the copy (the stage only ever needs the bytes in memory).
    private nonisolated static func readSecurityScopedData(at url: URL) throws -> Data {
        let hasScope = url.startAccessingSecurityScopedResource()
        defer { if hasScope { url.stopAccessingSecurityScopedResource() } }

        var coordinationError: NSError?
        var data: Data?
        var readError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            do {
                data = try Data(contentsOf: readableURL)
            } catch {
                readError = error
            }
        }
        if let error = coordinationError ?? readError { throw error }
        guard let data else { throw CocoaError(.fileReadUnknown) }
        return data
    }

    // MARK: - Shared

    private func warningLabel(_ message: String, systemImage: String, color: Color) -> some View {
        Label(message, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(color)
    }
}

// MARK: - Side card

/// One filled side: a rounded, shadowed, correctly-aspected card with hover-revealed (macOS) /
/// always-subtle (touch) controls to clear it or mark secrets, and an outline of any secrets
/// already drawn. `matchedGeometryEffect(id: probed.id, …)` is what makes `swapSides()` read as
/// the two cards crossing rather than their content just cutting over — `probed.id` travels
/// with the picture across the swap (see `ProbedImage.id`'s doc comment), so the same id
/// reappearing at the other slot is exactly the "this view moved" signal the effect needs.
private struct SideCard: View {
    let title: String
    let probed: ProbedImage
    @Binding var secrets: [SecretRegion]
    let namespace: Namespace.ID
    /// Set while the wizard has this side spotlighted (`PostcardStage.effectiveSpotlight`):
    /// grows the card to fill its container and hides the clear/secrets controls, which have
    /// nothing useful to do while the user's attention is on describing, not editing.
    var isZoomed: Bool = false
    let onClear: () -> Void

    @State private var previewImage: PlatformImage?
    @State private var isEditingSecrets = false
    @State private var isHovering = false

    private nonisolated static let thumbnailMaxPixelSize: CGFloat = 640

    var body: some View {
        VStack(spacing: 6) {
            imageCard
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: isZoomed ? .infinity : nil)
    }

    private var imageCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background)
            if let previewImage {
                Image(platformImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .overlay { secretsOutline }
            } else {
                ProgressView()
            }
        }
        .aspectRatio(CGFloat(probed.pixelWidth) / CGFloat(max(probed.pixelHeight, 1)), contentMode: .fit)
        .frame(maxHeight: isZoomed ? .infinity : nil)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 6)
        .matchedGeometryEffect(id: probed.id, in: namespace)
        .overlay(alignment: .topTrailing) { clearButton }
        .overlay(alignment: .bottomTrailing) { markSecretsButton }
        #if os(macOS)
        .onHover { isHovering = $0 }
        #endif
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .task(id: probed.id) { await loadPreview() }
        .sheet(isPresented: $isEditingSecrets) {
            SecretRegionEditor(imageData: probed.data, regions: $secrets)
        }
    }

    private var clearButton: some View {
        Button(action: onClear) {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.55))
                .font(.title3)
        }
        .buttonStyle(.plain)
        .padding(8)
        .opacity(controlOpacity)
        .allowsHitTesting(!isZoomed)
    }

    private var markSecretsButton: some View {
        Button {
            isEditingSecrets = true
        } label: {
            Label(
                secrets.isEmpty ? "Mark secrets…" : "\(secrets.count) secret\(secrets.count == 1 ? "" : "s")",
                systemImage: "eye.slash"
            )
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(8)
        .opacity(controlOpacity)
        .allowsHitTesting(!isZoomed)
    }

    private var controlOpacity: Double {
        guard !isZoomed else { return 0 }
        #if os(macOS)
        return isHovering ? 1 : 0
        #else
        return 0.85
        #endif
    }

    /// Small outlines of `secrets`, scaled from their normalized rects onto the decoded
    /// thumbnail — see `SecretRegion.fittedFrame`'s doc comment for why the letterbox math is
    /// needed even though `scaledToFit` here fills its container exactly (matching aspect).
    @ViewBuilder
    private var secretsOutline: some View {
        if !secrets.isEmpty {
            GeometryReader { proxy in
                let contentSize = CGSize(width: CGFloat(probed.pixelWidth), height: CGFloat(probed.pixelHeight))
                let frame = SecretRegion.fittedFrame(ofContentSize: contentSize, in: proxy.size)
                ForEach(secrets) { region in
                    let rect = SecretRegion.viewRect(ofNormalized: region.rect, displaySize: frame.size)
                    Rectangle()
                        .strokeBorder(region.prehidden ? Color.blue : Color.orange, lineWidth: 1)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: frame.minX + rect.midX, y: frame.minY + rect.midY)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func loadPreview() async {
        let data = probed.data
        let cgImage = await Task.detached(priority: .utility) {
            ScanThumbnail.decode(from: data, maxPixelSize: Self.thumbnailMaxPixelSize)
        }.value
        previewImage = cgImage.map(PlatformImage.from(cgImage:))
    }
}

// MARK: - Dimensions chip

/// The front card's "10.5 × 14.8 cm" corner badge; tapping it opens a popover with the
/// aspect-linked width/height fields `CreatePostcardModel` already keeps in sync, plus a
/// footnote naming where the current values came from.
private struct DimensionsChip: View {
    @Bindable var model: CreatePostcardModel
    let dimensionsError: String?

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 4) {
                if dimensionsError != nil {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                }
                Text(model.dimensionsChipText ?? "Set size…")
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented) {
            popoverContent
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Physical size").font(.headline)
            LabeledContent("Width") {
                TextField("cm", text: $model.cmWidthText)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
            }
            LabeledContent("Height") {
                TextField("cm", text: $model.cmHeightText)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
            }
            if let dimensionsError {
                Text(dimensionsError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text(model.dimensionsSourceFootnote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 240)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Empty") {
    PostcardStage(model: CreatePostcardModel(), dimensionsError: nil)
        .padding()
        .frame(width: 380, height: 640)
}

#Preview("Front only") {
    stagePreview(hasBack: false)
}

#Preview("Front and back") {
    stagePreview(hasBack: true)
}

#Preview("Zoomed on front") {
    stagePreview(hasBack: true, spotlight: .front)
}

#Preview("Dimensions error") {
    stagePreview(hasBack: false, dpi: nil, dimensionsError: "Enter a valid width and height — open the size chip to fix it.")
}

/// A `#Preview` closure is a `ViewBuilder`, where the model-configuring statements above
/// wouldn't compile as bare expressions — so the setup lives here instead.
@MainActor
private func stagePreview(
    hasBack: Bool,
    dpi: Double? = 300,
    dimensionsError: String? = nil,
    spotlight: CreatePostcardModel.DescribeStep.Side? = nil
) -> some View {
    let model = CreatePostcardModel()
    try? model.setFront(data: stagePreviewImageData(tint: (0.93, 0.90, 0.83), dpi: dpi), filename: "front.png")
    if hasBack {
        try? model.setBack(data: stagePreviewImageData(tint: (0.85, 0.88, 0.93), dpi: dpi), filename: "back.png")
    }
    model.spotlightSide = spotlight
    return PostcardStage(model: model, dimensionsError: dimensionsError)
        .padding()
        .frame(width: 380, height: 640)
}

/// A generated postcard-ish placeholder (border, "stamp" corner) so previews need no bundled
/// fixture image to iterate on this view — `tint` differentiates front/back at a glance.
private func stagePreviewImageData(width: Int = 900, height: Int = 600, tint: (Double, Double, Double), dpi: Double? = 300) -> Data {
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
    guard let destination = CGImageDestinationCreateWithData(mutableData, UTType.png.identifier as CFString, 1, nil) else { return Data() }
    var properties: [CFString: Any] = [:]
    if let dpi {
        properties[kCGImagePropertyDPIWidth] = dpi
        properties[kCGImagePropertyDPIHeight] = dpi
    }
    CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
    CGImageDestinationFinalize(destination)
    return mutableData as Data
}
#endif
