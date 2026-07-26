#include "nodes/RiverNode.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <queue>
#include <vector>

#include "Heightfield.hpp"

namespace theia {
namespace {

// Terrain-traced river masks inspired by Gaea's Rivers/HydroFix workflow and
// classic DEM hydrology: condition the terrain so flow does not die in small
// pits, estimate drainage area, then build a small connected macro network with
// least-cost paths through valleys/flow corridors. The node outputs a mask by
// default; terrain carving is handled by `rivercarve` so authoring can keep
// river data separate.

struct RiverParams {
    std::uint32_t seed = 1337;
    float water = 0.65f;        // network density / wetness
    float width = 2.0f;         // visible channel width in cells
    std::uint32_t headwaters = 32;
};

struct Vec2 {
    float x = 0.0f;
    float y = 0.0f;
};

float clamp01(float v) {
    if (!std::isfinite(v)) return 0.0f;
    return std::min(1.0f, std::max(0.0f, v));
}

float smoothStep(float e0, float e1, float x) {
    if (e1 <= e0) return x >= e1 ? 1.0f : 0.0f;
    const float t = std::min(1.0f, std::max(0.0f, (x - e0) / (e1 - e0)));
    return t * t * (3.0f - 2.0f * t);
}

std::size_t idx(std::uint32_t x, std::uint32_t y, std::uint32_t w) {
    return std::size_t(y) * w + x;
}

float length(Vec2 v) {
    return std::sqrt(v.x * v.x + v.y * v.y);
}

Vec2 normalized(Vec2 v) {
    const float len = length(v);
    if (len <= 1e-7f) return {};
    return {v.x / len, v.y / len};
}

float hashUnit(std::uint32_t seed, std::uint32_t value) {
    std::uint32_t x = value + 0x9e3779b9u + (seed << 6u) + (seed >> 2u);
    x ^= x >> 16u;
    x *= 0x7feb352du;
    x ^= x >> 15u;
    x *= 0x846ca68bu;
    x ^= x >> 16u;
    return float(x >> 8u) * (1.0f / 16777216.0f);
}

RiverParams readParams(const ParamSet& params) {
    RiverParams p;
    p.seed = static_cast<std::uint32_t>(std::max(0.0, params.get("seed", 1337)));
    p.water = clamp01(static_cast<float>(params.get("water", 0.65)));
    p.width = std::min(32.0f, std::max(0.5f, static_cast<float>(params.get("width", 2.0))));
    p.headwaters =
        static_cast<std::uint32_t>(std::min(512.0, std::max(1.0, params.get("headwaters", 32))));
    return p;
}

float sample(const std::vector<float>& f, std::uint32_t w, std::uint32_t h,
             float x, float y) {
    x = std::min(float(w - 1), std::max(0.0f, x));
    y = std::min(float(h - 1), std::max(0.0f, y));
    const auto x0 = std::uint32_t(std::floor(x));
    const auto y0 = std::uint32_t(std::floor(y));
    const auto x1 = std::min(x0 + 1, w - 1);
    const auto y1 = std::min(y0 + 1, h - 1);
    const float fx = x - float(x0);
    const float fy = y - float(y0);
    const float a = f[idx(x0, y0, w)];
    const float b = f[idx(x1, y0, w)];
    const float c = f[idx(x0, y1, w)];
    const float d = f[idx(x1, y1, w)];
    return (a * (1.0f - fx) + b * fx) * (1.0f - fy) +
           (c * (1.0f - fx) + d * fx) * fy;
}

Vec2 gradient(const std::vector<float>& f, std::uint32_t w, std::uint32_t h,
              float x, float y) {
    const float gx = 0.5f * (sample(f, w, h, x + 1.0f, y) -
                             sample(f, w, h, x - 1.0f, y));
    const float gy = 0.5f * (sample(f, w, h, x, y + 1.0f) -
                             sample(f, w, h, x, y - 1.0f));
    return {gx, gy};
}

std::vector<float> boxBlur(const std::vector<float>& input, std::uint32_t w,
                           std::uint32_t h, int radius, int passes) {
    if (radius <= 0 || passes <= 0) return input;
    std::vector<float> a = input;
    std::vector<float> b(input.size());
    radius = std::max(1, radius);
    for (int pass = 0; pass < passes; ++pass) {
        for (std::uint32_t y = 0; y < h; ++y) {
            for (std::uint32_t x = 0; x < w; ++x) {
                float sum = 0.0f;
                int count = 0;
                for (int dx = -radius; dx <= radius; ++dx) {
                    const int nx = int(x) + dx;
                    if (nx < 0 || nx >= int(w)) continue;
                    sum += a[idx(std::uint32_t(nx), y, w)];
                    ++count;
                }
                b[idx(x, y, w)] = sum / float(count);
            }
        }
        for (std::uint32_t y = 0; y < h; ++y) {
            for (std::uint32_t x = 0; x < w; ++x) {
                float sum = 0.0f;
                int count = 0;
                for (int dy = -radius; dy <= radius; ++dy) {
                    const int ny = int(y) + dy;
                    if (ny < 0 || ny >= int(h)) continue;
                    sum += b[idx(x, std::uint32_t(ny), w)];
                    ++count;
                }
                a[idx(x, y, w)] = sum / float(count);
            }
        }
    }
    return a;
}

struct Cell {
    float z;
    std::size_t i;
};

struct Greater {
    bool operator()(const Cell& a, const Cell& b) const { return a.z > b.z; }
};

// Priority-flood/Barnes-style conditioning: small depressions are breached into
// a monotone routing surface, so downstream traces keep moving to an outlet.
std::vector<float> conditionedSurface(const std::vector<float>& terrain,
                                      std::uint32_t w, std::uint32_t h) {
    const std::size_t n = terrain.size();
    std::vector<float> route(n, std::numeric_limits<float>::infinity());
    std::vector<std::uint8_t> seen(n, 0);
    std::priority_queue<Cell, std::vector<Cell>, Greater> open;
    auto push = [&](std::uint32_t x, std::uint32_t y) {
        const std::size_t i = idx(x, y, w);
        if (seen[i]) return;
        seen[i] = 1;
        route[i] = terrain[i];
        open.push({terrain[i], i});
    };
    for (std::uint32_t x = 0; x < w; ++x) {
        push(x, 0);
        push(x, h - 1);
    }
    for (std::uint32_t y = 1; y + 1 < h; ++y) {
        push(0, y);
        push(w - 1, y);
    }

    constexpr float eps = 1e-6f;
    while (!open.empty()) {
        const Cell c = open.top();
        open.pop();
        const std::uint32_t x = std::uint32_t(c.i % w);
        const std::uint32_t y = std::uint32_t(c.i / w);
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                if (dx == 0 && dy == 0) continue;
                const int nx = int(x) + dx;
                const int ny = int(y) + dy;
                if (nx < 0 || ny < 0 || nx >= int(w) || ny >= int(h)) continue;
                const std::size_t ni = idx(std::uint32_t(nx), std::uint32_t(ny), w);
                if (seen[ni]) continue;
                seen[ni] = 1;
                route[ni] = std::max(terrain[ni], c.z + eps);
                open.push({route[ni], ni});
            }
        }
    }
    return route;
}

