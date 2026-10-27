import SwiftUI

@main
struct PocketTestApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @AppStorage("tapCount") private var tapCount = 0
    @State private var showResetConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.blue)
                        .padding(.top, 32)

                    VStack(spacing: 8) {
                        Text("原生 App，跑起来了")
                            .font(.title2.bold())
                        Text("点几下，再关闭并重新打开 App。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 12) {
                        Text("已点击")
                            .foregroundStyle(.secondary)
                        Text(tapCount.formatted())
                            .font(.system(size: 72, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .minimumScaleFactor(0.4)
                            .lineLimit(1)
                            .accessibilityIdentifier("tapCount")
                        Button {
                            if tapCount < Int.max {
                                tapCount += 1
                            }
                        } label: {
                            Label("点我 +1", systemImage: "plus.circle.fill")
                                .font(.title3.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("incrementButton")
                    }
                    .padding(24)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 24))

                    VStack(alignment: .leading, spacing: 12) {
                        Label("SwiftUI 原生界面", systemImage: "iphone")
                        Label("计数保存在这台手机", systemImage: "internaldrive")
                        Label("无需登录，无需联网", systemImage: "wifi.slash")
                        Text("验证方法：点到 3，彻底退出，再打开；数字应仍为 3。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button("清零", role: .destructive) {
                        showResetConfirmation = true
                    }
                    .disabled(tapCount == 0)
                    .confirmationDialog("清除本机保存的计数？", isPresented: $showResetConfirmation, titleVisibility: .visible) {
                        Button("清零", role: .destructive) {
                            tapCount = 0
                        }
                    }

                    Text("PocketTest · 1.0 (1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 20)
                }
                .padding(.horizontal, 24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("口袋测试")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
