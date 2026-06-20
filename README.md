## 1. Möller–Trumbore ray–triangle intersection (root-finding via a linear system)

**Where:** `intersect_triangle()`

**What it's solving:** Given a ray `P(t) = O + tD` and a triangle defined by vertices `V0, V1, V2`, find the point where the ray crosses the triangle's plane and check whether that point lies inside the triangle.

Any point on the triangle can be written in **barycentric coordinates**:
```
P = (1 - u - v)·V0 + u·V1 + v·V2
```
Setting the ray equation equal to this gives three scalar equations in three unknowns (`t`, `u`, `v`) — a genuine 3×3 linear system:

```
O + tD = (1-u-v)V0 + u·V1 + v·V2
```

Rearranged into matrix form `Ax = b`, this could be solved by inverting a 3×3 matrix. Möller–Trumbore instead solves it via **Cramer's rule**, but expressed entirely through cross and dot products instead of computing determinants explicitly — mathematically equivalent, but cheaper:

```gdscript
var edge1 = tri.v1 - tri.v0
var edge2 = tri.v2 - tri.v0
var pvec = ray_dir.cross(edge2)
var det = edge1.dot(pvec)          # the system's determinant
...
var u = tvec.dot(pvec) * inv_det
var v = ray_dir.dot(qvec) * inv_det
var t = edge2.dot(qvec) * inv_det
```

**Numerical edge case handled:** if `det ≈ 0` (within `EPSILON = 1e-6`), the system is singular — the ray is parallel to the triangle's plane, so there's no unique solution. That's checked explicitly before dividing, avoiding a division-by-zero / `inf` propagation.

This is the mathematical core of the whole ray tracer — every other intersection test (primary rays, shadow rays) is a call to this same root-finding routine.

## 2. Vector normalization (with a numerical stability guard)

**Where:** scattered throughout (`normalized()` calls), but the guarded version is explicit in `is_in_shadow()`:

```gdscript
var delta = light.position - origin
max_dist = delta.length()
if max_dist < EPSILON:
    return false
to_light = delta / max_dist
```

Normalizing a vector is dividing by its own magnitude, `v̂ = v / ‖v‖`. This is numerically unstable as `‖v‖ → 0` (you get a division blow-up or `NaN`). The code explicitly checks for that near-degenerate case before dividing — a basic but real example of guarding against floating-point breakdown rather than trusting the engine's built-in `normalized()` blindly in every context.

## 3. Lambertian (cosine-law) diffuse shading — a dot-product based local illumination model

**Where:** `shade()`

```gdscript
var n_dot_l = clamp(hit.normal.dot(light_dir), 0.0, 1.0)
var diffuse = n_dot_l * shadow_factor * light.energy
```

This implements **Lambert's cosine law**: the amount of light a surface reflects diffusely is proportional to the cosine of the angle between the surface normal and the direction to the light, computed as a dot product (`N · L = cos θ`). The `clamp(..., 0.0, 1.0)` step discards negative cosines (light hitting the back of a surface) — physically, light from "behind" the surface contributes zero illumination, and this is the standard way to enforce that in the math.

## 4. Ray–sphere intersection via the quadratic discriminant (bounding-volume acceleration)

**Where:** `MeshGroup.ray_might_hit()`

This is the piece you actually saw deliver a real, measured speedup (391,281 ms → 814 ms). Each mesh (the floor, each fruit) is wrapped in a bounding sphere. Testing whether a ray hits a sphere centered at `C` with radius `r` means solving:

```
‖O + tD - C‖² = r²
```

which expands into a standard quadratic `at² + bt + c = 0` (with `a = 1` since `D` is normalized). The code solves it by computing the **discriminant** directly, without finding the actual roots — since for a fast reject test, you only need to know *whether* real roots exist, not *what* they are:

```gdscript
var oc = ray_origin - bounds_center
var b = oc.dot(ray_dir)
var c = oc.length_squared() - bounds_radius * bounds_radius
var discriminant = b*b - c
return discriminant >= 0.0 and b <= sqrt(discriminant)
```

This is a textbook example of choosing the cheapest sufficient computation: you avoid computing `sqrt` and the actual `t` values whenever `discriminant < 0` (ray misses entirely), which is the common case for a ray and a mesh it isn't anywhere near.

**Why it matters numerically/algorithmically:** without this, every ray tests every triangle of every mesh — `O(total triangles)` per ray. With it, a ray that's nowhere near a given fruit skips all of that fruit's triangles after one cheap quadratic test — turning the average case into something close to `O(number of meshes + triangles actually near a hit)`. This is a simplified stand-in for the kind of spatial acceleration structures (BVH, k-d trees) used in production ray tracers, and is genuinely worth a complexity discussion (before/after Big-O, with your real timing numbers) in the report.

## 5. Barycentric interpolation (used twice: normals and UVs)

**Where:** `intersect_scene()` for normals, `Triangle.sample_color()` for UVs

Once Möller–Trumbore gives you `(u, v)` (and `w = 1 - u - v`), those same barycentric weights are reused to **linearly interpolate** any per-vertex attribute across the triangle's surface:

```gdscript
result.normal = (w * tri.n0 + u * tri.n1 + v * tri.n2).normalized()
...
var uv = w * uv0 + u * uv1 + v * uv2
```

This is what gives you smooth (Phong-style) shading instead of flat per-triangle faceting, and what lets you sample a texture image at the correct point on the lime's surface rather than getting one flat color per triangle. It's a clean illustration of how one numerical result (the root of the intersection equation) feeds directly into a second numerical technique (linear interpolation) downstream.

## 6. (Implemented but not yet enabled in your controller) Monte Carlo supersampling for antialiasing

**Where:** `render()`'s `samples_per_pixel > 1` branch, and now wired into `RayTraceController._render_row_into_image()` with default `samples_per_pixel = 4`

```gdscript
for s in range(samples_per_pixel):
    var jx = px + rng.randf()   # random jitter within the pixel
    var jy = py + rng.randf()
    ...
    accum += shade(hit)
accum /= float(samples_per_pixel)
```

Each pixel's true color is really an **integral** of incoming light over the pixel's footprint on the image plane — there's no closed-form solution for an arbitrary scene, so it's approximated via **Monte Carlo integration**: take several random sample points within the pixel, evaluate the (expensive, non-smooth) function at each, and average. This is the same fundamental idea behind Monte Carlo methods used in numerical integration generally (e.g. estimating an integral by random sampling rather than quadrature), just applied at pixel scale. More samples reduce variance (visible noise/aliasing) at a cost that scales linearly with sample count — exactly the speed/quality tradeoff you've been navigating with render time.
