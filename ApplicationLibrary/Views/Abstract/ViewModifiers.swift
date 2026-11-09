import SwiftUI
#if os(macOS)
    import AppKit
#endif

#if os(macOS)
    /// A freshly presented sheet is not always made key, so keys keep going to the
    /// window behind it until the user clicks inside the sheet.
    public struct SheetKeyWindowFix: NSViewRepresentable {
        public init() {}

        public func makeNSView(context _: Context) -> NSView {
            KeyWindowView()
        }

        public func updateNSView(_: NSView, context _: Context) {}
    }

    private final class KeyWindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.makeKey()
            if window.firstResponder == nil || window.firstResponder === window {
                window.makeFirstResponder(window.initialFirstResponder)
            }
        }
    }
#endif

public struct PlatformSheetSize {
    let minWidth: CGFloat
    let minHeight: CGFloat

    public init(minWidth: CGFloat, minHeight: CGFloat) {
        self.minWidth = minWidth
        self.minHeight = minHeight
    }

    public static let `default` = PlatformSheetSize(minWidth: 500, minHeight: 400)
    public static let small = PlatformSheetSize(minWidth: 400, minHeight: 300)
}

public extension View {
    func platformSheet(
        isPresented: Binding<Bool>,
        size: PlatformSheetSize = .default,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        modifier(PlatformSheetModifier(isPresented: isPresented, size: size, onDismiss: onDismiss, content: content))
    }

    func platformSheet<Item: Identifiable>(
        item: Binding<Item?>,
        size: PlatformSheetSize = .default,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> some View
    ) -> some View {
        modifier(PlatformSheetItemModifier(item: item, size: size, onDismiss: onDismiss, content: content))
    }
}

private struct PlatformSheetModifier<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let size: PlatformSheetSize
    let onDismiss: (() -> Void)?
    @ViewBuilder let content: () -> SheetContent

    func body(content: Content) -> some View {
        #if os(iOS)
            content.sheet(isPresented: $isPresented, onDismiss: onDismiss) {
                NavigationStackCompat {
                    self.content()
                }
            }
        #elseif os(macOS)
            content.sheet(isPresented: $isPresented, onDismiss: onDismiss) {
                NavigationStackCompat {
                    self.content()
                }
                .frame(minWidth: size.minWidth, minHeight: size.minHeight)
                .background(SheetKeyWindowFix())
            }
        #elseif os(tvOS)
            content.fullScreenCover(isPresented: $isPresented, onDismiss: onDismiss) {
                NavigationStackCompat {
                    self.content()
                }
            }
        #endif
    }
}

private struct PlatformSheetItemModifier<Item: Identifiable, SheetContent: View>: ViewModifier {
    @Binding var item: Item?
    let size: PlatformSheetSize
    let onDismiss: (() -> Void)?
    @ViewBuilder let content: (Item) -> SheetContent

    func body(content: Content) -> some View {
        #if os(iOS)
            content.sheet(item: $item, onDismiss: onDismiss) { item in
                NavigationStackCompat {
                    self.content(item)
                }
            }
        #elseif os(macOS)
            content.sheet(item: $item, onDismiss: onDismiss) { item in
                NavigationStackCompat {
                    self.content(item)
                }
                .frame(minWidth: size.minWidth, minHeight: size.minHeight)
                .background(SheetKeyWindowFix())
            }
        #elseif os(tvOS)
            content.fullScreenCover(item: $item, onDismiss: onDismiss) { item in
                NavigationStackCompat {
                    self.content(item)
                }
            }
        #endif
    }
}

public extension View {
    @ViewBuilder
    func presentationDetentsIfAvailable() -> some View {
        #if os(iOS) || os(tvOS)
            if #available(iOS 16.0, tvOS 17.0, *) {
                presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            } else {
                self
            }
        #else
            self
        #endif
    }

    #if os(iOS) || os(tvOS)
        @available(iOS 16.0, tvOS 17.0, *)
        @ViewBuilder
        func presentationDetentsIfAvailable(_ detents: PresentationDetent...) -> some View {
            let detentSet: Set<PresentationDetent> = detents.isEmpty ? [.large] : Set(detents)
            presentationDetents(detentSet)
                .presentationDragIndicator(.visible)
        }
    #endif

    @ViewBuilder
    func actionButtonStyle() -> some View {
        #if os(tvOS)
            buttonStyle(ActionButtonStyle())
        #else
            frame(width: 44, height: 32)
                .glassInteractive(cornerRadius: 8)
        #endif
    }
}

