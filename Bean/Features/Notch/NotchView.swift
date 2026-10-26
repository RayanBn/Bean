import SwiftUI

struct NotchView: View {
    @ObservedObject var model: NotchModel
    let notchSize: CGSize
    let hasNotch: Bool
    let onTap: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            shape.fill(.black)
            if model.state == .expanded {
                expanded
            } else {
                rest
            }
        }
        .contentShape(shape)
        .onTapGesture(perform: onTap)
    }

    private var shape: UnevenRoundedRectangle {
        let bottom: CGFloat = model.state == .expanded ? 22 : 10
        let top: CGFloat = hasNotch ? 0 : 10
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous)
    }

    private var rest: some View {
        HStack {
            Spacer()
            Circle().fill(.green.opacity(0.85)).frame(width: 5, height: 5)
                .padding(.trailing, hasNotch ? 5 : 12)
        }
        .frame(height: notchSize.height)
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bean").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            Text(model.message).font(.system(size: 15)).foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .padding(.top, notchSize.height + 6)
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
