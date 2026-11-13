import SwiftUI

/// Popover with everything about one event.
struct EventDetailView: View {
    let event: CalendarEventItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(event.color).frame(width: 10, height: 10).padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title).font(.system(size: 15, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                    if !event.calendarName.isEmpty {
                        Text(event.calendarName).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            Label(event.timeRangeText(), systemImage: "clock").font(.system(size: 12))
            if let location = event.location, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse").font(.system(size: 12)).lineLimit(2)
            }
            if let notes = event.shortNotes {
                Text(notes).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(5)
            }
            HStack(spacing: 8) {
                if let url = event.joinURL {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Label("Entrar", systemImage: "video.fill").font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7).background(NJP.accent, in: Capsule())
                    }
                }
                Button {
                    if let url = URL(string: "calshow:\(event.start.timeIntervalSinceReferenceDate)") { NSWorkspace.shared.open(url) }
                } label: {
                    Label(AppLanguage.text("Abrir no Calendário"), systemImage: "calendar").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7).background(NJP.surfaceStrong, in: Capsule())
                }
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .preferredColorScheme(.dark)
    }
}

/// Popover listing every event of a busy day.
struct DayEventsListView: View {
    let day: Date
    let events: [CalendarEventItem]
    let onSelect: (CalendarEventItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "pt_BR"))).capitalizedFirst)
                .font(.system(size: 13, weight: .bold)).padding(.bottom, 2)
            ForEach(events) { event in
                Button { onSelect(event) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(event.color).frame(width: 8, height: 8)
                        Text(event.isAllDay ? AppLanguage.text("Dia todo") : event.start.formatted(.dateTime.hour().minute().locale(Locale(identifier: "pt_BR"))))
                            .font(.system(size: 11, weight: .bold)).frame(width: 52, alignment: .leading)
                        Text(event.title).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 0)
                        if event.joinURL != nil { Image(systemName: "video.fill").font(.system(size: 10)).foregroundStyle(NJP.accentSoft) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(NJP.surface, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .preferredColorScheme(.dark)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
