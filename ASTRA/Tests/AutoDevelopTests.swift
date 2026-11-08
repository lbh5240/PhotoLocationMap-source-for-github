import Foundation

@main
enum AutoDevelopTests {
    static func main() throws {
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
        print("PASS adaptive STF: sky \(skyMapped), core \(coreMapped), background \(a.autoBlack!)")
    }
}
