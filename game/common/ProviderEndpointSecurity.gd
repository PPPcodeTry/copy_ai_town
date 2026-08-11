extends RefCounted


static func scheme_is_supported(endpoint: String) -> bool:
	return endpoint.begins_with("https://") or endpoint.begins_with("http://")


static func requires_insecure_http_consent(endpoint: String) -> bool:
	if not endpoint.begins_with("http://"):
		return false
	return not _loopback_host_is_valid(_host_from_endpoint(endpoint))


static func consent_matches(endpoint: String, approved_endpoint: String) -> bool:
	return (
		not requires_insecure_http_consent(endpoint)
		or approved_endpoint == endpoint
	)


static func _host_from_endpoint(endpoint: String) -> String:
	var authority := endpoint.trim_prefix("http://").split("/", false)[0]
	if authority.begins_with("["):
		var closing := authority.find("]")
		return authority.left(closing + 1) if closing >= 0 else ""
	if authority.count(":") == 1:
		return authority.get_slice(":", 0)
	return authority


static func _loopback_host_is_valid(host: String) -> bool:
	var normalized := host.to_lower()
	if normalized == "localhost" or normalized == "[::1]":
		return true
	return normalized.begins_with("127.") and _canonical_ipv4_is_valid(
		normalized
	)


static func _canonical_ipv4_is_valid(host: String) -> bool:
	var labels := host.split(".", false)
	if labels.size() != 4:
		return false
	for label: String in labels:
		if label.is_empty():
			return false
		for character: String in label:
			if character not in "0123456789":
				return false
		var octet := int(label)
		if octet < 0 or octet > 255 or str(octet) != label:
			return false
	return true
