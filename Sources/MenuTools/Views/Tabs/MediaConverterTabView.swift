import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MediaConverterTabView: View {
    @ObservedObject var converter: MediaConverterManager
    @State private var isDropTargeted: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            // Category & Preset Selector Bar
            VStack(spacing: 8) {
                // Category Picker
                HStack(spacing: 6) {
                    ForEach(MediaCategory.allCases) { category in
                        Button(action: { converter.selectedCategory = category }) {
                            HStack(spacing: 5) {
                                Image(systemName: category.icon)
                                    .font(.system(size: 11))
                                Text(category.rawValue)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(
                                        converter.selectedCategory == category
                                            ? Color.accentColor : Color.white.opacity(0.05))
                            )
                            .foregroundColor(converter.selectedCategory == category ? .white : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Specific Preset Picker
                HStack {
                    Text("Preset:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)

                    switch converter.selectedCategory {
                    case .video:
                        Picker("", selection: $converter.selectedVideoPreset) {
                            ForEach(VideoPreset.allCases) { preset in
                                Text(preset.rawValue).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)

                    case .audio:
                        Picker("", selection: $converter.selectedAudioPreset) {
                            ForEach(AudioPreset.allCases) { preset in
                                Text(preset.rawValue).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)

                    case .gif:
                        Picker("", selection: $converter.selectedGIFPreset) {
                            ForEach(GIFQualityPreset.allCases) { preset in
                                Text(preset.rawValue).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)

                    case .image:
                        Picker("", selection: $converter.selectedImagePreset) {
                            ForEach(ImagePreset.allCases) { preset in
                                Text(preset.rawValue).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                    }

                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            // Drag and Drop Zone
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.white.opacity(0.15),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(isDropTargeted ? Color.accentColor.opacity(0.1) : Color.white.opacity(0.02))
                    )

                VStack(spacing: 6) {
                    Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "square.and.arrow.down")
                        .font(.system(size: 24))
                        .foregroundColor(isDropTargeted ? .accentColor : .secondary)

                    Text("Drag & Drop media files here")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)

                    Button("or Browse Files...") {
                        selectFiles()
                    }
                    .font(.system(size: 10, weight: .medium))
                    .controlSize(.small)
                }
                .padding(.vertical, 14)
            }
            .frame(height: 100)
            .padding(.horizontal, 12)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
            }

            // Queue Header
            HStack {
                Text("CONVERSION QUEUE (\(converter.tasks.count))")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)

                Spacer()

                if !converter.tasks.isEmpty {
                    Button("Clear Completed") {
                        converter.clearCompleted()
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)

            // Queue List
            if converter.tasks.isEmpty {
                VStack(spacing: 4) {
                    Spacer()
                    Text("No active conversions")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.7))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(converter.tasks) { task in
                            MediaTaskRow(
                                task: task,
                                onRemove: {
                                    converter.removeTask(id: task.id)
                                })
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }

            // Output Folder Bar
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Text("Output:")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)

                Text(converter.outputDirectory?.lastPathComponent ?? "Downloads")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer()

                Button("Change...") {
                    chooseOutputDirectory()
                }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.03))
        }
    }

    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            converter.addFiles(panel.urls)
        }
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            converter.outputDirectory = url
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    DispatchQueue.main.async {
                        self.converter.addFiles([url])
                    }
                }
            }
        }
        return true
    }
}

struct MediaTaskRow: View {
    let task: MediaTask
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: task.category.icon)
                .font(.system(size: 13))
                .foregroundColor(.accentColor)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(task.inputURL.lastPathComponent)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(task.fileSizeFormatted)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)

                    Text("→ \(task.outputFormat)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            switch task.status {
            case .queued:
                Text("QUEUED")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(4)

            case .converting:
                ProgressView()
                    .controlSize(.small)

            case .completed(let outputURL):
                Button(action: {
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                        Text("Show")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.green)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.12))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Show converted file in Finder")

            case .failed(let error):
                Text("FAILED")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.red)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.12))
                    .cornerRadius(4)
                    .help(error)
            }

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.03))
        .cornerRadius(8)
    }
}
