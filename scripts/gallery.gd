class_name Gallery
extends Node3D
## Une galerie hexagonale de la Bibliothèque, construite à partir de son adresse.
##
## Repère local : le sol est à y = 0, le centre du puits d'aération à l'origine.
## Les six côtés ont pour normales sortantes les directions à i × 60° de +Z.
## Les côtés 0 (+Z) et 3 (−Z) s'ouvrent sur le vestibule qui mène aux galeries
## voisines ; la galerie porte le vestibule de son côté +Z. Les côtés 1, 2, 4, 5
## portent les étagères : ce sont les murs de livres 0 à 3.
## Chaque mur porte 5 étagères (0 en haut) de 32 livres (0 à gauche face au mur).
##
## Trois degrés de détail, selon la distance au bibliothécaire :
## - FULL : tout, avec les collisionneurs (galerie où il marche, et ses voisines) ;
## - LIT : livres un à un et vraies lampes, sans collisionneur ;
## - DISTANT : façades de livres peintes, globes lumineux ; ni lampe réelle ni collisionneur.
## Les maillages des murs, des étagères, des lampes et des livres sont communs à toutes
## les galeries : seule la graine des livres (tirée de l'adresse) change d'une galerie à
## l'autre, et le nuanceur en tire la hauteur et le cuir de chaque livre.
##
## La lumière : chaque lampe de la Bibliothèque éclaire par deux voies dont la somme
## reste constante. Une vraie OmniLight3D porte la part `real_weight(d)` de son énergie,
## d étant la distance de la lampe à l'œil ; le nuanceur commun à toutes les surfaces
## ajoute, pixel par pixel, la part 1 − real_weight(d) de chacune des lampes du réseau
## (deux par galerie, à chaque niveau), par la formule même de Godot pour une
## OmniLight3D sans ombre. Une galerie lointaine reçoit donc exactement la lumière
## d'une galerie proche ; une vraie lampe naît et meurt à poids nul.
##
## Adresse : `hexagon` et `level` sont le repère local de main.gd (des int, noms des nœuds et
## positions) ; `place` désigne la vraie galerie : sa clé (BookText.gallery_key, tirée des vraies
## coordonnées seules) et ses vraies coordonnées, base 25 + petit décalage. La graine des livres
## (hauteurs, cuirs) et les titres des dos se tirent de la clé : une galerie est la même quel que
## soit le chemin qui y mène (à pied, d'un saut, au-delà de 2^62 ou à 917 000 chiffres).
##
## Les titres dorés (BookSpine) : le MultiMesh commun n'a pas de donnée par instance ; chaque
## galerie LIT ou FULL donne à son matériau des livres une petite texture RGBA8 (96 × 20 texels,
## 12 octets par livre) que le nuanceur lit au texel près selon INSTANCE_ID, sous Forward+ comme
## sous Compatibility. Les titres d'une galerie (SHA-256 de 640 adresses, ~4 ms) se calculent sur
## le fil d'arrière-plan de BookText (priorité basse), après les genres de ses livres (livres
## d'images : double filet doré) demandés au service d'arrière-plan (son propre processus) :
## pump_titles, une fois par image, ne fait que relever ce qui est prêt et lancer la suite, sans
## jamais attendre le service. Ceux des galeries qui deviendront LIT au prochain pas sont préparés
## d'avance (prefetch_titles) et gardés en mémoire : un pas ne fait que poser des textures prêtes.
## Des genres qui n'arrivent pas (service absent ou en panne) laissent les titres sans filets, et
## se redemandent plus tard (flag_retry_ms) ; arrivés, ils complètent les textures déjà posées.
## Des titres arrivés en retard entrent en fondu (TITLE_APPEAR). La dorure est éclairée comme le
## cuir (part réelle et part du nuanceur) ; son reflet, que les vraies lampes ne portent pas, vient
## du nuanceur seul, pour toutes les lampes du réseau.
##
## Livres absents (volés : set_missing_books) : la même texture les marque (bit 21 du premier mot,
## BookSpine.MISSING_BIT), le nuanceur réduit leur boîte à un point ; sans titres encore, une
## texture vide qui ne porte que ces marques. Les façades peintes reçoivent leurs rangs par un
## uniforme (quatre au plus). locate_book ne rend rien à leur place.

const GalleryScript := preload("res://scripts/gallery.gd")
const BookSpineScript := preload("res://scripts/book_spine.gd")
const BookTextScript := preload("res://scripts/book_text.gd")
const AmbientSpeakerScript := preload("res://scripts/ambient_speaker.gd")

enum Detail { DISTANT, LIT, FULL }

const SQRT3 := 1.7320508075688772

const APOTHEM := 5.0                         # centre → face intérieure d'un mur
const SIDE := 2.0 * APOTHEM / SQRT3          # longueur d'un côté
const HEIGHT := 3.0                          # hauteur sous plafond
const SLAB := 0.4                            # épaisseur du plancher entre deux niveaux
const LEVEL_PITCH := HEIGHT + SLAB           # écart vertical entre deux niveaux
const WALL_THICK := 0.3
const HALL_LENGTH := 2.0
const HALL_WIDTH := 1.6
const PITCH := 2.0 * APOTHEM + HALL_LENGTH   # écart entre deux galeries voisines (axe Z)
const SHAFT_APOTHEM := 1.6
const RAIL_APOTHEM := 1.7
const RAIL_HEIGHT := 0.85        # « barandas bajísimas »
const RING_APOTHEM := 3.0        # bord extérieur de l'anneau de plancher vu par le puits

const WALLS := 4
const SHELVES := 5
const BOOKS_PER_SHELF := 32
const BOOK_SIDES: Array[int] = [1, 2, 4, 5]
const BOOKCASES: Array[String] = ["Bookcase0", "Bookcase1", "Bookcase2", "Bookcase3"]
const SHELF_WIDTH := 4.8
const BOOK_SLOT := SHELF_WIDTH / BOOKS_PER_SHELF
const CASE_DEPTH := 0.3
const BOARD_BASE := 0.12                     # dessus de la planche la plus basse
const BOARD_PITCH := 0.42
const BOARD_THICK := 0.03
const CASE_TOP := BOARD_BASE + SHELVES * BOARD_PITCH
const BOOK_THICK := 0.13
const BOOK_DEPTH := 0.22
const BOOK_FRONT := APOTHEM - CASE_DEPTH + 0.03   # dos des livres, côté salle
const BOOK_MIN_HEIGHT := 0.28
const BOOK_MAX_HEIGHT := 0.36
const BOOK_MAX_DARKEN := 0.35                # cuir assombri de 0 à 35 %

# La lumière de la Bibliothèque : deux lampes par galerie, et la pénombre ambiante.
const LAMP_X := 3.2
const LAMP_GLOBE_Y := HEIGHT - 0.45
const LAMP_LIGHT_Y := LAMP_GLOBE_Y - 0.2
const LAMP_COLOR := Color(1.0, 0.78, 0.5)
const LAMP_ENERGY := 1.6
const LAMP_RANGE := 8.0
const AMBIENT_COLOR := Color(0.55, 0.42, 0.3)
const AMBIENT_ENERGY := 0.35
# Part réelle d'une lampe : entière jusqu'à REAL_LIGHT_NEAR de l'œil, nulle au-delà de
# REAL_LIGHT_FAR. Toute lampe à moins de REAL_LIGHT_FAR d'un œil placé n'importe où
# dans la galerie d'origine appartient à une galerie éclairée (la plus proche qui ne
# l'est pas est à 7,4 m) : les vraies lampes ne naissent et ne meurent qu'éteintes.
const REAL_LIGHT_NEAR := 3.0
const REAL_LIGHT_FAR := 7.0

# La brume : exponentielle, puis fondue au noir de brume entre FAR_FADE_BEGIN et
# FAR_FADE_END. Les galeries et les anneaux naissent et disparaissent hors de vue :
# derrière un mur, ou au-delà de 90 m, où la brume a tout recouvert.
const FOG_COLOR := Color(0.05, 0.035, 0.022)
const FOG_DENSITY := 0.04      # reste de lumière : 38 % à 24 m, 15 % à 48 m, 6 % à 70 m
const FAR_FADE_BEGIN := 70.0
const FAR_FADE_END := 90.0

# Les titres dorés des dos (BookSpine), dans les galeries LIT et FULL seulement : les façades
# peintes des galeries DISTANT n'en portent pas. La dorure s'efface avec la distance à l'œil, de
# TITLE_FADE_BEGIN à TITLE_FADE_END (title_weight), comme le suggère la règle « fondue avant la
# frontière LIT ↔ DISTANT » : à 24 m une lettre de 2 cm couvre 0,7 pixel (champ de 75° sur 1080
# lignes), le fondu ne retire qu'un éclat déjà mêlé au cuir par les mipmaps de l'atlas ; et à
# chaque pas, test_depth vérifie qu'aucun dos en vue à moins de TITLE_FADE_END de l'œil ne
# gagne ni ne perd ses titres (de fait, aucun dos d'une galerie DISTANT n'est en vue depuis la
# galerie d'origine, vestibules et puits compris) : rien ne saute au passage LIT ↔ DISTANT.
# LIT ↔ FULL ne change rien aux livres (même matériau, mêmes titres).
const GOLD := Color(0.86, 0.66, 0.30)         # dorure, sRGB
const GOLD_METALLIC := 0.75
## Lisibilité de la dorure sur les cuirs clairs (fauve, ocre) : un liseré sombre autour des lettres
## (le cuir assombri de HALO_DARKEN sous le halo des glyphes, BookSpine.glyph_halo), comme le
## creux d'un fer de reliure, et une dorure un peu plus claire à la lumière diffuse (GILT_DIFFUSE de
## la couleur de l'or, au lieu de 1 − GOLD_METALLIC) ; le reflet de l'or ne change pas.
const HALO_DARKEN := 0.55
## Sur les cuirs les plus clairs (luminance linéaire de PALE_BEGIN à PALE_END), le liseré fonce
## jusqu'à HALO_DARKEN_PALE : l'or s'y détache autant que sur un cuir sombre.
const HALO_DARKEN_PALE := 0.85
const PALE_BEGIN := 0.12
const PALE_END := 0.32
const GILT_DIFFUSE := 0.4
const GOLD_ROUGHNESS := 0.45
const TITLE_FADE_BEGIN := 24.0
const TITLE_FADE_END := 32.0
const TITLE_APPEAR := 0.5            # s : fondu d'arrivée des titres calculés en retard
const TITLE_CACHE_SIZE := 160        # galeries dont les titres restent en mémoire (7,5 Ko chacune)
const TITLE_JOBS := 2                # galeries confiées au fil d'arrière-plan à la fois (il les traite l'une après l'autre)

