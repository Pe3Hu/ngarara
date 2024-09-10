extends Node2D


var NUM_QUEENS = 4
var NUM_ANTS = 10
var NUM_RESOURCES = 12
var NUM_BOIDS = NUM_QUEENS * (NUM_ANTS * 3 + 1) + NUM_RESOURCES
var boid_pos = []
var boid_role = []
var boid_speed = []
var boid_direction = []
var boid_queen = []
var boid_resource = []

var IMAGE_SIZE = int(ceil(sqrt(NUM_BOIDS)))
var boid_data : Image
var boid_data_texture : ImageTexture

@export_category("Boid Settings")
@export_range(1,100) var scream_radius = 25.0
@export_range(1,100) var extraction_radius = 25.0
@export_range(1,100) var transfer_radius = 25.0
@export_range(0,100) var min_speed = 50.0
@export_range(50,100) var max_speed = 155.0
@export_range(0,100) var alignment_factor = 10.0
@export_range(0,100) var cohesion_factor = 1.0
@export_range(0,100) var separation_factor = 20.0

@export_category("Rendering")
enum BoidColorMode {SOLID, BIN, ROLE}
@export var boid_color = Color(Color.WHITE) :
	set(new_color):
		boid_color = new_color
		if is_inside_tree():
			%BoidParticles.process_material.set_shader_parameter("color", boid_color)
@export var boid_color_mode : BoidColorMode :
	set(new_color_mode):
		boid_color_mode = new_color_mode
		if is_inside_tree():
			%BoidParticles.process_material.set_shader_parameter("color_mode", boid_color_mode)
@export var boid_max_friends = 10 :
	set(new_max_friends):
		boid_max_friends = new_max_friends
		if is_inside_tree():
			%BoidParticles.process_material.set_shader_parameter("max_friends", boid_max_friends)
@export var boid_scale = Vector2(.5, .5):
	set(new_scale):
		boid_scale = new_scale
		if is_inside_tree():
			%BoidParticles.process_material.set_shader_parameter("scale", boid_scale)
@export var bin_grid = false:
	set(new_grid):
		bin_grid = new_grid
		if is_inside_tree():
			%Grid.visible = bin_grid

@export_category("Other")
@export var pause = false :
	set(new_value):
		pause = new_value

#region vars
# GPU Variables
var rd : RenderingDevice
var boid_compute_shader : RID
var boid_pipeline : RID
var bindings : Array
var uniform_set : RID

var boid_pos_buffer : RID
var boid_role_buffer : RID
var boid_speed_buffer : RID
var boid_direction_buffer : RID
var boid_queen_buffer : RID
var boid_resource_buffer : RID
var params_buffer: RID
var params_uniform : RDUniform
var boid_data_buffer : RID

# BIN Variable
var BIN_SIZE = 64
var BINS = Vector2i.ZERO
var NUM_BINS = 0

var bin_sum_shader : RID
var bin_sum_pipeline : RID
var bin_prefix_sum_shader : RID
var bin_prefix_sum_pipeline : RID
var bin_reindex_shader : RID
var bin_reindex_pipeline : RID

var bin_buffer : RID
var bin_sum_buffer : RID
var bin_prefix_sum_buffer : RID
var bin_index_tracker_buffer : RID
var bin_reindex_buffer : RID
var bin_params_buffer : RID
#endregion


func _ready():
	boid_data = Image.create(IMAGE_SIZE, IMAGE_SIZE, false, Image.FORMAT_RGBAH)
	boid_data_texture = ImageTexture.create_from_image(boid_data)
	
	boid_color = boid_color
	boid_color_mode = boid_color_mode
	boid_max_friends = boid_max_friends
	boid_scale = boid_scale
	bin_grid = bin_grid
	
	BINS = Vector2i(snapped(get_viewport_rect().size.x / BIN_SIZE + .4,1),
		snapped(get_viewport_rect().size.y / BIN_SIZE + .4,1))
	NUM_BINS = BINS.x * BINS.y
	
	%Grid.bin_size = BIN_SIZE
	%Grid.bins_x = BINS.x
	%Grid.bins_y = BINS.y
	
	_generate_boids()
	
	%BoidParticles.amount = NUM_BOIDS
	%BoidParticles.process_material.set_shader_parameter("boid_data", boid_data_texture)

	_setup_compute_shader()
	_update_boids_gpu(0)
	
