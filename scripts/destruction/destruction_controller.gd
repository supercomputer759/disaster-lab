extends RefCounted
class_name DestructionController


func disconnect_member(
	member: RigidBody2D,
	joints_by_member: Dictionary,
	joint_endpoints: Dictionary
) -> int:
	if not is_instance_valid(member):
		return 0
	var links: Array = joints_by_member.get(member, []).duplicate()
	for joint in links:
		if not is_instance_valid(joint):
			continue
		var endpoints: Array = joint_endpoints.get(joint, [])
		for endpoint in endpoints:
			if joints_by_member.has(endpoint):
				joints_by_member[endpoint].erase(joint)
		joint_endpoints.erase(joint)
		joint.queue_free()
	joints_by_member.erase(member)
	if member.has_method("mark_disconnected"):
		member.mark_disconnected()
	return links.size()
