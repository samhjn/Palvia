import SwiftUI

struct FunctionCallView: View {
    let toolCalls: [LLMToolCall]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(toolCalls, id: \.id) { call in
                VStack(alignment: .leading, spacing: 4) {
                    Label(call.function.name, systemImage: "gearshape.2")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.orange)

                    Text(call.function.arguments)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.1))
                )
            }
        }
    }
}