const LEATHER: Array[Color] = [
	Color(0.42, 0.12, 0.08), Color(0.30, 0.18, 0.10), Color(0.16, 0.24, 0.14),
	Color(0.48, 0.34, 0.16), Color(0.20, 0.14, 0.22), Color(0.12, 0.16, 0.26),
	Color(0.55, 0.45, 0.30),
]

## Nuanceur de toutes les surfaces de la Bibliothèque. Variantes : SURFACE (albédo
## uni), BOOKS (MultiMesh des livres : hauteur et cuir tirés de la graine et du
## numéro de l'instance), FACES (façade peinte des livres lointains : les mêmes livres,
## tirés de la même façon, dessinés à plat). Les constantes {…} viennent de ce script.
const LIBRARY_SHADER := """
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

#define {VARIANT}

const float PITCH = {PITCH};
const float LEVEL_PITCH = {LEVEL_PITCH};
const float LAMP_X = {LAMP_X};
const float LAMP_Y = {LAMP_Y};
const float LAMP_RANGE = {LAMP_RANGE};
const vec3 LAMP_LIGHT = {LAMP_LIGHT};   // couleur linéaire × énergie d'une lampe
const float REAL_NEAR = {REAL_NEAR};
const float REAL_FAR = {REAL_FAR};
const vec3 FOG_LINEAR = {FOG_LINEAR};
const float FOG_DENSITY = {FOG_DENSITY};
const float FAR_FADE_BEGIN = {FAR_FADE_BEGIN};
const float FAR_FADE_END = {FAR_FADE_END};

uniform vec3 albedo_linear = vec3(1.0);
uniform vec3 emission_linear = vec3(0.0);
uniform int seed = 0;

#if defined(BOOKS) || defined(FACES)
const int SHELVES = {SHELVES};
const int BOOKS_PER_SHELF = {BOOKS_PER_SHELF};
const float BOARD_BASE = {BOARD_BASE};
const float BOARD_PITCH = {BOARD_PITCH};
const float CASE_TOP = {CASE_TOP};
const float BOOK_SLOT = {BOOK_SLOT};
const float BOOK_THICK = {BOOK_THICK};
const float BOOK_MIN_HEIGHT = {BOOK_MIN_HEIGHT};
const float BOOK_MAX_HEIGHT = {BOOK_MAX_HEIGHT};
const float BOOK_MAX_DARKEN = {BOOK_MAX_DARKEN};
const vec3 WOOD_LINEAR = {WOOD_LINEAR};
const vec3 LEATHER[7] = vec3[7]({LEATHER});

// Hachage entier « lowbias32 » ; Gallery.lowbias32 en est le jumeau.
uint lowbias32(uint x) {
	x ^= x >> 16u;
	x *= 0x7feb352du;
	x ^= x >> 15u;
	x *= 0x846ca68bu;
	x ^= x >> 16u;
	return x;
}

uint book_hash(int book, uint draw) {
	return lowbias32(uint(seed) ^ lowbias32(uint(book) * 4u + draw));
}

float unit_float(uint h) {
	return float(h >> 8u) * (1.0 / 16777216.0);
}

float book_height(int book) {
	return BOOK_MIN_HEIGHT + (BOOK_MAX_HEIGHT - BOOK_MIN_HEIGHT) * unit_float(book_hash(book, 0u));
}

// Le cuir est pris tel quel comme albédo linéaire, comme les couleurs d'instance d'avant.
vec3 book_color(int book) {
	return LEATHER[book_hash(book, 1u) % 7u] * (1.0 - BOOK_MAX_DARKEN * unit_float(book_hash(book, 2u)));
}
#endif

#ifdef BOOKS
varying flat vec3 book_albedo;

// Titres dorés (BookSpine). La texture de la galerie porte 3 texels RGBA8 par livre : 4 mots
// de 20 bits, 4 symboles de 5 bits chacun (0 : fin, 1 à 25 : rang + 1, 26 à 31 : fin aussi),
// le bit 20 du premier mot marque un livre d'images (double filet doré en tête et en pied).
// titles_alpha : 0 tant que la galerie n'a pas ses titres, puis 1 (fondu à leur arrivée).
uniform sampler2D titles : hint_default_black, filter_nearest, repeat_disable;
uniform sampler2D glyph_atlas : hint_default_transparent, filter_linear_mipmap, repeat_disable;
uniform sampler2D glyph_halo : hint_default_transparent, filter_linear_mipmap, repeat_disable;
uniform float titles_alpha = 0.0;

const int MAX_SYMBOLS = 16;
const int SYMBOLS = 25;
const int LETTERS = 22;            // rangs 0 à 21 : les lettres ; 22 espace, 23 virgule, 24 point
const int PERIOD = 24;
const float GLYPH_ADVANCE[47] = float[47]({GLYPH_ADVANCE});   // chasses en em : 25 symboles, 22 capitales
const float ATLAS_CELL_EM = {ATLAS_CELL_EM};
const vec2 ATLAS_ORIGIN_EM = {ATLAS_ORIGIN_EM};
const int ATLAS_COLUMNS = {ATLAS_COLUMNS};
const float TRACKING_EM = {TRACKING_EM};
const float TITLE_MARGIN = {TITLE_MARGIN};
const float TITLE_SIZE_FRACTION = {TITLE_SIZE_FRACTION};
const float TITLE_CENTER_EM = {TITLE_CENTER_EM};
const vec3 GOLD_LINEAR = {GOLD_LINEAR};
const float GOLD_METALLIC = {GOLD_METALLIC};
const float GOLD_ROUGHNESS = {GOLD_ROUGHNESS};
const float HALO_DARKEN = {HALO_DARKEN};
const float HALO_DARKEN_PALE = {HALO_DARKEN_PALE};
const float PALE_BEGIN = {PALE_BEGIN};
const float PALE_END = {PALE_END};
const float GILT_DIFFUSE = {GILT_DIFFUSE};
const float TITLE_FADE_BEGIN = {TITLE_FADE_BEGIN};
const float TITLE_FADE_END = {TITLE_FADE_END};

varying vec3 spine_local;          // position dans la boîte unité
varying float spine_face;          // 1 sur le dos (face −Z locale, tournée vers la salle), 0 ailleurs
varying flat float spine_height;   // hauteur du livre, en mètres
varying flat uvec4 spine_codes;    // les 4 mots du titre
varying flat vec2 spine_layout;    // corps du titre (m par em), longueur du titre (em)

uint symbol_code(uvec4 codes, int i) {
	return (codes[i >> 2] >> uint(5 * (i & 3))) & 31u;
}

// Le glyphe à dessiner pour le rang `symbol`, et la règle des capitales mise à jour.
int glyph_for(int symbol, inout bool capital) {
	if (symbol < LETTERS) {
		int glyph = capital ? symbol + SYMBOLS : symbol;
		capital = false;
		return glyph;
	}
	if (symbol == PERIOD) {
		capital = true;
	}
	return symbol;
}

// Les 4 mots du titre du livre `book` : 12 octets dans 3 texels de la ligne mur·5 + étagère.
uvec4 title_codes(int book) {
	ivec2 at = ivec2((book % BOOKS_PER_SHELF) * 3, book / BOOKS_PER_SHELF);
	uvec4 a = uvec4(round(texelFetch(titles, at, 0) * 255.0));
	uvec4 b = uvec4(round(texelFetch(titles, at + ivec2(1, 0), 0) * 255.0));
	uvec4 c = uvec4(round(texelFetch(titles, at + ivec2(2, 0), 0) * 255.0));
	return uvec4(a.r | (a.g << 8u) | (a.b << 16u), a.a | (b.r << 8u) | (b.g << 16u),
			b.b | (b.a << 8u) | (c.r << 16u), c.g | (c.b << 8u) | (c.a << 16u));
}

// Encre dorée du dos au point `p` (mètres depuis le centre du dos) : titre et filets (x), et halo
// des lettres (y : leur couverture élargie, où le cuir s'assombrit autour de l'or).
vec2 spine_ink(vec2 p, vec2 atlas_dx, vec2 atlas_dy, float end_aa) {
	float ink = 0.0;
	float halo = 0.0;
	float from_end = 0.5 * spine_height - abs(p.y);   // distance à la tête ou au pied
	// Livre d'images : double filet doré en tête et en pied.
	if (((spine_codes.x >> 20u) & 1u) == 1u) {
		float wide = smoothstep(0.012 - end_aa, 0.012 + end_aa, from_end)
				- smoothstep(0.018 - end_aa, 0.018 + end_aa, from_end);
		float thin = smoothstep(0.022 - end_aa, 0.022 + end_aa, from_end)
				- smoothstep(0.0245 - end_aa, 0.0245 + end_aa, from_end);
		ink = max(wide, thin);
	}
	// Le titre se lit de bas en haut, le haut des lettres vers +X local ; t en em : t.x le long
	// de la ligne de base (du pied vers la tête), t.y vers le haut des lettres.
	float em = max(spine_layout.x, 0.0001);
	vec2 t = vec2(p.y / em + 0.5 * spine_layout.y, p.x / em + TITLE_CENTER_EM);
	float atlas_em = ATLAS_CELL_EM * float(ATLAS_COLUMNS);
	float pen = 0.0;
	bool capital = true;
	for (int i = 0; i < MAX_SYMBOLS; i++) {
		uint code = symbol_code(spine_codes, i);
		if (code == 0u || code > uint(SYMBOLS)) {
			break;
		}
		int glyph = glyph_for(int(code) - 1, capital);
		vec2 in_cell = ATLAS_ORIGIN_EM + vec2(t.x - pen, -t.y);
		if (all(greaterThan(in_cell, vec2(0.0))) && all(lessThan(in_cell, vec2(ATLAS_CELL_EM)))) {
			vec2 cell = vec2(float(glyph % ATLAS_COLUMNS), float(glyph / ATLAS_COLUMNS));
			vec2 uv = (cell * ATLAS_CELL_EM + in_cell) / atlas_em;
			ink = max(ink, textureGrad(glyph_atlas, uv, atlas_dx / atlas_em, atlas_dy / atlas_em).a);
			halo = max(halo, textureGrad(glyph_halo, uv, atlas_dx / atlas_em, atlas_dy / atlas_em).a);
		}
		pen += GLYPH_ADVANCE[glyph] + TRACKING_EM;
		if (pen - ATLAS_ORIGIN_EM.x > t.x) {
			break;
		}
	}
	return vec2(ink, halo);
}
#endif

#ifdef FACES
// Livres absents de la galerie (volés), rangs (mur·5 + étagère)·32 + livre ; −1 : aucun.
uniform ivec4 missing = ivec4(-1);

// UV.x = 2 × mur + u (u de 0 à 1 le long de l'étagère), UV.y de 0 (haut) à 1 (bas).
vec3 painted(vec2 uv) {
	float wall = floor(uv.x * 0.5);
	float slot = (uv.x - 2.0 * wall) * float(BOOKS_PER_SHELF);
	int book = clamp(int(floor(slot)), 0, BOOKS_PER_SHELF - 1);
	float y = mix(CASE_TOP, BOARD_BASE, uv.y);
	int board = clamp(int(floor((y - BOARD_BASE) / BOARD_PITCH)), 0, SHELVES - 1);
	int index = (int(wall) * SHELVES + SHELVES - 1 - board) * BOOKS_PER_SHELF + book;
	float across = abs(fract(slot) - 0.5) * BOOK_SLOT;
	float above = y - BOARD_BASE - float(board) * BOARD_PITCH;
	bool absent = any(equal(ivec4(index), missing));
	return (!absent && across < BOOK_THICK * 0.5 && above < book_height(index)) ? book_color(index) : WOOD_LINEAR;
}
#endif

void vertex() {
#ifdef BOOKS
	// Boîte unité ; l'instance la pose sur sa planche, sa hauteur vient de la graine.
	spine_local = VERTEX;
	spine_face = step(0.5, -NORMAL.z);
	spine_height = book_height(INSTANCE_ID);
	VERTEX.y = (VERTEX.y + 0.5) * spine_height;
	book_albedo = book_color(INSTANCE_ID);
	// Le titre et sa mise en page (BookSpine.title_layout) : un corps qui tient dans le dos.
	spine_codes = title_codes(INSTANCE_ID);
	float width = 0.0;
	bool capital = true;
	for (int i = 0; i < MAX_SYMBOLS; i++) {
		uint code = symbol_code(spine_codes, i);
		if (code == 0u || code > uint(SYMBOLS)) {
			break;
		}
		width += GLYPH_ADVANCE[glyph_for(int(code) - 1, capital)] + TRACKING_EM;
	}
	width = max(width - TRACKING_EM, 0.0);
	float room = max(spine_height - 2.0 * TITLE_MARGIN, 0.0);
	spine_layout = vec2(min(BOOK_THICK * TITLE_SIZE_FRACTION, room / max(width, 0.001)), width);
	// Livre absent (volé, bit 21 du premier mot) : sa boîte se réduit à un point, l'étagère montre
	// un vide à sa place.
	if (((spine_codes.x >> {MISSING_BIT}u) & 1u) == 1u) {
		VERTEX = vec3(0.0);
	}
#endif
}

float real_weight(float d) {
	return 1.0 - smoothstep(REAL_NEAR, REAL_FAR, d);
}

// Part des lampes du réseau que les vraies OmniLight3D ne portent pas : Σ (1 − poids
// réel) × (1 − (d/portée)⁴)² / d × max(N·L, 0). Les lampes à moins de LAMP_RANGE du
// point sont au plus à une galerie et à trois niveaux de lui.
float virtual_light(vec3 p, vec3 n, vec3 eye) {
	float n0 = round(p.z / PITCH);
	float k0 = floor((p.y - LAMP_Y) / LEVEL_PITCH);
	float sum = 0.0;
	for (int iz = -1; iz <= 1; iz++) {
		float z = (n0 + float(iz)) * PITCH;
		for (int iy = -2; iy <= 3; iy++) {
			float y = LAMP_Y + (k0 + float(iy)) * LEVEL_PITCH;
			for (int side = 0; side < 2; side++) {
				vec3 lamp = vec3(side == 0 ? -LAMP_X : LAMP_X, y, z);
				vec3 to = lamp - p;
				float d = length(to);
				if (d < LAMP_RANGE && d > 0.0001) {
					float nd = d / LAMP_RANGE;
					nd = 1.0 - nd * nd * nd * nd;
					sum += nd * nd / d * max(dot(n, to) / d, 0.0) * (1.0 - real_weight(distance(lamp, eye)));
				}
			}
		}
	}
	return sum;
}

#ifdef BOOKS
// Reflet de la dorure (GGX, Smith corrélé, Schlick : le spéculaire de Godot pour un métal de
// rugosité GOLD_ROUGHNESS), de TOUTES les lampes du réseau à poids entier. Les vraies lampes
// n'ont pas de spéculaire (light_specular = 0, specular_disabled) : le nuanceur le porte seul,
// sans dépendre de la part réelle, et rien ne saute quand une lampe devient réelle.
vec3 gold_sheen(vec3 p, vec3 n, vec3 eye) {
	vec3 v = normalize(eye - p);
	float nv = max(dot(n, v), 0.0001);
	float a = GOLD_ROUGHNESS * GOLD_ROUGHNESS;
	float a2 = a * a;
	vec3 f0 = mix(vec3(0.04), GOLD_LINEAR, GOLD_METALLIC);
	float n0 = round(p.z / PITCH);
	float k0 = floor((p.y - LAMP_Y) / LEVEL_PITCH);
	vec3 sum = vec3(0.0);
	for (int iz = -1; iz <= 1; iz++) {
		float z = (n0 + float(iz)) * PITCH;
		for (int iy = -2; iy <= 3; iy++) {
			float y = LAMP_Y + (k0 + float(iy)) * LEVEL_PITCH;
			for (int side = 0; side < 2; side++) {
				vec3 to = vec3(side == 0 ? -LAMP_X : LAMP_X, y, z) - p;
				float d = max(length(to), 0.0001);
				vec3 l = to / d;
				float nl = dot(n, l);
				if (d < LAMP_RANGE && nl > 0.0) {
					float nd = d / LAMP_RANGE;
					nd = 1.0 - nd * nd * nd * nd;
					vec3 h = normalize(l + v);
					float nh = max(dot(n, h), 0.0);
					float q = nh * nh * (a2 - 1.0) + 1.0;
					float ggx = a2 / (PI * q * q);
					float vis = 0.5 / (nl * (nv * (1.0 - a) + a) + nv * (nl * (1.0 - a) + a));
					vec3 fresnel = f0 + (1.0 - f0) * pow(1.0 - max(dot(v, h), 0.0), 5.0);
					sum += nd * nd / d * nl * PI * ggx * vis * fresnel;
				}
			}
		}
	}
	return sum;
}
#endif

// Le rendu Compatibilité tient ALBEDO et EMISSION pour du sRGB et les linéarise ensuite.
vec3 encoded(vec3 c) {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	return mix(1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, c * 12.92, lessThan(c, vec3(0.0031308)));
#else
	return c;
#endif
}

void fragment() {
	vec3 albedo = albedo_linear;
	vec3 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 normal = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float d = length(VERTEX);
	vec3 sheen = vec3(0.0);
#ifdef BOOKS
	albedo = book_albedo;
	// La dorure, pondérée par title_weight(d) : entière jusqu'à TITLE_FADE_BEGIN de l'œil, nulle
	// dès TITLE_FADE_END, en deçà de toute galerie sans titres qu'un œil de la galerie d'origine
	// peut voir. Dérivées prises hors de toute branche, pour les mipmaps de l'atlas.
	vec2 p = vec2(spine_local.x * BOOK_THICK, spine_local.y * spine_height);
	float em = max(spine_layout.x, 0.0001);
	vec2 atlas_dx = dFdx(vec2(p.y, -p.x) / em);
	vec2 atlas_dy = dFdy(vec2(p.y, -p.x) / em);
	float end_aa = fwidth(p.y);
	float gilt = titles_alpha * (1.0 - smoothstep(TITLE_FADE_BEGIN, TITLE_FADE_END, d));
	float shade = 0.0;
	if (spine_face > 0.5 && gilt > 0.0) {
		vec2 inked = spine_ink(p, atlas_dx, atlas_dy, end_aa);
		shade = gilt * max(inked.y - inked.x, 0.0);
		gilt *= inked.x;
	} else {
		gilt = 0.0;
	}
	if (gilt > 0.0) {
		sheen = gilt * LAMP_LIGHT * gold_sheen(world, normal, CAMERA_POSITION_WORLD);
	}
	float pale = smoothstep(PALE_BEGIN, PALE_END, dot(albedo, vec3(0.2126, 0.7152, 0.0722)));
	albedo *= 1.0 - mix(HALO_DARKEN, HALO_DARKEN_PALE, pale) * shade;
	albedo = mix(albedo, GOLD_LINEAR * GILT_DIFFUSE, gilt);
#endif
#ifdef FACES
	albedo = painted(UV);
#endif
	ALBEDO = encoded(albedo);
	// Lumière des lampes en partie virtuelles : ajoutée comme l'est la lumière diffuse.
	EMISSION = encoded(albedo * LAMP_LIGHT * virtual_light(world, normal, CAMERA_POSITION_WORLD) + emission_linear + sheen);
	FOG = vec4(FOG_LINEAR, 1.0 - exp(-FOG_DENSITY * d) * (1.0 - smoothstep(FAR_FADE_BEGIN, FAR_FADE_END, d)));
}
"""

