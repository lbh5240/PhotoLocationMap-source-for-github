import Foundation

@main
struct SelectionTests {
    static func project(_ suffixes: [String]) -> AstroProject {
        var project = AstroProject()
        project.frames = suffixes.enumerated().map { index, suffix in
            FrameRecord(name: "DSC_\(index / 2).\(suffix)", fileName: "\(index).\(suffix)")
        }
        return project
    }
    static func main() throws {
        let paired = try StackSelection.indices(in: project(["jpg", "NEF", "jpg", "NEF"]))
        assert(paired == [1, 3])
        let mixed = project(["jpg", "NEF", "jpg", "NEF"])
        assert(StackSelection.formats(in: mixed) == [.raw, .processed])
        let requestedJPEG = try StackSelection.indices(in: mixed, format: .processed)
        let requestedRAW = try StackSelection.indices(in: mixed, format: .raw)
        assert(requestedJPEG == [0, 2] && requestedRAW == [1, 3])
        do {
            _ = try StackSelection.indices(in: project(["jpg", "NEF", "NEF"]), format: .processed)
            fatalError("Must not fall back to the other format")
        } catch { assert(error.localizedDescription.contains("所选格式不足")) }
        let jpeg = try StackSelection.indices(in: project(["jpeg", "nef", "jpeg"]))
        assert(jpeg == [0, 2])
        let raw = try StackSelection.indices(in: project(["NEF", "NEF"]))
        assert(raw == [0, 1])
        do {
            _ = try StackSelection.indices(in: project(["jpg", "NEF"]))
            fatalError("One exposure must not be counted twice")
        } catch { assert(error.localizedDescription.contains("同一次曝光")) }
        var old = Adjustments()
        old.colorGrading = nil
        let encoder = JSONEncoder()
        let data = try encoder.encode(old)
        let restored = try JSONDecoder().decode(Adjustments.self, from: data)
        assert(restored.colorGrading == nil)
        print("PASS RAW+JPEG grouping, one-exposure rejection and old adjustment compatibility")
    }
}
