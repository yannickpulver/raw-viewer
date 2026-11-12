import AppKit
import SwiftUI

/// The app's Settings window (⌘,). One section for now: rating on the phone.
struct SettingsView: View {
    let remote: RemoteRating

    var body: some View {
        Form {
            Section {
                Toggle("Rate on Phone", isOn: Binding(get: { remote.isEnabled },
                                                      set: { remote.setEnabled($0) }))
                status
            } footer: {
                Text("Open the address on a phone or tablet in your Tailscale network to rate your recent folders there. Only devices in your tailnet can reach it. The Mac stays awake while this is on.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var status: some View {
        switch remote.status {
        case .off:
            EmptyView()
        case .starting:
            LabeledContent("Status", value: "Starting…")
        case .failed(let reason):
            LabeledContent("Status") {
                HStack {
                    Text(reason).foregroundStyle(.secondary)
                    Button("Try Again") { remote.setEnabled(true) }
                }
            }
        case .running(let url):
            LabeledContent("Address") {
                HStack(spacing: 6) {
                    Text(url.absoluteString)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy")
                }
            }
            if let qr = QRCode.image(for: url.absoluteString) {
                HStack {
                    Spacer()
                    Image(decorative: qr, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 160, height: 160)
                        .padding(10)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                }
            }
        }
    }
}
