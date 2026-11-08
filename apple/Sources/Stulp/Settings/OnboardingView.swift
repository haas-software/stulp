import StulpKit
import SwiftUI

/// The first screen: where Stulp is and its key. The same fields serve *Verbinding wijzigen* in
/// Settings (`ConnectionSheet`), so connecting reads the same both times.
struct OnboardingView: View {
    @Environment(HomeModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "house.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("Je huis, op je telefoon.")
                        .font(.largeTitle.weight(.bold))
                    Text("Stulp toont je huis, bedient je apparaten en automatiseringen, en voegt Matter-apparaten rechtstreeks aan je eigen Stulp toe.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 18) {
                    Reason(symbol: "network", title: "Je eigen Stulp",
                           text: "De app praat alleen met jouw Stulp, in huis of via je eigen https-adres. Er zit geen dienst tussen.")
                    Reason(symbol: "key.fill", title: "Met de toegangssleutel",
                           text: "De sleutel is de STULP_TOKEN waarmee Stulp draait. Hij staat alleen in de sleutelhanger van dit toestel.")
                }

                ConnectionFields { _ in }
                    .padding(20)
                    .background(.background.secondary, in: .rect(cornerRadius: 22, style: .continuous))
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(HomeBackground())
        .inlineTitle()
    }
}

private struct Reason: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Address, key and *Verbinden*. Pasting an old Manage link (`https://host/KEY`) into the address
/// splits it: the key goes to its own field, so nobody has to find it in the link.
struct ConnectionFields: View {
    @Environment(HomeModel.self) private var model
    /// Called with Stulp's version once the connection works and is saved.
    let connected: (String) -> Void

    @State private var address = ""
    @State private var key = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Verbind met Stulp").font(.headline)
            VStack(spacing: 10) {
                TextField("Adres, bijvoorbeeld stulp.local:8080", text: $address)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .submitLabel(.next)
                    .onChange(of: address) { _, new in split(new) }
                    .accessibilityIdentifier("address")
                SecureField("Toegangssleutel", text: $key)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .onSubmit { Task { await connect() } }
                    .accessibilityIdentifier("key")
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("connect-error")
            }

            Button {
                Task { await connect() }
            } label: {
                Group {
                    if working {
                        ProgressView()
                    } else {
                        Text("Verbinden")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(working || address.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("connect")

            Text("Gebruik buiten je eigen netwerk altijd https met een certificaat dat dit toestel vertrouwt.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// A pasted `https://host/KEY` (the old Manage link) becomes address plus key.
    private func split(_ text: String) {
        guard key.isEmpty, text.contains("://"),
              let parsed = try? StulpConnection.parse(address: text),
              URLComponents(string: text)?.path.count ?? 0 > 1
        else { return }
        key = parsed.accessKey
        address = parsed.baseURL.absoluteString
    }

    private func connect() async {
        error = nil
        working = true
        defer { working = false }
        do {
            let candidate = try StulpConnection.parse(address: address, key: key)
            let version = try await model.connect(candidate)
            connected(version)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// *Verbinding wijzigen*: the same fields in a sheet. The old connection stays until the new one
/// has answered.
struct ConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(HomeModel.self) private var model

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ConnectionFields { version in
                        model.notice = .init(text: "Verbonden met Stulp \(version).", isError: false)
                        dismiss()
                    }
                } footer: {
                    Text("De sleutel is de STULP_TOKEN waarmee Stulp draait.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Verbinding")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuleer") { dismiss() }
                }
            }
        }
        .macSheetSize(width: 480, height: 420)
    }
}

#Preview("Onboarding") {
    NavigationStack { OnboardingView() }.previewHouse()
}