static var _shaders: Dictionary = {}     # variante → Shader
static var _materials: Dictionary = {}
static var _book_mesh: BoxMesh
static var _book_multimesh: MultiMesh    # les 640 places de livres, hauteur unité
static var _book_buffer := PackedFloat32Array()
static var _interior_mesh: ArrayMesh     # murs, étagères, sol, plafond, lampes
static var _faces_mesh: ArrayMesh        # façades des quatre murs de livres, à plat
static var _ring_mesh: ArrayMesh         # l'anneau du puits d'un niveau lointain
static var _structure_boxes: Array = []  # [Transform3D, Vector3] : collisionneurs des murs et du sol
static var _pool: Dictionary = {}        # nom d'enfant → enfants détachés, prêts à resservir
static var _glyph_texture: ImageTexture  # atlas des glyphes de Lora (BookSpine), commun
static var _halo_texture: ImageTexture   # halo des glyphes (BookSpine.glyph_halo), commun
static var _title_cache: Dictionary = {} # clé de galerie → octets de la texture des titres (du plus ancien au plus récent)
static var _title_queue: Array = []      # adresses (place) à calculer, urgentes d'abord
static var _title_jobs: Array = []       # travaux en cours {key, place, ticket} (fil d'arrière-plan)
static var _title_waiting: Array = []    # galeries LIT ou FULL qui attendent leurs titres
static var _flag_retry: Dictionary = {}  # clé → {place, at, ticket, delay} : genres à redemander
static var _shown: Array = []            # galeries dont la texture porte des titres (pour les compléter)
## Temps passé par le dernier pump_titles sur le fil principal, en µs (mesures des tests), et son
## détail : [flush (verrou de la file), take (relevés), textures posées, genres redemandés,
## lancements] en µs, puis le nombre de relevés, de textures posées et de lancements, puis le
## détail du flush (BookText.last_flush_parts).
static var last_pump_usec := 0
static var last_pump_parts := PackedInt32Array()
## Attente avant de redemander des genres de livres qui ne sont pas arrivés (doublée ensuite).
static var flag_retry_ms := 5000
## Livres absents de leur étagère (volés : ceux du catalogue, celui que porte le bibliothécaire),
## par clé de galerie : clé → [{hexagon, level : vraies coordonnées (base 25), book : rang}].
static var _missing: Dictionary = {}
## Clé → rangs des livres absents de la galerie de cette clé, vérifiés une fois sur ses vraies
## coordonnées (comparaison exacte des chaînes base 25) ; la clé, tirée des vraies coordonnées
## seules, désigne ensuite la même galerie.
static var _missing_checked: Dictionary = {}

