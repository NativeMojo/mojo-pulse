import Foundation
import CoreGraphics
import SwiftUI

/// Equirectangular (plate-carrée) projection, re-centerable on any longitude.
/// We draw our own vector world map in a SwiftUI Canvas (not MapKit) so endpoints
/// can be plotted as a custom overlay. Centering on the user's longitude puts
/// them in the middle and makes trans-Pacific connections (e.g. SF→Tokyo) draw
/// to the correct side instead of smearing across the dateline — the curved
/// meridians of Natural Earth can't re-center cleanly, equirectangular can.
/// Degrees → screen points fitted to `size`, centered, y growing DOWNWARD.
enum MapProjection {
    /// Normalize a longitude delta into [-180, 180].
    static func wrapLon(_ d: Double) -> Double {
        var v = d.truncatingRemainder(dividingBy: 360)
        if v > 180 { v -= 360 } else if v < -180 { v += 360 }
        return v
    }

    /// Degrees-per-point scale that fits the whole world in `size`.
    static func scale(in size: CGSize) -> CGFloat {
        min(size.width / 360, size.height / 180)
    }

    /// Project lon/lat (degrees) into `size`, with the map centered on
    /// `centerLon`. Longitudes are measured relative to that center and wrapped,
    /// so the user sits at the horizontal middle.
    static func project(lon: Double, lat: Double, in size: CGSize, centerLon: Double = 0) -> CGPoint {
        let k = scale(in: size)
        let rel = wrapLon(lon - centerLon)
        return CGPoint(x: size.width / 2 + rel * k, y: size.height / 2 - lat * k)
    }

    /// Great-circle samples (spherical slerp) between two lon/lat points, as
    /// (lon, lat) CGPoints in degrees. Drawing an arc through these makes it bow
    /// along the globe like a flight path, instead of a straight line in
    /// projected space.
    static func greatCircle(_ a: CGPoint, _ b: CGPoint, steps: Int = 64) -> [CGPoint] {
        func vec(_ lon: Double, _ lat: Double) -> (Double, Double, Double) {
            let la = lat * .pi / 180, lo = lon * .pi / 180
            return (cos(la) * cos(lo), cos(la) * sin(lo), sin(la))
        }
        let v1 = vec(a.x, a.y), v2 = vec(b.x, b.y)
        let dot = max(-1, min(1, v1.0 * v2.0 + v1.1 * v2.1 + v1.2 * v2.2))
        let omega = acos(dot)
        guard omega > 1e-6 else { return [a, b] }
        let so = sin(omega)
        var out: [CGPoint] = []
        out.reserveCapacity(steps + 1)
        for i in 0...steps {
            let f = Double(i) / Double(steps)
            let s1 = sin((1 - f) * omega) / so, s2 = sin(f * omega) / so
            let x = s1 * v1.0 + s2 * v2.0, y = s1 * v1.1 + s2 * v2.1, z = s1 * v1.2 + s2 * v2.2
            let lat = asin(max(-1, min(1, z))) * 180 / .pi
            let lon = atan2(y, x) * 180 / .pi
            out.append(CGPoint(x: lon, y: lat))
        }
        return out
    }
}

/// Loads the bundled simplified country outlines (Resources/WorldOutline.json,
/// shape `{"rings":[[lon,lat,lon,lat,...], ...]}`) into raw lon/lat rings for
/// the Canvas to stroke/fill. Each ring is a flat lon,lat list; we keep the
/// degrees unprojected here and project at draw time so the same data adapts to
/// any Canvas size. Loads once, lazily.
enum WorldMap {
    /// All landmass rings, points as CGPoint(x: lon, y: lat) in DEGREES.
    /// Empty if the resource is missing (e.g. `swift run`, where the bundle
    /// layout differs) — never crashes.
    static let rings: [[CGPoint]] = loadRings()

    private static func loadRings() -> [[CGPoint]] {
        guard let url = Bundle.main.url(forResource: "WorldOutline", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let flatRings = doc["rings"] as? [[Double]] else {
            return []
        }
        return flatRings.map { flat in
            var pts: [CGPoint] = []
            pts.reserveCapacity(flat.count / 2)
            var i = 0
            while i + 1 < flat.count {
                pts.append(CGPoint(x: flat[i], y: flat[i + 1])) // x=lon, y=lat
                i += 2
            }
            return pts
        }
    }

    /// One Path of every ring, projected into `size` centered on `centerLon`.
    /// A ring edge that wraps across the seam (the meridian opposite the center)
    /// would otherwise draw a long horizontal smear, so we break the subpath
    /// there. Subpaths are left open; SwiftUI implicitly closes them when filling.
    static func landPath(in size: CGSize, centerLon: Double) -> Path {
        var path = Path()
        let halfW = size.width / 2
        for ring in rings {
            var prev: CGPoint?
            for p in ring {
                let pt = MapProjection.project(lon: p.x, lat: p.y, in: size, centerLon: centerLon)
                if let pr = prev, abs(pt.x - pr.x) > halfW {
                    path.move(to: pt)            // seam crossing → start a new subpath
                } else if prev == nil {
                    path.move(to: pt)
                } else {
                    path.addLine(to: pt)
                }
                prev = pt
            }
        }
        return path
    }
}
