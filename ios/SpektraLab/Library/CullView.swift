//  CullView.swift — 挑片: the shots from SpektraLab's camera that were never exported, by day.
//  Tap the ones to keep; export them, and/or delete the rest. Nothing is removed without a confirm.

import SwiftUI

struct CullView: View {
    @ObservedObject var model: ViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var keep: Set<UUID> = []
    @State private var looking: LibraryPhoto?
    @State private var confirmingDelete = false
    @State private var working = false

    private var shots: [LibraryPhoto] { model.unexportedShots() }

    /// Newest day first; inside a day, in shooting order.
    private var days: [(Date, [LibraryPhoto])] {
        let calendar = Calendar.current
        return Dictionary(grouping: shots) { calendar.startOfDay(for: $0.createdAt) }
            .map { ($0.key, $0.value.sorted { $0.createdAt < $1.createdAt }) }
            .sorted { $0.0 > $1.0 }
    }

    private var rest: [LibraryPhoto] { shots.filter { !keep.contains($0.id) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4,
                          pinnedViews: [.sectionHeaders]) {
                    ForEach(days, id: \.0) { day, photos in
                        Section {
                            ForEach(photos) { photo in tile(photo) }
                        } header: {
                            HStack {
                                Text(day.formatted(.dateTime.month().day().weekday()))
                                Text("· \(photos.count) 张").foregroundStyle(.secondary)
                                Spacer()
                                Button(photos.allSatisfy { keep.contains($0.id) } ? "取消全选" : "全选这天") {
                                    let ids = Set(photos.map(\.id))
                                    if ids.isSubset(of: keep) { keep.subtract(ids) } else { keep.formUnion(ids) }
                                }
                                .font(.caption)
                            }
                            .font(.footnote.weight(.semibold))
                            .padding(.vertical, 8)
                            .padding(.horizontal, 4)
                            .background(Color.labInk)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 120)
            }
            .overlay {
                if shots.isEmpty {
                    Text("没有待挑的照片").font(.headline).foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .bottom) { if !shots.isEmpty { actions } }
            .background(Color.labInk.ignoresSafeArea())
            .navigationTitle("挑片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() }.disabled(working) }
            }
            .confirmationDialog("删除 \(rest.count) 张？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("删除 \(rest.count) 张", role: .destructive) {
                    model.deletePhotos(Set(rest.map(\.id)))
                }
            } message: {
                Text("这些照片还没导出过，Spektra Cam 里的底片是唯一的一份，删除后找不回来。")
            }
            .sheet(item: $looking) { photo in
                Image(uiImage: photo.thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .presentationBackground(.black)
                    .onTapGesture { looking = nil }
            }
        }
        .tint(Color.labRed)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(working)
    }

    private func tile(_ photo: LibraryPhoto) -> some View {
        let on = keep.contains(photo.id)
        return Color.labPanel
            .aspectRatio(1, contentMode: .fit)
            .overlay { Image(uiImage: photo.thumbnail).resizable().scaledToFill() }
            .overlay { if !on && !keep.isEmpty { Color.black.opacity(0.35) } }
            .overlay(alignment: .topTrailing) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(on ? Color.labRed : .white.opacity(0.8))
                    .background(on ? Circle().fill(.white) : nil)
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if on { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.labRed, lineWidth: 2) }
            }
            .contentShape(Rectangle())
            .onTapGesture { if on { keep.remove(photo.id) } else { keep.insert(photo.id) } }
            .contextMenu {
                Button { looking = photo } label: { Label("放大看", systemImage: "magnifyingglass") }
            }
            .accessibilityLabel(on ? "保留" : "未选")
            .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Text(keep.isEmpty ? "点照片标记要保留的；长按可以放大看" : "保留 \(keep.count) 张 · 其余 \(rest.count) 张")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button {
                    working = true
                    Task {
                        let ids = shots.filter { keep.contains($0.id) }.map(\.id)
                        _ = await model.exportPhotos(ids)
                        keep.removeAll()
                        working = false
                    }
                } label: {
                    Label(working ? "正在导出…" : "导出保留的 \(keep.count) 张", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Color.white.opacity(0.1), in: Capsule())
                }
                .disabled(keep.isEmpty || working)
                Button { confirmingDelete = true } label: {
                    Label(String(format: "删除其余 %d 张 · %.1f GB", rest.count,
                                 Double(model.negativeBytes(rest)) / 1_073_741_824), systemImage: "trash")
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Color.labRed.opacity(0.3), in: Capsule())
                }
                .disabled(rest.isEmpty || working)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.labCream)
            .buttonStyle(.plain)
            if working, let progress = model.libraryBusy {
                Text(progress).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .labGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}