var hexagon: int
var level: int
## La vraie galerie : {key, hexagon, dh, level, dl} (voir place_of).
var place: Dictionary = {}
var detail: Detail = Detail.DISTANT
var _book_heights := PackedFloat32Array()   # calculées à la demande (book_heights)
var _book_material: ShaderMaterial          # livres un à un : graine de l'adresse, titres
var _face_material: ShaderMaterial          # façades peintes : même graine
var _parts: Dictionary = {}                 # nom → enfant présent (voir _keep)
var _titles_key := ""                       # adresse dont la texture des titres porte les titres
var _titles_texture: ImageTexture           # titres des 640 livres (BookSpine.gallery_title_bytes)
var _titles_tween: Tween
var _speaker: AmbientSpeakerScript          # haut-parleur d'ambiance du vestibule (set_speaker)
var _missing_books := PackedInt32Array()    # rangs des livres absents (volés) de la galerie
var _titles_bytes := PackedByteArray()      # titres posés (ceux de _titles_key), sans les absents
var _texture_marks := false                 # la texture branchée marque des livres absents
var _faces_shown := Vector4i(-1, -1, -1, -1)  # livres absents donnés au matériau des façades


## Une galerie au repère local (p_hexagon, p_level), à la vraie adresse `p_place` (place_of) ;
## sans `p_place`, le repère local est la vraie adresse.
static func create(p_hexagon: int, p_level: int, p_detail: Detail = Detail.FULL, p_place: Dictionary = {}) -> GalleryScript:
	var gallery := GalleryScript.new()
	gallery.hexagon = p_hexagon
	gallery.level = p_level
	gallery.place = p_place if not p_place.is_empty() else place_of_ints(p_hexagon, p_level)
	gallery.name = _node_name(p_hexagon, p_level)
	gallery._missing_books = _missing_in(gallery.place)
	gallery.set_detail(p_detail)
	return gallery


## La vraie adresse d'une galerie : hexagone = hexagon_base + dh, niveau = level_base + dl (bases
## en base 25, de toute taille, partagées sans copie entre les galeries d'un même pas ; décalages
## petits), et sa clé `key` (BookText.gallery_key de ces coordonnées).
static func place_of(hexagon_base: String, dh: int, level_base: String, dl: int, key: String) -> Dictionary:
	return {"key": key, "hexagon": hexagon_base, "dh": dh, "level": level_base, "dl": dl}


## La vraie adresse d'une galerie de coordonnées int.
static func place_of_ints(p_hexagon: int, p_level: int) -> Dictionary:
	return place_of(BookTextScript.b25_from_int(p_hexagon), 0, BookTextScript.b25_from_int(p_level), 0,
		BookTextScript.gallery_key(p_hexagon, p_level))


## Hexagone et niveau de la vraie galerie, en base 25 (une copie de la coordonnée).
func true_coordinates() -> Array:
	return [BookTextScript.b25_add_small(place.hexagon, place.dh), BookTextScript.b25_add_small(place.level, place.dl)]


## Donne à la galerie une nouvelle adresse (repère local et vraie adresse, place_of ; sans
## `p_place`, le repère local) et un degré de détail : seules la graine des livres et la texture
## des titres changent, les maillages partagés restent. Même clé : seule la description de la vraie
## adresse se met à jour (nouvelles bases d'un pas).
func readdress(p_hexagon: int, p_level: int, p_detail: Detail, p_place: Dictionary = {}) -> void:
	var new_place := p_place if not p_place.is_empty() else place_of_ints(p_hexagon, p_level)
	if p_hexagon != hexagon or p_level != level:
		hexagon = p_hexagon
		level = p_level
		name = _node_name(p_hexagon, p_level)
	var same: bool = new_place.key == place.key
	place = new_place
	if not same:
		_book_heights = PackedFloat32Array()
		var shader_seed := _signed32(book_seed())
		if _book_material != null:
			_book_material.set_shader_parameter("seed", shader_seed)
		if _face_material != null:
			_face_material.set_shader_parameter("seed", shader_seed)
		_titles_key = ""
		_set_titles_alpha(0.0)
		_missing_books = _missing_in(place)
		_show_missing_faces()
	set_detail(p_detail)


## Ajoute ou retire les éléments pour atteindre le degré de détail demandé.
func set_detail(p_detail: Detail) -> void:
	detail = p_detail
	_keep("Interior", true, _new_interior)
	_keep("Faces", detail == Detail.DISTANT, _new_faces)
	_keep("Books", detail >= Detail.LIT, _new_books)
	_keep("Lights", detail >= Detail.LIT, _new_lights)
	var full := detail == Detail.FULL
	if _parts.has("Structure") != full:
		_keep("Structure", full, _new_structure)
		for wall in WALLS:
			_keep(BOOKCASES[wall], full, _new_bookcase.bind(wall))
	if detail >= Detail.LIT:
		_want_titles()


## Donne ou retire au vestibule de la galerie (côté +Z, à z = APOTHEM + HALL_LENGTH / 2) son
## haut-parleur d'ambiance ; à appeler une fois la galerie à sa place. Un haut-parleur retiré
## s'éteint en fondu (AmbientSpeaker.retire) et n'appartient plus à la galerie.
func set_speaker(wanted: bool) -> void:
	if wanted and _speaker == null:
		_speaker = AmbientSpeakerScript.create()
		_speaker.position = Vector3(0.0, AmbientSpeakerScript.HEIGHT, APOTHEM + HALL_LENGTH * 0.5)
		add_child(_speaker)
	elif not wanted and _speaker != null:
		_speaker.retire()
		_speaker = null


# --- Titres des dos --------------------------------------------------------------------------

## Poids de la dorure à la distance `d` de l'œil (jumeau du fondu du nuanceur des livres).
static func title_weight(d: float) -> float:
	return 1.0 - smoothstep(TITLE_FADE_BEGIN, TITLE_FADE_END, d)


## Vrai quand la texture des titres porte ceux de l'adresse de la galerie.
func titles_ready() -> bool:
	return detail >= Detail.LIT and _titles_key == place.key


## Opacité des titres dans le nuanceur : 0 en attente, 1 une fois arrivés (après un fondu).
func titles_alpha() -> float:
	return _book_material.get_shader_parameter("titles_alpha") if _book_material != null else 0.0


## La texture des titres branchée sur le matériau des livres (null avant les premiers titres).
func titles_texture() -> ImageTexture:
	return _titles_texture


## Calcule tout de suite les titres de la galerie s'ils manquent (démonstration, tests) :
## une requête au service (fil principal) et ~4 ms de hachage.
func load_titles_now() -> void:
	if detail < Detail.LIT or titles_ready():
		return
	var key: String = place.key
	if not _title_cache.has(key):
		var coordinates := true_coordinates()
		var bytes := BookSpineScript.gallery_title_bytes(key)
		var flags := BookTextScript.gallery_image_books(coordinates[0], coordinates[1])
		if flags.size() == BookSpineScript.WALLS * BookSpineScript.SHELVES * BookSpineScript.BOOKS:
			BookSpineScript.set_image_flags(bytes, flags)
		_store_titles(key, bytes)
	_want_titles()


## Prépare les titres des galeries qui deviendront LIT ou FULL au prochain pas : les cases
## `cells` (à vraies lampes, relatives à l'origine), décalées d'un pas dans chacune des quatre
## directions ; `place_at(case)` rend la vraie adresse d'une case (place_of). Les galeries en
## attente passent d'abord, de la plus proche à la plus lointaine.
static func prefetch_titles(place_at: Callable, cells: Array) -> void:
	var queue: Array = []
	var queued := {}
	_title_waiting = _title_waiting.filter(func(g: Variant) -> bool:
		return is_instance_valid(g) and g.detail >= Detail.LIT and not g.titles_ready())
	_title_waiting.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		return a.position.length_squared() < b.position.length_squared())
	for gallery: GalleryScript in _title_waiting:
		if not queued.has(gallery.place.key):
			queued[gallery.place.key] = true
			queue.append(gallery.place)
	var lit := {}
	for cell: Vector2i in cells:
		lit[cell] = true
	for move: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		for cell: Vector2i in cells:
			var next: Vector2i = cell + move
			if lit.has(next):
				continue
			var next_place: Dictionary = place_at.call(next)
			if not queued.has(next_place.key) and not _title_cache.has(next_place.key):
				queued[next_place.key] = true
				queue.append(next_place)
	_title_queue = queue