std::vector<std::size_t> receivers(const std::vector<float>& route,
                                   std::uint32_t w, std::uint32_t h,
                                   std::uint32_t seed) {
    std::vector<std::size_t> recv(route.size());
    for (std::size_t i = 0; i < route.size(); ++i) recv[i] = i;
    for (std::uint32_t y = 0; y < h; ++y) {
        for (std::uint32_t x = 0; x < w; ++x) {
            const std::size_t i = idx(x, y, w);
            float best = 0.0f;
            std::size_t bestI = i;
            for (int dy = -1; dy <= 1; ++dy) {
                for (int dx = -1; dx <= 1; ++dx) {
                    if (dx == 0 && dy == 0) continue;
                    const int nx = int(x) + dx;
                    const int ny = int(y) + dy;
                    if (nx < 0 || ny < 0 || nx >= int(w) || ny >= int(h)) continue;
                    const std::size_t ni = idx(std::uint32_t(nx), std::uint32_t(ny), w);
                    const float dist = (dx != 0 && dy != 0) ? 1.41421356f : 1.0f;
                    const float jitter =
                        (hashUnit(seed, std::uint32_t(i ^ (ni * 2654435761u))) - 0.5f) *
                        1e-7f;
                    const float slope = (route[i] - route[ni] + jitter) / dist;
                    if (slope > best) {
                        best = slope;
                        bestI = ni;
                    }
                }
            }
            recv[i] = bestI;
        }
    }
    return recv;
}

std::vector<float> multiFlowAccumulation(const std::vector<float>& route,
                                         std::uint32_t w, std::uint32_t h) {
    const std::size_t n = route.size();
    std::vector<float> acc(n, 1.0f);
    std::vector<std::size_t> order(n);
    for (std::size_t i = 0; i < n; ++i) order[i] = i;
    std::sort(order.begin(), order.end(),
              [&](std::size_t a, std::size_t b) { return route[a] > route[b]; });

    for (std::size_t i : order) {
        const std::uint32_t x = std::uint32_t(i % w);
        const std::uint32_t y = std::uint32_t(i / w);
        float weights[8];
        std::size_t targets[8];
        int count = 0;
        float sum = 0.0f;
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                if (dx == 0 && dy == 0) continue;
                const int nx = int(x) + dx;
                const int ny = int(y) + dy;
                if (nx < 0 || ny < 0 || nx >= int(w) || ny >= int(h)) continue;
                const std::size_t ni = idx(std::uint32_t(nx), std::uint32_t(ny), w);
                const float dist = (dx != 0 && dy != 0) ? 1.41421356f : 1.0f;
                const float slope = (route[i] - route[ni]) / dist;
                if (slope <= 0.0f) continue;
                const float weight = std::pow(slope, 1.35f);
                weights[count] = weight;
                targets[count] = ni;
                sum += weight;
                ++count;
            }
        }
        if (sum <= 0.0f) continue;
        for (int k = 0; k < count; ++k) {
            acc[targets[k]] += acc[i] * (weights[k] / sum);
        }
    }
    return acc;
}

