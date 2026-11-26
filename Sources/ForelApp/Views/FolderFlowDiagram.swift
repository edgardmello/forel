// Forel - A native macOS file-automation app
// Copyright (C) 2026  Edgard Mello
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.


import SwiftUI
import ForelCore

/// The folder flow drawn as a diagram: watched folders as boxes laid out
/// left to right in hand-off order, arrows for where rules send files, and
/// destinations outside the watched folders (another folder, the Trash) at
/// the right. Loops are orange; arrows from rules that are off are dashed.
struct FolderFlowDiagram: View {
    let nodes: [FolderFlow.Node]
    let name: (String) -> String

    private let boxSize = CGSize(width: 168, height: 46)
    private let columnGap: CGFloat = 70
    private let rowGap: CGFloat = 22
    private let margin: CGFloat = 16

    var body: some View {
        let layout = FlowLayout(nodes: nodes)
        let size = canvasSize(layout)
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for edge in layout.edges {
                        draw(edge, layout: layout, in: &context)
                    }
                }
                .frame(width: size.width, height: size.height)

                ForEach(layout.boxes) { box in
                    boxView(box)
                        .frame(width: boxSize.width, height: boxSize.height)
                        .position(center(of: box.id, layout: layout))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .scrollIndicators(.automatic)
        .accessibilityElement(children: .contain)
    }

    // MARK: Boxes

    @ViewBuilder private func boxView(_ box: FlowLayout.Box) -> some View {
        let (title, icon, isWatched) = describe(box.kind)
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(isWatched ? ForelTheme.accent : ForelTheme.secondaryText)
            Text(title)
                .font(.system(size: 12, weight: isWatched ? .semibold : .regular))
                .foregroundStyle(ForelTheme.primaryText)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isWatched ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isWatched ? ForelTheme.accent.opacity(0.6) : ForelTheme.divider, style: StrokeStyle(lineWidth: 1, dash: isWatched ? [] : [3, 3]))
        )
        .help(help(for: box.kind))
        .accessibilityElement(children: .combine)
    }

    private func describe(_ kind: FlowLayout.Box.Kind) -> (String, String, Bool) {
        switch kind {
        case .watched(let id): return (name(id), "folder.fill", true)
        case .elsewhere(let path): return ((path as NSString).lastPathComponent, "folder", false)
        case .trash: return (localized("Trash"), "trash", false)
        case .removed: return (localized("Deleted or uploaded"), "xmark.bin", false)
        }
    }

    private func help(for kind: FlowLayout.Box.Kind) -> String {
        switch kind {
        case .watched(let id): return nodes.first { $0.id == id }?.folder.path ?? ""
        case .elsewhere(let path): return path
        case .trash, .removed: return ""
        }
    }

    // MARK: Geometry

    private func canvasSize(_ layout: FlowLayout) -> CGSize {
        let columns = CGFloat(layout.columnCount)
        let rows = CGFloat(max(layout.rowCount, 1))
        return CGSize(
            width: margin * 2 + columns * boxSize.width + max(columns - 1, 0) * columnGap,
            height: margin * 2 + rows * boxSize.height + max(rows - 1, 0) * rowGap + 40
        )
    }

    private func center(of id: String, layout: FlowLayout) -> CGPoint {
        let slot = layout.slots[id] ?? (0, 0)
        return CGPoint(
            x: margin + CGFloat(slot.column) * (boxSize.width + columnGap) + boxSize.width / 2,
            y: margin + 20 + CGFloat(slot.row) * (boxSize.height + rowGap) + boxSize.height / 2
        )
    }

    private func draw(_ edge: FlowLayout.Edge, layout: FlowLayout, in context: inout GraphicsContext) {
        let from = center(of: edge.from, layout: layout)
        let to = center(of: edge.to, layout: layout)
        let half = boxSize.width / 2
        var path = Path()
        let end: CGPoint
        let control: CGPoint
        if to.x > from.x {
            // Forward: right side to left side.
            let start = CGPoint(x: from.x + half, y: from.y)
            end = CGPoint(x: to.x - half, y: to.y)
            path.move(to: start)
            let midX = (start.x + end.x) / 2
            path.addCurve(to: end, control1: CGPoint(x: midX, y: start.y), control2: CGPoint(x: midX, y: end.y))
            control = CGPoint(x: midX, y: end.y)
        } else {
            // Backward or same column: loop over the top of the boxes.
            let start = CGPoint(x: from.x, y: from.y - boxSize.height / 2)
            end = CGPoint(x: to.x + (to.x == from.x ? 12 : 0), y: to.y - boxSize.height / 2)
            let lift = min(start.y, end.y) - 18 - CGFloat(edge.lane) * 6
            control = CGPoint(x: end.x, y: lift)
            path.move(to: start)
            path.addCurve(to: end, control1: CGPoint(x: start.x, y: lift), control2: control)
        }
        let color: Color = edge.inLoop ? .orange : ForelTheme.accent
        let style = StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: edge.enabled ? [] : [5, 4])
        context.stroke(path, with: .color(color.opacity(edge.enabled ? 0.9 : 0.5)), style: style)

        // Arrowhead along the direction from the last control point.
        let angle = atan2(end.y - control.y, end.x - control.x)
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - 8 * cos(angle - .pi / 7), y: end.y - 8 * sin(angle - .pi / 7)))
        head.addLine(to: CGPoint(x: end.x - 8 * cos(angle + .pi / 7), y: end.y - 8 * sin(angle + .pi / 7)))
        head.closeSubpath()
        context.fill(head, with: .color(color.opacity(edge.enabled ? 0.9 : 0.5)))
    }
}

