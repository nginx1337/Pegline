import ServiceManagement

/// "Open at login" through the system Login Items list (visible in System Settings).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                if needsApproval {
                    SMAppService.openSystemSettingsLoginItems()
                    return "Разрешите запуск Pegline в Системных настройках → Основные → Объекты входа."
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            Log.system.error("Login item: \(error.localizedDescription, privacy: .public)")
            return "Не удалось изменить автозапуск: \(error.localizedDescription)"
        }
    }
}