float percentile(std::vector<float> values, float q) {
    if (values.empty()) return 0.0f;
    std::sort(values.begin(), values.end());
    q = std::min(1.0f, std::max(0.0f, q));
    return values[std::size_t(float(values.size() - 1) * q)];
}

void splat(std::vector<float>& mask, std::uint32_t w, std::uint32_t h,
           float x, float y, float radius, float value) {
    const int minX = std::max(0, int(std::floor(x - radius)));
    const int maxX = std::min(int(w) - 1, int(std::ceil(x + radius)));
    const int minY = std::max(0, int(std::floor(y - radius)));
    const int maxY = std::min(int(h) - 1, int(std::ceil(y + radius)));
    const float r2 = std::max(1e-4f, radius * radius);
    for (int yy = minY; yy <= maxY; ++yy) {
        for (int xx = minX; xx <= maxX; ++xx) {
            const float dx = float(xx) - x;
            const float dy = float(yy) - y;
            const float d2 = dx * dx + dy * dy;
            if (d2 > r2) continue;
            const float k = 1.0f - smoothStep(0.0f, 1.0f, d2 / r2);
            const std::size_t i = idx(std::uint32_t(xx), std::uint32_t(yy), w);
            mask[i] += value * k;
        }
    }
}

Vec2 mix(Vec2 a, Vec2 b, float t) {
    return {a.x * (1.0f - t) + b.x * t, a.y * (1.0f - t) + b.y * t};
}

void splatSegment(std::vector<float>& mask, std::uint32_t w, std::uint32_t h,
                  Vec2 a, Vec2 b, float radius, float value) {
    const float dx = b.x - a.x;
    const float dy = b.y - a.y;
    const float dist = std::sqrt(dx * dx + dy * dy);
    const int steps = std::max(1, int(std::ceil(dist / 0.22f)));
    for (int i = 0; i <= steps; ++i) {
        const float t = float(i) / float(steps);
        const Vec2 p = mix(a, b, t);
        splat(mask, w, h, p.x, p.y, radius, value);
    }
}

std::vector<Vec2> smoothPolyline(std::vector<Vec2> points, int passes) {
    if (points.size() < 3 || passes <= 0) return points;
    for (int pass = 0; pass < passes; ++pass) {
        std::vector<Vec2> out;
        out.reserve(points.size() * 2);
        out.push_back(points.front());
        for (std::size_t i = 0; i + 1 < points.size(); ++i) {
            const Vec2 a = points[i];
            const Vec2 b = points[i + 1];
            out.push_back(mix(a, b, 0.25f));
            out.push_back(mix(a, b, 0.75f));
        }
        out.push_back(points.back());
        points.swap(out);
    }
    return points;
}

std::vector<Vec2> receiverPath(std::size_t start,
                               const std::vector<std::size_t>& recv,
                               std::uint32_t w, std::uint32_t h,
                               std::uint32_t maxSteps) {
    std::vector<Vec2> path;
    path.reserve(maxSteps);
    std::size_t cur = start;
    for (std::uint32_t step = 0; step < maxSteps; ++step) {
        const std::uint32_t x = std::uint32_t(cur % w);
        const std::uint32_t y = std::uint32_t(cur / w);
        path.push_back({float(x), float(y)});
        if (x == 0 || y == 0 || x + 1 == w || y + 1 == h) break;
        const std::size_t next = recv[cur];
        if (next == cur || next >= recv.size()) break;
        cur = next;
    }
    return path;
}

float centerBias(std::uint32_t x, std::uint32_t y,
                 std::uint32_t w, std::uint32_t h,
                 float centerX, float centerY) {
    const float cx = (float(w) - 1.0f) * centerX;
    const float cy = (float(h) - 1.0f) * centerY;
    const float dx = (float(x) - cx) / std::max(1.0f, float(w) * 0.5f);
    const float dy = (float(y) - cy) / std::max(1.0f, float(h) * 0.5f);
    return clamp01(1.0f - std::sqrt(dx * dx + dy * dy));
}