## Fait avancer les titres, une fois par image, sans rien attendre : relève les calculs de titres
## finis (fils du moteur) et les genres des livres arrivés (service d'arrière-plan), range les
## galeries complètes (et les donne aux galeries qui les attendent), redemande les genres qui
## manquent, puis lance les galeries suivantes (TITLE_JOBS en cours au plus).
static func pump_titles() -> void:
	var started := Time.get_ticks_usec()
	var now := Time.get_ticks_msec()
	var parts := PackedInt32Array([0, 0, 0, 0, 0, 0, 0, 0])
	BookTextScript.flush()   # requêtes et oublis en attente du verrou (Hud, redemandes)
	var mark := Time.get_ticks_usec()
	parts[0] = mark - started
	parts.append_array(BookTextScript.last_flush_parts)
	for i in range(_title_jobs.size() - 1, -1, -1):
		var job: Dictionary = _title_jobs[i]
		var response: Variant = BookTextScript.take(job.ticket)
		var taken := Time.get_ticks_usec()
		parts[1] += taken - mark
		parts[5] += 1
		mark = taken
		if response == null:
			continue
		_title_jobs.remove_at(i)
		var bytes: Variant = response.get("title_bytes") if response is Dictionary else null
		if not bytes is PackedByteArray:   # service arrêté avant le calcul : la galerie se redemande
			_title_queue.push_front(job.place)
			continue
		if response.get("flags_ok") != true:
			_flag_retry[job.key] = {"place": job.place, "at": now + flag_retry_ms, "ticket": -1, "delay": flag_retry_ms}
		_store_titles(job.key, bytes)
		var stored := Time.get_ticks_usec()
		parts[2] += stored - mark
		parts[6] += 1
		mark = stored
	_pump_retries(now)
	var retried := Time.get_ticks_usec()
	parts[3] = retried - mark
	while not _title_queue.is_empty() and _title_jobs.size() < TITLE_JOBS:
		var entry: Dictionary = _title_queue.pop_front()
		if _title_cache.has(entry.key) or _title_running(entry.key):
			continue
		var key: String = entry.key
		# Titres (SHA-256 des 640 adresses) et genres, tout sur le fil d'arrière-plan.
		var ticket := BookTextScript.submit_gallery_flags(entry.hexagon, entry.dh, entry.level, entry.dl,
			GalleryScript._titles_of.bind(key))
		_title_jobs.append({"key": key, "place": entry, "ticket": ticket})
		parts[7] += 1
	var ended := Time.get_ticks_usec()
	parts[4] = ended - retried
	last_pump_parts = parts
	last_pump_usec = ended - started


## Sur le fil d'arrière-plan : les titres de la galerie `key`, avec les genres de la réponse du
## service (fonction statique, sans fermeture : rien n'est partagé avec le fil principal).
static func _titles_of(flags_response: Dictionary, key: String) -> Dictionary:
	var title_bytes := BookSpineScript.gallery_title_bytes(key)
	var flags := _flags_of(flags_response)
	if not flags.is_empty():
		BookSpineScript.set_image_flags(title_bytes, flags)
	return {"title_bytes": title_bytes, "flags_ok": not flags.is_empty()}


## Les 640 genres d'une réponse du service, ou [] (erreur, réponse incomplète).
static func _flags_of(response: Variant) -> Array:
	var flags: Variant = response.get("is_image") if response is Dictionary else null
	if flags is Array and flags.size() == BookSpineScript.WALLS * BookSpineScript.SHELVES * BookSpineScript.BOOKS:
		return flags
	return []


## Genres manquants : redemandés à l'échéance ; arrivés, ils complètent les titres en mémoire et
## les textures posées. Une galerie sortie de la mémoire des titres est oubliée.
static func _pump_retries(now: int) -> void:
	for key: String in _flag_retry.keys():
		var retry: Dictionary = _flag_retry[key]
		if not _title_cache.has(key):
			if retry.ticket >= 0:
				BookTextScript.cancel(retry.ticket)
			_flag_retry.erase(key)
		elif retry.ticket < 0:
			if now >= retry.at:
				retry.ticket = BookTextScript.submit_gallery_flags(retry.place.hexagon, retry.place.dh, retry.place.level, retry.place.dl)
		else:
			var response: Variant = BookTextScript.take(retry.ticket)
			if response == null:
				continue
			retry.ticket = -1
			var flags := _flags_of(response)
			if flags.is_empty():
				retry.delay = mini(retry.delay * 2, 60000)
				retry.at = now + retry.delay
				continue
			_flag_retry.erase(key)
			var bytes: PackedByteArray = _title_cache[key]
			BookSpineScript.set_image_flags(bytes, flags)
			_title_cache[key] = bytes
			_shown = _shown.filter(func(g: Variant) -> bool: return is_instance_valid(g))
			for gallery: GalleryScript in _shown:
				if gallery._titles_key == key:
					gallery._apply_titles(key, bytes, false)


## Vrai quand aucun titre ne reste à calculer ni aucun genre à redemander.
static func titles_idle() -> bool:
	return _title_queue.is_empty() and _title_jobs.is_empty() and _flag_retry.is_empty()


## Les clés dont les genres des livres restent à redemander (service absent ou en panne).
static func flags_pending() -> Array:
	return _flag_retry.keys()


static func _title_running(key: String) -> bool:
	for running: Dictionary in _title_jobs:
		if running.key == key:
			return true
	return false


## Range des titres calculés (les plus anciens sortent au-delà de TITLE_CACHE_SIZE) et les
## donne, en fondu, aux galeries qui les attendent.
static func _store_titles(key: String, bytes: PackedByteArray) -> void:
	_title_cache.erase(key)
	_title_cache[key] = bytes
	while _title_cache.size() > TITLE_CACHE_SIZE:
		_title_cache.erase(_title_cache.keys()[0])
	var still: Array = []
	for gallery: Variant in _title_waiting:   # une galerie libérée en attente : sautée
		if not is_instance_valid(gallery) or gallery.detail < Detail.LIT or gallery.titles_ready():
			continue
		if gallery.place.key == key:
			gallery._apply_titles(key, bytes, true)
		else:
			still.append(gallery)
	_title_waiting = still


## Les titres de l'adresse : de la mémoire tout de suite, sinon en attente du calcul.
func _want_titles() -> void:
	var key: String = place.key
	if _titles_key == key:
		return
	var bytes: Variant = _title_cache.get(key)
	if bytes != null:
		_title_cache.erase(key)   # le plus récent sort le dernier
		_title_cache[key] = bytes
		_apply_titles(key, bytes, false)
		return
	_set_titles_alpha(0.0)
	if _texture_marks or not _missing_books.is_empty():
		_set_texture(PackedByteArray())   # sans titres, mais les livres absents restent absents
	if not _title_waiting.has(self):
		_title_waiting.append(self)
	if not _title_running(key) and not _title_queue.any(func(e: Dictionary) -> bool: return e.key == key):
		_title_queue.push_front(place)


func _apply_titles(key: String, bytes: PackedByteArray, fade: bool) -> void:
	_titles_bytes = bytes
	_set_texture(bytes)
	_titles_key = key
	if not _shown.has(self):
		_shown.append(self)
	if fade and is_inside_tree():
		_set_titles_alpha(0.0)
		_titles_tween = create_tween()
		_titles_tween.tween_property(_book_material, "shader_parameter/titles_alpha", 1.0, TITLE_APPEAR)
	else:
		_set_titles_alpha(1.0)


## Branche la texture des titres `bytes` (vide : pas de titres), les livres absents marqués (bit
## MISSING_BIT, sur une copie : les titres en mémoire restent sans marque).
func _set_texture(bytes: PackedByteArray) -> void:
	var data := bytes
	if not _missing_books.is_empty():
		if data.is_empty():
			data.resize(BookSpineScript.TEXTURE_WIDTH * BookSpineScript.TEXTURE_HEIGHT * 4)
		else:
			data = bytes.duplicate()
		BookSpineScript.set_missing_flags(data, _missing_books)
	_texture_marks = not _missing_books.is_empty()
	if data.is_empty():
		_titles_texture = null
		_book_material.set_shader_parameter("titles", null)
		return
	var image := Image.create_from_data(BookSpineScript.TEXTURE_WIDTH, BookSpineScript.TEXTURE_HEIGHT,
		false, Image.FORMAT_RGBA8, data)
	# Une texture neuve (7,5 Ko) plutôt que update() : la texture branchée sur le matériau reste
	# lisible telle quelle (le rendu factice des tests ne garde que l'image de création).
	_titles_texture = ImageTexture.create_from_image(image)
	_book_material.set_shader_parameter("titles", _titles_texture)


# --- Livres absents ----------------------------------------------------------------------------

## Déclare les livres absents de leur étagère : [{key : clé de leur galerie (BookText.gallery_key),
## hexagon, level : vraies coordonnées base 25, wall, shelf, book}]. Les galeries déjà construites
## se mettent à jour par refresh_missing.
static func set_missing_books(books: Array) -> void:
	_missing = {}
	_missing_checked = {}
	for b: Dictionary in books:
		if not _missing.has(b.key):
			_missing[b.key] = []
		_missing[b.key].append({"hexagon": b.hexagon, "level": b.level,
			"book": (int(b.wall) * SHELVES + int(b.shelf)) * BOOKS_PER_SHELF + int(b.book)})


## Les rangs des livres absents de la galerie `p` (place_of), triés : une clé sans livre absent ne
## coûte qu'une recherche ; sinon les vraies coordonnées de la galerie se comparent, une fois par clé,
## à celles des livres absents.
static func _missing_in(p: Dictionary) -> PackedInt32Array:
	var candidates: Variant = _missing.get(p.key)
	if candidates == null:
		return PackedInt32Array()
	var checked: Variant = _missing_checked.get(p.key)
	if checked != null:
		return checked
	var h := BookTextScript.b25_add_small(p.hexagon, p.dh)
	var l := BookTextScript.b25_add_small(p.level, p.dl)
	var books := PackedInt32Array()
	for candidate: Dictionary in candidates:
		if candidate.hexagon == h and candidate.level == l and not books.has(candidate.book):
			books.append(candidate.book)
	books.sort()
	_missing_checked[p.key] = books
	return books


## Les rangs des livres absents de la galerie (aucun : tableau vide).
func missing_books() -> PackedInt32Array:
	return _missing_books


## Reprend les livres absents de la galerie après set_missing_books : façades peintes et texture
## des livres.
func refresh_missing() -> void:
	var books := _missing_in(place)
	if books == _missing_books:
		return
	_missing_books = books
	_show_missing_faces()
	if _book_material != null:
		_set_texture(_titles_bytes if _titles_key == place.key else PackedByteArray())


## Donne aux façades peintes les livres absents, seulement quand ils changent (un pas readresse
## des dizaines de galeries, presque toujours sans livre absent).
func _show_missing_faces() -> void:
	var faces := _missing_faces()
	if _face_material != null and faces != _faces_shown:
		_face_material.set_shader_parameter("missing", faces)
		_faces_shown = faces


## Les quatre premiers livres absents, pour les façades peintes (−1 : aucun). Plus de quatre livres
## volés dans une même galerie n'arrive pas (les livres volés du catalogue sont dans des galeries
## distinctes, le bibliothécaire n'en porte qu'un) ; le cinquième resterait peint au loin.
func _missing_faces() -> Vector4i:
	var faces := Vector4i(-1, -1, -1, -1)
	for i in mini(_missing_books.size(), 4):
		faces[i] = _missing_books[i]
	return faces


