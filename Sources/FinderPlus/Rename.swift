import SwiftUI

/// The rows the Rename sheet was opened for.
struct RenameRequest: Identifiable {
    let id = UUID()
    let hits: [FileHit]
}

/// One file's rename, planned in the sheet and carried out by `SearchModel.rename`.
struct RenameStep: Sendable {
    let source: URL
    let target: URL
}

/// The naming rules behind the Rename sheet, and the checks every planned name must pass — out of
/// the view, so they are testable.
enum BatchRename {
    enum Action: String, CaseIterable, Identifiable {
        case replaceText, sequence, changeCase, addDate

        var id: Self { self }

        var title: String {
            switch self {
            case .replaceText: "Replace Text"
            case .sequence: "Name and Number"
            case .changeCase: "Change Case"
            case .addDate: "Add Date"
            }
        }
    }

    enum CaseStyle: String, CaseIterable, Identifiable {
        case lowercase, uppercase, capitalized

        var id: Self { self }

        var title: String {
            switch self {
            case .lowercase: "lowercase"
            case .uppercase: "UPPERCASE"
            case .capitalized: "Capitalized"
            }
        }
    }

    enum DatePosition: String, CaseIterable, Identifiable {
        case before, after

        var id: Self { self }

        var title: String {
            switch self {
            case .before: "Before the name"
            case .after: "After the name"
            }
        }
    }

    /// Everything the sheet's fields choose. `newName` applies whichever rule `action` picks.
    struct Recipe: Equatable {
        var action: Action = .replaceText
        var find = ""
        var replacement = ""
        /// The stem for Name and Number; empty keeps each file's own name.
        var base = ""
        var start = 1
        var caseStyle: CaseStyle = .lowercase
        var datePosition: DatePosition = .before

        /// `index` is the row's position in the batch, for numbering. The extension stays put in
        /// every rule but Replace Text, which works on the whole name the way Finder's does. A
        /// folder has no extension: the dot in "v1.0" is part of its name.
        func newName(for name: String, at index: Int, on date: Date = .now, isFolder: Bool = false) -> String {
            let stem = isFolder ? name : (name as NSString).deletingPathExtension
            let ext = isFolder ? "" : (name as NSString).pathExtension
            func withExtension(_ stem: String) -> String { ext.isEmpty ? stem : stem + "." + ext }
            switch action {
            case .replaceText:
                guard !find.isEmpty else { return name }
                return name.replacingOccurrences(of: find, with: replacement)
            case .sequence:
                let base = base.trimmingCharacters(in: .whitespaces)
                return withExtension("\(base.isEmpty ? stem : base) \(start + index)")
            case .changeCase:
                let changed = switch caseStyle {
                case .lowercase: stem.lowercased()
                case .uppercase: stem.uppercased()
                case .capitalized: stem.capitalized
                }
                return withExtension(changed)
            case .addDate:
                // The local calendar's date, not UTC's: past 8 pm here, .iso8601's default (GMT)
                // would already stamp tomorrow.
                let day = date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
                return datePosition == .before ? day + " " + name : withExtension(stem + " " + day)
            }
        }
    }

    /// Why a proposed name can never be used, or nil for a usable one.
    static func problem(with name: String) -> String? {
        if name.isEmpty { return "The name is empty" }
        if name == "." || name == ".." { return "That name is reserved" }
        if name.contains("/") || name.contains(":") { return "Names can’t contain “/” or “:”" }
        if name.utf8.count > 255 { return "That name is too long" }
        return nil
    }

    /// One row of the preview: the file, the name it would get, and what stops it, if anything.
    struct PlannedName: Identifiable {
        let hit: FileHit
        let name: String
        let problem: String?
        var id: FileHit.ID { hit.id }
        var changes: Bool { name != hit.name }
    }