func _generate_boids():
	var start_radius = min(get_viewport_rect().size.x, get_viewport_rect().size.y) / 3
	var ant_radius = start_radius / 4
	var queen_speed = min_speed
	var resource_types = [1, 2, 3]
	
	for _i in resource_types:
		var role = resource_types.size() + 1 + _i
		
		for _j in NUM_RESOURCES / float(resource_types.size()):
			boid_pos.append(Vector2(randf() * get_viewport_rect().size.x, randf() * get_viewport_rect().size.y))
			boid_direction.append(Vector2.from_angle(randf_range(0, PI * 2)))
			boid_speed.append(randi_range(min_speed, max_speed))
			boid_queen.append(-1)
			boid_resource.append(0)
			boid_role.append(role)
	
	for _i in NUM_QUEENS:
		var queen_pos = get_viewport_rect().size / 2 + Vector2.from_angle(float(_i) / NUM_QUEENS * PI * 2 ) * start_radius
		boid_pos.append(Vector2(queen_pos))
		boid_direction.append(Vector2.from_angle(randf_range(0, PI * 2)))
		boid_speed.append(queen_speed)
		boid_queen.append(0)
		boid_resource.append(-1)
		boid_role.append(0)
		
		for ant_role in resource_types:
			for _j in NUM_ANTS:
				var ant_pos = queen_pos + Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * ant_radius
				boid_pos.append(ant_pos)
				boid_direction.append(Vector2.from_angle(randf_range(0, PI * 2)))
				boid_speed.append(randf_range(min_speed, max_speed))
				boid_queen.append(ant_radius)
				boid_resource.append(ant_radius)
				boid_role.append(ant_role)
	
func _process(delta):
	get_window().title = "Boids: " + str(NUM_BOIDS) + " / FPS: " + str(Engine.get_frames_per_second())
	
	if Input.is_key_pressed(KEY_ESCAPE):
		get_tree().quit()
	
	_sync_boids_gpu()
	_update_data_texture()
	_update_boids_gpu(delta)
	
func _update_boids_gpu(delta):
	rd.free_rid(params_buffer)
	params_buffer = _generate_parameter_buffer(delta)
	params_uniform.clear_ids()
	params_uniform.add_id(params_buffer)
	uniform_set = rd.uniform_set_create(bindings, boid_compute_shader, 0)
	
	_run_compute_shader(bin_sum_pipeline)
	rd.sync()
	_run_compute_shader(bin_prefix_sum_pipeline)
	rd.sync()
	_run_compute_shader(bin_reindex_pipeline)
	rd.sync()
	_run_compute_shader(boid_pipeline)
	
func _run_compute_shader(pipeline):
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_dispatch(compute_list, ceil(NUM_BOIDS/1024.), 1, 1)
	rd.compute_list_end()
	rd.submit()
	
func _sync_boids_gpu():
	rd.sync()
	
func _update_data_texture():
	var boid_data_image_data := rd.texture_get_data(boid_data_buffer, 0)
	boid_data.set_data(IMAGE_SIZE, IMAGE_SIZE, false, Image.FORMAT_RGBAH, boid_data_image_data)
	boid_data_texture.update(boid_data)
	
func _setup_compute_shader():
	rd = RenderingServer.create_local_rendering_device()
	
	var shader_file := load("res://compute shaders/boid_simulation.glsl")
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	boid_compute_shader = rd.shader_create_from_spirv(shader_spirv)
	boid_pipeline = rd.compute_pipeline_create(boid_compute_shader)
	
	boid_pos_buffer = _generate_vec2_buffer(boid_pos)
	var boid_pos_uniform = _generate_uniform(boid_pos_buffer, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 0)
	
	boid_role_buffer = _generate_int_buffer_custom(boid_role)
	var boid_role_uniform = _generate_uniform(boid_role_buffer, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 1)
	
	params_buffer = _generate_parameter_buffer(0)
	params_uniform = _generate_uniform(params_buffer, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 2)
	
	var fmt := RDTextureFormat.new()
	fmt.width = IMAGE_SIZE
	fmt.height = IMAGE_SIZE
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	
	var view := RDTextureView.new()
	boid_data_buffer = rd.texture_create(fmt, view, [boid_data.get_data()])
	var boid_data_buffer_uniform = _generate_uniform(boid_data_buffer, RenderingDevice.UNIFORM_TYPE_IMAGE, 3)
	
	shader_file = load("res://compute shaders/bin_sum.glsl")
	shader_spirv = shader_file.get_spirv()
	bin_sum_shader = rd.shader_create_from_spirv(shader_spirv)
	bin_sum_pipeline = rd.compute_pipeline_create(bin_sum_shader)
	
	shader_file = load("res://compute shaders/bin_prefix_sum.glsl")
	shader_spirv = shader_file.get_spirv()
	bin_prefix_sum_shader = rd.shader_create_from_spirv(shader_spirv)
	bin_prefix_sum_pipeline = rd.compute_pipeline_create(bin_prefix_sum_shader)
	
	shader_file = load("res://compute shaders/bin_reindex.glsl")
	shader_spirv = shader_file.get_spirv()
	bin_reindex_shader = rd.shader_create_from_spirv(shader_spirv)
	bin_reindex_pipeline = rd.compute_pipeline_create(bin_reindex_shader)
	
	var bin_params_buffer_bytes = PackedInt32Array([BIN_SIZE, BINS.x, BINS.y, NUM_BINS]).to_byte_array()
	bin_params_buffer = rd.storage_buffer_create(bin_params_buffer_bytes.size(), bin_params_buffer_bytes)
	var bin_params_uniform = _generate_uniform(bin_params_buffer, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 4)
	
	bin_buffer = _generate_int_buffer(NUM_BOIDS)
	var bin_buffer_uniform = _generate_uniform(bin_buffer, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 5)
	
	bin_sum_buffer = _generate_int_buffer(NUM_BINS)
	var bin_sum_uniform = _generate_uniform(bin_sum_buffer, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 6)
	
	bin_prefix_sum_buffer = _generate_int_buffer(NUM_BINS)
	var bin_prefix_sum_uniform = _generate_uniform(bin_prefix_sum_buffer, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 7)
	
	bin_index_tracker_buffer = _generate_int_buffer(NUM_BINS)
	var bin_index_tracker_uniform = _generate_uniform(bin_index_tracker_buffer, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 8)
	
	bin_reindex_buffer = _generate_int_buffer(NUM_BOIDS)
	var bin_reindex_uniform = _generate_uniform(bin_reindex_buffer, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 9)
	
	boid_direction_buffer = _generate_vec2_buffer(boid_direction)
	var boid_direction_uniform = _generate_uniform(boid_direction_buffer, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 10)
	
	boid_speed_buffer = _generate_int_buffer_custom(boid_speed)
	var boid_speed_uniform = _generate_uniform(boid_speed_buffer, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 11)
	
	boid_queen_buffer = _generate_int_buffer_custom(boid_queen)
	var boid_queen_uniform = _generate_uniform(boid_queen_buffer, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 12)
	
	boid_resource_buffer = _generate_int_buffer_custom(boid_resource)
	var boid_resource_uniform = _generate_uniform(boid_resource_buffer, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 13)
	
	bindings = [boid_pos_uniform,
		boid_role_uniform,
		params_uniform,
		boid_data_buffer_uniform,
		bin_params_uniform,
		bin_buffer_uniform,
		bin_sum_uniform,
		bin_prefix_sum_uniform,
		bin_index_tracker_uniform,
		bin_reindex_uniform,
		boid_direction_uniform,
		boid_speed_uniform,
		boid_queen_uniform,
		boid_resource_uniform]
	
