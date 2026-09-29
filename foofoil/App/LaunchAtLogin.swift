//
//  LaunchAtLogin.swift
//  foofoil
//
//  Created by tolg on 2026/9/28.
//

import Foundation
import ServiceManagement

@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        get {
            SMAppService.mainApp.status == .enabled
        }
        set {
            guard newValue != isEnabled else { return }
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Failed to update Launch at Login: %@", error.localizedDescription)
            }
        }
    }
}
