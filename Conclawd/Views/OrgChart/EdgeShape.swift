import SwiftUI

/// A shape that draws a directed edge (Bezier curve with arrowhead) between two points.
struct EdgeShape: Shape {
    let from: CGPoint
    let to: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()

        // Bezier curve
        let controlOffset = abs(to.y - from.y) * 0.4
        let cp1 = CGPoint(x: from.x, y: from.y + controlOffset)
        let cp2 = CGPoint(x: to.x, y: to.y - controlOffset)

        path.move(to: from)
        path.addCurve(to: to, control1: cp1, control2: cp2)

        // Arrowhead
        let arrowSize: CGFloat = 8
        let angle = atan2(to.y - cp2.y, to.x - cp2.x)
        let arrowPoint1 = CGPoint(
            x: to.x - arrowSize * cos(angle - .pi / 6),
            y: to.y - arrowSize * sin(angle - .pi / 6)
        )
        let arrowPoint2 = CGPoint(
            x: to.x - arrowSize * cos(angle + .pi / 6),
            y: to.y - arrowSize * sin(angle + .pi / 6)
        )

        path.move(to: to)
        path.addLine(to: arrowPoint1)
        path.move(to: to)
        path.addLine(to: arrowPoint2)

        return path
    }
}

/// A filled shape representing the wide hit area around an edge path.
/// Used as `.contentShape` so right-click context menus work reliably.
struct EdgeHitArea: Shape {
    let from: CGPoint
    let to: CGPoint
    var width: CGFloat = 20

    func path(in rect: CGRect) -> Path {
        EdgeShape(from: from, to: to)
            .path(in: rect)
            .strokedPath(.init(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}

/// A dashed line used during edge creation drag.
struct DragLineShape: Shape {
    let from: CGPoint
    let to: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        return path
    }
}
