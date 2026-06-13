import SwiftUI

struct AboutView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var build: String {
        let info = Bundle.main.infoDictionary
        let hash = info?["GitCommitHash"] as? String ?? "dev"
        let dirty = info?["GitIsDirty"] as? Bool ?? false
        return dirty ? "\(hash)-dirty" : hash
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image("AppIconImage")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                    Text(version)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                Text(L10n.Settings.aboutDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text(L10n.Settings.version)
                    Spacer()
                    Text(version)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(L10n.Settings.build)
                    Spacer()
                    Text(build)
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
            }

            Section {
                Link(destination: URL(string: "https://github.com/samhjn/Palvia")!) {
                    HStack {
                        Text(L10n.Settings.sourceCode)
                        Spacer()
                        Text("samhjn/Palvia")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.up.forward")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                HStack {
                    Text(L10n.Settings.license)
                    Spacer()
                    Text("MIT")
                        .foregroundStyle(.secondary)
                }
            }

            if Locale.current.language.languageCode == .chinese {
                Section {
                    Text("浙ICP备2021031153号-7A")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.Settings.about)
        .navigationBarTitleDisplayMode(.inline)
    }
}