func _set_titles_alpha(alpha: float) -> void:
	if _titles_tween != null:
		_titles_tween.kill()
		_titles_tween = null
	if _book_material != null:
		_book_material.set_shader_parameter("titles_alpha", alpha)


## Règle la part réelle de chaque lampe de la galerie pour un œil en `eye` (repère du monde).
func update_lights(eye: Vector3) -> void:
	var lights: Node = _parts.get("Lights")
	if lights == null:
		return
	for light: OmniLight3D in lights.get_children():
		var weight := real_weight((position + light.position).distance_to(eye))
		light.light_energy = LAMP_ENERGY * weight
		light.visible = weight > 0.0


## Le livre sous le point `world_pos` de la façade d'une bibliothèque, ou {} entre deux étagères.
func locate_book(bookcase: StaticBody3D, world_pos: Vector3) -> Dictionary:
	var local := bookcase.to_local(world_pos)
	var slot := floori((SHELF_WIDTH * 0.5 - local.x) / BOOK_SLOT)
	var board := floori((local.y - BOARD_BASE) / BOARD_PITCH)
	if slot < 0 or slot >= BOOKS_PER_SHELF or board < 0 or board >= SHELVES:
		return {}
	var wall := int(bookcase.get_meta("book_wall"))
	var shelf := SHELVES - 1 - board
	if _missing_books.has((wall * SHELVES + shelf) * BOOKS_PER_SHELF + slot):
		return {}   # un vide sur l'étagère : rien à viser
	return {
		"gallery": self, "hexagon": hexagon, "level": level,
		"wall": wall, "shelf": shelf, "book": slot,
	}


## Position, orientation et dimensions d'un livre, dans le repère de la galerie.
func book_transform(wall: int, shelf: int, book: int) -> Transform3D:
	var height := book_heights()[(wall * SHELVES + shelf) * BOOKS_PER_SHELF + book]
	var board := SHELVES - 1 - shelf
	var local := Vector3(
		SHELF_WIDTH * 0.5 - (book + 0.5) * BOOK_SLOT,
		BOARD_BASE + board * BOARD_PITCH + height * 0.5,
		BOOK_FRONT + BOOK_DEPTH * 0.5)
	var side := _side_basis(BOOK_SIDES[wall])
	return Transform3D(side * Basis.from_scale(Vector3(BOOK_THICK, height, BOOK_DEPTH)), side * local)


## Hauteur de chaque livre (numéro (mur × 5 + étagère) × 32 + livre), tirée comme le
## fait le nuanceur des livres et des façades.
func book_heights() -> PackedFloat32Array:
	if _book_heights.is_empty():
		var book_seed_value := book_seed()
		_book_heights.resize(WALLS * SHELVES * BOOKS_PER_SHELF)
		for i in _book_heights.size():
			_book_heights[i] = book_height(book_seed_value, i)
	return _book_heights


## Graine des livres de la galerie, sur 32 bits : les 4 premiers octets du SHA-256 de sa clé
## (vraies coordonnées seules, voir place).
func book_seed() -> int:
	return seed_of(place.key)


## Graine des livres de la galerie de clé `key`.
static func seed_of(key: String) -> int:
	return ("graine|" + key).sha256_buffer().decode_u32(0)


## Hauteur du livre `book` pour la graine `book_seed_value` (jumeau de book_height du nuanceur).
static func book_height(book_seed_value: int, book: int) -> float:
	return BOOK_MIN_HEIGHT + (BOOK_MAX_HEIGHT - BOOK_MIN_HEIGHT) * _unit_float(_book_hash(book_seed_value, book, 0))


## Cuir du livre `book` (jumeau de book_color du nuanceur), en albédo linéaire.
static func book_color(book_seed_value: int, book: int) -> Color:
	var leather := LEATHER[_book_hash(book_seed_value, book, 1) % LEATHER.size()]
	return leather * (1.0 - BOOK_MAX_DARKEN * _unit_float(_book_hash(book_seed_value, book, 2)))


## Hachage entier « lowbias32 » de Chris Wellons, sur 32 bits.
static func lowbias32(x: int) -> int:
	x &= 0xFFFFFFFF
	x ^= x >> 16
	x = _mul32(x, 0x7feb352d)
	x ^= x >> 15
	x = _mul32(x, 0x846ca68b)
	x ^= x >> 16
	return x


## Part réelle d'une lampe à la distance `d` de l'œil (jumeau de real_weight du nuanceur).
static func real_weight(d: float) -> float:
	return 1.0 - smoothstep(REAL_LIGHT_NEAR, REAL_LIGHT_FAR, d)


## Reste de lumière au-delà de la brume exponentielle : 1 jusqu'à FAR_FADE_BEGIN, 0 après FAR_FADE_END.
static func far_fade(d: float) -> float:
	return 1.0 - smoothstep(FAR_FADE_BEGIN, FAR_FADE_END, d)


## Jumeau de virtual_light du nuanceur, en unités d'énergie de lampe : la lumière que
## le nuanceur ajoute au point `p` de normale `n`, pour un œil en `eye`.
static func virtual_light(p: Vector3, n: Vector3, eye: Vector3) -> float:
	var n0 := roundf(p.z / PITCH)
	var k0 := floorf((p.y - LAMP_LIGHT_Y) / LEVEL_PITCH)
	var sum := 0.0
	for iz in range(-1, 2):
		var z := (n0 + iz) * PITCH
		for iy in range(-2, 4):
			var y := LAMP_LIGHT_Y + (k0 + iy) * LEVEL_PITCH
			for dir: float in [-1.0, 1.0]:
				var lamp := Vector3(dir * LAMP_X, y, z)
				var to := lamp - p
				var d := to.length()
				if d < LAMP_RANGE and d > 0.0001:
					var nd := d / LAMP_RANGE
					nd = 1.0 - nd * nd * nd * nd
					sum += nd * nd / d * maxf(n.dot(to) / d, 0.0) * (1.0 - real_weight(lamp.distance_to(eye)))
	return LAMP_ENERGY * sum


## Maillage partagé de l'anneau du puits d'un niveau : plancher autour du trou, bord
## du trou, plafond du dessous, balustrade et lampes.
static func ring_mesh() -> ArrayMesh:
	if _ring_mesh == null:
		var plaster := _begin()
		var floor_st := _begin()
		_build_floor_and_ceiling(floor_st, plaster, RING_APOTHEM)
		_build_railing(plaster, [])
		_ring_mesh = ArrayMesh.new()
		_add_surface(_ring_mesh, plaster.commit_to_arrays(), "plaster")
		_add_surface(_ring_mesh, floor_st.commit_to_arrays(), "floor")
		_add_lamp_surfaces(_ring_mesh)
	return _ring_mesh


# --- Éléments d'une galerie ------------------------------------------------

## Garde l'enfant `child` présent ou absent. Un enfant retiré attend dans la réserve
## commune à toutes les galeries ; un enfant voulu en sort, ou `factory` le fabrique :
## un pas ne construit ni ne détruit presque rien (collisionneurs compris).
func _keep(child: String, wanted: bool, factory: Callable) -> void:
	var node: Node = _parts.get(child)
	if wanted and node == null:
		var pool: Array = _pool.get(child, [])
		node = pool.pop_back() if not pool.is_empty() else factory.call()
		node.name = child
		_fit(node)
		add_child(node)
		_parts[child] = node
	elif not wanted and node != null:
		remove_child(node)
		_parts.erase(child)
		if child == "Lights":
			for light: OmniLight3D in node.get_children():
				light.light_energy = 0.0
				light.visible = false
		if not _pool.has(child):
			_pool[child] = []
		_pool[child].append(node)


## Donne à un enfant ce qui tient à la galerie : le matériau à sa graine.
func _fit(node: Node) -> void:
	if node is MultiMeshInstance3D:
		if _book_material == null:
			_book_material = _seeded_material("BOOKS")
			if _glyph_texture == null:
				_glyph_texture = ImageTexture.create_from_image(BookSpineScript.glyph_atlas())
				_halo_texture = ImageTexture.create_from_image(BookSpineScript.glyph_halo())
			_book_material.set_shader_parameter("glyph_atlas", _glyph_texture)
			_book_material.set_shader_parameter("glyph_halo", _halo_texture)
		node.material_override = _book_material
	elif node.name == "Faces":
		if _face_material == null:
			_face_material = _seeded_material("FACES")
			_show_missing_faces()
		node.material_override = _face_material


## Libère la réserve d'enfants détachés (à la sortie du monde).
static func release_pool() -> void:
	for pool: Array in _pool.values():
		for node: Node in pool:
			node.free()
	_pool.clear()
	for running: Dictionary in _title_jobs:
		BookTextScript.cancel(running.ticket)
	for retry: Dictionary in _flag_retry.values():
		if retry.ticket >= 0:
			BookTextScript.cancel(retry.ticket)
	_title_jobs.clear()
	_title_queue.clear()
	_title_waiting.clear()
	_flag_retry.clear()
	_shown.clear()
	_missing = {}
	_missing_checked = {}


func _new_interior() -> Node:
	_ensure_shared()
	var instance := MeshInstance3D.new()
	instance.mesh = _interior_mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


## Façades peintes des quatre murs : les livres de la galerie, à plat.
func _new_faces() -> Node:
	_ensure_shared()
	var instance := MeshInstance3D.new()
	instance.mesh = _faces_mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


func _new_structure() -> Node:
	_ensure_shared()
	var body := StaticBody3D.new()
	for box in _structure_boxes:
		_add_shape(body, box[0], box[1])
	return body


## Un seul collisionneur par mur : le livre visé se déduit du point d'impact.
func _new_bookcase(wall: int) -> Node:
	var bookcase := StaticBody3D.new()
	bookcase.basis = _side_basis(BOOK_SIDES[wall])
	bookcase.set_meta("book_wall", wall)
	_add_shape(bookcase, Transform3D(Basis(), Vector3(0.0, CASE_TOP * 0.5, APOTHEM - CASE_DEPTH * 0.5)),
		Vector3(SHELF_WIDTH + 0.08, CASE_TOP, CASE_DEPTH))
	return bookcase


## Les 640 livres : un MultiMesh commun à toutes les galeries ; le matériau de la
## galerie porte sa graine, d'où le nuanceur tire hauteur et cuir.
func _new_books() -> Node:
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = _shared_book_multimesh()
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


func _seeded_material(variant: String) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = _shader(variant)
	material.set_shader_parameter("seed", _signed32(book_seed()))
	return material