func _generate_vec2_buffer(data):
	var data_buffer_bytes := PackedVector2Array(data).to_byte_array()
	var data_buffer = rd.storage_buffer_create(data_buffer_bytes.size(), data_buffer_bytes)
	return data_buffer
	
func _generate_int_buffer_custom(data):
	var data_buffer_bytes := PackedInt32Array(data).to_byte_array()
	var data_buffer = rd.storage_buffer_create(data_buffer_bytes.size(), data_buffer_bytes)
	return data_buffer
	
func _generate_int_buffer(size):
	var data = []
	data.resize(size)
	var data_buffer_bytes = PackedInt32Array(data).to_byte_array()
	var data_buffer = rd.storage_buffer_create(data_buffer_bytes.size(), data_buffer_bytes)
	return data_buffer
	
func _generate_uniform(data_buffer, type, binding):
	var data_uniform = RDUniform.new()
	data_uniform.uniform_type = type
	data_uniform.binding = binding
	data_uniform.add_id(data_buffer)
	return data_uniform
	
func _generate_parameter_buffer(delta):
	var params_buffer_bytes : PackedByteArray = PackedFloat32Array(
		[NUM_BOIDS,
		IMAGE_SIZE,
		scream_radius,
		extraction_radius,
		transfer_radius,
		min_speed,
		max_speed,
		get_viewport_rect().size.x,
		get_viewport_rect().size.y,
		delta,
		pause,
		boid_color_mode]).to_byte_array()
	
	return rd.storage_buffer_create(params_buffer_bytes.size(), params_buffer_bytes)
	
func _exit_tree():
	_sync_boids_gpu()
	rd.free_rid(uniform_set)
	rd.free_rid(boid_data_buffer)
	rd.free_rid(params_buffer)
	rd.free_rid(boid_pos_buffer)
	rd.free_rid(boid_role_buffer)
	rd.free_rid(boid_direction_buffer)
	rd.free_rid(boid_speed_buffer)
	rd.free_rid(boid_queen_buffer)
	rd.free_rid(boid_resource_buffer)
	rd.free_rid(bin_buffer)
	rd.free_rid(bin_sum_buffer)
	rd.free_rid(bin_prefix_sum_buffer)
	rd.free_rid(bin_index_tracker_buffer)
	rd.free_rid(bin_reindex_buffer)
	rd.free_rid(bin_params_buffer)
	rd.free_rid(bin_sum_pipeline)
	rd.free_rid(bin_sum_shader)
	rd.free_rid(bin_prefix_sum_pipeline)
	rd.free_rid(bin_prefix_sum_shader)
	rd.free_rid(bin_reindex_pipeline)
	rd.free_rid(bin_reindex_shader)
	rd.free_rid(boid_pipeline)
	rd.free_rid(boid_compute_shader)
	rd.free()
