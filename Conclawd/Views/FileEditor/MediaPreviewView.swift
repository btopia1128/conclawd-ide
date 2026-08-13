import AVKit
import SwiftUI

/// Displays image or video files in the file editor area.
struct MediaPreviewView: View {
    @Environment(AppState.self) private var appState
    let file: OpenFile
    @State private var zoom: CGFloat = 1.0
    @State private var baseZoom: CGFloat = 1.0
    @State private var initialZoomSet = false
    @State private var imageSize: CGSize?

    var body: some View {
        VStack(spacing: 0) {
            switch file.kind {
            case .image:
                imagePreview
            case .video:
                videoPreview
            case .text:
                EmptyView()
            }

            mediaBottomBar
        }
    }

    // MARK: - Image Preview

    private var imagePreview: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                if let nsImage = NSImage(contentsOf: file.url) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            width: nsImage.size.width * zoom,
                            height: nsImage.size.height * zoom
                        )
                        .frame(
                            minWidth: geo.size.width,
                            minHeight: geo.size.height
                        )
                        .onAppear {
                            imageSize = nsImage.size
                            if !initialZoomSet {
                                let scaleW = geo.size.width / nsImage.size.width
                                let scaleH = geo.size.height / nsImage.size.height
                                zoom = min(scaleW, scaleH, 1.0)
                                baseZoom = zoom
                                initialZoomSet = true
                            }
                        }
                } else {
                    errorPlaceholder
                }
            }
            .background(checkerboardBackground)
        }
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    zoom = min(max(baseZoom * value.magnification, 0.1), 10.0)
                }
                .onEnded { _ in
                    baseZoom = zoom
                }
        )
    }

    // MARK: - Video Preview

    private var videoPreview: some View {
        VideoPlayer(player: AVPlayer(url: file.url))
            .background(Color.black)
    }

    // MARK: - Bottom Bar

    private var mediaBottomBar: some View {
        HStack(spacing: 12) {
            if let project = appState.selectedProject {
                Text(file.relativePath(from: project.directoryPath))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.appTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            } else {
                Text(file.fileName)
                    .font(.system(size: 12, weight: .medium))
            }

            Spacer()

            if let size = imageSize {
                Text("\(Int(size.width)) x \(Int(size.height))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.appTertiary)
            }

            if let fileSize = fileSizeString {
                Text(fileSize)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.appTertiary)
            }

            if file.kind == .image {
                Button {
                    zoom = max(zoom - 0.25, 0.1)
                    baseZoom = zoom
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appTertiary)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                Text("\(Int(zoom * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.appSecondary)
                    .frame(width: 40)

                Button {
                    zoom = min(zoom + 0.25, 10.0)
                    baseZoom = zoom
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appTertiary)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                Button {
                    zoom = 1.0
                    baseZoom = 1.0
                } label: {
                    Text("1:1")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.appTertiary)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            Button {
                NSWorkspace.shared.open(file.url)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appTertiary)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .themedBackground(Color.appSurface)
    }

    // MARK: - Helpers

    private var checkerboardBackground: some View {
        Canvas { context, size in
            let cellSize: CGFloat = 8
            let rows = Int(ceil(size.height / cellSize))
            let cols = Int(ceil(size.width / cellSize))
            for row in 0..<rows {
                for col in 0..<cols {
                    let isLight = (row + col) % 2 == 0
                    let rect = CGRect(
                        x: CGFloat(col) * cellSize,
                        y: CGFloat(row) * cellSize,
                        width: cellSize,
                        height: cellSize
                    )
                    context.fill(
                        Path(rect),
                        with: .color(isLight ? Color(white: 0.15) : Color(white: 0.12))
                    )
                }
            }
        }
    }

    private var errorPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(Color.appIconMuted)
            Text("Cannot preview this file")
                .font(.headline)
                .foregroundStyle(Color.appMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileSizeString: String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.url.path),
              let size = attrs[.size] as? UInt64 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
