//
//  ContentView.swift
//  OpenPad
//
//  Created by Cesar Fraire on 17/02/26.
//

import SwiftUI

/// Backwards-compatible root view for previews and any leftover references.
/// The real app window still launches ChatView via OpenClawPadApp.
struct ContentView: View {
    var body: some View {
        ChatView()
    }
}

#Preview {
    ContentView()
}
