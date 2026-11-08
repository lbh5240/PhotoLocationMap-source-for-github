import Foundation

@main
enum AutoDevelopTests {
    static func main() throws {
        verifySkyModel()
        for count in 2...160 {
            let limits = StarSpikeDensity.allCases.map { $0.starLimit(detected: count) }
            precondition(limits == limits.sorted() && limits.allSatisfy { $0 > 0 && $0 < count })
        }
        precondition(StarSpikeDensity.allCases.map { $0.starLimit(detected: 40) } == [4, 10, 20])
        let w = 256, h = 192
        var pixels = [Float](repeating: 0, count: w*h*4)
        for y in 0..<h { for x in 0..<w {
            let dx = (Double(x)-Double(w)/2)/Double(w), dy = (Double(y)-Double(h)/2)/Double(h)
            let glow = 0.085*exp(-(dx*dx+dy*dy)/0.085)
            let nebula = 0.22*exp(-(dx*dx+dy*dy)/0.0035)
            let sky = 0.13+glow
            let i = (y*w+x)*4
            pixels[i] = Float(0.8*sky+nebula)
            pixels[i+1] = Float(sky+0.25*nebula)
            pixels[i+2] = Float(1.15*sky+0.65*nebula)
            pixels[i+3] = 1
        } }
        let sample = (data: pixels.withUnsafeBytes { Data($0) }, width: w, height: h, scale: 1.0)
        var a = try AutoDevelop.suggest(sample)
        try AutoDevelop.calibrateSTF(&a, sample: sample)
        let black = [a.autoBlackRed!, a.autoBlackGreen!, a.autoBlackBlue!]
        let sky = [Double(pixels[(h/4*w+w/4)*4]), Double(pixels[(h/4*w+w/4)*4+1]), Double(pixels[(h/4*w+w/4)*4+2])]
        let contrast = (sky[0]-black[0])*0.2126 + (sky[1]-black[1])*0.7152 + (sky[2]-black[2])*0.0722
        let white = a.autoWhite! - a.autoBlack!
        let skyMapped = 1-exp(-1.7*asinh(8*max(0,contrast)/white)/asinh(8))
        precondition(skyMapped < 0.2, "The sky must stay dark after adaptive stretch")
        let core = (h/2*w+w/2)*4
        let coreL = 0.2126*(Double(pixels[core])-black[0]) + 0.7152*(Double(pixels[core+1])-black[1]) + 0.0722*(Double(pixels[core+2])-black[2])
        let coreMapped = 1-exp(-1.7*asinh(8*max(0,coreL)/white)/asinh(8))
        precondition(coreMapped > 0.5 && coreMapped < 1, "Core must remain visible without clipping")
        var hazy = a
        hazy.adaptiveSky = true
        try AutoDevelop.calibrateSTF(&hazy, sample: sample)
        var cleanPixels = pixels
        for y in 0..<h { for x in 0..<w {
            let dx = (Double(x)-Double(w)/2)/Double(w)
            let dy = (Double(y)-Double(h)/2)/Double(h)
            let glow = Float(0.085*exp(-(dx*dx+dy*dy)/0.085))
            let i = (y*w+x)*4
            cleanPixels[i] -= 0.8 * glow
            cleanPixels[i+1] -= glow
            cleanPixels[i+2] -= 1.15 * glow
        } }
        var clean = hazy
        let cleanData = cleanPixels.withUnsafeBytes { Data($0) }
        try AutoDevelop.calibrateSTF(&clean, sample: (cleanData, w, h, 1.0))
        precondition((hazy.adaptiveShadowKnee ?? 0) > 0.3, "Residual sky glow needs a measured shadow toe")
        precondition((clean.adaptiveShadowKnee ?? 1) < 0.1, "Flat sky should keep a narrow shadow toe")
        print("PASS adaptive STF: sky \(skyMapped), core \(coreMapped), background \(a.autoBlack!)")
    }
    private static func verifySkyModel() {
        func sky(_ x: Double, _ y: Double) -> Double {
            0.12 + 0.042*x - 0.018*y + 0.027*y*y
        }
        var tiles: [AutoDevelop.SkyTile] = []
        for row in 0..<8 {
            for col in 0..<12 {
                let x = (Double(col) + 0.5) / 6 - 1
                let y = (Double(row) + 0.5) / 4 - 1
                let nebula = abs(x) < 0.35 && abs(y) < 0.43 ? 0.09 : 0
                tiles.append(.init(x: x, y: y, level: sky(x,y) + nebula))
            }
        }
        guard let fit = AutoDevelop.fitSky(tiles, noise: 0.003) else {
            preconditionFailure("The fit should have enough sky around the nebula")
        }
        let error = tiles.map { abs(fit.value(x: $0.x, y: $0.y) - sky($0.x, $0.y)) }.max()!
        precondition(error < 0.004, "The model must follow the gradient without absorbing the nebula")
        let clean = AutoDevelop.skyCorrection(spread: 0.002, noise: 0.003, signal: 0.07)
        let hazy = AutoDevelop.skyCorrection(spread: 0.07, noise: 0.003, signal: 0.07)
        precondition(clean == 0 && hazy > 0.7, "Correction must respond to measured gradients")
        precondition(AutoDevelop.noiseWeight(noise: 0.02, typical: 0.01) == 0.25)
        precondition(AutoDevelop.noiseWeight(noise: 0.01, typical: 0.01) == 1)
        print("PASS adaptive sky model: max background error \(error), clean strength \(clean), hazy strength \(hazy)")
    }

}
