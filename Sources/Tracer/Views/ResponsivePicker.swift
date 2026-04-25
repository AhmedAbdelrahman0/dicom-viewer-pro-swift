import SwiftUI

struct ResponsivePicker<Selection: Hashable, Content: View>: View {
    private let title: String
    @Binding private var selection: Selection
    private let menuBreakpoint: CGFloat
    private let height: CGFloat
    private let content: () -> Content

    init(_ title: String,
         selection: Binding<Selection>,
         menuBreakpoint: CGFloat,
         height: CGFloat = 28,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self._selection = selection
        self.menuBreakpoint = menuBreakpoint
        self.height = height
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width <= menuBreakpoint {
                Picker(title, selection: $selection) {
                    content()
                }
                .pickerStyle(.menu)
                .tint(TracerTheme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Picker(title, selection: $selection) {
                    content()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .tint(TracerTheme.accent)
            }
        }
        .frame(height: height)
    }
}
