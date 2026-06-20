class_name RayTracer
extends RefCounted

## ----------------------------------------------------------------------
## RayTracer.gd
##
## A from-scratch CPU ray tracer for Godot 4.6, written for a numerical
## methods course project.
##
## Numerical methods used here (good to reference in your report):
##   1. Ray-Triangle intersection: Möller-Trumbore algorithm.
##      This solves a 3x3 linear system (for t, u, v barycentric coords)
##      via Cramer's rule, implemented through vector cross/dot products
##      rather than explicit matrix inversion (numerically efficient,
##      avoids forming/inverting a matrix directly).
##   2. Vector normalization: v / ||v||, with care taken to avoid
##      division by (near) zero -- a classic floating point stability
##      issue.
##   3. Lambertian shading: dot-product based cosine law for diffuse
##      reflectance, clamped to [0, 1].
##   4. Shadow rays reuse the same root-finding intersection routine,
##      with an epsilon bias added along the surface normal to avoid
##      "shadow acne" (self-intersection due to floating point error
##      at the origin of the ray).
## ----------------------------------------------------------------------

const EPSILON: float = 1e-6        # Tolerance for the Möller-Trumbore test
const SHADOW_BIAS: float = 1e-4    # Offset to avoid self-shadowing artifacts
const MAX_RENDER_DISTANCE: float = 1000.0

# --------------------------------------------------------------------
# Data structures
# --------------------------------------------------------------------

## A single triangle in world space, with precomputed vertex normals
## (for smooth/Phong-style shading) or a flat face normal as fallback,
## plus optional per-vertex UVs and a shared albedo texture for the
## mesh group it belongs to (used for textured fruit models).
class Triangle:
	var v0: Vector3
	var v1: Vector3
	var v2: Vector3
	var n0: Vector3
	var n1: Vector3
	var n2: Vector3
	var color: Color
	var uv0: Vector2 = Vector2.ZERO
	var uv1: Vector2 = Vector2.ZERO
	var uv2: Vector2 = Vector2.ZERO
	var has_uv: bool = false
	# Reference to the Image to sample for albedo color, or null to use
	# the flat `color` field instead. Shared across all triangles of
	# the same mesh group (not duplicated per-triangle in memory --
	# Godot Images are reference-counted objects).
	var albedo_image: Image = null

	func _init(p0: Vector3, p1: Vector3, p2: Vector3,
			   nn0: Vector3, nn1: Vector3, nn2: Vector3, c: Color) -> void:
		v0 = p0; v1 = p1; v2 = p2
		n0 = nn0; n1 = nn1; n2 = nn2
		color = c

	## Flat geometric normal, used as a fallback when no vertex normals
	## are available from the mesh data.
	func face_normal() -> Vector3:
		return (v1 - v0).cross(v2 - v0).normalized()

	## Resolves the surface color at given barycentric weights (w, u, v
	## for v0, v1, v2 respectively). If a texture is present and the
	## triangle has UVs, samples the texture via barycentric-interpolated
	## UV coordinates; otherwise falls back to the flat material color.
	func sample_color(w: float, u: float, v: float) -> Color:
		if albedo_image == null or not has_uv:
			return color

		var uv: Vector2 = w * uv0 + u * uv1 + v * uv2

		# UVs can legitimately fall outside [0,1] for tiling textures;
		# wrap them rather than clamp, which is the more common
		# convention for UV-mapped assets like this one.
		var tex_x: float = fposmod(uv.x, 1.0)
		var tex_y: float = fposmod(uv.y, 1.0)

		var img_w: int = albedo_image.get_width()
		var img_h: int = albedo_image.get_height()
		# Godot image V=0 is the top row; most exported UVs use V=0 at
		# the bottom (OpenGL convention), so flip Y when sampling.
		var px: int = clampi(int(tex_x * img_w), 0, img_w - 1)
		var py: int = clampi(int((1.0 - tex_y) * img_h), 0, img_h - 1)

		return albedo_image.get_pixel(px, py)