    /// Every row's new name, checked against the others and the disk — a duplicate inside the
    /// batch, a file that already carries the name, or a row inside a folder the same batch
    /// renames all disable the Rename button rather than failing halfway through. Paths are
    /// compared lowercased: APFS is case-insensitive by default, so "a.txt" and "A.txt" are one
    /// name there. A row keeping its name is never checked — it is not being renamed.
    static func plan(_ hits: [FileHit], recipe: Recipe, on date: Date = .now) -> [PlannedName] {
        let names = hits.enumerated().map { index, hit in
            (hit: hit, name: recipe.newName(for: hit.name, at: index, on: date, isFolder: hit.isFolder))
        }
        var counts: [String: Int] = [:]
        for (hit, name) in names {
            counts[hit.url.deletingLastPathComponent().appending(path: name).path.lowercased(), default: 0] += 1
        }
        // Sources that will move: parked first by performRename, so their old names are free.
        let vacated = Set(names.filter { $0.name != $0.hit.name }.map { $0.hit.url.path.lowercased() })
        // A lookup per ancestor rather than a prefix test against every vacated path, which was
        // quadratic: seconds per keystroke at 10,000 rows.
        func insideVacated(_ path: String) -> Bool {
            var ancestor = (path.lowercased() as NSString).deletingLastPathComponent
            while !ancestor.isEmpty, ancestor != "/" {
                if vacated.contains(ancestor) { return true }
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
            return false
        }
        return names.map { hit, name in
            guard name != hit.name else { return PlannedName(hit: hit, name: name, problem: nil) }
            var problem = Self.problem(with: name)
            if problem == nil {
                let target = hit.url.deletingLastPathComponent().appending(path: name).path
                if counts[target.lowercased(), default: 0] > 1 {
                    problem = "Two items would get this name"
                } else if insideVacated(hit.url.path) {
                    problem = "Inside a folder that is also being renamed"
                } else if SearchModel.isLocked(hit.url) {
                    problem = "File is locked"
                } else if !vacated.contains(target.lowercased()), target.lowercased() != hit.url.path.lowercased(),
                          FileManager.default.fileExists(atPath: target)
                {
                    problem = "A file with this name already exists"
                }
            }
            return PlannedName(hit: hit, name: name, problem: problem)
        }
    }
}

/// Finder-style batch rename for the selected results: replace text, name-and-number, change case
/// or add the date, with every outcome shown — and checked — before anything is touched.
struct RenameSheet: View {
    @Environment(SearchModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let hits: [FileHit]

    @State private var recipe = BatchRename.Recipe()
    /// The plan for the current recipe, rebuilt only when the recipe changes: it checks the disk
    /// for every row, which on every keystroke froze the sheet for large selections.
    @State private var planned: [BatchRename.PlannedName] = []
    /// The first field of the mode showing one, so the sheet takes typing the moment it opens.
    @FocusState private var typingFocused: Bool

    var body: some View {
        let plan = planned
        VStack(alignment: .leading, spacing: 14) {
            Text(hits.count == 1 ? "Rename “\(hits[0].name)”" : "Rename \(hits.count) Items")
                .font(.headline)

            Picker("Rename using", selection: $recipe.action) {
                ForEach(BatchRename.Action.allCases) { Text($0.title).tag($0) }
            }
            fields

            preview(plan)

            HStack {
                if let problem = plan.compactMap(\.problem).first {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Rename") { apply(plan) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.contains { $0.problem != nil } || !plan.contains(where: \.changes))
            }
        }
        .padding(20)
        .frame(width: 480)
        .defaultFocus($typingFocused, true)
        .onChange(of: recipe.action) { typingFocused = true }
        .onChange(of: recipe, initial: true) { planned = BatchRename.plan(hits, recipe: recipe) }
    }

    @ViewBuilder private var fields: some View {
        switch recipe.action {
        case .replaceText:
            HStack(spacing: 8) {
                TextField("Find", text: $recipe.find, prompt: Text("Find"))
                    .focused($typingFocused)
                Image(systemName: "arrow.forward").foregroundStyle(.secondary)
                TextField("Replace with", text: $recipe.replacement, prompt: Text("Replace with"))
            }
            .labelsHidden()
        case .sequence:
            HStack(spacing: 12) {
                TextField("Name", text: $recipe.base, prompt: Text("Keep each name"))
                    .focused($typingFocused)
                Stepper("Start at \(recipe.start)", value: $recipe.start, in: 0...9999)
                    .fixedSize()
            }
        case .changeCase:
            Picker("Case", selection: $recipe.caseStyle) {
                ForEach(BatchRename.CaseStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        case .addDate:
            Picker("Position", selection: $recipe.datePosition) {
                ForEach(BatchRename.DatePosition.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private func preview(_ plan: [BatchRename.PlannedName]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(plan) { planned in
                    HStack(spacing: 6) {
                        Text(planned.hit.name).foregroundStyle(.secondary)
                        Image(systemName: "arrow.forward").font(.caption2).foregroundStyle(.tertiary)
                        Text(planned.name).fontWeight(planned.changes ? .medium : .regular)
                        if let problem = planned.problem {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help(problem)
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 170)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func apply(_ plan: [BatchRename.PlannedName]) {
        let steps = plan.filter(\.changes).map {
            RenameStep(
                source: $0.hit.url,
                target: $0.hit.url.deletingLastPathComponent().appending(path: $0.name))
        }
        dismiss()
        Task { await model.rename(steps) }
    }
}
