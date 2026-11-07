#pragma once
#include <vector>
#include <string>
#include <functional>
#include <atomic>

namespace astra {
struct Star { double x, y, flux, radius; };
struct Analysis { std::vector<Star> stars; double background=0, noise=0, quality=0; };
// Maps reference pixel centers into source pixel centers.
struct Transform {
    double a=1, b=0, tx=0, ty=0;
    int matches=0;
    double rms=0;
};
Analysis analyze(const float* rgba, int width, int height, double skyFraction=1);
Transform align(const Analysis& reference, const Analysis& source);
Transform liftToFullResolution(Transform proxyTransform, double proxyScale);
struct Input { std::string path; Transform transform; double weight=1; };
enum class Mode { sky=0, landscape=1, trails=2 };
struct Settings {
    Mode mode=Mode::sky;
    double sigma=3;
    // Fraction of image height from TOP, sky ends at this horizontal boundary.
    double skyFraction=0.65, feather=0.03;
    double minimumCoverage=0.8;
};
// Raw cache: little endian native float32 RGBA, row 0 at Core Image's bottom.
// Streaming/tiled compute with mapped input windows. Output commits on success only.
void stack(const std::vector<Input>& inputs, int width, int height,
           const Settings& settings, const std::string& output,
           std::atomic<bool>& cancelled, const std::function<void(double)>& progress);
}