## A group of triangles belonging to one mesh instance, with a
## precomputed bounding sphere used to quickly reject rays that can't
## possibly hit anything in the group -- a simple, easy-to-explain
## spatial acceleration structure (cheaper than a full BVH, but turns
## "test every triangle of every fruit for every ray" into "test one
## sphere per fruit, then only the triangles of fruits actually hit").
class MeshGroup:
	var tris: Array[Triangle] = []
	var bounds_center: Vector3 = Vector3.ZERO
	var bounds_radius: float = 0.0

	func recompute_bounds() -> void:
		if tris.is_empty():
			bounds_radius = 0.0
			return
		# Center = average of all vertex positions (cheap approximation,
		# not the true minimal bounding sphere, but sufficient for
		# rejection purposes).
		var sum := Vector3.ZERO
		var count := 0
		for t in tris:
			sum += t.v0; sum += t.v1; sum += t.v2
			count += 3
		bounds_center = sum / float(count)

		var max_dist_sq := 0.0
		for t in tris:
			max_dist_sq = max(max_dist_sq, t.v0.distance_squared_to(bounds_center))
			max_dist_sq = max(max_dist_sq, t.v1.distance_squared_to(bounds_center))
			max_dist_sq = max(max_dist_sq, t.v2.distance_squared_to(bounds_center))
		bounds_radius = sqrt(max_dist_sq)

	## Ray-sphere intersection test, used purely as a fast reject:
	## returns true if the ray *might* hit something in this group.
	## This solves the quadratic |O + tD - C|^2 = r^2 for real roots
	## via the discriminant, without needing the actual root values.
	func ray_might_hit(ray_origin: Vector3, ray_dir: Vector3) -> bool:
		var oc: Vector3 = ray_origin - bounds_center
		var b: float = oc.dot(ray_dir)
		var c: float = oc.length_squared() - bounds_radius * bounds_radius
		# If the ray origin is already inside the bounding sphere, always test.
		if c < 0.0:
			return true
		var discriminant: float = b * b - c
		return discriminant >= 0.0 and b <= sqrt(discriminant)


## Result of a ray-scene intersection query.
class HitResult:
	var hit: bool = false
	var t: float = INF              # Ray parameter at intersection
	var point: Vector3 = Vector3.ZERO
	var normal: Vector3 = Vector3.ZERO
	var color: Color = Color.BLACK


## Simple point/directional light description.
class SceneLight:
	var position: Vector3
	var color: Color
	var energy: float
	var is_directional: bool
	var direction: Vector3   # used if is_directional == true

	func _init(pos: Vector3, col: Color, e: float,
			   directional: bool = false, dir: Vector3 = Vector3.DOWN) -> void:
		position = pos
		color = col
		energy = e
		is_directional = directional
		direction = dir.normalized()


# --------------------------------------------------------------------
# Scene state
# --------------------------------------------------------------------

var mesh_groups: Array[MeshGroup] = []
var light: SceneLight
var ambient: float = 0.08   # small ambient term so shadows aren't pure black


# --------------------------------------------------------------------
# Scene construction
# --------------------------------------------------------------------

## Clears any previously cached scene geometry.
func clear_scene() -> void:
	mesh_groups.clear()


## Pulls triangle data (world-space) out of a MeshInstance3D's ArrayMesh
## surfaces and adds them as one new MeshGroup (with its own bounding
## sphere for fast ray rejection).
##
## NOTE: this is a relatively expensive operation (walks every triangle
## of every surface), so it should be called once when (re)building the
## scene -- not per-frame and not per-pixel.
func add_mesh_instance(mesh_instance: MeshInstance3D, base_color: Color = Color.WHITE) -> void:
	var mesh := mesh_instance.mesh
	if mesh == null:
		return

	var group := MeshGroup.new()

	var world_transform: Transform3D = mesh_instance.global_transform
	# Normal vectors must be transformed by the inverse-transpose of the
	# transform's basis to remain correct under non-uniform scale.
	var normal_basis: Basis = world_transform.basis.inverse().transposed()

	for surface_idx in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(surface_idx)
		if arrays.is_empty():
			continue

		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]

		# Try to pull a material color, fall back to base_color.
		var color := base_color
		var mat := mesh_instance.get_active_material(surface_idx)
		var albedo_image: Image = null
		if mat is BaseMaterial3D:
			var std_mat := mat as BaseMaterial3D
			color = std_mat.albedo_color
			var tex: Texture2D = std_mat.albedo_texture
			if tex != null:
				albedo_image = tex.get_image()
				if albedo_image == null:
					push_warning("[RayTracer] tex.get_image() returned null for mesh '%s' -- texture may not be CPU-readable" % mesh_instance.name)
				elif albedo_image.is_compressed():
					var decomp_err := albedo_image.decompress()
					if decomp_err != OK:
						push_warning("[RayTracer] decompress() failed for mesh '%s' -- falling back to flat color" % mesh_instance.name)
						albedo_image = null

		var has_normals := normals.size() == verts.size()
		var has_uvs := uvs.size() == verts.size()

		if indices.size() > 0:
			# Indexed triangle list.
			var tri_count := indices.size() / 3
			for i in range(tri_count):
				var i0 := indices[i * 3]
				var i1 := indices[i * 3 + 1]
				var i2 := indices[i * 3 + 2]
				_add_triangle_from_indices(
					group, verts, normals, has_normals, uvs, has_uvs,
					i0, i1, i2,
					world_transform, normal_basis, color, albedo_image
				)
		else:
			# Non-indexed: every 3 verts form a triangle.
			var tri_count := verts.size() / 3
			for i in range(tri_count):
				_add_triangle_from_indices(
					group, verts, normals, has_normals, uvs, has_uvs,
					i * 3, i * 3 + 1, i * 3 + 2,
					world_transform, normal_basis, color, albedo_image
				)

	group.recompute_bounds()
	mesh_groups.append(group)


