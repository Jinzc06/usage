import SwiftUI

struct PopoverView: View {
    var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                card(
                    title: "模型 · TOKENS",
                    center: tokenCenter,
                    note: nil,
                    fractions: tokenFractions
                )
                card(
                    title: "模型 · COST",
                    center: costCenter,
                    note: store.hasUnpriced ? "未标价" : nil,
                    fractions: costFractions
                )
            }
            if store.showSettings {
                SettingsPanel(store: store)
            }
            footer
        }
        .padding(16)
        .frame(width: 588)
        .background(Palette.paper)
        .onAppear { store.refresh() }
    }

    private func card(title: String, center: String, note: String?, fractions: [(Color, Double)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(Palette.muted)
            HStack(alignment: .center, spacing: 8) {
                DonutChart(
                    fractions: fractions.map { (color: $0.0, fraction: $0.1) },
                    center: center,
                    note: note
                )
                legend
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Palette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Palette.line, lineWidth: 1)
        )
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 7) {
            if store.legend.isEmpty {
                Text(emptyLegend)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(store.legend) { slice in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(color(for: slice.name))
                            .frame(width: 7, height: 7)
                        Text(slice.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(basis)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(store.sources) { source in
                        Text(sourceLabel(source))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(sourceColor(source))
                    }
                }
                Spacer(minLength: 8)
                Text(stamp)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                Button("设置") {
                    store.toggleSettings()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(store.showSettings ? Palette.paper : Palette.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(store.showSettings ? Palette.ink : Color.clear)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Palette.ink.opacity(store.showSettings ? 0 : 0.28), lineWidth: 1)
                )
                Button(store.refreshing ? "更新中" : "刷新") {
                    store.refresh()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .disabled(store.refreshing)
            }
        }
    }

    private var tokenCenter: String {
        guard store.loaded else { return "…" }
        return UsageMath.formatTokens(store.totalTokens)
    }

    private var costCenter: String {
        guard store.loaded else { return "…" }
        guard store.totalTokens > 0 else { return "$0.00" }
        guard let cost = store.totalCost else { return "—" }
        return UsageMath.formatUSD(cost)
    }

    private var tokenFractions: [(Color, Double)] {
        let total = Double(store.totalTokens)
        guard total > 0 else { return [] }
        return store.legend.map { (color(for: $0.name), Double($0.tokens) / total) }
    }

    private var costFractions: [(Color, Double)] {
        guard let total = store.totalCost, total > 0 else { return [] }
        let totalDouble = NSDecimalNumber(decimal: total).doubleValue
        guard totalDouble > 0 else { return [] }
        return store.legend.compactMap { slice in
            guard let cost = slice.costDecimal, cost > 0 else { return nil }
            return (color(for: slice.name), NSDecimalNumber(decimal: cost).doubleValue / totalDouble)
        }
    }

    private var colors: [String: Color] {
        Palette.assignedColors(names: store.legend.map(\.name))
    }

    private func color(for name: String) -> Color {
        colors[name] ?? Palette.muted
    }

    private var emptyLegend: String {
        if !store.loaded || store.refreshing && store.sources.isEmpty { return "正在读取" }
        if store.settings.everySourceOff { return "来源都已关闭" }
        if store.sources.contains(where: \.ok) { return "今天还没有用量" }
        return "没有读到今天的用量"
    }

    private func sourceLabel(_ source: SourceReport) -> String {
        store.settings.isEnabled(source.name) ? source.detail : "\(source.name) 已关闭"
    }

    private func sourceColor(_ source: SourceReport) -> Color {
        if !store.settings.isEnabled(source.name) { return Palette.muted }
        return source.ok ? Palette.ink.opacity(0.72) : Palette.clay
    }

    private var basis: String {
        var text = store.settings.includeEstimates
            ? "今天 · Cursor 为账单实扣，其余为标价估算"
            : "今天 · 只计 Cursor 账单"
        if store.hasUnpriced { text += " · 有模型未标价" }
        if store.showingCache { text += " · 显示上次结果" }
        return text
    }

    private var stamp: String {
        guard let generatedAt = store.generatedAt else { return "--:--" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: generatedAt)
    }
}

private struct SettingsPanel: View {
    var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("来源")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(Palette.muted)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(UsageSettings.sources, id: \.self) { name in
                    sourceRow(name)
                }
            }
            Text("金额")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(Palette.muted)
                .padding(.top, 2)
            Text("Cursor 用的是账户账单。Codex、ZCode、Kimi 只有 token，金额是按官方标价乘出来的，不是从账户扣掉的钱。")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                store.toggleEstimates()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    CheckMark(on: store.settings.includeEstimates)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("把标价估算计入合计")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.ink)
                        Text(store.settings.includeEstimates ? "当前会计入菜单栏和金额环。" : "当前只计 Cursor 账单。")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Palette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Palette.line, lineWidth: 1)
        )
    }

    private func sourceRow(_ name: String) -> some View {
        Button {
            store.toggleSource(name)
        } label: {
            HStack(spacing: 10) {
                CheckMark(on: store.settings.isEnabled(name))
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                Text(UsageSettings.kind(of: name))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CheckMark: View {
    var on: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(on ? Palette.ink : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(on ? Palette.ink : Palette.muted, lineWidth: 1)
            )
            .overlay {
                if on {
                    CheckShape()
                        .stroke(Palette.paper, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .frame(width: 8, height: 6)
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
    }
}

private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
