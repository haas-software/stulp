import StulpKit
import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
}
#else
import UIKit
typealias PlatformImage = UIImage
extension Image {
    init(platformImage: UIImage) { self.init(uiImage: platformImage) }
}
#endif

/// Cameras as Home shows them: a row of stills, each opening the camera's live view.
struct CameraStrip: View {
    @Environment(HomeModel.self) private var model
    let cameras: [Device]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(cameras) { camera in
                    Button {
                        model.openDevice = camera.id
                    } label: {
                        CameraStill(device: camera)
                            .frame(width: 260, height: 146)
                            .clipShape(.rect(cornerRadius: 20, style: .continuous))
                            .overlay(alignment: .bottomLeading) {
                                Text(camera.name)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .shadow(radius: 3)
                                    .padding(10)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Camera \(camera.name)")
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }
}

/// A camera's still, fetched with the key and refreshed every ten seconds while it is on screen.
/// The first image slot the plugin registered is the one shown.
struct CameraStill: View {
    @Environment(HomeModel.self) private var model
    let device: Device
    var refresh: Duration = .seconds(10)
    @State private var image: PlatformImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: failed ? "video.slash.fill" : "video.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: device.id) { await load() }
    }

    private func load() async {
        guard let client = model.client else { return }
        guard let slot = try? await client.media(device.id).first(where: { !$0.isVideo })?.slot else {
            failed = true
            return
        }
        while !Task.isCancelled {
            if let data = try? await client.still(device: device.id, slot: slot), let decoded = PlatformImage(data: data) {
                withAnimation { image = decoded }
                failed = false
            } else if image == nil {
                failed = true
            }
            try? await Task.sleep(for: refresh)
        }
    }
}