## MultiMesh commun des livres, rempli d'un bloc par _book_places.
static func _shared_book_multimesh() -> MultiMesh:
	if _book_multimesh == null:
		_book_mesh = BoxMesh.new()
		_book_mesh.size = Vector3.ONE
		_book_multimesh = MultiMesh.new()
		_book_multimesh.transform_format = MultiMesh.TRANSFORM_3D
		_book_multimesh.mesh = _book_mesh
		_book_multimesh.instance_count = WALLS * SHELVES * BOOKS_PER_SHELF
		_book_multimesh.buffer = _book_places()
	return _book_multimesh


## Les places des livres, chacun d'une hauteur unité posé sur sa planche : par livre,
## 12 flottants (3 lignes de 4) : la base du mur mise à l'échelle (épaisseur, 1,
## profondeur), et le pied du dos. La boîte unité, centrée, dépasse d'un demi-mètre
## de part et d'autre de la planche : la boîte englobante couvre toutes les hauteurs.
static func _book_places() -> PackedFloat32Array:
	if not _book_buffer.is_empty():
		return _book_buffer
	_book_buffer.resize(WALLS * SHELVES * BOOKS_PER_SHELF * 12)
	for wall in WALLS:
		var side := _side_basis(BOOK_SIDES[wall])
		var b := side * Basis.from_scale(Vector3(BOOK_THICK, 1.0, BOOK_DEPTH))
		for shelf in SHELVES:
			for book in BOOKS_PER_SHELF:
				var origin := side * Vector3(
					SHELF_WIDTH * 0.5 - (book + 0.5) * BOOK_SLOT,
					BOARD_BASE + (SHELVES - 1 - shelf) * BOARD_PITCH,
					BOOK_FRONT + BOOK_DEPTH * 0.5)
				var o := ((wall * SHELVES + shelf) * BOOKS_PER_SHELF + book) * 12
				var row := [b.x.x, b.y.x, b.z.x, origin.x, b.x.y, b.y.y, b.z.y, origin.y,
					b.x.z, b.y.z, b.z.z, origin.z]
				for k in 12:
					_book_buffer[o + k] = row[k]
	return _book_buffer


## « La luz procede de unas frutas esféricas que llevan el nombre de lámparas.
## Hay dos en cada hexágono: transversales. » Éteintes à la naissance :
## update_lights leur donne leur part.
func _new_lights() -> Node:
	var lights := Node3D.new()
	for dir in [-1.0, 1.0]:
		var light := OmniLight3D.new()
		light.position = Vector3(dir * LAMP_X, LAMP_LIGHT_Y, 0.0)
		light.light_color = LAMP_COLOR
		light.light_energy = 0.0
		light.light_specular = 0.0
		light.omni_range = LAMP_RANGE
		light.visible = false
		lights.add_child(light)
	return lights


static func _node_name(p_hexagon: int, p_level: int) -> String:
	return "Gallery_%d_%d" % [p_hexagon, p_level]


static func _book_hash(book_seed_value: int, book: int, draw: int) -> int:
	return lowbias32(book_seed_value ^ lowbias32(book * 4 + draw))


static func _unit_float(h: int) -> float:
	return float(h >> 8) / 16777216.0


## Produit sur 32 bits, en morceaux de 16 bits pour rester loin du dépassement de 64 bits.
static func _mul32(a: int, b: int) -> int:
	return (a * (b & 0xFFFF) + (((a * (b >> 16)) & 0xFFFF) << 16)) & 0xFFFFFFFF


## Entier de 32 bits sans signe vu comme un int signé de nuanceur (mêmes bits).
static func _signed32(x: int) -> int:
	return x - 0x100000000 if x >= 0x80000000 else x


# --- Maillages partagés ----------------------------------------------------

static func _ensure_shared() -> void:
	if _interior_mesh != null:
		return
	var plaster := _begin()
	var wood := _begin()
	var floor_st := _begin()
	_structure_boxes = []
	_build_floor_and_ceiling(floor_st, plaster, APOTHEM)
	# Le sol plein sous l'anneau : la balustrade tient le bibliothécaire loin du puits.
	_structure_boxes.append([Transform3D(Basis(), Vector3(0.0, -SLAB * 0.5, 0.0)),
		Vector3(2.0 * SIDE, SLAB, 2.0 * APOTHEM)])
	_build_walls(plaster, _structure_boxes)
	_build_hallway(floor_st, plaster, _structure_boxes)
	_build_railing(plaster, _structure_boxes)
	for wall in WALLS:
		_build_bookcase(wall, wood)

	_interior_mesh = ArrayMesh.new()
	_add_surface(_interior_mesh, plaster.commit_to_arrays(), "plaster")
	_add_surface(_interior_mesh, wood.commit_to_arrays(), "wood")
	_add_surface(_interior_mesh, floor_st.commit_to_arrays(), "floor")
	_add_lamp_surfaces(_interior_mesh)

	var faces := _begin()
	for wall in WALLS:
		_build_book_face(wall, faces)
	_faces_mesh = ArrayMesh.new()
	_faces_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, faces.commit_to_arrays())


static func _add_surface(mesh: ArrayMesh, arrays: Array, material: String) -> void:
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(mesh.get_surface_count() - 1, _material(material))


## Les deux globes (lumineux par eux-mêmes) et leurs cordons.
static func _add_lamp_surfaces(mesh: ArrayMesh) -> void:
	var sphere := SphereMesh.new()
	sphere.radius = 0.14
	sphere.height = 0.28
	sphere.radial_segments = 24
	sphere.rings = 12
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.008
	cylinder.bottom_radius = 0.008
	cylinder.height = 0.32
	cylinder.radial_segments = 8
	cylinder.rings = 1
	var globes := _begin()
	var cords := _begin()
	for dir in [-1.0, 1.0]:
		var at := Vector3(dir * LAMP_X, LAMP_GLOBE_Y, 0.0)
		globes.append_from(sphere, 0, Transform3D(Basis(), at))
		cords.append_from(cylinder, 0, Transform3D(Basis(), at + Vector3.UP * 0.29))
	_add_surface(mesh, globes.commit_to_arrays(), "lamp")
	_add_surface(mesh, cords.commit_to_arrays(), "wood")


# --- Construction ----------------------------------------------------------

## Plancher (anneau autour du puits jusqu'à l'apothème `outer`), bord du trou, et
## plafond, en bandes concentriques.
static func _build_floor_and_ceiling(floor_st: SurfaceTool, plaster: SurfaceTool, outer: float) -> void:
	var bands := 3
	for k in 6:
		for band in bands:
			var a0 := lerpf(SHAFT_APOTHEM, outer, float(band) / bands)
			var a1 := lerpf(SHAFT_APOTHEM, outer, float(band + 1) / bands)
			var o0 := _hex_vertex(a1, k)
			var o1 := _hex_vertex(a1, k + 1)
			var i0 := _hex_vertex(a0, k)
			var i1 := _hex_vertex(a0, k + 1)
			var up := Vector3.UP * HEIGHT
			_add_quad(floor_st, o0, o1, i1, i0, Vector3.UP)
			_add_quad(plaster, o0 + up, o1 + up, i1 + up, i0 + up, Vector3.DOWN)
		var e0 := _hex_vertex(SHAFT_APOTHEM, k)
		var e1 := _hex_vertex(SHAFT_APOTHEM, k + 1)
		var down := Vector3.DOWN * SLAB
		_add_quad(floor_st, e0, e1, e1 + down, e0 + down, -_side_basis(k + 1).z)


static func _build_walls(plaster: SurfaceTool, boxes: Array) -> void:
	var z := APOTHEM + WALL_THICK * 0.5
	for side in 6:
		var basis := _side_basis(side)
		if side == 0 or side == 3:
			var length := SIDE * 0.5 - HALL_WIDTH * 0.5 + 0.2
			for dir in [-1.0, 1.0]:
				var x: float = dir * (HALL_WIDTH * 0.5 + length * 0.5)
				_solid(plaster, boxes, Transform3D(basis, basis * Vector3(x, HEIGHT * 0.5, z)),
					Vector3(length, HEIGHT, WALL_THICK))
		else:
			_solid(plaster, boxes, Transform3D(basis, basis * Vector3(0.0, HEIGHT * 0.5, z)),
				Vector3(SIDE + 0.4, HEIGHT, WALL_THICK))


static func _build_hallway(floor_st: SurfaceTool, plaster: SurfaceTool, boxes: Array) -> void:
	var w := HALL_WIDTH * 0.5
	var z0 := APOTHEM
	var z1 := APOTHEM + HALL_LENGTH
	_add_quad(floor_st, Vector3(-w, 0, z0), Vector3(w, 0, z0), Vector3(w, 0, z1), Vector3(-w, 0, z1), Vector3.UP)
	_add_quad(plaster, Vector3(-w, HEIGHT, z0), Vector3(w, HEIGHT, z0), Vector3(w, HEIGHT, z1),
		Vector3(-w, HEIGHT, z1), Vector3.DOWN)
	var zc := APOTHEM + HALL_LENGTH * 0.5
	boxes.append([Transform3D(Basis(), Vector3(0.0, -SLAB * 0.5, zc)),
		Vector3(HALL_WIDTH + 2.0 * WALL_THICK, SLAB, HALL_LENGTH)])
	for dir in [-1.0, 1.0]:
		var x: float = dir * (w + WALL_THICK * 0.5)
		_solid(plaster, boxes, Transform3D(Basis(), Vector3(x, HEIGHT * 0.5, zc)),
			Vector3(WALL_THICK, HEIGHT, HALL_LENGTH))


static func _build_railing(plaster: SurfaceTool, boxes: Array) -> void:
	var length := 2.0 * RAIL_APOTHEM / SQRT3
	for side in 6:
		var basis := _side_basis(side)
		_solid(plaster, boxes, Transform3D(basis, basis * Vector3(0.0, RAIL_HEIGHT * 0.5, RAIL_APOTHEM)),
			Vector3(length + 0.05, RAIL_HEIGHT, 0.08))


static func _build_bookcase(wall: int, wood: SurfaceTool) -> void:
	var basis := _side_basis(BOOK_SIDES[wall])
	var zc := APOTHEM - CASE_DEPTH * 0.5
	var boxes: Array = [
		[Vector3(0.0, BOARD_BASE * 0.5, zc), Vector3(SHELF_WIDTH, BOARD_BASE, CASE_DEPTH)],
		[Vector3(0.0, CASE_TOP * 0.5, APOTHEM - 0.01), Vector3(SHELF_WIDTH, CASE_TOP, 0.02)],
	]
	for board in SHELVES + 1:
		var top := BOARD_BASE + board * BOARD_PITCH
		boxes.append([Vector3(0.0, top - BOARD_THICK * 0.5, zc), Vector3(SHELF_WIDTH, BOARD_THICK, CASE_DEPTH)])
	for dir in [-1.0, 1.0]:
		boxes.append([Vector3(dir * (SHELF_WIDTH * 0.5 + 0.02), CASE_TOP * 0.5, zc), Vector3(0.04, CASE_TOP, CASE_DEPTH)])
	for box in boxes:
		_add_box(wood, Transform3D(basis, basis * box[0]), box[1])


