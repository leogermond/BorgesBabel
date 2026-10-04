// Livre de la Bibliothèque : cuir teinté par livre, titre doré en Lora sur le dos.
//
// Le maillage est la boîte unité de la galerie (gallery.gd, _shared_book_mesh), mise à
// l'échelle par instance en (épaisseur, hauteur, profondeur) ; sa face −Z locale est le dos,
// tourné vers la salle. Le cuir vient de la couleur d'instance (COLOR), comme avant.
//
// Le titre arrive par INSTANCE_CUSTOM (MultiMesh.use_custom_data), codé par BookSpine.encode_title :
// chaque composante vaut 2^23 + 20 bits utiles, soit 4 symboles de 5 bits (0 : fin du titre,
// 1 à 25 : rang dans l'alphabet + 1) ; le bit 20 de x marque un livre d'images. Une composante
// hors de [2^23, 2^24) (donnée absente, ou demi-flottant du moteur Compatibility) efface le titre.
//
// Le titre se lit de bas en haut, tête penchée à gauche : la ligne de base monte le long du dos,
// le haut des lettres regarde vers +X local (la gauche du lecteur face au dos). Il est centré
// sur le dos, dans l'atlas de glyphes de BookSpine.glyph_atlas(), avec chasse proportionnelle.
shader_type spatial;

const float MARK = 8388608.0;           // 2^23 : repère des composantes valides
const int MAX_SYMBOLS = 16;

uniform sampler2D glyph_atlas : hint_default_transparent, filter_linear_mipmap, repeat_disable;
uniform float glyph_advance[25];         // chasse de chaque symbole, en em
uniform float atlas_cell_em = 1.5;       // côté d'une case de l'atlas, en em
uniform vec2 atlas_origin_em = vec2(0.25, 1.09375);   // point de chasse dans la case, depuis le coin haut-gauche
uniform int atlas_columns = 5;

uniform vec3 gold : source_color = vec3(0.86, 0.66, 0.30);
// Métal à 0,75 et non 1 : la galerie n'a ni ciel ni sonde de reflets, l'or pur n'y refléterait
// que le fond sombre du brouillard et ne brillerait qu'aux reflets des lampes.
uniform float gold_metallic : hint_range(0.0, 1.0) = 0.75;
uniform float gold_roughness : hint_range(0.0, 1.0) = 0.45;
uniform float leather_roughness : hint_range(0.0, 1.0) = 0.8;
uniform float tracking_em = 0.06;        // espace ajouté entre deux lettres
uniform float title_margin = 0.035;      // réserve en tête et en pied du dos, en mètres
uniform float title_size_fraction = 0.42;   // corps maximal (1 em) rapporté à l'épaisseur du dos
uniform float title_center_em = 0.25;    // hauteur du milieu de l'œil des minuscules au-dessus de la ligne de base

varying vec3 v_local;                    // position dans la boîte unité
varying float v_spine;                   // 1 sur le dos, 0 ailleurs
varying flat vec2 v_size;                // épaisseur et hauteur du livre, en mètres
varying flat uvec4 v_codes;              // 4 × 20 bits de symboles, et le drapeau ; 0 sans titre
varying flat vec2 v_layout;              // corps du titre (m par em), longueur du titre (em)


uint symbol_code(uvec4 codes, int i) {
	return (codes[i >> 2] >> uint(5 * (i & 3))) & 31u;
}


void vertex() {
	v_local = VERTEX;
	v_spine = step(0.5, -NORMAL.z);
	v_size = vec2(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz));
	vec4 custom = INSTANCE_CUSTOM;
	bool valid = all(greaterThanEqual(custom, vec4(MARK))) && all(lessThan(custom, vec4(2.0 * MARK)));
	v_codes = valid ? uvec4(custom - vec4(MARK)) : uvec4(0u);
	float width = 0.0;
	int count = 0;
	for (int i = 0; i < MAX_SYMBOLS; i++) {
		uint code = symbol_code(v_codes, i);
		if (code == 0u) {
			break;
		}
		width += glyph_advance[int(code) - 1] + tracking_em;
		count++;
	}
	width = max(width - tracking_em, 0.0);
	float room = max(v_size.y - 2.0 * title_margin, 0.0);
	float em = min(v_size.x * title_size_fraction, room / max(width, 0.001));
	v_layout = vec2(em, width);
}


void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = leather_roughness;
	METALLIC = 0.0;

	// Coordonnées du titre, en em : t.x le long de la ligne de base (du pied vers la tête),
	// t.y vers le haut des lettres. Dérivées prises hors de toute branche, pour les mipmaps.
	vec2 p = v_local.xy * v_size;                       // mètres, depuis le centre du dos
	float em = max(v_layout.x, 0.0001);
	vec2 t = vec2(p.y / em + 0.5 * v_layout.y, p.x / em + title_center_em);
	vec2 atlas_dx = dFdx(vec2(t.x, -t.y));
	vec2 atlas_dy = dFdy(vec2(t.x, -t.y));
	float atlas_em = atlas_cell_em * float(atlas_columns);
	float from_end = 0.5 * v_size.y - abs(p.y);         // distance à la tête ou au pied, en mètres
	float end_aa = fwidth(from_end);

	if (v_spine > 0.5) {
		float ink = 0.0;
		// Livre d'images : double filet doré en tête et en pied.
		if (((v_codes.x >> 20u) & 1u) == 1u) {
			float wide = smoothstep(0.012 - end_aa, 0.012 + end_aa, from_end)
					- smoothstep(0.018 - end_aa, 0.018 + end_aa, from_end);
			float thin = smoothstep(0.022 - end_aa, 0.022 + end_aa, from_end)
					- smoothstep(0.0245 - end_aa, 0.0245 + end_aa, from_end);
			ink = max(wide, thin);
		}
		// Chaque lettre se lit dans sa case de l'atlas ; les cases voisines couvrent les débords.
		float pen = 0.0;
		for (int i = 0; i < MAX_SYMBOLS; i++) {
			uint code = symbol_code(v_codes, i);
			if (code == 0u) {
				break;
			}
			int glyph = int(code) - 1;
			vec2 in_cell = atlas_origin_em + vec2(t.x - pen, -t.y);
			if (all(greaterThan(in_cell, vec2(0.0))) && all(lessThan(in_cell, vec2(atlas_cell_em)))) {
				vec2 cell = vec2(float(glyph % atlas_columns), float(glyph / atlas_columns));
				vec2 uv = (cell * atlas_cell_em + in_cell) / atlas_em;
				ink = max(ink, textureGrad(glyph_atlas, uv, atlas_dx / atlas_em, atlas_dy / atlas_em).a);
			}
			pen += glyph_advance[glyph] + tracking_em;
			if (pen - atlas_origin_em.x > t.x) {
				break;
			}
		}
		ALBEDO = mix(ALBEDO, gold, ink);
		METALLIC = gold_metallic * ink;
		ROUGHNESS = mix(leather_roughness, gold_roughness, ink);
	}
}
