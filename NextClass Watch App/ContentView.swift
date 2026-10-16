// xcode: set sdk=watchOS

//
//  ContentView.swift
//  NextClass Watch App
//
//  Created by Lucas Johansson on 2026-09-18.
//

import SwiftUI
import Combine

// MARK: - Datamodell för Lektion
struct Lesson: Identifiable {
    let id = UUID()
    let title: String
    let location: String
    let startDate: Date
    let endDate: Date
    
    // Kollar om händelsen pågår just nu
    var isCurrent: Bool {
        let now = Date()
        return now >= startDate && now <= endDate
    }
    
    var timeFormatted: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "\(formatter.string(from: startDate)) - \(formatter.string(from: endDate))"
    }
    var dayFormatted: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(startDate) {
            return String(localized: "Idag")
        } else if calendar.isDateInTomorrow(startDate) {
            return String(localized: "Imorgon")
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.dateFormat = "EEEE d MMM"
            return formatter.string(from: startDate).capitalized
        }
    }
 
    
}

// MARK: - Schema Manager
@MainActor
class ScheduleManager: ObservableObject {
    @Published var lessons: [Lesson] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    var groupedLessons: [(day: String, lessons: [Lesson])] {
        let sorted = lessons.sorted { $0.startDate < $1.startDate }
        let dictionary = Dictionary(grouping: sorted) { $0.dayFormatted }
        
        var result: [(day: String, lessons: [Lesson])] = []
        for lesson in sorted {
            let day = lesson.dayFormatted
            if !result.contains(where: { $0.day == day }) {
                if let dayLessons = dictionary[day] {
                    result.append((day: day, lessons: dayLessons))
                }
            }
        }
        return result
    }
    
    func fetchSchedule(from urlString: String) {
        guard let url = URL(string: urlString), !urlString.isEmpty else {
            self.errorMessage = "Ogiltig iCal-URL"
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false
                
                if let error = error {
                    self?.errorMessage = "Nätverksfel: \(error.localizedDescription)"
                    return
                }
                
                guard let data = data, let text = String(data: data, encoding: .utf8) else {
                    self?.errorMessage = "Kunde inte läsa schemadata."
                    return
                }
                
                self?.parseICS(text)
            }
        }.resume()
    }
    
    private func parseICS(_ icsText: String) {
        let unfoldedText = icsText.replacingOccurrences(of: "\n ", with: "")
                                  .replacingOccurrences(of: "\r\n ", with: "")

        var parsedLessons: [Lesson] = []
        let events = unfoldedText.components(separatedBy: "BEGIN:VEVENT")
        
        let now = Date()
        
        for event in events.dropFirst() {
            var title = extractValue(for: "SUMMARY", in: event)
            var location = extractValue(for: "LOCATION", in: event)
            let description = extractValue(for: "DESCRIPTION", in: event)
            let startStr = extractValue(for: "DTSTART", in: event)
            let endStr = extractValue(for: "DTEND", in: event)
            
            // 1. Plats-hantering om LOCATION är tom
            if location.isEmpty {
                if description.contains("Sal:") || description.contains("Rum:") {
                    location = description
                } else if title.contains(";") || title.contains(",") {
                    let parts = title.components(separatedBy: CharacterSet(charactersIn: ";,"))
                    if parts.count > 1 {
                        title = parts[0].trimmingCharacters(in: .whitespaces)
                        location = parts[1].trimmingCharacters(in: .whitespaces)
                    }
                } else if !description.isEmpty {
                    location = description
                }
            }
            
            location = location.replacingOccurrences(of: "\\\\", with: "")
                               .replacingOccurrences(of: "\\", with: "")
                               .replacingOccurrences(of: "\n", with: " ")
                               .replacingOccurrences(of: "\r", with: " ")
                               .trimmingCharacters(in: .whitespacesAndNewlines)
            
            // 2. Rensa bort "Lektion" och onödiga tecken från titeln
            title = title.replacingOccurrences(of: "Lektion:", with: "", options: .caseInsensitive)
                         .replacingOccurrences(of: "Lektion", with: "", options: .caseInsensitive)
                         .replacingOccurrences(of: "\\\\", with: "")
                         .replacingOccurrences(of: "\\", with: "")
                         .trimmingCharacters(in: .whitespacesAndNewlines)

            // 3. Använd den universella datumtolken
            if let startDate = parseDate(startStr),
               let endDate = parseDate(endStr) {
                
                // Tillåt att pågående händelser hänger kvar lite efter start
                if endDate > now.addingTimeInterval(-1800) {
                    parsedLessons.append(Lesson(
                        title: title.isEmpty ? "Händelse" : title,
                        location: location.isEmpty ? "Ingen plats angiven" : location,
                        startDate: startDate,
                        endDate: endDate
                    ))
                }
            }
        }
        
        self.lessons = parsedLessons.sorted { $0.startDate < $1.startDate }
    }
    
    // Universell extraktor som hanterar tidszoner och parametrar före kolon
    private func extractValue(for key: String, in text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let cleanLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanLine.uppercased().hasPrefix(key.uppercased() + ":") || cleanLine.uppercased().hasPrefix(key.uppercased() + ";") {
                if let range = cleanLine.range(of: ":", options: .backwards) {
                    return String(cleanLine[range.upperBound...])
                }
            }
        }
        return ""
    }
    
    // Universell datumtolk som klarar flera olika iCal-format
    private func parseDate(_ dateStr: String) -> Date? {
        let trimmed = dateStr.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "Europe/Stockholm")
        
        if trimmed.hasSuffix("Z") {
            // Om tiderna skickas i UTC ('Z'), behåll UTC-zonen i tolken så konverterar Swift till lokal tid automatiskt
            df.timeZone = TimeZone(identifier: "UTC")
            df.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            if let date = df.date(from: trimmed) {
                return date
            }
        }
        
        // För övriga format (lokal tid)
        let formats = ["yyyyMMdd'T'HHmmss", "yyyyMMdd"]
        for format in formats {
            df.dateFormat = format
            if let date = df.date(from: trimmed) {
                return date
            }
        }
        
        return nil
    }
}