## Façade peinte d'un mur de livres, au ras des dos. UV.x = 2 × mur + u : le nuanceur
## y retrouve le mur, l'étagère et le livre de chaque pixel.
static func _build_book_face(wall: int, st: SurfaceTool) -> void:
	var basis := _side_basis(BOOK_SIDES[wall])
	var normal := basis * Vector3.FORWARD   # vers le centre de la galerie
	var columns := 4
	var rows := SHELVES
	var offset := 2.0 * wall
	for col in columns:
		for row in rows:
			var u0 := float(col) / columns
			var u1 := float(col + 1) / columns
			var v0 := float(row) / rows
			var v1 := float(row + 1) / rows
			var corner := func(u: float, v: float) -> Vector3:
				return basis * Vector3(SHELF_WIDTH * (0.5 - u), lerpf(CASE_TOP, BOARD_BASE, v), BOOK_FRONT)
			_add_tri_uv(st, [corner.call(u0, v0), corner.call(u1, v0), corner.call(u1, v1)],
				[Vector2(offset + u0, v0), Vector2(offset + u1, v0), Vector2(offset + u1, v1)], normal)
			_add_tri_uv(st, [corner.call(u0, v0), corner.call(u1, v1), corner.call(u0, v1)],
				[Vector2(offset + u0, v0), Vector2(offset + u1, v1), Vector2(offset + u0, v1)], normal)


# --- Géométrie -------------------------------------------------------------

## Repère d'un côté : son +Z local est la normale sortante du côté.
static func _side_basis(side: int) -> Basis:
	return Basis(Vector3.UP, side * PI / 3.0)


## Sommet k de l'hexagone d'apothème donné (entre les côtés k et k + 1), au sol.
static func _hex_vertex(apothem: float, k: int) -> Vector3:
	var angle := deg_to_rad(30.0 + 60.0 * k)
	var radius := 2.0 * apothem / SQRT3
	return Vector3(radius * sin(angle), 0.0, radius * cos(angle))


static func _begin() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st


## Triangle tourné vers `normal` (Godot dessine les faces avant dans le sens horaire).
static func _add_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, normal: Vector3) -> void:
	st.set_normal(normal)
	st.add_vertex(a)
	if (b - a).cross(c - a).dot(normal) > 0.0:
		st.add_vertex(c)
		st.add_vertex(b)
	else:
		st.add_vertex(b)
		st.add_vertex(c)


## Triangle texturé tourné vers `normal` : chaque sommet garde sa coordonnée de texture.
static func _add_tri_uv(st: SurfaceTool, corners: Array, uvs: Array, normal: Vector3) -> void:
	var order := [0, 1, 2]
	var a: Vector3 = corners[0]
	var b: Vector3 = corners[1]
	var c: Vector3 = corners[2]
	if (b - a).cross(c - a).dot(normal) > 0.0:
		order = [0, 2, 1]
	for i in order:
		st.set_normal(normal)
		st.set_uv(uvs[i])
		st.add_vertex(corners[i])


static func _add_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, normal: Vector3) -> void:
	_add_tri(st, a, b, c, normal)
	_add_tri(st, a, c, d, normal)


static func _add_box(st: SurfaceTool, xform: Transform3D, size: Vector3) -> void:
	var half := size * 0.5
	for axis in 3:
		var u_axis := (axis + 1) % 3
		var v_axis := (axis + 2) % 3
		for dir in [-1.0, 1.0]:
			var normal := Vector3.ZERO
			normal[axis] = dir
			var center := normal * half[axis]
			var du := Vector3.ZERO
			du[u_axis] = half[u_axis]
			var dv := Vector3.ZERO
			dv[v_axis] = half[v_axis]
			_add_quad(st, xform * (center - du - dv), xform * (center + du - dv),
				xform * (center + du + dv), xform * (center - du + dv), (xform.basis * normal).normalized())


static func _add_shape(body: StaticBody3D, xform: Transform3D, size: Vector3) -> void:
	var box := BoxShape3D.new()
	box.size = size
	var shape := CollisionShape3D.new()
	shape.shape = box
	shape.transform = xform
	body.add_child(shape)


## Boîte visible, dont le collisionneur rejoint la liste `boxes`.
static func _solid(st: SurfaceTool, boxes: Array, xform: Transform3D, size: Vector3) -> void:
	_add_box(st, xform, size)
	boxes.append([xform, size])


# --- Matériaux partagés ----------------------------------------------------

## Albédos (sRGB, comme dans un StandardMaterial3D) et émission des globes.
const ALBEDO := {
	"plaster": Color(0.72, 0.64, 0.50),
	"wood": Color(0.30, 0.19, 0.11),
	"floor": Color(0.36, 0.30, 0.24),
	"lamp": Color(1.0, 0.85, 0.6),
}
const LAMP_EMISSION := Color(1.0, 0.8, 0.5)
const LAMP_EMISSION_ENERGY := 3.0


static func _material(kind: String) -> ShaderMaterial:
	if _materials.has(kind):
		return _materials[kind]
	var material := ShaderMaterial.new()
	material.shader = _shader("SURFACE")
	material.set_shader_parameter("albedo_linear", _linear(ALBEDO[kind]))
	if kind == "lamp":
		material.set_shader_parameter("emission_linear", _linear(LAMP_EMISSION) * LAMP_EMISSION_ENERGY)
	_materials[kind] = material
	return material


## Le nuanceur de la Bibliothèque pour une variante (SURFACE, BOOKS, FACES).
static func _shader(variant: String) -> Shader:
	if _shaders.has(variant):
		return _shaders[variant]
	var lamp := _linear(LAMP_COLOR) * LAMP_ENERGY
	var leather := PackedStringArray()
	for color in LEATHER:
		leather.append(_vec3(Vector3(color.r, color.g, color.b)))
	# Chasses des glyphes de l'atlas, pour les seuls livres (rendu de l'atlas : ~10 ms, une fois).
	var advances := PackedStringArray()
	for advance in (BookSpineScript.glyph_advances() if variant == "BOOKS" else PackedFloat32Array()):
		advances.append(_float(advance))
	advances.resize(BookSpineScript.GLYPHS.length())
	for i in advances.size():
		if advances[i].is_empty():
			advances[i] = _float(0.0)
	var shader := Shader.new()
	shader.code = LIBRARY_SHADER.format({
		"VARIANT": variant,
		"PITCH": _float(PITCH), "LEVEL_PITCH": _float(LEVEL_PITCH),
		"LAMP_X": _float(LAMP_X), "LAMP_Y": _float(LAMP_LIGHT_Y), "LAMP_RANGE": _float(LAMP_RANGE),
		"LAMP_LIGHT": _vec3(lamp),
		"REAL_NEAR": _float(REAL_LIGHT_NEAR), "REAL_FAR": _float(REAL_LIGHT_FAR),
		"FOG_LINEAR": _vec3(_linear(FOG_COLOR)), "FOG_DENSITY": _float(FOG_DENSITY),
		"FAR_FADE_BEGIN": _float(FAR_FADE_BEGIN), "FAR_FADE_END": _float(FAR_FADE_END),
		"SHELVES": str(SHELVES), "BOOKS_PER_SHELF": str(BOOKS_PER_SHELF),
		"BOARD_BASE": _float(BOARD_BASE), "BOARD_PITCH": _float(BOARD_PITCH), "CASE_TOP": _float(CASE_TOP),
		"BOOK_SLOT": _float(BOOK_SLOT), "BOOK_THICK": _float(BOOK_THICK),
		"BOOK_MIN_HEIGHT": _float(BOOK_MIN_HEIGHT), "BOOK_MAX_HEIGHT": _float(BOOK_MAX_HEIGHT),
		"BOOK_MAX_DARKEN": _float(BOOK_MAX_DARKEN),
		"WOOD_LINEAR": _vec3(_linear(ALBEDO["wood"])),
		"LEATHER": ", ".join(leather),
		"GLYPH_ADVANCE": ", ".join(advances),
		"ATLAS_CELL_EM": _float(float(BookSpineScript.CELL_PX) / BookSpineScript.FONT_PX),
		"ATLAS_ORIGIN_EM": "vec2(%s, %s)" % [_float(float(BookSpineScript.PEN_PX.x) / BookSpineScript.FONT_PX),
			_float(float(BookSpineScript.PEN_PX.y) / BookSpineScript.FONT_PX)],
		"ATLAS_COLUMNS": str(BookSpineScript.ATLAS_COLUMNS),
		"TRACKING_EM": _float(BookSpineScript.TRACKING_EM), "TITLE_MARGIN": _float(BookSpineScript.TITLE_MARGIN),
		"TITLE_SIZE_FRACTION": _float(BookSpineScript.TITLE_SIZE_FRACTION),
		"TITLE_CENTER_EM": _float(BookSpineScript.TITLE_CENTER_EM),
		"GOLD_LINEAR": _vec3(_linear(GOLD)), "GOLD_METALLIC": _float(GOLD_METALLIC),
		"GOLD_ROUGHNESS": _float(GOLD_ROUGHNESS),
		"HALO_DARKEN": _float(HALO_DARKEN), "GILT_DIFFUSE": _float(GILT_DIFFUSE),
		"HALO_DARKEN_PALE": _float(HALO_DARKEN_PALE), "PALE_BEGIN": _float(PALE_BEGIN), "PALE_END": _float(PALE_END),
		"TITLE_FADE_BEGIN": _float(TITLE_FADE_BEGIN), "TITLE_FADE_END": _float(TITLE_FADE_END),
		"MISSING_BIT": str(BookSpineScript.MISSING_BIT),
	})
	_shaders[variant] = shader
	return shader


## Couleur sRGB en lumière linéaire.
static func _linear(color: Color) -> Vector3:
	var linear := color.srgb_to_linear()
	return Vector3(linear.r, linear.g, linear.b)


static func _float(x: float) -> String:
	return "%.8f" % x


static func _vec3(v: Vector3) -> String:
	return "vec3(%s, %s, %s)" % [_float(v.x), _float(v.y), _float(v.z)]
