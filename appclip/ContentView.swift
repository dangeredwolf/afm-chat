//
//  ContentView.swift
//  appclip
//
//  Created by dangered wolf on 6/11/25.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationView {
            ChatView(
                showSettings: true,
                showClearButton: true,
                navigationTitle: "AFM Chat"
            )
        }
    }
}

#Preview {
    ContentView()
}
