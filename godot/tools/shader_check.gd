extends SceneTree

## Compiles each .gdshader named after `--` and a deliberately broken copy of the last
## one, printing SHADERCHECK <path> params=<n> per file. A shader that fails to compile
## reports no uniforms, so the broken control must print params=0 or the check itself
## is not looking. Runs headless; the dummy renderer still parses and compiles.
##
##   tools/shader_check.sh shaders/march.gdshader shaders/tree.gdshader

func _init() -> void:
	var paths := OS.get_cmdline_user_args()
	if paths.is_empty():
		print("SHADERCHECK no paths given")
		quit(2)
		return
	var last := ""
	for path in paths:
		last = FileAccess.get_file_as_string(path)
		_check(path, last)
	# Control: the last shader with a type error spliced into its first function body.
	var at := last.find("{")
	var broken := last.substr(0, at + 1) + " float __x = vec3(1.0) + 1;" + last.substr(at + 1)
	_check("broken.gdshader", broken)
	await process_frame
	await process_frame
	quit(0)


func _check(path: String, code: String) -> void:
	var sh := Shader.new()
	sh.code = code
	print("SHADERCHECK %s params=%d" % [path, sh.get_shader_uniform_list().size()])
