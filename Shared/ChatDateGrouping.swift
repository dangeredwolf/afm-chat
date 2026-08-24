//
//  ChatDateGrouping.swift
//  Shared
//

import Foundation

enum ChatDateGroup: Hashable, Comparable {
    case today
    case yesterday
    case previous7Days
    case previous30Days
    case month(year: Int, month: Int)

    var title: String {
        switch self {
        case .today:
            return "Today"
        case .yesterday:
            return "Yesterday"
        case .previous7Days:
            return "Previous 7 Days"
        case .previous30Days:
            return "Previous 30 Days"
        case .month(let year, let month):
            let formatter = DateFormatter()
            formatter.dateFormat = "MMMM yyyy"
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = 1
            guard let date = Calendar.current.date(from: components) else {
                return "\(month)/\(year)"
            }
            return formatter.string(from: date)
        }
    }

    private var sortOrder: Int {
        switch self {
        case .today: return 0
        case .yesterday: return 1
        case .previous7Days: return 2
        case .previous30Days: return 3
        case .month: return 4
        }
    }

    static func < (lhs: ChatDateGroup, rhs: ChatDateGroup) -> Bool {
        if lhs.sortOrder != rhs.sortOrder {
            return lhs.sortOrder < rhs.sortOrder
        }
        if case .month(let ly, let lm) = lhs, case .month(let ry, let rm) = rhs {
            if ly != ry { return ly > ry }
            return lm > rm
        }
        return false
    }
}

enum ChatListSectionID: Hashable {
    case dateGroup(ChatDateGroup)
    case searchResults
}

struct ChatListSection: Identifiable {
    let id: ChatListSectionID
    let title: String
    let chats: [Chat]
}

func chatsSortedByActivity(_ chats: [Chat]) -> [Chat] {
    chats.sorted { $0.lastActivityDate > $1.lastActivityDate }
}

func groupedChats(_ chats: [Chat]) -> [ChatListSection] {
    let calendar = Calendar.current
    let now = Date()
    let startOfToday = calendar.startOfDay(for: now)
    let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
    let startOf7DaysAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday)!
    let startOf30DaysAgo = calendar.date(byAdding: .day, value: -30, to: startOfToday)!

    var buckets: [ChatDateGroup: [Chat]] = [:]

    for chat in chats {
        let activityDate = chat.lastActivityDate
        let startOfActivityDay = calendar.startOfDay(for: activityDate)

        let group: ChatDateGroup
        if startOfActivityDay >= startOfToday {
            group = .today
        } else if startOfActivityDay >= startOfYesterday {
            group = .yesterday
        } else if startOfActivityDay >= startOf7DaysAgo {
            group = .previous7Days
        } else if startOfActivityDay >= startOf30DaysAgo {
            group = .previous30Days
        } else {
            let components = calendar.dateComponents([.year, .month], from: activityDate)
            group = .month(year: components.year ?? 0, month: components.month ?? 0)
        }

        buckets[group, default: []].append(chat)
    }

    return buckets
        .sorted { $0.key < $1.key }
        .map { group, chats in
            let sortedChats = chats.sorted { $0.lastActivityDate > $1.lastActivityDate }
            return ChatListSection(id: .dateGroup(group), title: group.title, chats: sortedChats)
        }
}
