shader_type spatial;
render_mode specular_schlick_ggx, diffuse_burley;

// ============================================================
//  OCEAN SHADER - Godot 4.x (Forward+ / Mobile)
//  Fitur: Gerstner waves, normal detail prosedural, fresnel & refleksi
//  langit (dari Environment), refraksi, warna berdasarkan kedalaman,
//  buih pantai + buih puncak ombak, subsurface scattering palsu.
//  Pakai PlaneMesh dengan subdivisi tinggi (mis. 256 x 256).
//  Jangan rotasi/scale node (gelombang dihitung di world space).
// ============================================================

uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, repeat_disable, filter_linear_mipmap;

group_uniforms colors;
uniform vec4 DEEP_COL : source_color = vec4(0.01, 0.09, 0.20, 1.0);
uniform vec4 SHALLOW_COL : source_color = vec4(0.06, 0.52, 0.58, 1.0);
uniform vec4 FOAM_COL : source_color = vec4(0.93, 0.97, 0.98, 1.0);
uniform vec4 SSS_COL : source_color = vec4(0.10, 0.75, 0.55, 1.0);

group_uniforms waves;
// xy = arah, z = steepness (0..1), w = panjang gelombang (meter)
uniform vec4 wave_a = vec4(1.0, 0.25, 0.15, 50.0);
uniform vec4 wave_b = vec4(0.6, 1.0, 0.12, 28.0);
uniform vec4 wave_c = vec4(-0.4, 0.9, 0.10, 15.0);
uniform vec4 wave_d = vec4(0.9, -0.5, 0.08, 7.0);
uniform float wave_speed = 1.0;
uniform float choppiness : hint_range(0.0, 2.0) = 1.0;

group_uniforms detail;
uniform float normal_scale = 0.35;
uniform float normal_strength : hint_range(0.0, 1.0) = 0.25;
uniform float detail_fade_start = 60.0;
uniform float detail_fade_end = 250.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.04;

group_uniforms water_body;
uniform vec3 absorption = vec3(0.45, 0.10, 0.06);
uniform float clarity = 0.35;
uniform float depth_color_fade = 0.25;
uniform float refraction_strength = 0.15;

group_uniforms foam;
uniform float foam_scale = 0.6;
uniform float shore_foam_width = 1.6;
uniform float crest_foam_threshold : hint_range(0.0, 1.0) = 0.55;
uniform float crest_foam_strength : hint_range(0.0, 1.0) = 0.8;

group_uniforms sss;
uniform vec2 sss_height_range = vec2(0.2, 1.2);
uniform float sss_strength = 0.6;

varying vec3 v_world_pos;
varying vec3 v_normal;
varying float v_jacobian;
varying float v_height;

// ------------------------------------------------------------
//  Gerstner wave
// ------------------------------------------------------------
void gerstner(vec4 w, vec2 p, float t, inout vec3 disp, inout vec3 tang, inout vec3 binorm) {
	vec2 d = normalize(w.xy);
	float steep = w.z * choppiness;
	float k = TAU / w.w;
	float c = sqrt(9.81 / k);
	float f = k * (dot(d, p) - c * t);
	float a = steep / k;
	float s = sin(f);
	float co = cos(f);

	disp.x += d.x * a * co;
	disp.z += d.y * a * co;
	disp.y += a * s;

	tang += vec3(-d.x * d.x * steep * s, d.x * steep * co, -d.x * d.y * steep * s);
	binorm += vec3(-d.x * d.y * steep * s, d.y * steep * co, -d.y * d.y * steep * s);
}

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 disp = vec3(0.0);
	vec3 tang = vec3(1.0, 0.0, 0.0);
	vec3 binorm = vec3(0.0, 0.0, 1.0);
	float t = TIME * wave_speed;

	gerstner(wave_a, wp.xz, t, disp, tang, binorm);
	gerstner(wave_b, wp.xz, t, disp, tang, binorm);
	gerstner(wave_c, wp.xz, t, disp, tang, binorm);
	gerstner(wave_d, wp.xz, t, disp, tang, binorm);

	VERTEX += disp;
	v_world_pos = wp + disp;
	v_normal = normalize(cross(binorm, tang));
	// Jacobian: makin kecil = gelombang makin "menumpuk" -> buih
	v_jacobian = tang.x * binorm.z - tang.z * binorm.x;
	v_height = disp.y;
}

// ------------------------------------------------------------
//  Noise
// ------------------------------------------------------------
float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x),
		u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * vnoise(p);
		p = p * 2.03 + vec2(17.1, 9.2);
		a *= 0.5;
	}
	return v;
}

