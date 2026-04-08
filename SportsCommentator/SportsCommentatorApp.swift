//
//  SportsCommentatorApp.swift
//  SportsCommentator
//
//  Created by Zacary Brown on 4/7/26.
//

import SwiftUI

@main
struct SportsCommentatorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: PipelineViewModel())
        }
    }
}
