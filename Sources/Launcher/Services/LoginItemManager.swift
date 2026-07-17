import Foundation
import ServiceManagement

protocol LoginItemService {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

struct AppLoginItemService: LoginItemService {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// Stand-in used by UI tests so they never modify the machine's login items.
final class InMemoryLoginItemService: LoginItemService {
    private(set) var isEnabled = false

    func setEnabled(_ enabled: Bool) throws {
        isEnabled = enabled
    }
}
