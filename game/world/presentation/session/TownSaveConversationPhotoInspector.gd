extends RefCounted
## 会话照片属于会话而非修订；每个会话只扫描一次并记录受影响修订。


const SUPPORT := preload(
	"res://world/presentation/session/TownSaveInspectionSupport.gd"
)
const PHOTO_PREFIX := "chat-photo-sha256-"
const PHOTO_SUFFIX := ".bin"


static func collect_references(value: Variant) -> Array[String]:
	var found := {}
	_collect_references(value, found)
	var result: Array[String] = []
	for ref_value: Variant in found:
		result.append(String(ref_value))
	result.sort()
	return result


static func inspect(
	source: String,
	slot_id: String,
	revisions: Array[Dictionary],
) -> Array[Dictionary]:
	var sessions := _references_by_session(revisions)
	_collect_photo_directories(source, slot_id, sessions)
	var session_ids: Array[String] = []
	for session_id_value: Variant in sessions:
		session_ids.append(String(session_id_value))
	session_ids.sort()
	var result: Array[Dictionary] = []
	for session_id in session_ids:
		result.append(_inspect_session(
			source,
			slot_id,
			session_id,
			sessions.get(session_id, {}) as Dictionary,
		))
	return result


static func _references_by_session(revisions: Array[Dictionary]) -> Dictionary:
	var sessions := {}
	for revision in revisions:
		var session_id := String(revision.get("sessionId", ""))
		if session_id.is_empty():
			continue
		var references := sessions.get(session_id, {}) as Dictionary
		for ref_value: Variant in revision.get("photoReferences", []) as Array:
			var ref := String(ref_value)
			var affected := references.get(ref, []) as Array
			var save_revision := int(revision.get("saveRevision", -1))
			if save_revision >= 0 and not affected.has(save_revision):
				affected.append(save_revision)
			references[ref] = affected
		sessions[session_id] = references
	return sessions


static func _collect_photo_directories(
	source: String,
	slot_id: String,
	sessions: Dictionary,
) -> void:
	var slot_root := source.path_join("town_conversation_photos/%s" % slot_id)
	var directory := DirAccess.open(slot_root)
	if directory == null:
		return
	for session_id in directory.get_directories():
		if not sessions.has(session_id):
			sessions[session_id] = {}


static func _inspect_session(
	source: String,
	slot_id: String,
	session_id: String,
	references: Dictionary,
) -> Dictionary:
	var root := source.path_join(
		"town_conversation_photos/%s/%s" % [slot_id, session_id],
	)
	var hashes: Array[Dictionary] = []
	var issues: Array[Dictionary] = []
	var affected: Array[int] = []
	var directory := DirAccess.open(root)
	if directory != null:
		if not directory.get_directories().is_empty():
			issues.append(SUPPORT.issue(
				"damaged_save", "conversation_photos",
				SUPPORT.relative_path(source, root),
				"conversation photo directory contains unexpected subdirectories",
			))
			_append_all_revisions(references, affected)
		var files := directory.get_files()
		files.sort()
		for file_name in files:
			_inspect_file(
				source, root, file_name, references, hashes, issues, affected,
			)
	for ref_value: Variant in references:
		var ref := String(ref_value)
		var path := root.path_join("%s%s" % [ref, PHOTO_SUFFIX])
		if _valid_ref(ref) and FileAccess.file_exists(path):
			continue
		issues.append(SUPPORT.issue(
			"damaged_save", "conversation_photos",
			SUPPORT.relative_path(source, path),
			"referenced conversation photo is missing or invalid",
		))
		_append_revisions(references.get(ref, []) as Array, affected)
	affected.sort()
	var refs: Array[String] = []
	for ref_value: Variant in references:
		refs.append(String(ref_value))
	refs.sort()
	return {
		"sessionId": session_id,
		"references": refs,
		"hashes": hashes,
		"affectedRevisions": affected,
		"issues": issues,
	}


static func _inspect_file(
	source: String,
	root: String,
	file_name: String,
	references: Dictionary,
	hashes: Array[Dictionary],
	issues: Array[Dictionary],
	affected: Array[int],
) -> void:
	var path := root.path_join(file_name)
	var ref := file_name.trim_suffix(PHOTO_SUFFIX)
	var digest := ref.trim_prefix(PHOTO_PREFIX)
	var actual := FileAccess.get_sha256(path)
	hashes.append(SUPPORT.hash_evidence(
		source, "conversation_photos", path, digest, actual,
	))
	if (
		file_name != "%s%s%s" % [PHOTO_PREFIX, actual, PHOTO_SUFFIX]
		or not _valid_digest(actual)
	):
		issues.append(SUPPORT.issue(
			"damaged_save", "conversation_photos",
			SUPPORT.relative_path(source, path),
			"conversation photo name does not match its content hash",
		))
		_append_revisions(references.get(ref, []) as Array, affected)


static func _valid_ref(ref: String) -> bool:
	return ref.begins_with(PHOTO_PREFIX) and _valid_digest(
		ref.trim_prefix(PHOTO_PREFIX),
	)


static func _valid_digest(digest: String) -> bool:
	return (
		digest.length() == 64
		and digest == digest.to_lower()
		and digest.is_valid_hex_number(false)
	)


static func _append_all_revisions(
	references: Dictionary,
	affected: Array[int],
) -> void:
	for revisions_value: Variant in references.values():
		_append_revisions(revisions_value as Array, affected)


static func _append_revisions(revisions: Array, affected: Array[int]) -> void:
	for revision_value: Variant in revisions:
		var revision := int(revision_value)
		if not affected.has(revision):
			affected.append(revision)


static func _collect_references(value: Variant, found: Dictionary) -> void:
	if value is Array:
		for item: Variant in value as Array:
			_collect_references(item, found)
		return
	if not value is Dictionary:
		return
	var dictionary := value as Dictionary
	var ref_value: Variant = dictionary.get("ref")
	if ref_value is String and String(ref_value).begins_with(PHOTO_PREFIX):
		found[String(ref_value)] = true
	for child: Variant in dictionary.values():
		_collect_references(child, found)