/// Columns and rows for the diagram. Watched folders sit one column right
/// of the folders that hand them files (loops are cut so this ends);
/// outside destinations share the last column.
struct FlowLayout {
    struct Box: Identifiable {
        enum Kind { case watched(String), elsewhere(String), trash, removed }
        let id: String
        let kind: Kind
    }

    struct Edge {
        let from: String
        let to: String
        let enabled: Bool
        let inLoop: Bool
        /// Spreads arcs of backward edges apart.
        let lane: Int
    }

    private(set) var boxes: [Box] = []
    private(set) var edges: [Edge] = []
    private(set) var slots: [String: (column: Int, row: Int)] = [:]
    private(set) var columnCount = 1
    private(set) var rowCount = 1

    init(nodes: [FolderFlow.Node]) {
        let ids = nodes.map(\.id)
        var level = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
        var handOffs: [(String, String)] = []
        for node in nodes {
            for step in node.outgoing {
                if case .watched(let target) = step.destination, level[target] != nil, target != node.id {
                    handOffs.append((node.id, target))
                }
            }
        }
        // Longest-path levels, capped so a loop can't push forever.
        let cap = max(ids.count - 1, 0)
        for _ in 0..<max(ids.count, 1) {
            var changed = false
            for (from, to) in handOffs {
                let candidate = min((level[from] ?? 0) + 1, cap)
                if candidate > (level[to] ?? 0) {
                    level[to] = candidate
                    changed = true
                }
            }
            if !changed { break }
        }

        var boxes: [Box] = []
        var edges: [Edge] = []
        var slots: [String: (column: Int, row: Int)] = [:]
        var rowsInColumn: [Int: Int] = [:]
        func place(_ box: Box, column: Int) {
            let row = rowsInColumn[column, default: 0]
            rowsInColumn[column] = row + 1
            slots[box.id] = (column, row)
            boxes.append(box)
        }
        for node in nodes.sorted(by: { (level[$0.id] ?? 0, $0.folder.path) < (level[$1.id] ?? 0, $1.folder.path) }) {
            place(Box(id: node.id, kind: .watched(node.id)), column: level[node.id] ?? 0)
        }

        let outsideColumn = (level.values.max() ?? 0) + 1
        var lane = 0
        for node in nodes {
            for step in node.outgoing {
                let target: String
                let outside: Box?
                switch step.destination {
                case .watched(let id):
                    target = id
                    outside = nil
                case .elsewhere(let path):
                    target = "path:" + path
                    outside = Box(id: target, kind: .elsewhere(path))
                case .trash:
                    target = "trash"
                    outside = Box(id: target, kind: .trash)
                case .removed:
                    target = "removed"
                    outside = Box(id: target, kind: .removed)
                }
                if let outside, slots[target] == nil { place(outside, column: outsideColumn) }
                guard slots[target] != nil else { continue }
                if edges.contains(where: { $0.from == node.id && $0.to == target && $0.enabled == step.ruleEnabled }) { continue }
                let backward = (slots[target]?.column ?? 0) <= (slots[node.id]?.column ?? 0)
                edges.append(Edge(from: node.id, to: target, enabled: step.ruleEnabled, inLoop: step.inLoop, lane: backward ? lane : 0))
                if backward { lane += 1 }
            }
        }
        self.boxes = boxes
        self.edges = edges
        self.slots = slots
        columnCount = (slots.values.map(\.column).max() ?? 0) + 1
        rowCount = rowsInColumn.values.max() ?? 1
    }
}
