import SwiftUI

/// Green-on-black firmware text, shown while a session is in the
/// `.firmware` / `.bootingLoader` phases. The lines themselves come from
/// `VMSessionViewModel` (firmware checks, then `GuestOSProfile.bootSplashLines`)
/// — this view only renders them.
struct BIOSBootView: View {
    let lines: [String]
    let resolution: DisplayResolution

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                Text("SIMULATED FIRMWARE — \(resolution.label)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color.green.opacity(0.9))
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeIn(duration: 0.2), value: lines.count)
    }
}