vec2 ripple_grad(vec2 p) {
	float e = 0.05;
	float h0 = fbm(p);
	return vec2(fbm(p + vec2(e, 0.0)) - h0, fbm(p + vec2(0.0, e)) - h0) / e;
}

// Kedalaman linear (view space) dari depth texture
float linear_depth(sampler2D tex, vec2 uv, mat4 inv_proj) {
	float raw = texture(tex, uv).r;
	vec3 ndc = vec3(uv * 2.0 - 1.0, raw);
	vec4 vp = inv_proj * vec4(ndc, 1.0);
	vp.xyz /= vp.w;
	return -vp.z;
}

// ------------------------------------------------------------
//  Fragment
// ------------------------------------------------------------
void fragment() {
	float t = TIME;
	float dist = length(VERTEX);
	float detail_fade = 1.0 - smoothstep(detail_fade_start, detail_fade_end, dist);
	vec2 p = v_world_pos.xz;

	// --- Normal detail: 2 layer riak yang bergerak berlawanan ---
	vec2 g = ripple_grad(p * normal_scale + t * vec2(0.03, 0.02)) * 0.6
		   + ripple_grad(p * normal_scale * 2.7 - t * vec2(0.05, -0.04)) * 0.4;
	vec3 n = normalize(v_normal + vec3(-g.x, 0.0, -g.y) * normal_strength * detail_fade);

	vec3 view_n = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	vec3 view_flat = normalize((VIEW_MATRIX * vec4(v_normal, 0.0)).xyz);

	// --- Kedalaman air ---
	float surface_depth = -VERTEX.z;
	float scene_d = linear_depth(DEPTH_TEXTURE, SCREEN_UV, INV_PROJECTION_MATRIX);
	float water_depth = max(scene_d - surface_depth, 0.0);

	// --- Refraksi (hindari objek di depan air) ---
	vec2 refr_uv = SCREEN_UV + (view_n.xy - view_flat.xy) * refraction_strength;
	float refr_d = linear_depth(DEPTH_TEXTURE, refr_uv, INV_PROJECTION_MATRIX);
	if (refr_d < surface_depth) {
		refr_uv = SCREEN_UV;
		refr_d = scene_d;
	}
	float d = max(refr_d - surface_depth, 0.0);

	// --- Warna badan air (Beer-Lambert sederhana) ---
	vec3 scene = textureLod(SCREEN_TEXTURE, refr_uv, 0.0).rgb;
	vec3 absorb = exp(-d * absorption);
	vec3 body = mix(DEEP_COL.rgb, SHALLOW_COL.rgb, exp(-d * depth_color_fade));
	float clear = exp(-d * clarity);
	vec3 col = mix(body, scene * absorb, clear);

	// --- Subsurface scattering palsu di puncak ombak ---
	float ndv = clamp(dot(view_n, VIEW), 0.0, 1.0);
	float sss = smoothstep(sss_height_range.x, sss_height_range.y, v_height) * (1.0 - ndv);
	col += SSS_COL.rgb * sss * sss_strength;

	// --- Buih ---
	float fn = fbm(p * foam_scale + vec2(t * 0.02, -t * 0.015));
	float fn2 = vnoise(p * foam_scale * 3.0 - vec2(t * 0.05, t * 0.03));

	float surf_width = shore_foam_width * (0.6 + 0.4 * sin(t * 1.1 + fn * 6.0));
	float shore = 1.0 - smoothstep(0.0, surf_width, water_depth);
	float shore_foam = shore * smoothstep(0.25, 0.6, fn * 1.2 + shore * 0.5);

	float crest = 1.0 - smoothstep(crest_foam_threshold - 0.15, crest_foam_threshold, v_jacobian);
	float crest_foam = crest * smoothstep(0.35, 0.65, fn2 * 0.5 + fn * 0.6) * crest_foam_strength;

	float foam = clamp(shore_foam + crest_foam, 0.0, 1.0);

	// --- Output ---
	// Warna air lewat EMISSION, buih lewat ALBEDO (kena cahaya),
	// refleksi langit & kilau matahari dari PBR Godot (fresnel otomatis).
	ALBEDO = FOAM_COL.rgb * foam;
	EMISSION = col * (1.0 - foam);
	METALLIC = 0.0;
	SPECULAR = 0.5;
	ROUGHNESS = mix(mix(roughness, 0.25, 1.0 - detail_fade), 0.9, foam);
	NORMAL = view_n;
}
