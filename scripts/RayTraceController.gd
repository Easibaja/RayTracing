extends Node3D

## ----------------------------------------------------------------------
## RayTraceController.gd
##
## Sits on the Main scene root. Responsibilities:
##   - Lets the player pan/fly the Camera3D in "normal" mode.
##   - On toggle (default: R key), freezes the camera and renders a
##     single frame with the from-scratch RayTracer, displaying it on
##     a full-screen TextureRect.
##   - Toggling again hides the ray-traced image and resumes normal
##     camera control.
##
## Attach to: Main (Node3D)
## Expects child nodes (see scenes/Main.tscn):
##   Camera3D            -- the flyable camera
##   DirectionalLight3D   -- the single light, shared by both renderers
##   Floor (MeshInstance3D)
##   Fruits (Node3D)       -- parent grouping all fruit MeshInstance3D nodes
##   CanvasLayer/TextureRect -- full-screen overlay for the RT image
##   CanvasLayer/Label       -- small HUD text (mode + render time)
## ----------------------------------------------------------------------

@export var move_speed: float = 4.0
@export var look_sensitivity: float = 0.0035
@export var light_move_speed: float = 3.0
@export var light_height: float = 4.0   # fixed Y height for the light as it orbits/moves
@export var use_viewport_resolution: bool = true  # if true, ignores render_width/height below and uses the actual window size
@export var render_width: int = 320               # only used if use_viewport_resolution is false
@export var render_height: int = 180               # only used if use_viewport_resolution is false
@export var samples_per_pixel: int = 4   # antialiasing quality; higher = smoother edges/shadows, slower
@export var rows_per_frame: int = 4       # render this many image rows per engine frame
# With the MeshGroup bounding-sphere fast-reject in RayTracer.gd, a
# scene with a handful of low-poly fruit meshes (hundreds, not
# thousands, of triangles each) renders quickly at low resolutions.
# Full viewport resolution (e.g. 1920x1080) at higher spp can take
# anywhere from several seconds to a few minutes in GDScript -- this
# is fine for a non-live demo where you toggle and just wait, but
# expect render time to scale roughly linearly with pixel count and
# with samples_per_pixel. If a render is taking unexpectedly long even
# accounting for that, check the Sketchfab import's triangle count --
# high-poly decimated meshes are the most common non-obvious cause of
# slow CPU ray tracing.

@onready var camera: Camera3D = $Camera3D
@onready var light_node: OmniLight3D = $OmniLight3D
@onready var fruits_root: Node3D = $Fruits
@onready var floor_mesh: MeshInstance3D = $Floor
@onready var rt_overlay: TextureRect = $CanvasLayer/TextureRect
@onready var hud_label: Label = $CanvasLayer/Label

var _raytracer: RayTracer
var _is_raytrace_mode: bool = false
var _is_rendering: bool = false
var _mouse_captured: bool = true

# Async render state (so we don't freeze the engine on a big image).
var _render_image: Image
var _render_row: int = 0
var _render_cam_origin: Vector3
var _render_cam_basis: Basis
var _render_start_msec: int = 0
var _active_width: int = 0
var _active_height: int = 0


func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	_build_scene_data()
	_update_hud("RASTER (live) -- press R to ray trace")


## Walks the live scene and (re)builds the RayTracer's internal
## triangle list + light. Call this whenever geometry moves, or once
## at startup for a static scene.
func _build_scene_data() -> void:
	_raytracer = RayTracer.new()
	_raytracer.clear_scene()

	# Floor as a quad (two triangles) so it goes through the same
	# intersection code path as everything else.
	var floor_aabb := floor_mesh.mesh.get_aabb()
	var ft: Transform3D = floor_mesh.global_transform
	var half_x: float = floor_aabb.size.x * 0.5
	var half_z: float = floor_aabb.size.z * 0.5
	var y: float = ft.origin.y

	var p0 := ft.origin + Vector3(-half_x, 0, -half_z)
	var p1 := ft.origin + Vector3(half_x, 0, -half_z)
	var p2 := ft.origin + Vector3(half_x, 0, half_z)
	var p3 := ft.origin + Vector3(-half_x, 0, half_z)
	_raytracer.add_quad(p0, p1, p2, p3, Color(0.55, 0.52, 0.48))

	# All fruit meshes, recursively, under Fruits/.
	for child in _get_all_mesh_instances(fruits_root):
		_raytracer.add_mesh_instance(child)

	# Light: a positional point light, matching the OmniLight3D's actual
	# world position, color and energy. is_directional=false tells the
	# RayTracer to compute the light direction per-hit-point (point
	# toward light.position), rather than using one fixed direction --
	# this is what makes shadows rotate correctly as the light orbits.
	var scene_light := RayTracer.SceneLight.new(
		light_node.global_transform.origin,
		light_node.light_color,
		light_node.light_energy,
		false
	)
	_raytracer.set_light(scene_light)