#if os(tvOS)
    /// The frame has to be applied to the label rather than to the button: the focus engine
    /// takes each button's focus region from the button's own layout frame, so sizing from the
    /// outside leaves the region at the glyph's size while the pill drawn around it is 70x48.
    private struct ActionButtonStyle: ButtonStyle {
        @Environment(\.isFocused) private var isFocused

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .frame(width: 70, height: 48)
                .contentShape(Rectangle())
                .foregroundStyle(isFocused ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
                .background(isFocused ? Color.white : Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
        }
    }
#endif

public struct ActionIconButton: View {
    let systemImage: String
    let action: () -> Void

    public init(_ systemImage: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
            #if !os(tvOS)
                .frame(width: 44, height: 32)
                .glassInteractive(cornerRadius: 8)
            #endif
                .contentShape(Rectangle())
        }
        #if os(tvOS)
        .actionButtonStyle()
        #else
        .buttonStyle(.plain)
        #endif
    }
}

// MARK: - Liquid Glass surfaces

public extension View {
    /// Every trailing title-bar control must share these metrics, otherwise pages with
    /// buttons get a taller title bar than pages without. The plain style also drops the
    /// hover background the default macOS toolbar button draws.
    @ViewBuilder
    func toolbarIconStyle() -> some View {
        #if os(macOS)
            labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .foregroundStyle(.secondary)
                // macOS pads a toolbar item to a 36pt minimum height but only ~3pt
                // horizontally, so the content box must be wider than it is tall for the
                // drawn pill to come out square.
                .frame(width: 36, height: 22)
                .contentShape(Rectangle())
        #else
            self
        #endif
    }

    /// A glass panel/card surface (non-interactive).
    func glassSurface(cornerRadius: CGFloat = 16, tint: Color? = nil) -> some View {
        modifier(GlassAppearance(cornerRadius: cornerRadius, tint: tint, interactive: false))
    }

    /// A glass surface for interactive controls (icon buttons, fields, pickers).
    func glassInteractive(cornerRadius: CGFloat = 12, tint: Color? = nil) -> some View {
        modifier(GlassAppearance(cornerRadius: cornerRadius, tint: tint, interactive: true))
    }

    /// Full-bleed glass bar for toolbars and footers.
    func glassBar() -> some View {
        modifier(GlassAppearance(cornerRadius: 0, tint: nil, interactive: false))
    }

    /// Lets the system batch nearby glass surfaces without merging their shapes.
    @ViewBuilder
    func glassEffectContainer(spacing: CGFloat? = nil) -> some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    /// A grouped macOS form draws an unfocused text field with no bezel, so the field
    /// stays invisible until the pointer lands on it.
    @ViewBuilder
    func visibleTextField() -> some View {
        #if os(macOS)
            textFieldStyle(.roundedBorder)
        #else
            self
        #endif
    }

    @ViewBuilder
    func visibleTextEditor() -> some View {
        #if os(macOS)
            padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1))
        #else
            self
        #endif
    }
}

private struct GlassAppearance: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
            content.glassEffect(makeGlass(), in: .rect(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fallbackFill)
            )
        }
    }

    @available(iOS 26.0, macOS 26.0, tvOS 26.0, *)
    private func makeGlass() -> Glass {
        var base: Glass = tint.map { Glass.regular.tint($0) } ?? Glass.regular
        if interactive {
            base = base.interactive()
        }
        return base
    }

    private var fallbackFill: Color {
        tint?.opacity(0.14) ?? Color.secondary.opacity(0.10)
    }
}

public extension View {
    func cardStyle() -> some View {
        modifier(CardStyleModifier())
    }
}

private struct CardStyleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            content
                .background(backgroundColor)
                .cornerRadius(16)
        }
    }

    private var backgroundColor: Color {
        #if os(iOS)
            return Color(uiColor: .secondarySystemGroupedBackground)
        #elseif os(macOS)
            return Color(nsColor: .textBackgroundColor)
        #elseif os(tvOS)
            switch colorScheme {
            case .dark:
                return Color(uiColor: .black)
            default:
                return Color(uiColor: .white)
            }
        #else
            return Color.clear
        #endif
    }
}
