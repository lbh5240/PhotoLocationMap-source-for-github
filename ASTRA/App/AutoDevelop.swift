import Foundation

// An image-dependent recipe calculated from the linear proxy, not a color lookup table.
enum AutoDevelop {
    static func suggest(_ sample: (data: Data, width: Int, height: Int, scale: Double)) throws -> Adjustments {
        let w = sample.width, h = sample.height
        guard w >= 16, h >= 16, sample.data.count >= w * h * 16 else {
            throw AstroError.message("自动显影无法分析当前照片")
        }
        let gx = 8, gy = 6
        var lights: [Double] = []
        var skyPixels: [(Double, Double, Double, Double)] = []
        var cellLights = [[Double]](repeating: [], count: gx * gy)
        sample.data.withUnsafeBytes { raw in
            let pixels = raw.bindMemory(to: Float.self)
            for y in stride(from: 0, to: h, by: 2) {
                for x in stride(from: 0, to: w, by: 2) {
                    let i = (y*w+x)*4
                    guard pixels[i+3] > 0.5 else { continue }
                    let r = Double(pixels[i]), g = Double(pixels[i+1]), b = Double(pixels[i+2])
                    guard r.isFinite, g.isFinite, b.isFinite else { continue }
                    let l = max(0, 0.2126*r + 0.7152*g + 0.0722*b)
                    lights.append(l)
                    skyPixels.append((l,r,g,b))
                    cellLights[min(gy-1,y*gy/h)*gx + min(gx-1,x*gx/w)].append(l)
                }
            }
        }
        guard lights.count >= 256 else { throw AstroError.message("有效星空区域不足，无法自动显影") }
        lights.sort()
        func quantile(_ sorted: [Double], _ q: Double) -> Double {
            sorted[min(sorted.count-1, max(0, Int(Double(sorted.count-1)*q)))]
        }
        let p10 = quantile(lights, 0.10), p50 = quantile(lights, 0.50)
        let p99 = quantile(lights, 0.99), p995 = quantile(lights, 0.995)
        let skyCut = quantile(lights, 0.30)
        var sky = [0.0,0.0,0.0], skyCount = 0.0
        for v in skyPixels where v.0 <= skyCut {
            sky[0] += v.1; sky[1] += v.2; sky[2] += v.3; skyCount += 1
        }
        if skyCount > 0 { sky = sky.map { $0 / skyCount } }
        let neutralSky = (sky[0]+sky[1]+sky[2])/3
        let greenExcess = max(0, sky[1]-(sky[0]+sky[2])*0.5)/max(0.005,neutralSky)
        let cellSky = cellLights.compactMap { v -> Double? in
            guard v.count >= 32 else { return nil }
            let ordered = v.sorted()
            return quantile(ordered, 0.20)
        }.sorted()
        let variation = cellSky.count >= 8 ?
            (quantile(cellSky, 0.75)-quantile(cellSky, 0.25))/max(p99-p10, 0.02) : 0
        let spread = max(0.005, p995-p10)
        var a = Adjustments()
        a.autoSTF = true
        // Dark sky and highlight bounds are measured independently for each stack.
        a.autoBlack = max(0, min(p10, p50*0.75))
        a.autoWhite = max((a.autoBlack ?? 0)+0.015, p995 + spread*0.14)
        a.arcsinh = 0 // the adaptive STF performs the stretch once, avoiding doubled curves
        a.maskedStretch = 0
        a.gradientRemoval = min(0.28, max(0, variation-0.05)*0.65)
        a.backgroundNeutralization = min(0.55, max(0.12, abs(sky[0]-sky[2])/max(0.015,neutralSky)*0.35))
        a.greenSuppression = min(0.4, max(0,greenExcess-0.05)*0.55)
        a.nebulaContrast = min(0.5, max(0.22, 0.42 - 0.04*log10(max(1,p99/max(p50,0.002)))))
        a.nebulaStructure = 0.14
        a.starProtection = 0.9
        a.starReduction = 0.08
        a.starSaturation = 0.12
        a.vibrance = 0.12
        a.saturation = 1.12
        return a
    }
}
