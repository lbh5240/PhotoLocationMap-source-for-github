import Foundation

// An image-dependent recipe calculated from the linear proxy, not a color lookup table.
enum AutoDevelop {
    struct SkyTile {
        let x: Double
        let y: Double
        let level: Double
    }

    struct SkySurface {
        let coefficients: [Double]
        let limits: ClosedRange<Double>

        func value(x: Double, y: Double) -> Double {
            let c = coefficients
            let value = c[0] + c[1]*x + c[2]*y + c[3]*x*x + c[4]*x*y + c[5]*y*y
            return min(limits.upperBound, max(limits.lowerBound, value))
        }
    }

    static func fitSky(_ tiles: [SkyTile], noise: Double) -> SkySurface? {
        guard tiles.count >= 24 else { return nil }
        let terms = tiles.map { [1, $0.x, $0.y, $0.x*$0.x, $0.x*$0.y, $0.y*$0.y] }
        var weights = [Double](repeating: 1, count: tiles.count)
        var coefficients = [Double](repeating: 0, count: 6)
        for _ in 0..<7 {
            var equations = [[Double]](repeating: [Double](repeating: 0, count: 7), count: 6)
            for i in tiles.indices {
                for row in 0..<6 {
                    let factor = weights[i] * terms[i][row]
                    for col in 0..<6 { equations[row][col] += factor * terms[i][col] }
                    equations[row][6] += factor * tiles[i].level
                }
            }
            // Dampen curvature where the available sky samples do not constrain it well.
            for i in 3..<6 { equations[i][i] += 0.12 }
            for col in 0..<6 {
                let pivot = (col..<6).max { abs(equations[$0][col]) < abs(equations[$1][col]) }!
                equations.swapAt(col, pivot)
                let scale = equations[col][col]
                guard abs(scale) > 1e-8 else { return nil }
                for j in col...6 { equations[col][j] /= scale }
                for row in 0..<6 where row != col {
                    let factor = equations[row][col]
                    for j in col...6 { equations[row][j] -= factor * equations[col][j] }
                }
            }
            coefficients = equations.map { $0[6] }
            let residuals = tiles.indices.map { i in
                tiles[i].level - zip(terms[i], coefficients).reduce(0) { $0 + $1.0 * $1.1 }
            }
            let center = residuals.sorted()[tiles.count / 2]
            let mad = residuals.map { abs($0 - center) }.sorted()[tiles.count / 2]
            let scale = max(0.0002, 1.48 * mad, 0.25 * noise)
            // Bright residuals are more likely to be diffuse objects than empty sky.
            weights = residuals.map { residual in
                let r = (residual - min(0, center)) / scale
                let distance = r > 0 ? r / 1.8 : -r / 3.5
                return distance < 1 ? pow(1 - distance*distance, 2) : 0
            }
        }
        let supported = tiles.indices.filter { weights[$0] > 0.15 }.map { tiles[$0] }
        guard supported.count >= 20 else { return nil }
        for x in [-1.0, 1.0] {
            for y in [-1.0, 1.0] {
                guard supported.filter({ $0.x * x > 0 && $0.y * y > 0 }).count >= 3 else { return nil }
            }
        }
        let levels = supported.map(\.level).sorted()
        let padding = max(0.001, noise, (levels.last! - levels[0]) * 0.15)
        return SkySurface(coefficients: coefficients, limits: (levels[0] - padding)...(levels.last! + padding))
    }