std::vector<float> normalizedFlow(const std::vector<float>& acc) {
    std::vector<float> logAcc(acc.size());
    for (std::size_t i = 0; i < acc.size(); ++i) logAcc[i] = std::log1p(acc[i]);
    const float lo = percentile(logAcc, 0.50f);
    const float hi = percentile(logAcc, 0.995f);
    const float span = std::max(1e-5f, hi - lo);
    std::vector<float> flow(acc.size());
    for (std::size_t i = 0; i < acc.size(); ++i) {
        flow[i] = smoothStep(0.0f, 1.0f, (logAcc[i] - lo) / span);
    }
    return flow;
}

std::size_t chooseConfluence(const std::vector<float>& terrain,
                             const std::vector<float>& flow,
                             std::uint32_t w, std::uint32_t h,
                             std::uint32_t seed) {
    const std::uint32_t margin =
        std::max<std::uint32_t>(4u, std::min(w, h) / 7u);
    const float centerX = 0.38f + 0.24f * hashUnit(seed, 0x613a31u);
    const float centerY = 0.34f + 0.28f * hashUnit(seed, 0x9f4a7cu);
    std::size_t best = idx(w / 2u, h / 2u, w);
    float bestScore = -std::numeric_limits<float>::infinity();
    for (std::uint32_t y = margin; y + margin < h; ++y) {
        for (std::uint32_t x = margin; x + margin < w; ++x) {
            const std::size_t i = idx(x, y, w);
            const float valley = 1.0f - terrain[i];
            const float central = centerBias(x, y, w, h, centerX, centerY);
            const float jitter = (hashUnit(seed, std::uint32_t(i)) - 0.5f) * 0.055f;
            // Favor the actual DEM drainage signature over a fixed art-directed
            // center. This keeps the macro river network responsive when the
            // upstream terrain has already been eroded, blended, or carved.
            const float score = 0.45f * flow[i] + 0.32f * valley +
                                0.18f * central + jitter;
            if (score > bestScore) {
                bestScore = score;
                best = i;
            }
        }
    }
    return best;
}

struct AnchorSpec {
    int side; // 0 left, 1 right, 2 top, 3 bottom
    float t;
};

struct RiverAnchor {
    std::size_t cell;
    AnchorSpec spec;
};

std::size_t chooseAnchor(const std::vector<float>& terrain,
                         const std::vector<float>& flow,
                         const std::vector<std::size_t>& existing,
                         AnchorSpec spec,
                         std::uint32_t w, std::uint32_t h,
                         std::uint32_t seed,
                         std::uint32_t ordinal) {
    const std::uint32_t edgeBand =
        std::max<std::uint32_t>(2u, std::min(w, h) / 32u);
    const std::uint32_t window =
        std::max<std::uint32_t>(6u, std::min(w, h) / 9u);
    std::uint32_t x0 = 0, x1 = w - 1, y0 = 0, y1 = h - 1;
    const std::uint32_t targetX =
        std::uint32_t(std::min(float(w - 1), std::max(0.0f, spec.t * float(w - 1))));
    const std::uint32_t targetY =
        std::uint32_t(std::min(float(h - 1), std::max(0.0f, spec.t * float(h - 1))));
    if (spec.side == 0) {
        x1 = edgeBand;
        y0 = targetY > window ? targetY - window : 0u;
        y1 = std::min(h - 1, targetY + window);
    } else if (spec.side == 1) {
        x0 = w - 1 - edgeBand;
        y0 = targetY > window ? targetY - window : 0u;
        y1 = std::min(h - 1, targetY + window);
    } else if (spec.side == 2) {
        y1 = edgeBand;
        x0 = targetX > window ? targetX - window : 0u;
        x1 = std::min(w - 1, targetX + window);
    } else {
        y0 = h - 1 - edgeBand;
        x0 = targetX > window ? targetX - window : 0u;
        x1 = std::min(w - 1, targetX + window);
    }

    std::size_t best = idx(targetX, targetY, w);
    float bestScore = -std::numeric_limits<float>::infinity();
    const float minSep = float(std::min(w, h)) * 0.16f;
    const float minSep2 = minSep * minSep;
    for (std::uint32_t y = y0; y <= y1; ++y) {
        for (std::uint32_t x = x0; x <= x1; ++x) {
            const std::size_t i = idx(x, y, w);
            bool farEnough = true;
            for (std::size_t e : existing) {
                const float dx = float(int(x) - int(e % w));
                const float dy = float(int(y) - int(e / w));
                if (dx * dx + dy * dy < minSep2) {
                    farEnough = false;
                    break;
                }
            }
            if (!farEnough) continue;
            const float valley = 1.0f - terrain[i];
            const float slotX = spec.side < 2 ? float(x) :
                std::min(float(w - 1), std::max(0.0f, spec.t * float(w - 1)));
            const float slotY = spec.side < 2 ?
                std::min(float(h - 1), std::max(0.0f, spec.t * float(h - 1))) :
                float(y);
            const float dx = (float(x) - slotX) / std::max(1.0f, float(window));
            const float dy = (float(y) - slotY) / std::max(1.0f, float(window));
            const float slotBias = clamp01(1.0f - std::sqrt(dx * dx + dy * dy));
            const float jitter =
                (hashUnit(seed + ordinal * 747796405u, std::uint32_t(i)) - 0.5f) * 0.07f;
            const float score = 0.31f * flow[i] + 0.30f * valley +
                                0.25f * slotBias + 0.07f * terrain[i] + jitter;
            if (score > bestScore) {
                bestScore = score;
                best = i;
            }
        }
    }
    return best;
}