func _add_triangle_from_indices(
		group: MeshGroup,
		verts: PackedVector3Array, normals: PackedVector3Array, has_normals: bool,
		uvs: PackedVector2Array, has_uvs: bool,
		i0: int, i1: int, i2: int,
		world_transform: Transform3D, normal_basis: Basis, color: Color,
		albedo_image: Image) -> void:

	var p0 := world_transform * verts[i0]
	var p1 := world_transform * verts[i1]
	var p2 := world_transform * verts[i2]

	var n0: Vector3
	var n1: Vector3
	var n2: Vector3
	if has_normals:
		n0 = (normal_basis * normals[i0]).normalized()
		n1 = (normal_basis * normals[i1]).normalized()
		n2 = (normal_basis * normals[i2]).normalized()
	else:
		var flat := (p1 - p0).cross(p2 - p0).normalized()
		n0 = flat; n1 = flat; n2 = flat

	var tri := Triangle.new(p0, p1, p2, n0, n1, n2, color)
	if has_uvs:
		tri.uv0 = uvs[i0]
		tri.uv1 = uvs[i1]
		tri.uv2 = uvs[i2]
		tri.has_uv = true
		tri.albedo_image = albedo_image

	group.tris.append(tri)


## Adds a single quad (e.g. the floor plane) as its own MeshGroup of two
## triangles, with a uniform normal and color. p0..p3 should be given
## in winding order (e.g. counter-clockwise viewed from above).
func add_quad(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, color: Color) -> void:
	# NOTE: winding determines normal direction via the right-hand rule.
	# For p0,p1,p2,p3 wound counter-clockwise as seen from above (+Y),
	# (p2 - p0).cross(p1 - p0) points up (+Y). Getting this backwards
	# silently flips the floor normal downward, which makes every
	# N.L term <= 0 and the surface renders as pure ambient (near-black).
	var n := (p2 - p0).cross(p1 - p0).normalized()
	var group := MeshGroup.new()
	group.tris.append(Triangle.new(p0, p1, p2, n, n, n, color))
	group.tris.append(Triangle.new(p0, p2, p3, n, n, n, color))
	group.recompute_bounds()
	mesh_groups.append(group)


func set_light(scene_light: SceneLight) -> void:
	light = scene_light


# --------------------------------------------------------------------
# Core numerical method: Möller-Trumbore ray-triangle intersection
# --------------------------------------------------------------------
#
# Solves for (t, u, v) in:
#   O + t*D = (1 - u - v)*V0 + u*V1 + v*V2
#
# Rearranged into a 3x3 linear system and solved via Cramer's rule,
# expressed with cross/dot products (this avoids explicitly building
# and inverting a 3x3 matrix -- equivalent math, fewer operations).
#
# Returns t (ray parameter) if hit, or -1.0 if no valid intersection
# within (epsilon, max_t).
# --------------------------------------------------------------------

static func intersect_triangle(
		ray_origin: Vector3, ray_dir: Vector3, tri: Triangle,
		max_t: float = MAX_RENDER_DISTANCE) -> Dictionary:

	var edge1: Vector3 = tri.v1 - tri.v0
	var edge2: Vector3 = tri.v2 - tri.v0

	var pvec: Vector3 = ray_dir.cross(edge2)
	var det: float = edge1.dot(pvec)

	# If det is close to 0, the ray is (nearly) parallel to the triangle's
	# plane -- no well-defined intersection (the linear system is singular).
	if abs(det) < EPSILON:
		return {"hit": false}

	var inv_det: float = 1.0 / det
	var tvec: Vector3 = ray_origin - tri.v0

	var u: float = tvec.dot(pvec) * inv_det
	if u < 0.0 or u > 1.0:
		return {"hit": false}

	var qvec: Vector3 = tvec.cross(edge1)
	var v: float = ray_dir.dot(qvec) * inv_det
	if v < 0.0 or u + v > 1.0:
		return {"hit": false}

	var t: float = edge2.dot(qvec) * inv_det
	if t < EPSILON or t > max_t:
		return {"hit": false}

	return {"hit": true, "t": t, "u": u, "v": v}


