extends RefCounted
class_name MaterialDatabase

## 물성은 SI 단위. 프리셋은 교육·시뮬레이션용 대표값이며 인증 설계값이 아니야.
const PRESETS: Dictionary = {
	"structural_steel": {
		"id": "structural_steel", "name": "Structural Steel · A36 reference",
		"density_kg_m3": 7850.0, "young_modulus_pa": 200.0e9, "poisson_ratio": 0.30,
		"yield_strength_pa": 250.0e6, "tensile_strength_pa": 400.0e6,
		"compressive_strength_pa": 250.0e6, "shear_strength_pa": 150.0e6,
		"fracture_limit_strain": 0.20,
		"source": "AISC A36 reported minimum Fy=250 MPa and tensile strength=400 MPa; E, density and Poisson ratio are representative isotropic steel values.",
		"source_url": "https://www.aisc.org/globalassets/aisc/research-library/high-strength-steel-report_aisc_adhoctg.pdf",
		"assumptions": "압축강도는 항복강도와 같게 둠. 전단강도는 0.6Fy로 둔 단순 근사. 파단 변형률 0.20은 재료모델 시험용 입력값이며 A36 인증값으로 사용하지 않음."
	},
	"reinforced_concrete": {
		"id": "reinforced_concrete", "name": "Reinforced Concrete · 28 MPa reference",
		"density_kg_m3": 2400.0, "young_modulus_pa": 25.8e9, "poisson_ratio": 0.15,
		"yield_strength_pa": null, "tensile_strength_pa": 2.9e6,
		"compressive_strength_pa": 28.0e6, "shear_strength_pa": 1.5e6,
		"fracture_limit_strain": 0.00012,
		"source": "FHWA LS-DYNA Concrete Model 159 table: 28 MPa concrete, E=25.8 GPa, ν=0.15. Density and reinforced-composite strength proxies are assumptions.",
		"source_url": "https://www.fhwa.dot.gov/publications/research/infrastructure/pavements/05062/chapt2c.cfm",
		"assumptions": "콘크리트와 철근의 복합재를 등방성 단일 재료로 단순화. 인장·전단 한계와 fracture strain은 게임용 대표 입력값이며 배합·철근비·구속 상세에 따른 설계값이 아님."
	},
	"timber": {
		"id": "timber", "name": "Timber · SPF No.2 reference",
		"density_kg_m3": 450.0, "young_modulus_pa": 8.3e9, "poisson_ratio": 0.35,
		"yield_strength_pa": null, "tensile_strength_pa": 3.1e6,
		"compressive_strength_pa": 7.9e6, "shear_strength_pa": 0.93e6,
		"fracture_limit_strain": 0.00037,
		"source": "AWC NDS Supplement: SPF lumber design values vary by species, grade and size; E≈1.2 million psi and listed design stresses inform the representative proxies.",
		"source_url": "https://awc.org/resources/2024-nds-supplement",
		"assumptions": "목재의 직교 이방성·함수율·결함을 무시한 등방성 모델. 강도는 SPF No.2 계열 설계값을 SI로 근사한 값이며 파괴강도 인증값이 아님."
	},
	"glass": {
		"id": "glass", "name": "Glass · Soda-lime float reference",
		"density_kg_m3": 2500.0, "young_modulus_pa": 70.0e9, "poisson_ratio": 0.22,
		"yield_strength_pa": null, "tensile_strength_pa": 10.0e6,
		"compressive_strength_pa": 500.0e6, "shear_strength_pa": 30.0e6,
		"fracture_limit_strain": 0.000143,
		"source": "Pilkington soda-lime glass references density 2500 kg/m³, E≈70 GPa, ν≈0.2. NGA notes strength is flaw- and load-duration-dependent.",
		"source_url": "https://www.glass.org/sites/default/files/2023-07/FM05-12_2023_Physical_Mechanical_Properties_Typical_Soda_Lime_Float_Glass.pdf",
		"assumptions": "인장 10 MPa, 압축 500 MPa, 전단 30 MPa는 표면 결함·가공·하중시간 미모델링을 보완하는 게임용 가정치이며 설계 허용치가 아님."
	}
}

const REQUIRED_NUMERIC_FIELDS: Array[String] = [
	"density_kg_m3", "young_modulus_pa", "poisson_ratio", "tensile_strength_pa",
	"compressive_strength_pa", "shear_strength_pa", "fracture_limit_strain"
]


static func preset_ids() -> Array[String]:
	var ids: Array[String] = []
	for material_id in PRESETS:
		ids.append(str(material_id))
	return ids


static func get_material(material_id: String) -> Dictionary:
	if not PRESETS.has(material_id):
		return {}
	return (PRESETS[material_id] as Dictionary).duplicate(true)


static func get_all_materials() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for material_id in preset_ids():
		result.append(get_material(material_id))
	return result