std::vector<RiverAnchor> chooseAnchors(const std::vector<float>& terrain,
                                       const std::vector<float>& flow,
                                       std::uint32_t w, std::uint32_t h,
                                       const RiverParams& p) {
    const AnchorSpec specs[] = {
        {0, 0.32f}, {2, 0.56f}, {1, 0.36f}, {1, 0.68f},
        {0, 0.74f}, {3, 0.52f}, {2, 0.22f}, {1, 0.86f},
    };
    const std::size_t specCount = sizeof(specs) / sizeof(specs[0]);
    const std::uint32_t specOffset =
        std::uint32_t(hashUnit(p.seed, 0xabc123u) * float(specCount));
    const std::uint32_t desired =
        std::max(3u, std::min(8u, std::uint32_t(std::round(
            std::sqrt(float(std::max(1u, p.headwaters))) * 1.35f + 1.0f))));
    std::vector<std::size_t> existing;
    std::vector<RiverAnchor> anchors;
    anchors.reserve(desired);
    for (std::uint32_t i = 0; i < desired; ++i) {
        AnchorSpec spec = specs[(i + specOffset) % specCount];
        const float tJitter =
            (hashUnit(p.seed + i * 1664525u, 0x51ed270bu) - 0.5f) * 0.34f;
        spec.t = std::min(0.92f, std::max(0.08f, spec.t + tJitter));
        const std::size_t cell =
            chooseAnchor(terrain, flow, existing, spec, w, h, p.seed, i);
        existing.push_back(cell);
        anchors.push_back({cell, spec});
    }
    return anchors;
}

std::vector<float> riverCostField(const std::vector<float>& terrain,
                                  const std::vector<float>& route,
                                  const std::vector<float>& flow,
                                  std::uint32_t w, std::uint32_t h,
                                  std::uint32_t seed) {
    std::vector<float> seedField(terrain.size());
    for (std::size_t i = 0; i < seedField.size(); ++i) {
        seedField[i] = hashUnit(seed ^ 0x68bc21ebu, std::uint32_t(i));
    }
    seedField = boxBlur(seedField, w, h,
                        std::max(2, int(std::min(w, h) / 64u)), 3);

    std::vector<float> cost(terrain.size());
    for (std::uint32_t y = 0; y < h; ++y) {
        for (std::uint32_t x = 0; x < w; ++x) {
            const std::size_t i = idx(x, y, w);
            const Vec2 g = gradient(route, w, h, float(x), float(y));
            const float valley = 1.0f - terrain[i];
            const float channel = smoothStep(0.18f, 0.88f, flow[i]);
            cost[i] = std::max(0.035f, 0.18f + terrain[i] * 0.60f +
                                           length(g) * 1.25f -
                                           channel * 0.92f -
                                           valley * 0.28f +
                                           (seedField[i] - 0.5f) * 0.22f);
        }
    }
    return boxBlur(cost, w, h, 1, 1);
}

struct PathCell {
    float f;
    std::size_t i;
};

struct PathGreater {
    bool operator()(const PathCell& a, const PathCell& b) const { return a.f > b.f; }
};