// MARK: - SwiftUI Vy
struct ContentView: View {
    @StateObject private var scheduleManager = ScheduleManager()
    
    @AppStorage("ical_url") private var icalURL: String = ""
    @State private var showSettings = false

    var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.1"
        return "v\(version)"
    }

    var body: some View {
        NavigationStack {
            Group {
                if scheduleManager.isLoading {
                    ProgressView("Hämtar schema...")
                } else if let error = scheduleManager.errorMessage {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title)
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                        Button("Försök igen") {
                            scheduleManager.fetchSchedule(from: icalURL)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if scheduleManager.lessons.isEmpty {
                    VStack(spacing: 8) {
                        Text("Inget schema inladdat.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Ange iCal-länk") {
                            showSettings = true
                        }
                    }
                } else {
                    List {
                        ForEach(scheduleManager.groupedLessons, id: \.day) { group in
                            Section(header: Text(group.day).font(.headline).foregroundColor(.cyan)) {
                                ForEach(group.lessons) { lesson in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(lesson.title)
                                                .font(.headline)
                                                .foregroundColor(lesson.isCurrent ? .green : .primary)
                                            
                                            Spacer()
                                            
                                            if lesson.isCurrent {
                                                Text("PÅGÅR")
                                                    .font(.system(size: 9, weight: .bold))
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.green)
                                                    .foregroundColor(.black)
                                                    .cornerRadius(4)
                                            }
                                        }
                                        
                                        HStack {
                                            Image(systemName: "clock")
                                            Text(lesson.timeFormatted)
                                        }
                                        .font(.caption)
                                        .foregroundColor(lesson.isCurrent ? .green.opacity(0.9) : .secondary)
                                        
                                        HStack {
                                            Image(systemName: "mappin.and.ellipse")
                                            Text(lesson.location)
                                        }
                                        .font(.caption2)
                                        .foregroundColor(lesson.isCurrent ? .green.opacity(0.8) : .secondary)
                                    }
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(lesson.isCurrent ? Color.green.opacity(0.2) : Color.white.opacity(0.12))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(lesson.isCurrent ? Color.green : Color.clear, lineWidth: 1.5)
                                    )
                                    .listRowBackground(Color.clear)
                                    .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("NextClass")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                VStack(spacing: 12) {
                    Text("Inställningar")
                        .font(.headline)
                    
                    TextField("Klistra in iCal URL", text: $icalURL)
                        .textContentType(.URL)
                    
                    Button("Spara & Hämta") {
                        showSettings = false
                        scheduleManager.fetchSchedule(from: icalURL)
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Spacer()
                    
                    Text("NextClass \(appVersion)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding()
            }
            .onAppear {
                if !icalURL.isEmpty {
                    scheduleManager.fetchSchedule(from: icalURL)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
