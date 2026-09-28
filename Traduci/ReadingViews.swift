import SwiftUI

extension Color {
    /// Headings, prices, the picked dish: warm, like candlelight on a menu.
    static let accentWarm = Color(red: 1.0, green: 0.76, blue: 0.33)

    init(_ rgb: InkSampler.RGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

// MARK: - Reading screen

/// The captured page: the picture above, the English below, the two moving together as the panel
/// is dragged between a peek, half the screen and nearly all of it.
struct ReadingScreen: View {
    let model: AppModel
    let size: CGSize
    let insets: EdgeInsets
    @State private var detent: PanelDetent
    @State private var drag: CGFloat = 0

    enum PanelDetent: CaseIterable {
        case peek, half, full
    }

    init(model: AppModel, size: CGSize, insets: EdgeInsets) {
        self.model = model
        self.size = size
        self.insets = insets
        switch model.demo?.panel {
        case "peek"?: _detent = State(initialValue: .peek)
        case "full"?: _detent = State(initialValue: .full)
        default: _detent = State(initialValue: .half)
        }
    }

    private func height(_ detent: PanelDetent) -> CGFloat {
        switch detent {
        case .peek: return 148 + insets.bottom
        case .half: return (size.height * 0.56).rounded()
        case .full: return size.height - insets.top - 8
        }
    }

    private var panelHeight: CGFloat {
        min(max(height(detent) - drag, height(.peek) - 40), height(.full) + 20)
    }

    var body: some View {
        let photoHeight = size.height - panelHeight + ReadingPanel.cornerRadius
        ZStack(alignment: .top) {
            Color.black
            PhotoView(model: model, size: CGSize(width: size.width, height: photoHeight))
                .frame(width: size.width, height: photoHeight)
                .clipped()
            ReadingPanel(model: model, bottomInset: insets.bottom) { translation in
                drag = translation
            } onDragEnded: { predicted in
                let landing = height(detent) - predicted
                let nearest = PanelDetent.allCases.min { abs(height($0) - landing) < abs(height($1) - landing) } ?? .half
                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                    detent = nearest
                    drag = 0
                }
            }
            .frame(height: panelHeight)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - The picture

/// The still, with the English painted over the Italian in the page's own colours. Pinch to look
/// closer, drag to move around, tap a dish to find it in the list.
struct PhotoView: View {
    let model: AppModel
    let size: CGSize
    @State private var gestureStart: (zoom: CGFloat, pan: CGSize)?

    var body: some View {
        let mapper = AspectFillMapper(imageSize: model.imageSize, viewSize: size, zoom: model.stillZoom, pan: model.stillPan)
        let frame = mapper.imageFrame
        ZStack(alignment: .topLeading) {
            if let still = model.stillImage {
                Image(decorative: still, scale: 1)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
            ForEach(model.captions) { caption in
                CaptionPatches(caption: caption, mapper: mapper, focused: caption.id == model.focusedID) {
                    model.focus(caption.id, fromList: false)
                }
                .zIndex(caption.id == model.focusedID ? 1 : 0) // the picked one over its neighbours
            }
            if model.isReadingPage {
                ReadingSweep()
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(pinch)
        .simultaneousGesture(pan)
        .onChange(of: size, initial: true) { _, size in
            model.stillViewSize = size
            model.panStill(to: model.stillPan) // keep the picture covering its area as the panel moves
        }
        .onChange(of: model.focusedID) { _, id in
            guard let id, model.focusFromList else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { model.showOnStill(id) }
        }
        .animation(.easeOut(duration: 0.25), value: model.captions.map(\.english))
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = gestureStart ?? (zoom: model.stillZoom, pan: model.stillPan)
                gestureStart = start
                model.zoomStill(to: start.zoom * value.magnification, from: start)
            }
            .onEnded { _ in gestureStart = nil }
    }

    private var pan: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let start = gestureStart ?? (zoom: model.stillZoom, pan: model.stillPan)
                gestureStart = start
                model.panStill(to: CGSize(width: start.pan.width + value.translation.width,
                                          height: start.pan.height + value.translation.height))
            }
            .onEnded { _ in gestureStart = nil }
    }
}

/// An entry's English over its Italian: the name over the name's lines, the description over the rest.
struct CaptionPatches: View {
    let caption: Caption
    let mapper: AspectFillMapper
    let focused: Bool
    let onTap: () -> Void

    var body: some View {
        let entry = caption.entry
        let titleRect = mapper.viewRect(for: entry.titleBox)
        let detailBox = CGRect(x: entry.box.minX, y: entry.titleBox.maxY,
                               width: entry.box.width, height: max(0, entry.box.maxY - entry.titleBox.maxY))
        let details = caption.details.compactMap { $0 }
        let allDetails = !details.isEmpty && details.count == entry.details.count
        // "CROSTONE: pecorino…" is one printed line: its English goes back on one line too.
        let sameLine = detailBox.height <= 0.004
        ZStack(alignment: .topLeading) {
            if caption.paintsTitle, let title = caption.title {
                let text = sameLine && allDetails ? title + ": " + details.joined(separator: ", ") : title
                PrintedText(text: text, rect: titleRect, room: room(from: entry.titleBox),
                            lines: max(1, titleLines), colors: caption.colors)
            }
            if allDetails, !sameLine {
                PrintedText(text: details.joined(separator: " · "), rect: mapper.viewRect(for: detailBox),
                            room: room(from: detailBox), lines: max(1, entry.lineCount - titleLines), colors: caption.colors)
            }
            let target = mapper.viewRect(for: entry.box).insetBy(dx: -4, dy: -3)
            Color.clear
                .contentShape(Rectangle())
                .frame(width: max(target.width, 1), height: max(target.height, 1))
                .position(x: target.midX, y: target.midY)
                .onTapGesture(perform: onTap)
            if focused {
                let whole = mapper.viewRect(for: entry.box).insetBy(dx: -5, dy: -4)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.accentWarm, lineWidth: 2.5)
                    .shadow(color: .black.opacity(0.5), radius: 3)
                    .frame(width: whole.width, height: whole.height)
                    .position(x: whole.midX, y: whole.midY)
                    .transition(.opacity)
            }
        }
    }

    /// How wide the English may run from `box`'s left edge, in points.
    private func room(from box: CGRect) -> CGFloat {
        mapper.viewRect(for: CGRect(x: box.minX, y: box.minY, width: max(caption.roomRight - box.minX, box.width), height: box.height)).width
    }

    private var titleLines: Int {
        let lineHeight = caption.entry.box.height / CGFloat(max(caption.entry.lineCount, 1))
        return max(1, Int((caption.entry.titleBox.height / max(lineHeight, 0.0001)).rounded()))
    }
}

/// English printed over the Italian in the page's paper and ink, at the Italian's type size. A
/// longer English runs on into the blank paper beside it (`room` wide at most), never over its
/// neighbours, and shrinks only a little before it's cut short: the list has it in full.
struct PrintedText: View {
    let text: String
    let rect: CGRect
    /// How wide it may run from the Italian's left edge, in points.
    let room: CGFloat
    let lines: Int
    let colors: InkSampler.Colors?

    var body: some View {
        let box = rect.insetBy(dx: -2, dy: -1)
        let lineHeight = box.height / CGFloat(max(lines, 1))
        let paper = colors.map { Color($0.paper) } ?? Color.black.opacity(0.82)
        let ink = colors.map { Color($0.ink) } ?? Color.white
        Text(text)
            .font(.system(size: max(min(lineHeight * 0.78, 40), 5), weight: .medium))
            .foregroundStyle(ink)
            .lineLimit(max(lines, 1))
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 1)
            .frame(minWidth: box.width, minHeight: box.height, maxHeight: box.height, alignment: .leading) // hugs the English
            .background(paper)
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            .frame(maxWidth: max(box.width, room + 2), alignment: .leading) // the room it may take
            .offset(x: box.minX, y: box.minY)
            .allowsHitTesting(false)
    }
}

/// A soft light passing down the page while it's being read closely (a fraction of a second).
struct ReadingSweep: View {
    @State private var down = false

    var body: some View {
        GeometryReader { geometry in
            LinearGradient(colors: [.clear, .white.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: geometry.size.height * 0.25)
                .offset(y: down ? geometry.size.height : -geometry.size.height * 0.25)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: false)) { down = true }
                }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - The English

/// The page in English, in reading order, at a size you can read at the table: dish, what's in
/// it, the Italian name to order by, the price.
struct ReadingPanel: View {
    static let cornerRadius: CGFloat = 22

    let model: AppModel
    let bottomInset: CGFloat
    /// The header is the handle: drag it to see more of the picture or more of the list.
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .global)
                        .onChanged { onDragChanged($0.translation.height) }
                        .onEnded { onDragEnded($0.predictedEndTranslation.height) }
                )
            Divider().opacity(0.4)
            content
        }
        .background(Color(white: 0.105))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: Self.cornerRadius, topTrailingRadius: Self.cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 12, y: -2)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(Color.white.opacity(0.28))
                .frame(width: 38, height: 5)
                .padding(.top, 7)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.default, value: subtitle)
                }
                Spacer(minLength: 8)
                if !model.captions.isEmpty {
                    ShareLink(item: model.shareText) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.body.weight(.semibold))
                            .frame(width: 40, height: 40)
                            .background(Color.white.opacity(0.1), in: Circle())
                    }
                    .accessibilityLabel("Share the translation")
                }
                Button {
                    model.backToCamera()
                } label: {
                    Label("Scan", systemImage: "camera.viewfinder")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(Color.accentWarm, in: Capsule())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Back to the camera")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .foregroundStyle(.white)
        .tint(.white)
    }

    @ViewBuilder
    private var content: some View {
        if model.isReadingPage, model.captions.isEmpty {
            VStack(spacing: 10) {
                ProgressView().tint(.white)
                Text("Reading the page…").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 28)
        } else if model.captions.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "text.magnifyingglass").font(.title2).foregroundStyle(.secondary)
                Text("No Italian text found").font(.headline)
                Text("Get a little closer, or turn on the light, then scan again.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 32)
            .padding(.top, 24)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.captions) { caption in
                            CaptionRow(caption: caption, focused: caption.id == model.focusedID)
                                .id(caption.id)
                                .contentShape(Rectangle())
                                .onTapGesture { model.focus(caption.id, fromList: true) }
                        }
                    }
                    .padding(.bottom, bottomInset + 24)
                }
                .onChange(of: model.focusedID) { _, id in
                    guard let id, !model.focusFromList else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
                }
                .onAppear {
                    if let id = model.focusedID { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private var isMenu: Bool { model.captions.contains { $0.entry.kind == .item } }

    private var title: String { isMenu ? "Menu in English" : "In English" }

    private var subtitle: String {
        if model.isReadingPage, model.captions.isEmpty { return "Reading…" }
        let translatable = model.captions.filter { !$0.entry.isForeign }
        let done = translatable.filter(\.isTranslated).count
        if done < translatable.count { return "Translating \(done) of \(translatable.count)…" }
        let dishes = model.captions.filter { $0.entry.kind == .item }.count
        if dishes > 0 { return dishes == 1 ? "1 dish" : "\(dishes) dishes" }
        return translatable.isEmpty ? "Already in English" : "Translated on this iPhone"
    }
}

/// One entry: a section heading, a dish, or a paragraph.
struct CaptionRow: View {
    let caption: Caption
    let focused: Bool

    var body: some View {
        Group {
            switch caption.entry.kind {
            case .heading: heading
            case .item, .text: item
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(focused ? Color.accentWarm.opacity(0.13) : .clear)
        .overlay(alignment: .leading) {
            if focused { Rectangle().fill(Color.accentWarm).frame(width: 3) }
        }
        .animation(.easeOut(duration: 0.2), value: focused)
        .animation(.easeOut(duration: 0.25), value: caption.english)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text((caption.title ?? caption.entry.title).uppercased())
                .font(.footnote.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(Color.accentWarm)
                .redacted(reason: caption.title == nil ? .placeholder : [])
            if caption.showsItalian, caption.title != nil {
                Text(caption.entry.title)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 8)
    }

    private var item: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                if let title = caption.title {
                    Text(title)
                        .font(caption.entry.kind == .item ? .body.weight(.semibold) : .body)
                        .foregroundStyle(caption.entry.isForeign ? .white.opacity(0.75) : .white)
                } else {
                    Text(caption.entry.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .redacted(reason: .placeholder)
                }
                ForEach(Array(caption.entry.details.enumerated()), id: \.offset) { index, italian in
                    let english = caption.details[index]
                    Text(english ?? italian)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.68))
                        .redacted(reason: english == nil ? .placeholder : [])
                }
                if caption.showsItalian, caption.title != nil {
                    Text(caption.entry.title)
                        .font(.footnote.italic())
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            Spacer(minLength: 4)
            if let price = caption.entry.price {
                Text(price)
                    .font(.body.monospacedDigit().weight(.medium))
                    .foregroundStyle(Color.accentWarm)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
    }
}