## Finds the nearest triangle hit along a ray, if any.
##
## Uses each MeshGroup's bounding sphere as a cheap first test: if the
## ray can't possibly hit the group's bounding sphere, all of that
## group's triangles are skipped without testing them individually.
## This is what takes the per-ray cost from O(total triangles) down to
## roughly O(groups + triangles in groups actually hit).
func intersect_scene(ray_origin: Vector3, ray_dir: Vector3,
		max_t: float = MAX_RENDER_DISTANCE) -> HitResult:
	var result := HitResult.new()
	var closest_t := max_t

	for group in mesh_groups:
		if not group.ray_might_hit(ray_origin, ray_dir):
			continue
		for tri in group.tris:
			var res: Dictionary = intersect_triangle(ray_origin, ray_dir, tri, closest_t)
			if res.get("hit", false):
				var t: float = res["t"]
				if t < closest_t:
					closest_t = t
					result.hit = true
					result.t = t
					var u: float = res["u"]
					var v: float = res["v"]
					var w: float = 1.0 - u - v
					# Barycentric interpolation of the vertex normals gives
					# smooth (Phong-like) shading instead of flat faceting.
					result.normal = (w * tri.n0 + u * tri.n1 + v * tri.n2).normalized()
					result.point = ray_origin + ray_dir * t
					result.color = tri.sample_color(w, u, v)

	return result


## True if a ray from `point` toward the light is occluded before
## reaching the light (i.e. point is in shadow).
func is_in_shadow(point: Vector3, normal: Vector3) -> bool:
	if light == null:
		return false

	# Bias the shadow ray origin along the normal to avoid "shadow acne"
	# caused by the ray re-intersecting the same surface due to floating
	# point rounding at t ~= 0.
	var origin: Vector3 = point + normal * SHADOW_BIAS

	var to_light: Vector3
	var max_dist: float
	if light.is_directional:
		to_light = -light.direction
		max_dist = MAX_RENDER_DISTANCE
	else:
		var delta: Vector3 = light.position - origin
		max_dist = delta.length()
		# Guard against normalizing a (near) zero-length vector.
		if max_dist < EPSILON:
			return false
		to_light = delta / max_dist

	for group in mesh_groups:
		if not group.ray_might_hit(origin, to_light):
			continue
		for tri in group.tris:
			var res: Dictionary = intersect_triangle(origin, to_light, tri, max_dist)
			if res.get("hit", false):
				return true
	return false


# --------------------------------------------------------------------
# Shading
# --------------------------------------------------------------------

## Lambertian (diffuse) shading: I = k_d * max(0, N . L)
## Plus a flat ambient term so unlit/shadowed surfaces aren't pure black.
##
## For positional (point) lights, applies inverse-square distance
## attenuation -- physically, the same light energy spreads over a
## sphere of surface area 4*pi*d^2 as it travels, so intensity falls
## off as 1/d^2. This keeps the ray-traced view visually consistent
## with Godot's OmniLight3D in the raster view, which attenuates
## similarly. Directional lights have no meaningful distance (they
## represent parallel rays from effectively infinite distance, e.g.
## sunlight), so no attenuation is applied for those.
func shade(hit: HitResult) -> Color:
	if not hit.hit:
		return Color(0.05, 0.06, 0.09)  # background / "sky" color

	if light == null:
		return hit.color * ambient

	var light_dir: Vector3
	var attenuation := 1.0
	if light.is_directional:
		light_dir = -light.direction
	else:
		var to_light: Vector3 = light.position - hit.point
		var dist: float = to_light.length()
		if dist < EPSILON:
			light_dir = Vector3.UP  # degenerate case: point coincides with light
		else:
			light_dir = to_light / dist
			# Inverse-square falloff, with a small +1 added to the
			# denominator (a common "soft" variant) to avoid a
			# singularity (division blow-up) as dist -> 0.
			attenuation = 1.0 / (1.0 + dist * dist)

	var n_dot_l: float = clamp(hit.normal.dot(light_dir), 0.0, 1.0)

	var shadow_factor := 1.0
	if n_dot_l > 0.0 and is_in_shadow(hit.point, hit.normal):
		shadow_factor = 0.0

	var diffuse: float = n_dot_l * shadow_factor * light.energy * attenuation
	var intensity: float = ambient + diffuse * (1.0 - ambient)

	return Color(
		clamp(hit.color.r * intensity * light.color.r, 0.0, 1.0),
		clamp(hit.color.g * intensity * light.color.g, 0.0, 1.0),
		clamp(hit.color.b * intensity * light.color.b, 0.0, 1.0),
		1.0
	)


