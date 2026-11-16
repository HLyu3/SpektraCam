//  FinishPanel.swift — the 后期 deck: Layer 2's light, colour, HSL, curve and
//  colour balance. Upstream's panels lean on the Mac design system, so this is
//  written for the phone; the model (`Adjustments`) is upstream's.

import SwiftUI

struct FinishPanel: View {
    @ObservedObject var model: ViewModel
    /// Set by the editor's deck, which shows its own tool row: one tool, no header of its own.
    var fixedTool: FinishTool? = nil
    @State private var chosenTool: FinishTool = .light
    private var tool: FinishTool { fixedTool ?? chosenTool }
    @State private var hue: HSLHue = .red
    @State private var channel: CurveChannel = .rgb
    @State private var zone: ColorBalance.Zone = .master

    enum FinishTool: String, CaseIterable, Identifiable {
        case light = "光线", colour = "色彩", hsl = "HSL", curve = "曲线", balance = "色彩平衡"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 6) {
            if fixedTool == nil { header }
            switch tool {
            case .light:
                sliders([.exposure, .contrast, .brightness, .highlights, .shadows, .whites, .blacks,
                         .vignette, .vignetteMidpoint])
            case .colour:
                sliders([.temperature, .tint, .saturation, .vibrance])
            case .hsl:
                hslPanel
            case .curve:
                curvePanel
            case .balance:
                balancePanel
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(FinishTool.allCases) { t in
                        Button { chosenTool = t } label: {
                            HStack(spacing: 3) {
                                Text(t.rawValue)
                                if !isNeutral(t) { Circle().fill(Color.labRed).frame(width: 4, height: 4) }
                            }
                            .font(.system(size: 11, weight: tool == t ? .semibold : .medium))
                            .foregroundStyle(tool == t ? Color.labCream : Color.secondary)
                            .padding(.horizontal, 9)
                            .frame(height: 26)
                            .background(tool == t ? Color.white.opacity(0.1) : Color.clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button { reset(tool) } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isNeutral(tool) ? Color.secondary.opacity(0.4) : Color.labCream)
            .disabled(isNeutral(tool))
            .accessibilityLabel("重置\(tool.rawValue)")
        }
    }

    private func isNeutral(_ t: FinishTool) -> Bool {
        let a = model.adjustments
        switch t {
        case .light: return a.isNeutral(.light)
        case .colour: return a.temperature == 0 && a.tint == 0 && a.saturation == 0 && a.vibrance == 0
        case .hsl: return a.hsl.isNeutral
        case .curve: return a.curves.isIdentity
        case .balance: return a.colorBalance.isNeutral
        }
    }

    private func reset(_ t: FinishTool) {
        var a = model.adjustments
        switch t {
        case .light: a.reset(.light)
        case .colour: a.temperature = 0; a.tint = 0; a.saturation = 0; a.vibrance = 0
        case .hsl: a.hsl = HSLSet()
        case .curve: a.curves = CurveSet()
        case .balance: a.colorBalance = ColorBalance()
        }
        model.setAdjustments(a)
    }

    private func bind<T>(_ path: WritableKeyPath<Adjustments, T>) -> Binding<T> {
        Binding(get: { model.adjustments[keyPath: path] },
                set: { var a = model.adjustments; a[keyPath: path] = $0; model.setAdjustments(a) })
    }

    // MARK: tools

    private func sliders(_ controls: [Layer2Control]) -> some View {
        ScrollView {
            VStack(spacing: 7) {
                ForEach(controls) { c in
                    FinishSlider(title: c.title, value: bind(\.[c]), range: c.range, rest: c.rest,
                                 text: c.text)
                }
            }
        }
    }

    private var hslPanel: some View {
        VStack(spacing: 7) {
            HStack(spacing: 0) {
                ForEach(HSLHue.allCases) { h in
                    Button { hue = h } label: {
                        Circle()
                            .fill(Color(hue: h.centre / 360, saturation: 0.75, brightness: 0.9))
                            .frame(width: 20, height: 20)
                            .overlay { Circle().stroke(Color.labCream, lineWidth: hue == h ? 2 : 0).padding(-3) }
                            .overlay(alignment: .topTrailing) {
                                if !model.adjustments.hsl[h].isNeutral {
                                    Circle().fill(Color.labCream).frame(width: 4, height: 4).offset(x: 3, y: -3)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(h.title)
                }
            }
            FinishSlider(title: "\(hue.title) · 色相", value: bind(\.hsl[hue].hue), range: HSLSet.range)
            FinishSlider(title: "\(hue.title) · 饱和度", value: bind(\.hsl[hue].saturation), range: HSLSet.range)
            FinishSlider(title: "\(hue.title) · 明度", value: bind(\.hsl[hue].luminance), range: HSLSet.range)
            Spacer(minLength: 0)
        }
    }

    private var curvePanel: some View {
        HStack(spacing: 10) {
            VStack(spacing: 4) {
                ForEach(CurveChannel.allCases) { c in
                    Button { channel = c } label: {
                        Text(c.tab)
                            .font(.system(size: 11, weight: channel == c ? .semibold : .medium))
                            .foregroundStyle(channel == c ? Color.labCream : Color.secondary)
                            .frame(width: 44, height: 26)
                            .background(channel == c ? Color.white.opacity(0.1) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            CurveEditor(curve: bind(\.curves[channel]), tint: channel.tint)
                .aspectRatio(1, contentMode: .fit)
            Spacer(minLength: 0)
        }
    }

    private var balancePanel: some View {
        VStack(spacing: 7) {
            Picker("区域", selection: $zone) {
                ForEach(ColorBalance.Zone.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            FinishSlider(title: "色相", value: bind(\.colorBalance[zone].hue), range: 0...360, rest: 0,
                         text: { String(format: "%.0f°", $0) },
                         track: LinearGradient(colors: stride(from: 0.0, through: 1, by: 1 / 6).map {
                             Color(hue: $0, saturation: 0.7, brightness: 0.9)
                         }, startPoint: .leading, endPoint: .trailing))
            FinishSlider(title: "强度", value: bind(\.colorBalance[zone].saturation), range: 0...1, rest: 0,
                         text: { String(format: "%.0f", $0 * 100) })
            FinishSlider(title: "明度", value: bind(\.colorBalance[zone].luminance), range: -1...1, rest: 0,
                         text: { Fmt.signed($0 * 100, decimals: 0) })
            Spacer(minLength: 0)
        }
    }
}

// MARK: - a slider (double-tap the title to reset)

struct FinishSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var rest: Double = 0
    var text: (Double) -> String = { Fmt.signed($0, decimals: 0) }
    var track: LinearGradient?

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.footnote)
                Spacer()
                Text(text(value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(value == rest ? Color.secondary : Color.labCream)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { value = rest }
            Slider(value: $value, in: range)
                .tint(Color.labRed)
                .background(alignment: .center) {
                    if let track { Capsule().fill(track).frame(height: 3).opacity(0.7) }
                }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - the curve

struct CurveEditor: View {
    @Binding var curve: Curve
    let tint: Color
    @State private var held: (index: Int, offset: CGPoint)?
    @State private var dropped = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            Canvas { ctx, size in
                let rect = CGRect(origin: .zero, size: size)
                ctx.fill(Path(rect), with: .color(.white.opacity(0.04)))
                var grid = Path()
                for i in 1..<4 {
                    let t = CGFloat(i) / 4
                    grid.move(to: CGPoint(x: t * size.width, y: 0)); grid.addLine(to: CGPoint(x: t * size.width, y: size.height))
                    grid.move(to: CGPoint(x: 0, y: t * size.height)); grid.addLine(to: CGPoint(x: size.width, y: t * size.height))
                }
                ctx.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 0.5)
                var diagonal = Path()
                diagonal.move(to: CGPoint(x: 0, y: size.height)); diagonal.addLine(to: CGPoint(x: size.width, y: 0))
                ctx.stroke(diagonal, with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                var line = Path()
                for i in 0...96 {
                    let x = CGFloat(i) / 96
                    let p = CGPoint(x: x * size.width, y: (1 - curve.evaluate(x)) * size.height)
                    i == 0 ? line.move(to: p) : line.addLine(to: p)
                }
                ctx.stroke(line, with: .color(tint), lineWidth: 1.5)
                for p in curve.points {
                    let c = CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(.white))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let u = CGPoint(x: g.location.x / max(size.width, 1), y: 1 - g.location.y / max(size.height, 1))
                        guard !dropped else { return }
                        var c = curve
                        if held == nil {
                            let t = c.touch(at: u, in: size)
                            held = (t.index, t.offset)
                        }
                        guard let h = held else { return }
                        if let i = c.drag(h.index, to: CGPoint(x: u.x + h.offset.x, y: u.y + h.offset.y)) {
                            held = (i, h.offset)
                        } else {
                            held = nil; dropped = true  // dragged off the plot: the point is gone
                        }
                        curve = c
                    }
                    .onEnded { _ in held = nil; dropped = false }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { curve = .identity })
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("曲线，双击重置")
    }
}

extension CurveChannel {
    var tint: Color {
        switch self {
        case .rgb, .luma: Color.labCream
        case .red: .red
        case .green: .green
        case .blue: Color(red: 0.35, green: 0.55, blue: 1)
        }
    }
}
