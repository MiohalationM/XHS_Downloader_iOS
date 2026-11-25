import SwiftUI

/// Shared visual language for the three tabs: solid content cards sit on a
/// softly tinted backdrop, and floating controls use native Liquid Glass on
/// iOS 26+ with frosted-material fallbacks on iOS 17–18. Content never becomes
/// glass; only the layer the user acts on does.
enum XHSDesign {
    static let cardRadius: CGFloat = 26
    static let tileRadius: CGFloat = 20
    static let controlRadius: CGFloat = 18
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.86)

    static func animation(_ reduceMotion: Bool, _ animation: Animation = spring) -> Animation? {
        reduceMotion ? nil : animation
    }
}

// MARK: - iOS 17+ Liquid Glass compatibility

struct XHSGlassContainer<Content: View>: View {
    var spacing: CGFloat = 8
    let content: () -> Content

    init(spacing: CGFloat = 8, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

extension View {
    @ViewBuilder
    func xhsGlass(
        tint: Color? = nil,
        prominent: Bool = false,
        interactive: Bool = false,
        darkOverlay: Bool = false
    ) -> some View {
        xhsGlass(tint: tint, prominent: prominent, interactive: interactive, darkOverlay: darkOverlay, in: Capsule())
    }

    @ViewBuilder
    func xhsGlass<S: InsettableShape>(
        tint: Color? = nil,
        prominent: Bool = false,
        interactive: Bool = false,
        darkOverlay: Bool = false,
        in shape: S
    ) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                self.glassEffect(
                    interactive ? .regular.tint(tint ?? .coral).interactive() : .regular.tint(tint ?? .coral),
                    in: shape
                )
            } else if let tint {
                self.glassEffect(
                    interactive ? .regular.tint(tint).interactive() : .regular.tint(tint),
                    in: shape
                )
            } else if darkOverlay {
                self.glassEffect(
                    interactive ? .regular.tint(Color.black.opacity(0.28)).interactive() : .regular.tint(Color.black.opacity(0.28)),
                    in: shape
                )
            } else {
                self.glassEffect(
                    interactive ? .regular.interactive() : .regular,
                    in: shape
                )
            }
        } else {
            if prominent {
                let fillStyle: AnyShapeStyle = (tint == nil || tint == .coral)
                    ? AnyShapeStyle(.coralGradient)
                    : AnyShapeStyle((tint ?? .coral).gradient)
                self
                    .background(fillStyle, in: shape)
                    .overlay {
                        shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                            .allowsHitTesting(false)
                    }
            } else if darkOverlay {
                self
                    .background {
                        ZStack {
                            shape.fill(.ultraThinMaterial)
                                .environment(\.colorScheme, .dark)
                            shape.fill(Color.black.opacity(0.45))
                        }
                    }
                    .overlay {
                        shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                            .allowsHitTesting(false)
                    }
            } else {
                self
                    .background {
                        XHSFrostedSurface(tint: tint, shape: shape)
                    }
                    .overlay {
                        XHSFrostedBorder(shape: shape)
                    }
            }
        }
    }

    @ViewBuilder
    func xhsSafeAreaBar<V: View>(edge: VerticalEdge, spacing: CGFloat = 0, @ViewBuilder content: () -> V) -> some View {
        if #available(iOS 26.0, *) {
            self.safeAreaBar(edge: edge, spacing: spacing, content: content)
        } else {
            self.safeAreaInset(edge: edge, spacing: spacing, content: content)
        }
    }

    /// Soft translucent scrim behind floating bars on iOS 17–18 (where
    /// `.safeAreaInset` lacks iOS 26's `.safeAreaBar` progressive edge blur).
    /// No-op on iOS 26+.
    @ViewBuilder
    func xhsBarBackdrop(edge: VerticalEdge) -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            self.background {
                XHSBarBackdropView(edge: edge)
                    .ignoresSafeArea(edges: edge == .top ? .top : .bottom)
            }
        }
    }

    @ViewBuilder
    func xhsSoftBottomEdgeEffect() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            self
        }
    }

    @ViewBuilder
    func xhsMatchedTransitionSource<ID: Hashable>(id: ID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }
}

private struct XHSFrostedSurface<S: InsettableShape>: View {
    let tint: Color?
    let shape: S
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                shape.fill(.thinMaterial)
                if let tint {
                    shape.fill(tint)
                } else {
                    shape.fill(Color.white.opacity(0.06))
                }
            } else if let tint {
                shape.fill(.thinMaterial)
                shape.fill(Color.white.opacity(0.32))
                shape.fill(tint)
            } else {
                shape.fill(.regularMaterial)
                shape.fill(Color.primary.opacity(0.04))
            }
        }
    }
}

private struct XHSFrostedBorder<S: InsettableShape>: View {
    let shape: S
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        shape
            .strokeBorder(
                colorScheme == .dark ? Color.white.opacity(0.15) : Color.primary.opacity(0.12),
                lineWidth: 0.5
            )
            .allowsHitTesting(false)
    }
}

private struct XHSBarBackdropView: View {
    let edge: VerticalEdge
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let base = Color(uiColor: .systemGroupedBackground)
        let strong = base.opacity(colorScheme == .dark ? 0.92 : 0.94)
        let mid = base.opacity(colorScheme == .dark ? 0.72 : 0.78)
        let clear = base.opacity(0)
        LinearGradient(
            stops: edge == .top
                ? [.init(color: strong, location: 0),
                   .init(color: mid, location: 0.72),
                   .init(color: clear, location: 1)]
                : [.init(color: clear, location: 0),
                   .init(color: mid, location: 0.28),
                   .init(color: strong, location: 1)],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }
}

