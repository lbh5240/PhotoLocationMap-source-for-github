import SwiftUI
import UIKit

extension View {
    func astroGlass() -> some View {
        self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
    }
}
struct StarBackdrop: View {
    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.032, blue: 0.055)
            RadialGradient(colors: [.indigo.opacity(0.2), .clear], center: .topTrailing, startRadius: 0, endRadius: 500)
            Canvas { ctx, size in
                for i in 0..<95 {
                    let x = CGFloat((i * 127 + 31) % 997) / 997 * size.width
                    let y = CGFloat((i * 263 + 17) % 991) / 991 * size.height
                    let r: CGFloat = i % 7 == 0 ? 1.2 : 0.6
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r*2, height: r*2)), with: .color(.white.opacity(i % 4 == 0 ? 0.5 : 0.15)))
                }
            }.accessibilityHidden(true)
        }.ignoresSafeArea()
    }
}
struct Badge: View {
    var text: String
    var color: Color = .secondary
    var body: some View { Text(text).font(.caption2.weight(.medium)).padding(.horizontal, 9).padding(.vertical, 5).foregroundStyle(color).background(color.opacity(0.12), in: Capsule()) }
}
struct HistogramView: View {
    var values: [Double]
    var height: CGFloat = 42
    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }; var path = Path(); path.move(to: CGPoint(x: 0, y: size.height))
            for (i, y) in values.enumerated() { path.addLine(to: CGPoint(x: CGFloat(i) / CGFloat(values.count-1) * size.width, y: size.height * (1-y))) }
            path.addLine(to: CGPoint(x: size.width, y: size.height)); path.closeSubpath()
            ctx.fill(path, with: .linearGradient(Gradient(colors: [.white.opacity(0.55), .indigo.opacity(0.1)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        }.frame(height: height).accessibilityLabel("亮度直方图")
    }
}
struct PhotoCanvas: View {
    var image: UIImage?
    var original: UIImage?
    var skyFraction: Double?
    var showOriginal = false
    @State private var comparing = false
    @State private var zoom = 1.0
    @State private var offset = CGSize.zero
    @GestureState private var scale = 1.0
    @GestureState private var drag = CGSize.zero
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let image {
                    let photo = comparing || showOriginal ? (original ?? image) : image
                    let fitted = fit(photo.size, into: geo.size)
                    Image(uiImage: photo).resizable().scaledToFit().frame(width: fitted.width, height: fitted.height)
                        .scaleEffect(min(8, max(1, zoom * scale)))
                        .offset(x: offset.width + drag.width, y: offset.height + drag.height)
                    if let skyFraction, zoom == 1 {
                        let y = (geo.size.height-fitted.height)/2 + fitted.height * skyFraction
                        Path { p in p.move(to: CGPoint(x: (geo.size.width-fitted.width)/2, y: y)); p.addLine(to: CGPoint(x: (geo.size.width+fitted.width)/2, y: y)) }.stroke(.cyan, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        Text("天空 / 地景").font(.caption2).padding(5).background(.black.opacity(0.65), in: Capsule()).position(x: geo.size.width/2, y: max(12, y-12))
                    }
                } else {
                    VStack(spacing: 12) { Image(systemName: "sparkles.rectangle.stack").font(.system(size: 42, weight: .ultraLight)); Text("让每一颗星，都更清晰").font(.headline); Text("从相册或文件导入照片开始处理").font(.caption).foregroundStyle(.secondary) }.foregroundStyle(.white.opacity(0.8))
                }
                if comparing || showOriginal { VStack { Badge(text: "调整前", color: .white); Spacer() }.padding(10) }
            }
            .contentShape(Rectangle()).clipped()
            .gesture(MagnifyGesture().updating($scale) { value, state, _ in state = value.magnification }.onEnded { value in zoom = min(8, max(1, zoom * value.magnification)); if zoom <= 1 { offset = .zero } })
            .simultaneousGesture(DragGesture(minimumDistance: 10).updating($drag) { value, state, _ in if zoom > 1 { state = value.translation } }.onEnded { value in if zoom > 1 { offset.width += value.translation.width; offset.height += value.translation.height } })
            .onLongPressGesture(minimumDuration: 0.25, pressing: { comparing = $0 }, perform: {})
            .onTapGesture(count: 2) { withAnimation(.snappy) { zoom = zoom > 1 ? 1 : 3; offset = .zero } }
            .accessibilityLabel("照片预览。双指缩放，长按比较调整前后。预览最长边 1600 像素。")
        }
    }
    private func fit(_ size: CGSize, into box: CGSize) -> CGSize { let s = min(box.width/size.width, box.height/size.height); return CGSize(width: size.width*s, height: size.height*s) }
}
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
