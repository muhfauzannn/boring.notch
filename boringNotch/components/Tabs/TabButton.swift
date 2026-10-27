//
//  TabButton.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-24.
//

import SwiftUI

struct TabButton<Accessory: View>: View {
    let label: String
    let icon: String
    let selected: Bool
    let onClick: () -> Void
    /// Optional content after the icon, like the Focus tab's countdown.
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                accessory()
            }
            .padding(.horizontal, 15)
            .contentShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

extension TabButton where Accessory == EmptyView {
    init(label: String, icon: String, selected: Bool, onClick: @escaping () -> Void) {
        self.init(label: label, icon: icon, selected: selected, onClick: onClick) { EmptyView() }
    }
}

#Preview {
    TabButton(label: "Home", icon: "tray.fill", selected: true) {
        print("Tapped")
    }
}