    // Neighbor differences remove slowly changing sky levels. A median keeps
    // sparse stars and hot pixels from setting the noise scale.
    static func skyNoise(_ sample: (data: Data, width: Int, height: Int, scale: Double)) -> Double? {
        let w = sample.width, h = sample.height
        guard w >= 2, h > 0, sample.data.count >= w*h*16 else { return nil }
        let step = max(2, max(w,h) / 160)
        let differences: [Float] = sample.data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self)
            func luma(_ i: Int) -> Float { 0.2126*p[i] + 0.7152*p[i+1] + 0.0722*p[i+2] }
            var result: [Float] = []
            for y in stride(from: 0, to: h, by: step) {
                for x in stride(from: 0, to: w-1, by: step) {
                    let i = (y*w+x)*4, j = i+4
                    guard p[i+3] > 0.98, p[j+3] > 0.98 else { continue }
                    let d = abs(luma(i) - luma(j))
                    if d.isFinite { result.append(d) }
                }
            }
            return result.sorted()
        }
        guard differences.count >= 32 else { return nil }
        return Double(differences[differences.count / 2]) * 1.0484
    }

    static func skyCorrection(spread: Double, noise: Double, signal: Double) -> Double {
        let excess = max(0, spread - max(0.001, 1.8 * noise))
        return min(0.94, 1.8 * excess / max(0.008, signal + excess))
    }

    static func noiseWeight(noise: Double, typical: Double) -> Double {
        guard noise.isFinite, typical.isFinite, noise > 0, typical > 0 else { return 1 }
        return min(2, max(0.25, pow(typical / noise, 2)))
    }

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
        let p99 = quantile(lights, 0.99)
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
        var a = Adjustments()
        a.autoSTF = true
        // STF bounds are calibrated *after* background/color processing below.
        a.arcsinh = 0 // the adaptive STF performs the stretch once, avoiding doubled curves
        a.maskedStretch = 0
        a.gradientRemoval = min(0.35, max(0.08, variation*1.2))
        a.backgroundNeutralization = min(0.4, max(0.08, abs(sky[0]-sky[2])/max(0.015,neutralSky)*0.3))
        a.greenSuppression = min(0.2, max(0,greenExcess-0.05)*0.3)
        a.nebulaContrast = min(0.28, max(0.12, 0.24 - 0.04*log10(max(1,p99/max(p50,0.002)))))
        a.nebulaStructure = 0
        a.starProtection = 0.9
        a.starReduction = 0
        a.starSaturation = 0.03
        a.noise = 0.16
        a.vibrance = 0.02
        a.saturation = 1
        return a
    }

    static func calibrateSTF(_ a: inout Adjustments,
                             sample: (data: Data, width: Int, height: Int, scale: Double)) throws {
        let w = sample.width, h = sample.height
        if a.adaptiveSky == true { a.adaptiveSkyNoise = skyNoise(sample) }
        var pixels: [(Double, Double, Double, Double)] = []
        sample.data.withUnsafeBytes { raw in
            let v = raw.bindMemory(to: Float.self)
            for y in stride(from: 0, to: h, by: 2) {
                for x in stride(from: 0, to: w, by: 2) {
                    let i = (y*w+x)*4
                    guard v[i+3] > 0.8 else { continue }
                    let r = Double(v[i]), g = Double(v[i+1]), b = Double(v[i+2])
                    guard r.isFinite, g.isFinite, b.isFinite else { continue }
                    pixels.append((0.2126*r+0.7152*g+0.0722*b, r, g, b))
                }
            }
        }
        guard pixels.count >= 256 else { throw AstroError.message("有效背景区域不足，无法设定黑场") }
        pixels.sort { $0.0 < $1.0 }
        let n = pixels.count
        let skyPixels = pixels[(n*45/100)..<(n*65/100)]
        func median(_ channel: Int) -> Double {
            let values = skyPixels.map { v in
                channel == 0 ? v.1 : (channel == 1 ? v.2 : v.3)
            }.sorted()
            return values[values.count/2]
        }
        // The sky spans much of a typical M42 frame; use its middle, not a dark
        // corner or the illuminated cloud, to keep the surrounding sky dark.
        let r = max(0, median(0))
        let g = max(0, median(1))
        let b = max(0, median(2))
        a.autoBlackRed = r; a.autoBlackGreen = g; a.autoBlackBlue = b
        let sky = 0.2126*r+0.7152*g+0.0722*b
        a.autoBlack = sky
        let bright = pixels[min(n-1, n*995/1000)].0
        a.autoWhite = max(sky+0.015, bright)
    }
}