extension ToolbarContent {
    @ToolbarContentBuilder
    func xhsHiddenSharedToolbarBackground() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

extension Color {
    /// A warmer partner for coral, used in gradients and the ambient backdrop.
    static let coralWarm = Color(red: 1.0, green: 0.52, blue: 0.40)
    static let coralGradientEnd = Color(red: 0.98, green: 0.36, blue: 0.48)

    static var cardBackground: Color { Color(uiColor: .secondarySystemGroupedBackground) }
}

extension ShapeStyle where Self == LinearGradient {
    static var coralGradient: LinearGradient {
        LinearGradient(colors: [.coralWarm, .coral], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Buttons

/// Gentle press-down for tappable cards and tiles. It never moves the layout
/// and is removed under Reduce Motion.
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(XHSDesign.animation(reduceMotion, XHSDesign.snappy), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

/// Leaves touch animation to native Liquid Glass on iOS 26+ while providing a
/// crisp press scale and dim highlight on iOS 17–18.
struct XHSGlassButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26.0, *) {
            configuration.label
        } else {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
                .opacity(configuration.isPressed ? 0.86 : 1)
                .animation(XHSDesign.animation(reduceMotion, XHSDesign.snappy), value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == XHSGlassButtonStyle {
    static var xhsGlass: XHSGlassButtonStyle { XHSGlassButtonStyle() }
}

/// Compact glass action used inside task cards (stop, retry, choose).
struct GlassPillButton: View {
    let title: String
    let systemImage: String
    var tint: Color? = nil
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(prominent ? Color.white : (tint ?? .primary))
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .contentShape(Capsule())
                .xhsGlass(
                    tint: prominent ? (tint ?? .coral) : tint.map { $0.opacity(0.12) },
                    prominent: prominent,
                    interactive: true,
                    in: Capsule()
                )
        }
        .buttonStyle(.xhsGlass)
    }
}

// MARK: - Chips and segmented scope

struct GlassChipItem<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var count: Int? = nil
    var accessibilityID: String? = nil
    var id: Value { value }
}

/// Horizontally scrolling glass filter chips. The selected chip turns into a
/// coral-tinted glass drop; the others stay clear so the content shows through.
struct GlassChipBar<Value: Hashable>: View {
    let items: [GlassChipItem<Value>]
    @Binding var selection: Value
    var spacing: CGFloat = 8
    var horizontalPadding: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            XHSGlassContainer(spacing: spacing) {
                HStack(spacing: spacing) {
                    ForEach(items) { item in
                        chip(item)
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 6)
            }
        }
        .scrollClipDisabled()
    }

    private func chip(_ item: GlassChipItem<Value>) -> some View {
        let selected = item.value == selection
        return Button {
            guard selection != item.value else { return }
            withAnimation(XHSDesign.animation(reduceMotion)) { selection = item.value }
        } label: {
            HStack(spacing: 6) {
                Text(item.title)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let count = item.count, count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(selected ? Color.white.opacity(0.25) : Color.coral.opacity(0.14), in: Capsule())
                        .contentTransition(.numericText(value: Double(count)))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .font(.subheadline.weight(selected ? .semibold : .medium))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .contentShape(Capsule())
            .xhsGlass(tint: selected ? .coral : nil, prominent: selected, interactive: true, in: Capsule())
        }
        .buttonStyle(.xhsGlass)
        .accessibilityIdentifier(item.accessibilityID ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Two or three mutually exclusive scopes inside one glass capsule, with a
/// solid coral thumb that slides between them.
struct GlassSegmentedScope<Value: Hashable>: View {
    let items: [GlassChipItem<Value>]
    @Binding var selection: Value
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let selected = item.value == selection
                Button {
                    guard selection != item.value else { return }
                    withAnimation(XHSDesign.animation(reduceMotion)) { selection = item.value }
                } label: {
                    Text(item.title)
                        .font(.subheadline.weight(selected ? .semibold : .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background {
                            if selected {
                                Capsule().fill(.coralGradient)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                                    .shadow(color: .coral.opacity(0.28), radius: 3, y: 1)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(item.accessibilityID ?? "")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .xhsGlass(interactive: true, in: Capsule())
    }
}

// MARK: - Icons

/// Settings-style squircle icon matching iOS corner proportions and glyph padding.
struct IconTile: View {
    let systemImage: String
    let color: Color
    var size: CGFloat = 30

    private var cornerRadius: CGFloat { size * 0.27 }

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A slim, animated capsule progress bar. Determinate values glide; the
/// gradient fill keeps a running download readable at a glance.
struct CapsuleProgressBar: View {
    let value: Double
    var tint: Color = .coral
    var height: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, proxy.size.width * min(max(value, 0), 1)))
                    .opacity(value > 0 ? 1 : 0)
            }
        }
        .frame(height: height)
        .animation(XHSDesign.animation(reduceMotion, .smooth(duration: 0.45)), value: value)
        .accessibilityElement()
        .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
    }
}

/// Centered empty state with a coral-tinted Liquid Glass emblem so empty tabs
/// and filtered lists share one visual rhythm.
struct GlassEmptyState: View {
    let title: String
    var subtitle: String? = nil
    let systemImage: String
    var tint: Color = .coral

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(tint == .coral ? AnyShapeStyle(.coralGradient) : AnyShapeStyle(tint.gradient))
                .frame(width: 76, height: 76)
                .xhsGlass(tint: tint.opacity(0.08), in: Circle())
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 36)
    }
}