std::vector<std::size_t> leastCostPath(std::size_t start,
                                       std::size_t goal,
                                       const std::vector<float>& terrain,
                                       const std::vector<float>& cost,
                                       std::uint32_t w,
                                       std::uint32_t h) {
    const std::size_t n = terrain.size();
    constexpr float inf = std::numeric_limits<float>::infinity();
    constexpr std::size_t none = std::numeric_limits<std::size_t>::max();
    std::vector<float> gScore(n, inf);
    std::vector<std::size_t> parent(n, none);
    std::vector<std::uint8_t> closed(n, 0);
    std::priority_queue<PathCell, std::vector<PathCell>, PathGreater> open;
    const auto heuristic = [&](std::size_t i) {
        const float dx = float(int(i % w) - int(goal % w));
        const float dy = float(int(i / w) - int(goal / w));
        return std::sqrt(dx * dx + dy * dy) * 0.06f;
    };

    gScore[start] = 0.0f;
    open.push({heuristic(start), start});
    while (!open.empty()) {
        const PathCell cur = open.top();
        open.pop();
        if (closed[cur.i]) continue;
        closed[cur.i] = 1;
        if (cur.i == goal) break;
        const std::uint32_t x = std::uint32_t(cur.i % w);
        const std::uint32_t y = std::uint32_t(cur.i / w);
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                if (dx == 0 && dy == 0) continue;
                const int nx = int(x) + dx;
                const int ny = int(y) + dy;
                if (nx < 0 || ny < 0 || nx >= int(w) || ny >= int(h)) continue;
                const std::size_t ni = idx(std::uint32_t(nx), std::uint32_t(ny), w);
                if (closed[ni]) continue;
                const float dist = (dx != 0 && dy != 0) ? 1.41421356f : 1.0f;
                const float climb = std::max(0.0f, terrain[ni] - terrain[cur.i]);
                const float descend = std::max(0.0f, terrain[cur.i] - terrain[ni]);
                const float edge =
                    dist * (0.12f + cost[ni]) + climb * 1.65f - descend * 0.08f;
                const float tentative = gScore[cur.i] + std::max(0.01f, edge);
                if (tentative < gScore[ni]) {
                    gScore[ni] = tentative;
                    parent[ni] = cur.i;
                    open.push({tentative + heuristic(ni), ni});
                }
            }
        }
    }

    std::vector<std::size_t> path;
    if (parent[goal] == none && start != goal) return path;
    for (std::size_t cur = goal; cur != none; cur = parent[cur]) {
        path.push_back(cur);
        if (cur == start) break;
    }
    std::reverse(path.begin(), path.end());
    return path;
}

std::vector<Vec2> cellPathToPolyline(const std::vector<std::size_t>& cells,
                                     std::uint32_t w) {
    std::vector<Vec2> points;
    points.reserve(cells.size());
    for (std::size_t c : cells) {
        points.push_back({float(c % w), float(c / w)});
    }
    return points;
}

std::vector<Vec2> decimatePolyline(const std::vector<Vec2>& points,
                                   float minSpacing) {
    if (points.size() < 3) return points;
    std::vector<Vec2> out;
    out.reserve(points.size());
    out.push_back(points.front());
    Vec2 last = points.front();
    for (std::size_t i = 1; i + 1 < points.size(); ++i) {
        const Vec2 p = points[i];
        if (length({p.x - last.x, p.y - last.y}) >= minSpacing) {
            out.push_back(p);
            last = p;
        }
    }
    if (length({points.back().x - out.back().x,
                points.back().y - out.back().y}) > 0.01f) {
        out.push_back(points.back());
    }
    return out;
}

std::vector<Vec2> relaxPolyline(std::vector<Vec2> points, int passes) {
    if (points.size() < 4 || passes <= 0) return points;
    for (int pass = 0; pass < passes; ++pass) {
        std::vector<Vec2> out = points;
        for (std::size_t i = 1; i + 1 < points.size(); ++i) {
            out[i] = {
                points[i - 1].x * 0.22f + points[i].x * 0.56f + points[i + 1].x * 0.22f,
                points[i - 1].y * 0.22f + points[i].y * 0.56f + points[i + 1].y * 0.22f,
            };
        }
        points.swap(out);
    }
    return points;
}

void clampPolyline(std::vector<Vec2>& points, std::uint32_t w, std::uint32_t h);

std::vector<Vec2> seedMeanderPolyline(std::vector<Vec2> points,
                                      std::uint32_t seed,
                                      std::uint32_t ordinal,
                                      std::uint32_t w,
                                      std::uint32_t h) {
    if (points.size() < 4) return points;
    const float amplitude = std::max(1.0f, float(std::min(w, h)) * 0.012f);
    for (std::size_t i = 1; i + 1 < points.size(); ++i) {
        const Vec2 tangent = {
            points[i + 1].x - points[i - 1].x,
            points[i + 1].y - points[i - 1].y,
        };
        const Vec2 n = normalized({-tangent.y, tangent.x});
        const float endFade =
            smoothStep(0.0f, 0.22f, float(i) / float(points.size() - 1)) *
            smoothStep(0.0f, 0.22f, float(points.size() - 1 - i) /
                                      float(points.size() - 1));
        const std::uint32_t h0 =
            std::uint32_t(i * 2654435761u) ^ (ordinal * 747796405u);
        const float jitter = hashUnit(seed, h0) * 2.0f - 1.0f;
        points[i].x += n.x * amplitude * jitter * endFade;
        points[i].y += n.y * amplitude * jitter * endFade;
    }
    clampPolyline(points, w, h);
    return relaxPolyline(std::move(points), 2);
}

