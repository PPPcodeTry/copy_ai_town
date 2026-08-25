class_name InteriorGeometryLoadTask
extends RefCounted

const ROOM_GEOMETRY := preload(
	"res://world/maps/town/interiors/InteriorRoomGeometry.gd"
)

var _mutex := Mutex.new()
var _result: Dictionary = {}


func run(path: String) -> void:
	var loaded := ROOM_GEOMETRY.load_geometry(path)
	_mutex.lock()
	_result = loaded
	_mutex.unlock()


func take_result() -> Dictionary:
	_mutex.lock()
	var result := _result
	_result = {}
	_mutex.unlock()
	return result
