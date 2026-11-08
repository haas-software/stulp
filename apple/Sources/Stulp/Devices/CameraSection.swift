import StulpKit
import SwiftUI

/// A camera's still and its streams. The still refreshes on its own; each video slot opens the live
/// view.
struct CameraSection: View {
    @Environment(HomeModel.self) private var model
    let device: Device
    @State private var media: [MediaSource] = []
    @State private var live: MediaSource?

    var body: some View {
        Section {
            CameraStill(device: device, refresh: .seconds(5))
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if let first = media.first(where: \.isVideo) {
                        Button("Live", systemImage: "play.fill") { live = first }
                            .buttonStyle(.glassProminent)
                            .padding(10)
                    }
                }
                .contentShape(.rect)
                .onTapGesture { if let first = media.first(where: \.isVideo) { live = first } }
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                .accessibilityLabel("Camerabeeld van \(device.name)")
            let videos = media.filter(\.isVideo)
            if videos.count > 1 {
                ForEach(videos) { source in
                    Button {
                        live = source
                    } label: {
                        Label(source.title ?? source.slot, systemImage: "video")
                    }
                }
            }
        }
        .task(id: device.id) {
            guard let client = model.client else { return }
            media = (try? await client.media(device.id)) ?? []
        }
        #if os(iOS)
        .fullScreenCover(item: $live) { source in
            LiveCameraView(device: device, source: source)
                .environment(model)
        }
        #else
        .sheet(item: $live) { source in
            LiveCameraView(device: device, source: source)
                .environment(model)
                .frame(minWidth: 720, idealWidth: 960, minHeight: 460, idealHeight: 600)
        }
        #endif
    }
}

/// The live view: black, the stream filling the screen, the name and a close button on glass.
struct LiveCameraView: View {
    @Environment(HomeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let device: Device
    let source: MediaSource

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if let client = model.client {
                LivePlayer(client: client, path: client.mediaPath(device: device.id, slot: source.slot, kind: "video"))
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView("Geen verbinding", systemImage: "video.slash.fill")
                    .foregroundStyle(.white)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.headline)
                    if let title = source.title, title != device.name {
                        Text(title).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                Spacer()
                Button("Sluit", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            .environment(\.colorScheme, .dark)
        }
    }
}
