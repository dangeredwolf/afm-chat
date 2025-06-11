//
//  ContentView.swift
//  afm-chat
//
//  Created by dangered wolf on 6/10/25.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        ChatContainerView(
            showSettings: true,
            showClearButton: true,
            navigationTitle: "AFM Chat"
        )
    }
}

#Preview {
    ContentView()
}
