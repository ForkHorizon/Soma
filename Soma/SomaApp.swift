//
//  SomaApp.swift
//  Soma
//
//  Created by Кирилл Щербо on 18/04/2026.
//

import SwiftUI

@main
struct SomaApp: App {
    @StateObject private var viewModel = SomaViewModel()
    
    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
    }
}
