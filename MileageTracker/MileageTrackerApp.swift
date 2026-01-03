//
//  MileageTrackerApp.swift
//  MileageTracker
//
//  Created by Seth Permann on 1/2/26.
//

import SwiftUI
import CoreData

@main
struct MileageTrackerApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