Vec2 catmull(Vec2 p0, Vec2 p1, Vec2 p2, Vec2 p3, float t) {
    const float t2 = t * t;
    const float t3 = t2 * t;
    return {
        0.5f * ((2.0f * p1.x) + (-p0.x + p2.x) * t +
                (2.0f * p0.x - 5.0f * p1.x + 4.0f * p2.x - p3.x) * t2 +
                (-p0.x + 3.0f * p1.x - 3.0f * p2.x + p3.x) * t3),
        0.5f * ((2.0f * p1.y) + (-p0.y + p2.y) * t +
                (2.0f * p0.y - 5.0f * p1.y + 4.0f * p2.y - p3.y) * t2 +
                (-p0.y + 3.0f * p1.y - 3.0f * p2.y + p3.y) * t3),
    };
}

std::vector<Vec2> catmullPolyline(const std::vector<Vec2>& points,
                                  int subdivisions) {
    if (points.size() < 3 || subdivisions <= 1) return points;
    std::vector<Vec2> out;
    out.reserve(points.size() * std::size_t(subdivisions));
    for (std::size_t i = 0; i + 1 < points.size(); ++i) {
        const Vec2 p0 = i == 0 ? points[i] : points[i - 1];
        const Vec2 p1 = points[i];
        const Vec2 p2 = points[i + 1];
        const Vec2 p3 = (i + 2 < points.size()) ? points[i + 2] : p2;
        for (int s = 0; s < subdivisions; ++s) {
            out.push_back(catmull(p0, p1, p2, p3,
                                  float(s) / float(subdivisions)));
        }
    }
    out.push_back(points.back());
    return out;
}

void clampPolyline(std::vector<Vec2>& points, std::uint32_t w, std::uint32_t h) {
    for (Vec2& p : points) {
        p.x = std::min(float(w - 1), std::max(0.0f, p.x));
        p.y = std::min(float(h - 1), std::max(0.0f, p.y));
    }
}

Vec2 boundaryPoint(const RiverAnchor& anchor, std::uint32_t w, std::uint32_t h) {
    const float x = float(anchor.cell % w);
    const float y = float(anchor.cell / w);
    if (anchor.spec.side == 0) return {0.0f, y};
    if (anchor.spec.side == 1) return {float(w - 1), y};
    if (anchor.spec.side == 2) return {x, 0.0f};
    return {x, float(h - 1)};
}

std::size_t entryCell(const RiverAnchor& anchor, std::uint32_t w, std::uint32_t h) {
    const std::uint32_t inset =
        std::max<std::uint32_t>(4u, std::min(w, h) / 24u);
    const std::uint32_t x = std::uint32_t(anchor.cell % w);
    const std::uint32_t y = std::uint32_t(anchor.cell / w);
    if (anchor.spec.side == 0) return idx(std::min(inset, w - 1), y, w);
    if (anchor.spec.side == 1) return idx(w - 1 - std::min(inset, w - 1), y, w);
    if (anchor.spec.side == 2) return idx(x, std::min(inset, h - 1), w);
    return idx(x, h - 1 - std::min(inset, h - 1), w);
}

std::vector<std::size_t> selectHeadwaters(const std::vector<float>& terrain,
                                          const std::vector<float>& route,
                                          const std::vector<float>& acc,
                                          std::uint32_t w, std::uint32_t h,
                                          const RiverParams& p) {
    const float minElevation = percentile(terrain, 0.58f);
    const std::vector<float> logAcc = [&] {
        std::vector<float> v(acc.size());
        for (std::size_t i = 0; i < acc.size(); ++i) v[i] = std::log1p(acc[i]);
        return v;
    }();
    const float accHi = percentile(logAcc, 0.995f);
    const float accLo = percentile(logAcc, 0.25f);
    const float accSpan = std::max(1e-5f, accHi - accLo);

    std::vector<std::size_t> candidates(terrain.size());
    for (std::size_t i = 0; i < terrain.size(); ++i) candidates[i] = i;
    std::sort(candidates.begin(), candidates.end(), [&](std::size_t a, std::size_t b) {
        const Vec2 ga = gradient(route, w, h, float(a % w), float(a / w));
        const Vec2 gb = gradient(route, w, h, float(b % w), float(b / w));
        const float aa = smoothStep(0.0f, 1.0f, (std::log1p(acc[a]) - accLo) / accSpan);
        const float ab = smoothStep(0.0f, 1.0f, (std::log1p(acc[b]) - accLo) / accSpan);
        const float sa = terrain[a] + 0.12f * length(ga) - 0.08f * aa +
                         0.035f * hashUnit(p.seed, std::uint32_t(a));
        const float sb = terrain[b] + 0.12f * length(gb) - 0.08f * ab +
                         0.035f * hashUnit(p.seed, std::uint32_t(b));
        return sa > sb;
    });

    const std::uint32_t target =
        std::max(1u, std::min<std::uint32_t>(512u, p.headwaters));
    const float waterBoost = 0.75f + p.water * 0.65f;
    const float minSep = std::max(3.0f, std::min(float(w), float(h)) /
                                            (std::sqrt(float(target)) * waterBoost));
    const float minSep2 = minSep * minSep;
    std::vector<std::size_t> selected;
    selected.reserve(target);
    for (std::size_t candidate : candidates) {
        if (selected.size() >= target) break;
        const std::uint32_t x = std::uint32_t(candidate % w);
        const std::uint32_t y = std::uint32_t(candidate / w);
        if (x < 2 || y < 2 || x + 3 >= w || y + 3 >= h) continue;
        if (terrain[candidate] < minElevation) break;
        bool farEnough = true;
        for (std::size_t s : selected) {
            const float dx = float(int(x) - int(s % w));
            const float dy = float(int(y) - int(s / w));
            if (dx * dx + dy * dy < minSep2) {
                farEnough = false;
                break;
            }
        }
        if (farEnough) selected.push_back(candidate);
    }
    return selected;
}