# --------------------------------------------------------------------
# Camera ray generation
# --------------------------------------------------------------------

## Generates a world-space ray (origin, direction) for pixel (px, py)
## of a `width` x `height` image, matching the given Camera3D's
## position, orientation and (vertical) field of view.
##
## This maps discrete pixel coordinates to a continuous view-space
## direction (a small but real numerical step: pixel -> NDC -> view
## space -> world space).
static func generate_camera_ray(cam: Camera3D, px: int, py: int,
		width: int, height: int) -> Dictionary:

	var fov_rad: float = deg_to_rad(cam.fov)
	var aspect: float = float(width) / float(height)

	# Half-height of the view plane at distance 1 from the camera.
	var tan_half_fov: float = tan(fov_rad * 0.5)

	# Map pixel center to normalized device coords in [-1, 1],
	# with y flipped (image row 0 is the top of the screen).
	var ndc_x: float = (2.0 * (px + 0.5) / width - 1.0)
	var ndc_y: float = (1.0 - 2.0 * (py + 0.5) / height)

	var view_x: float = ndc_x * tan_half_fov * aspect
	var view_y: float = ndc_y * tan_half_fov

	# Camera looks down -Z in Godot's convention.
	var dir_camera_space := Vector3(view_x, view_y, -1.0).normalized()
	var dir_world: Vector3 = (cam.global_transform.basis * dir_camera_space).normalized()

	return {
		"origin": cam.global_transform.origin,
		"direction": dir_world
	}


# --------------------------------------------------------------------
# Full-frame render
# --------------------------------------------------------------------

## Renders the current scene from `cam`'s point of view into an Image
## of size width x height. Returns the Image (format RGB8).
##
## samples_per_pixel > 1 enables simple jittered supersampling
## (a Monte Carlo style numerical integration of the pixel's color
## over its footprint) -- good talking point for the report if you
## want to discuss numerical integration / variance reduction.
func render(cam: Camera3D, width: int, height: int,
		samples_per_pixel: int = 1) -> Image:

	var img := Image.create(width, height, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.randomize()

	for py in range(height):
		for px in range(width):
			var accum := Color(0, 0, 0)

			if samples_per_pixel <= 1:
				var ray: Dictionary = generate_camera_ray(cam, px, py, width, height)
				var hit := intersect_scene(ray["origin"], ray["direction"])
				accum = shade(hit)
			else:
				for s in range(samples_per_pixel):
					# Jitter within the pixel footprint for antialiasing.
					var jx: float = px + rng.randf()
					var jy: float = py + rng.randf()
					var ray: Dictionary = _generate_camera_ray_subpixel(cam, jx, jy, width, height)
					var hit := intersect_scene(ray["origin"], ray["direction"])
					accum += shade(hit)
				accum /= float(samples_per_pixel)

			img.set_pixel(px, py, accum)

		# Yield control back to the engine periodically so the editor /
		# game doesn't appear frozen on larger images. Caller should
		# `await` this function from a coroutine if using this.
		if py % 16 == 0:
			pass  # see RayTraceController.gd for the async-friendly version

	return img


## Sub-pixel variant of generate_camera_ray, accepting continuous
## (fx, fy) pixel coordinates for supersampling.
static func _generate_camera_ray_subpixel(cam: Camera3D, fx: float, fy: float,
		width: int, height: int) -> Dictionary:

	var fov_rad: float = deg_to_rad(cam.fov)
	var aspect: float = float(width) / float(height)
	var tan_half_fov: float = tan(fov_rad * 0.5)

	var ndc_x: float = (2.0 * fx / width - 1.0)
	var ndc_y: float = (1.0 - 2.0 * fy / height)

	var view_x: float = ndc_x * tan_half_fov * aspect
	var view_y: float = ndc_y * tan_half_fov

	var dir_camera_space := Vector3(view_x, view_y, -1.0).normalized()
	var dir_world: Vector3 = (cam.global_transform.basis * dir_camera_space).normalized()

	return {
		"origin": cam.global_transform.origin,
		"direction": dir_world
	}
