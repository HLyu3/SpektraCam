//  LightTableSlideShow.swift — 幻灯: the films on the light table one at a time, full screen on black, like a
//  slide projector (after the other project's 全屏幻灯; our own code). Swipe or tap the sides to change slide,
//  the middle to show or hide the controls; 自动 advances every 5 s; 随机 shuffles. Each slide is developed at
//  2048 px through the engine (`ViewModel.slideImage`), the developed thumbnail standing in until it lands,
//  and the next one is made ahead. A change of slide is a carrier's: the old one out, a beat of dark, the new
//  one in with a little settle, a click.

import AudioToolbox
import SwiftUI

struct LightTableSlideShow: View {
    @ObservedObject var model: ViewModel
    let ids: [UUID]
    @Environment(\.dismiss) private var dismiss
    @State private var order: [UUID] = []
    @State private var index = 0
    @State private var images: [UUID: UIImage] = [:]
    @State private var chrome = true
    @State private var auto = false
    @State private var shuffled = false
    @State private var dark = false
    @State private var offset: CGFloat = 0
    @State private var settle: CGFloat = 1
    @State private var drag: CGFloat = 0

    private var current: UUID? { order.indices.contains(index) ? order[index] : nil }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if let id = current, let image = images[id] ?? model.library.first(where: { $0.id == id })?.thumbnail {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(settle)
                        .offset(x: offset + drag)
                        .padding(.vertical, 8)
                        .id(id)
                }
                Color.black.opacity(dark ? 1 : 0).ignoresSafeArea().allowsHitTesting(false)
                if chrome { controls }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 20)
                .onChanged { drag = $0.translation.width * 0.6 }
                .onEnded { v in
                    let dx = v.translation.width
                    withAnimation(.easeOut(duration: 0.12)) { drag = 0 }
                    if dx < -60 { advance(1, width: geo.size.width) } else if dx > 60 { advance(-1, width: geo.size.width) }
                })
            .onTapGesture { p in
                if p.x < geo.size.width * 0.25 { advance(-1, width: geo.size.width) }
                else if p.x > geo.size.width * 0.75 { advance(1, width: geo.size.width) }
                else { withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() } }
            }
            .task(id: auto) {
                guard auto else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    advance(1, width: geo.size.width)
                }
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear { order = ids }
        .task(id: current) { await develop() }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: auto) { _, on in UIApplication.shared.isIdleTimerDisabled = on }
    }

    private var controls: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
                Text(order.isEmpty ? "" : "\(index + 1) / \(order.count)")
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Color.clear.frame(width: 40, height: 40)
            }
            Spacer()
            HStack(spacing: 12) {
                Button { shuffle() } label: {
                    Label("随机", systemImage: "shuffle").padding(.horizontal, 14).frame(height: 40)
                        .background(shuffled ? Color.labRed.opacity(0.4) : Color.white.opacity(0.1), in: Capsule())
                }
                Button { auto.toggle() } label: {
                    Label(auto ? "暂停" : "自动", systemImage: auto ? "pause.fill" : "play.fill").padding(.horizontal, 14).frame(height: 40)
                        .background(auto ? Color.labRed.opacity(0.4) : Color.white.opacity(0.1), in: Capsule())
                }
            }
            .font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.labCream)
        .padding(16)
    }

    private func shuffle() {
        shuffled.toggle()
        let keep = current
        order = shuffled ? ids.shuffled() : ids
        index = keep.flatMap { order.firstIndex(of: $0) } ?? 0
    }

    /// The carrier: the old slide out, a beat of dark, the new one in and settling.
    private func advance(_ step: Int, width: CGFloat) {
        guard order.count > 1 else { return }
        let next = (index + step + order.count) % order.count
        AudioServicesPlaySystemSound(1104)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.6)
        withAnimation(.easeIn(duration: 0.14)) { offset = -CGFloat(step) * width; dark = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            index = next
            offset = CGFloat(step) * width * 0.35
            settle = 1.02
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { offset = 0; settle = 1 }
            withAnimation(.easeOut(duration: 0.18)) { dark = false }
        }
    }

    /// This slide at 2048 px, then the next one ahead; at most three kept.
    private func develop() async {
        guard let id = current else { return }
        if images[id] == nil, let image = await model.slideImage(for: id) { images[id] = image }
        guard order.count > 1 else { return }
        let ahead = order[(index + 1) % order.count]
        if images[ahead] == nil, let image = await model.slideImage(for: ahead) { images[ahead] = image }
        let keep = Set([id, ahead, order[(index - 1 + order.count) % order.count]])
        for k in images.keys where !keep.contains(k) { images[k] = nil }
    }
}
