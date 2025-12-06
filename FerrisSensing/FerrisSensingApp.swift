//
//  FerrisSensingApp.swift
//  FerrisSensing
//
//  Created by 加藤風真 on 2025/11/20.
//

import SwiftUI

@main
struct FerrisSensingApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    testBarometerFilterOffline()
                }
        }
    }
}