static func create_custom_material(properties: Dictionary) -> Dictionary:
	var validation := validate_material(properties)
	if not bool(validation["valid"]):
		return {"valid": false, "error": str(validation["error"]), "material": {}}
	var material := properties.duplicate(true)
	material["id"] = str(material.get("id", "custom_%s" % str(Time.get_ticks_usec())))
	material["name"] = str(material.get("name", "사용자 정의 재료"))
	material["yield_strength_pa"] = material.get("yield_strength_pa", null)
	material["source"] = str(material.get("source", "사용자 입력"))
	material["source_url"] = str(material.get("source_url", ""))
	material["assumptions"] = str(material.get("assumptions", "사용자 입력값. 별도 검증 필요."))
	return {"valid": true, "error": "", "material": material}


static func validate_material(material: Dictionary) -> Dictionary:
	for field in REQUIRED_NUMERIC_FIELDS:
		if not material.has(field) or not is_finite(float(material[field])):
			return {"valid": false, "error": "%s 값이 없거나 유한하지 않아." % field}
		if float(material[field]) <= 0.0:
			return {"valid": false, "error": "%s 값은 0보다 커야 해." % field}
	var poisson := float(material["poisson_ratio"])
	if poisson <= -1.0 or poisson >= 0.5:
		return {"valid": false, "error": "poisson_ratio는 -1과 0.5 사이여야 해."}
	if material.has("yield_strength_pa") and material["yield_strength_pa"] != null:
		var yield_strength := float(material["yield_strength_pa"])
		if not is_finite(yield_strength) or yield_strength <= 0.0:
			return {"valid": false, "error": "yield_strength_pa는 null 또는 양의 Pa 값이어야 해."}
	if str(material.get("source", "")).strip_edges().is_empty():
		return {"valid": false, "error": "출처 또는 사용자 입력 표기가 필요해."}
	if str(material.get("assumptions", "")).strip_edges().is_empty():
		return {"valid": false, "error": "적용 가정을 기록해야 해."}
	return {"valid": true, "error": ""}


static func mass_kg(material: Dictionary, area_m2: float, length_m: float) -> float:
	if not bool(validate_material(material)["valid"]) or area_m2 <= 0.0 or length_m <= 0.0:
		return NAN
	return float(material["density_kg_m3"]) * area_m2 * length_m


static func assign_to_member(member: RigidBody2D, material: Dictionary, area_m2: float, length_m: float) -> Dictionary:
	var validation := validate_material(material)
	if not bool(validation["valid"]):
		return validation
	if not is_instance_valid(member):
		return {"valid": false, "error": "유효한 RigidBody2D 부재가 필요해."}
	var mass_value := mass_kg(material, area_m2, length_m)
	if not is_finite(mass_value):
		return {"valid": false, "error": "부재의 단면적과 길이는 양수여야 해."}
	member.set_meta("material", material.duplicate(true))
	member.mass = mass_value
	var property_values := {
		"material_id": str(material.get("id", "")),
		"material_density_kg_m3": float(material["density_kg_m3"]),
		"elastic_modulus_pa": float(material["young_modulus_pa"]),
		"yield_strength_pa": material.get("yield_strength_pa", null),
		"tensile_strength_pa": float(material["tensile_strength_pa"]),
		"compressive_strength_pa": float(material["compressive_strength_pa"]),
		"shear_strength_pa": float(material["shear_strength_pa"]),
		"fracture_limit_strain": float(material["fracture_limit_strain"])
	}
	var available_properties: Dictionary = {}
	for property_info in member.get_property_list():
		available_properties[str(property_info["name"])] = true
	for property_name in property_values:
		if available_properties.has(property_name) and property_values[property_name] != null:
			member.set(property_name, property_values[property_name])
	return {"valid": true, "error": "", "mass_kg": mass_value, "material_id": str(material.get("id", ""))}


static func solver_materials(materials: Array[Dictionary]) -> Dictionary:
	var result: Dictionary = {}
	for material in materials:
		if bool(validate_material(material)["valid"]):
			var solver_material := material.duplicate(true)
			solver_material["elastic_modulus_pa"] = float(material["young_modulus_pa"])
			result[str(material["id"])] = solver_material
	return result


static func custom_materials_path() -> String:
	return "user://custom_materials.json"


static func save_custom_material(material: Dictionary) -> Dictionary:
	var created := create_custom_material(material)
	if not bool(created["valid"]):
		return created
	var existing := load_custom_materials()
	var saved_material: Dictionary = created["material"]
	for index in range(existing.size()):
		if str(existing[index].get("id", "")) == str(saved_material["id"]):
			existing[index] = saved_material
			return _write_custom_materials(existing)
	existing.append(saved_material)
	return _write_custom_materials(existing)


static func load_custom_materials() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not FileAccess.file_exists(custom_materials_path()):
		return result
	var file := FileAccess.open(custom_materials_path(), FileAccess.READ)
	if file == null:
		return result
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Array:
		return result
	for entry in parsed:
		if entry is Dictionary and bool(validate_material(entry)["valid"]):
			result.append(entry)
	return result


static func _write_custom_materials(materials: Array[Dictionary]) -> Dictionary:
	var file := FileAccess.open(custom_materials_path(), FileAccess.WRITE)
	if file == null:
		return {"valid": false, "error": "사용자 재료 파일을 저장하지 못했어.", "material": {}}
	file.store_string(JSON.stringify(materials, "\t"))
	return {"valid": true, "error": "", "material": {}}