std::vector<float> riverMask(const std::vector<float>& terrain,
                             const RiverParams& p,
                             std::uint32_t w, std::uint32_t h) {
    const std::size_t n = terrain.size();
    const std::vector<float> routingBase = boxBlur(terrain, w, h, 1, 1);
    const std::vector<float> route = conditionedSurface(routingBase, w, h);
    const std::vector<float> acc = multiFlowAccumulation(route, w, h);
    const std::vector<float> flow = normalizedFlow(acc);
    const std::vector<float> cost = riverCostField(terrain, route, flow, w, h, p.seed);
    const std::size_t confluence = chooseConfluence(terrain, flow, w, h, p.seed);
    const std::vector<RiverAnchor> anchors = chooseAnchors(terrain, flow, w, h, p);
    std::vector<float> trace(n, 0.0f);

    const float spacing = std::max(7.0f, float(std::min(w, h)) / 26.0f);
    const float baseRadius = std::max(0.75f, p.width * (0.50f + 0.18f * p.water));
    for (std::size_t anchorIndex = 0; anchorIndex < anchors.size(); ++anchorIndex) {
        const RiverAnchor& anchor = anchors[anchorIndex];
        const std::size_t start = entryCell(anchor, w, h);
        std::vector<std::size_t> cells =
            leastCostPath(start, confluence, route, cost, w, h);
        if (cells.size() < 2) continue;
        std::vector<Vec2> path = cellPathToPolyline(cells, w);
        path = decimatePolyline(path, spacing);
        path.insert(path.begin(), boundaryPoint(anchor, w, h));
        path = relaxPolyline(std::move(path), 3);
        path = catmullPolyline(path, 10);
        clampPolyline(path, w, h);
        path = relaxPolyline(std::move(path), 2);
        if (path.size() < 2) continue;
        for (std::size_t i = 0; i + 1 < path.size(); ++i) {
            const Vec2 a = path[i];
            const Vec2 b = path[i + 1];
            const Vec2 mid = mix(a, b, 0.5f);
            const float localFlow = sample(flow, w, h, mid.x, mid.y);
            const float radius = baseRadius * (0.82f + 0.42f * localFlow);
            splatSegment(trace, w, h, a, b, radius, 0.80f + 0.32f * localFlow);
        }
    }

    std::vector<float> mask(n);
    for (std::size_t i = 0; i < n; ++i) {
        mask[i] = clamp01(trace[i]);
    }
    mask = boxBlur(mask, w, h, std::max(1, int(std::ceil(p.width * 0.75f))), 3);
    for (float& v : mask) {
        v = smoothStep(0.045f, 0.56f, v);
    }
    return mask;
}

} // namespace

RiverNode::RiverNode(std::string id) : Node(std::move(id), "river") {
    params.set("water", 0.65);
    params.set("width", 2.0);
    params.set("headwaters", 32);
    params.set("seed", 1337);
}

bool RiverNode::evaluate(GPUContext&,
                         const std::vector<const Heightfield*>& inputs,
                         Heightfield& out, std::string& error) {
    if (inputs.size() != 1 || !inputs[0]) {
        error = "river '" + id() + "' requires 1 input";
        return false;
    }
    const Heightfield* in = inputs[0];
    const std::uint32_t w = in->width();
    const std::uint32_t h = in->height();
    const RiverParams p = readParams(params);

    std::vector<float> terrain(in->data(), in->data() + in->count());
    for (float& v : terrain) v = clamp01(v);

    // River is a mask/data node; destructive carving belongs in `rivercarve`.
    const std::vector<float> mask = riverMask(terrain, p, w, h);
    for (std::size_t i = 0; i < terrain.size(); ++i) {
        out.data()[i] = clamp01(mask[i]);
    }
    return true;
}

} // namespace theia
