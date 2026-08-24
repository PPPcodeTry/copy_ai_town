class_name TownSaveRecoveryPlanner
extends RefCounted


const INSPECTION_VERSION := 1
const PLAN_VERSION := 1
const REPUBLISH_ACTION := "restore_complete_pair_and_publish"


static func plan_id(
	slot_id: String,
	source_revision: int,
	damaged_revision: int,
) -> String:
	return "%s:%d:%d" % [slot_id, source_revision, damaged_revision]


static func inspection_report(slot: Dictionary) -> Dictionary:
	var recovery_state := String(slot.get("recoveryState", "none"))
	var classification := recovery_state
	if String(slot.get("state", "")) == "healthy":
		classification = "healthy"
	elif String(slot.get("state", "")) == "empty":
		classification = "empty"
	return {
		"version": INSPECTION_VERSION,
		"slotId": String(slot.get("slotId", "")),
		"classification": classification,
		"errorCode": String(slot.get("errorCode", "")),
		"latestEvidenceRevision": int(
			slot.get("latestEvidenceRevision", -1),
		),
		"latestCompleteRevision": int(
			slot.get("latestCompleteRevision", -1),
		),
		"repairable": recovery_state == "older_complete_revision_available",
	}


static func recovery_plan(
	slot: Dictionary,
	report: Dictionary,
) -> Dictionary:
	if (
		String(report.get("classification", ""))
		!= "older_complete_revision_available"
		or not bool(report.get("repairable", false))
	):
		return {}
	var summary := slot.get("summary", {}) as Dictionary
	var damage := slot.get("damageDetails", {}) as Dictionary
	var slot_id := String(slot.get("slotId", ""))
	var source_session_id := String(summary.get("sessionId", ""))
	var source_revision := int(summary.get("saveRevision", -1))
	var damaged_revision := int(damage.get("damagedSaveRevision", -1))
	if (
		slot_id.is_empty()
		or source_session_id.is_empty()
		or source_revision < 1
		or damaged_revision <= source_revision
	):
		return {}
	return {
		"version": PLAN_VERSION,
		"planId": plan_id(slot_id, source_revision, damaged_revision),
		"action": REPUBLISH_ACTION,
		"slotId": slot_id,
		"sourceSessionId": source_session_id,
		"sourceSaveRevision": source_revision,
		"damagedSaveRevision": damaged_revision,
		"damageCode": String(damage.get("damageCode", "")),
		"progressRollback": bool(damage.get("progressRollback", false)),
		"confirmationRequired": true,
	}
