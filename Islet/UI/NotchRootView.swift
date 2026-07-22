import SwiftUI

struct NotchRootView: View {
  @ObservedObject var vm: NotchViewModel

  private var radii: (top: CGFloat, bottom: CGFloat) {
    vm.state.isExpanded ? Metrics.expandedRadii : Metrics.closedRadii
  }

  /// Size of the black shape body, EXCLUDING the top-flare ears.
  private var bodySize: CGSize {
    let notch = vm.geometry.notchSize
    switch vm.state {
    case .closed:
      return CGSize(
        width: notch.width + Metrics.closedOversize * 2,
        height: notch.height + Metrics.closedOversize)
    case .peek:
      return CGSize(
        width: notch.width + Metrics.closedOversize * 2,
        height: notch.height + Metrics.peekGrowth)
    case .expanded:
      return Metrics.expandedSize
    }
  }

  var body: some View {
    ZStack(alignment: .top) {
      content
        .frame(width: bodySize.width, height: bodySize.height, alignment: .top)
        .background { Rectangle().fill(.black).padding(-50) }
        .mask {
          NotchShape(topRadius: radii.top, bottomRadius: radii.bottom)
            .frame(
              width: bodySize.width + radii.top * 2,
              height: bodySize.height
            )
            .padding(.horizontal, -0.5)
        }
        .shadow(color: .black.opacity(vm.state.isExpanded ? 0.8 : 0), radius: 16)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .animation(vm.state.isExpanded ? Metrics.opening : Metrics.closing, value: vm.state)
    .preferredColorScheme(.dark)
    .allowsHitTesting(false)  // M1: interaction is monitor-driven; content stays passive
  }

  @ViewBuilder private var content: some View {
    if vm.state.isExpanded {
      VStack {
        Spacer().frame(height: vm.geometry.notchSize.height)
        Text("Islet")
          .font(.system(.title2, design: .rounded).weight(.bold))
          .foregroundStyle(.white)
        Spacer()
      }
      .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .top)))
    } else {
      Color.clear
    }
  }
}
