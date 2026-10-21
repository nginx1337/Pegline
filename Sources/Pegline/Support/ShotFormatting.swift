import Foundation
import PeglineCore

enum ShotFormatting {
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM, HH:mm"
        return f
    }()

    /// "только что", "5 мин назад", "сегодня в 15:12", "вчера в 09:03", "3 окт., 18:40".
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "только что" }
        if seconds < 3600 { return "\(Int(seconds / 60)) мин назад" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "сегодня в \(time.string(from: date))" }
        if calendar.isDateInYesterday(date) { return "вчера в \(time.string(from: date))" }
        return day.string(from: date)
    }

    static func caption(_ record: ShotRecord) -> String {
        let source = record.origin == "clipboard" ? " · из буфера" : ""
        return "\(relative(record.addedAt)) · \(record.pixelWidth)×\(record.pixelHeight)\(source)"
    }

    static func abbreviatedPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}