func _get_all_mesh_instances(root: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	for child in root.get_children():
		if child is MeshInstance3D:
			result.append(child)
		result.append_array(_get_all_mesh_instances(child))
	return result


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_raytrace"):
		_toggle_raytrace_mode()
		return

	if event.is_action_pressed("ui_cancel"):
		_mouse_captured = not _mouse_captured
		Input.set_mouse_mode(
			Input.MOUSE_MODE_CAPTURED if _mouse_captured else Input.MOUSE_MODE_VISIBLE
		)

	if _is_raytrace_mode or _is_rendering:
		return

	if event is InputEventMouseMotion and _mouse_captured:
		rotate_y(-event.relative.x * look_sensitivity)
		camera.rotate_x(-event.relative.y * look_sensitivity)
		camera.rotation.x = clamp(camera.rotation.x, -1.4, 1.4)


func _physics_process(delta: float) -> void:
	_handle_light_movement(delta)

	if _is_raytrace_mode or _is_rendering:
		return

	var input_dir := Vector3.ZERO
	if Input.is_action_pressed("move_forward"):
		input_dir -= camera.global_transform.basis.z
	if Input.is_action_pressed("move_back"):
		input_dir += camera.global_transform.basis.z
	if Input.is_action_pressed("move_left"):
		input_dir -= camera.global_transform.basis.x
	if Input.is_action_pressed("move_right"):
		input_dir += camera.global_transform.basis.x
	if Input.is_action_pressed("move_up"):
		input_dir += Vector3.UP
	if Input.is_action_pressed("move_down"):
		input_dir -= Vector3.UP

	if input_dir.length_squared() > 0.0:
		camera.global_translate(input_dir.normalized() * move_speed * delta)


## Moves the OmniLight3D in the world XZ plane using the arrow keys, at
## a fixed height. Works independently of camera control (separate keys),
## and intentionally still works while in ray-trace mode is being toggled
## so the person can adjust the light, then press R to re-render.
func _handle_light_movement(delta: float) -> void:
	var move := Vector2.ZERO  # x, z plane movement
	if Input.is_action_pressed("light_forward"):
		move.y -= 1.0
	if Input.is_action_pressed("light_back"):
		move.y += 1.0
	if Input.is_action_pressed("light_left"):
		move.x -= 1.0
	if Input.is_action_pressed("light_right"):
		move.x += 1.0

	if move.length_squared() == 0.0:
		return

	move = move.normalized() * light_move_speed * delta
	var pos: Vector3 = light_node.global_transform.origin
	pos.x += move.x
	pos.z += move.y
	pos.y = light_height
	light_node.global_transform.origin = pos


func _toggle_raytrace_mode() -> void:
	if _is_rendering:
		return  # ignore toggle while a render is in flight

	if _is_raytrace_mode:
		# Switch back to raster/live mode.
		_is_raytrace_mode = false
		rt_overlay.visible = false
		_update_hud("RASTER (live) -- press R to ray trace")
	else:
		# Kick off an async ray-traced render from the current camera pose.
		_start_async_render()


func _start_async_render() -> void:
	_is_rendering = true
	_update_hud("Ray tracing... 0%%")

	# Rebuild scene data in case anything moved (cheap enough for a
	# small static demo scene; for a fully dynamic scene you'd only
	# rebuild on actual geometry changes).
	_build_scene_data()

	if use_viewport_resolution:
		var vp_size: Vector2i = get_viewport().size
		_active_width = vp_size.x
		_active_height = vp_size.y
	else:
		_active_width = render_width
		_active_height = render_height

	_render_image = Image.create(_active_width, _active_height, false, Image.FORMAT_RGB8)
	_render_row = 0
	_render_cam_origin = camera.global_transform.origin
	_render_cam_basis = camera.global_transform.basis
	_render_start_msec = Time.get_ticks_msec()

	set_process(true)


func _process(_delta: float) -> void:
	if not _is_rendering:
		return

	var rows_done_this_frame := 0
	while _render_row < _active_height and rows_done_this_frame < rows_per_frame:
		_render_row_into_image(_render_row)
		_render_row += 1
		rows_done_this_frame += 1

	if _render_row >= _active_height:
		_finish_async_render()
	else:
		var pct: int = int(100.0 * _render_row / float(_active_height))
		_update_hud("Ray tracing... %d%%" % pct)


func _render_row_into_image(py: int) -> void:
	for px in range(_active_width):
		var accum := Color(0, 0, 0)

		if samples_per_pixel <= 1:
			var ray: Dictionary = RayTracer.generate_camera_ray(camera, px, py, _active_width, _active_height)
			var hit := _raytracer.intersect_scene(ray["origin"], ray["direction"])
			accum = _raytracer.shade(hit)
		else:
			var rng := RandomNumberGenerator.new()
			for s in range(samples_per_pixel):
				var jx: float = px + rng.randf()
				var jy: float = py + rng.randf()
				var ray2: Dictionary = RayTracer._generate_camera_ray_subpixel(
					camera, jx, jy, _active_width, _active_height
				)
				var hit2 := _raytracer.intersect_scene(ray2["origin"], ray2["direction"])
				accum += _raytracer.shade(hit2)
			accum /= float(samples_per_pixel)

		_render_image.set_pixel(px, py, accum)


func _finish_async_render() -> void:
	set_process(false)
	_is_rendering = false
	_is_raytrace_mode = true

	var elapsed_ms: int = Time.get_ticks_msec() - _render_start_msec

	var tex := ImageTexture.create_from_image(_render_image)
	rt_overlay.texture = tex
	rt_overlay.visible = true

	_update_hud("RAY TRACED (%dx%d, %d spp) -- %d ms -- press R for live view" % [
		_active_width, _active_height, samples_per_pixel, elapsed_ms
	])


func _update_hud(text: String) -> void:
	if hud_label:
		hud_label.text = text
