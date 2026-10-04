class_name AmbientSpeaker
extends AudioStreamPlayer3D
## Haut-parleur de couloir : la même musique d'ambiance, synchronisée, qui s'éteint avec la distance.
##
## MUSIQUE. res://audio/ambiance.ogg (≈ 14 min, générée par tools/make_ambiance.py, boucle sans couture) ;
## si res://audio/ambiance_custom.ogg existe, elle la remplace. La boucle se règle ici (AudioStreamOggVorbis.loop),
## aucun fichier .import n'est suivi. Un fichier absent de l'import est lu directement (load_from_file).
##
## ATTÉNUATION (ATTENUATION_INVERSE_DISTANCE, unit_size 2 m, max_distance 26 m, max_db 0, voir gain_at) :
##   distance   0 m (sous le haut-parleur)  gain 1,00  (   0 dB)  plein volume jusqu'à 2 m
##   distance   6 m (centre de la galerie)  gain 0,26  ( −12 dB)  chaque haut-parleur ; les deux voisins s'additionnent
##   distance  12 m (haut-parleur suivant)  gain 0,09  ( −21 dB)
##   distance  24 m (deux galeries plus loin) gain 0,006 ( −44 dB)  quasi muet ; 0 à 26 m
## Dans le couloir on entend un haut-parleur à fond ; au centre d'une galerie, les deux couloirs voisins (à 6 m) donnent
## ≈ −6 dB ; au couloir suivant le suivant se réduit à −21 dB. Pas de haut-parleur aux autres niveaux : à 3,4 m
## à la verticale le gain vaudrait −6 dB, trop pour une dalle de 0,4 m ; seuls les couloirs du niveau courant sonnent.
## Le filtre passe-bas de distance du moteur (attenuation_filter_*) reste à sa valeur par défaut : le lointain s'étouffe.
##
## SYNCHRONISATION. Une seule horloge globale : music_position() = (temps écoulé depuis le premier haut-parleur) modulo la
## durée du morceau. Un haut-parleur créé ou recyclé démarre à cette position (play(from_position)), il ne redémarre
## jamais le morceau : décalage d'origine, recyclage de galerie et arrivée tardive tombent à la même phase, à quelques
## millisecondes près (une période de mixage). Tous les lecteurs partagent le même mélangeur : une fois lancés, ils ne
## dérivent pas entre eux. Le premier haut-parleur vivant sert de référence : l'horloge murale s'ajuste doucement
## sur son horloge audio (sans saut), et un haut-parleur qui s'écarterait de plus de 0,25 s se recale (rare).
##
## BUS « Ambiance » créé en code s'il manque (envoi vers Master) : AmbientSpeaker.set_bus_volume(db), set_bus_muted(bool).
##
## INTÉGRATION (gallery.gd ; main.gd garde la règle « un seul niveau, 2 galeries de chaque côté ») :
##   # gallery.gd, variable de membre
##   var _speaker: AmbientSpeaker
##   # gallery.gd, méthode publique : appelée par main._update_galleries() pour chaque case, après gallery.position = …
##   func set_speaker(wanted: bool) -> void:
##       if wanted and _speaker == null:
##           _speaker = AmbientSpeaker.create()
##           _speaker.position = Vector3(0.0, AmbientSpeaker.HEIGHT, APOTHEM + HALL_LENGTH * 0.5)   # (0 ; 2,4 ; 6)
##           add_child(_speaker)
##       elif not wanted and _speaker != null:
##           _speaker.retire()      # fondu de 1 s puis queue_free ; le nœud n'est plus la propriété de la galerie
##           _speaker = null
##   # main.gd, dans la boucle de _update_galleries(), après le placement :
##   gallery.set_speaker(cell.y == 0 and absi(cell.x) <= AmbientSpeaker.REACH_GALLERIES)
## Recyclage : une galerie relabellisée (readdress) garde son haut-parleur tant que sa case reste dans la règle ; la case
## d'arrivée d'un décalage d'origine est à plus de 26 m du joueur, donc muette : pas de claquement. Une galerie qui
## quitte la règle appelle retire() (pas de queue_free direct, sinon le volume coupe net s'il restait audible).
## Hors de la portée de l'oreille, create() démarre à plein volume ; à moins de MAX_DISTANCE du joueur, fondu d'entrée de 0,5 s.

const BUS := &"Ambiance"
const DEFAULT_PATH := "res://audio/ambiance.ogg"
const CUSTOM_PATH := "res://audio/ambiance_custom.ogg"

const HEIGHT := 2.4                     # hauteur du haut-parleur dans le couloir (plafond à 3 m)
const REACH_GALLERIES := 2              # galeries de chaque côté de l'origine qui reçoivent un haut-parleur
const UNIT_SIZE := 2.0                  # distance du gain 1 (modèle inverse : gain = unit_size / distance)
const MAX_DISTANCE := 26.0              # le moteur y ajoute une décroissance linéaire jusqu'à zéro
const MAX_DB := 0.0                     # plafond sous le haut-parleur (le modèle inverse tend vers l'infini en 0)
const FADE_IN := 0.5
const FADE_OUT := 1.0
const RESYNC_AFTER := 0.25              # écart de lecture (s) au-delà duquel un haut-parleur se recale
const RESYNC_EVERY := 4.0               # secondes entre deux contrôles de dérive

static var _stream: AudioStream
static var _stream_loaded := false
static var _origin_usec := -1           # musique à la position 0 à cet instant (Time.get_ticks_usec)
static var _reference: AudioStreamPlayer3D

var start_position := 0.0               # position de départ réelle, pour contrôle
var start_usec := 0
var _fade_in := FADE_IN
var _retiring := false
var _since_check := 0.0


## Un haut-parleur prêt à entrer dans l'arbre : il démarre dans _ready à la position de l'horloge globale.
static func create(fade_in: float = FADE_IN) -> AmbientSpeaker:
	var speaker := AmbientSpeaker.new()
	speaker._fade_in = fade_in
	speaker.stream = load_stream()
	speaker.bus = ensure_bus_name()
	speaker.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	speaker.unit_size = UNIT_SIZE
	speaker.max_distance = MAX_DISTANCE
	speaker.max_db = MAX_DB
	speaker.volume_db = 0.0
	speaker.name = "AmbientSpeaker"
	return speaker


## Gain linéaire du modèle d'atténuation du moteur à la distance donnée (inverse de la distance, plafonné à max_db,
## multiplié par la décroissance linéaire jusqu'à max_distance).
static func gain_at(distance: float) -> float:
	if distance >= MAX_DISTANCE:
		return 0.0
	var inverse := UNIT_SIZE / maxf(distance, 0.0001)
	return minf(inverse, db_to_linear(MAX_DB)) * (1.0 - distance / MAX_DISTANCE)


## Durée du morceau en secondes (0 si aucun fichier audio).
static func music_length() -> float:
	var s := load_stream()
	return s.get_length() if s != null else 0.0


## Position actuelle de la musique, en secondes, dans [0 ; durée[. Horloge globale commune à tous les haut-parleurs.
static func music_position() -> float:
	var length := music_length()
	if length <= 0.0:
		return 0.0
	var now := Time.get_ticks_usec()
	if _origin_usec < 0:
		_origin_usec = now
	return fposmod(float(now - _origin_usec) / 1.0e6, length)


## Le flux partagé, bouclé (ambiance_custom.ogg d'abord, puis ambiance.ogg). Null si aucun n'existe.
static func load_stream() -> AudioStream:
	if _stream_loaded:
		return _stream
	_stream_loaded = true
	for path: String in [CUSTOM_PATH, DEFAULT_PATH]:
		var s := _open(path)
		if s != null:
			if s is AudioStreamOggVorbis:
				(s as AudioStreamOggVorbis).loop = true
				(s as AudioStreamOggVorbis).loop_offset = 0.0
			_stream = s
			break
	return _stream


static func stream_path() -> String:
	return CUSTOM_PATH if _open_exists(CUSTOM_PATH) else DEFAULT_PATH


static func ensure_bus_name() -> StringName:
	if AudioServer.get_bus_index(BUS) == -1:
		AudioServer.add_bus()
		var index := AudioServer.bus_count - 1
		AudioServer.set_bus_name(index, BUS)
		AudioServer.set_bus_send(index, &"Master")
	return BUS


static func set_bus_volume(db: float) -> void:
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index(ensure_bus_name()), db)


static func bus_volume() -> float:
	return AudioServer.get_bus_volume_db(AudioServer.get_bus_index(ensure_bus_name()))


static func set_bus_muted(muted: bool) -> void:
	AudioServer.set_bus_mute(AudioServer.get_bus_index(ensure_bus_name()), muted)


static func bus_muted() -> bool:
	return AudioServer.is_bus_mute(AudioServer.get_bus_index(ensure_bus_name()))


## Position attendue de ce haut-parleur d'après l'horloge murale depuis son départ (pour contrôle).
func expected_position() -> float:
	var length := music_length()
	if length <= 0.0:
		return 0.0
	return fposmod(start_position + float(Time.get_ticks_usec() - start_usec) / 1.0e6, length)


## Fondu de sortie puis libération. À préférer à queue_free() pour un haut-parleur encore audible.
func retire(fade_out: float = FADE_OUT) -> void:
	if _retiring:
		return
	_retiring = true
	if not is_inside_tree() or not playing or fade_out <= 0.0:
		queue_free()
		return
	var tween := create_tween()
	tween.tween_method(_set_linear, 1.0, 0.0, fade_out)
	tween.tween_callback(queue_free)


func _ready() -> void:
	if stream == null:
		return
	if _reference == null or not is_instance_valid(_reference):
		_reference = self
	start_position = music_position()
	start_usec = Time.get_ticks_usec()
	var fade := _fade_in > 0.0 and _audible_now()
	if fade:
		volume_db = -80.0
	play(start_position)
	if fade:
		create_tween().tween_method(_set_linear, 0.0, 1.0, _fade_in)


func _exit_tree() -> void:
	if _reference == self:
		_reference = null


func _process(delta: float) -> void:
	if not playing or _retiring:
		return
	if _reference == null or not is_instance_valid(_reference) or not _reference.playing:
		_reference = self
	if _reference == self:
		_steer_clock()
		return
	_since_check += delta
	if _since_check >= RESYNC_EVERY:
		_since_check = 0.0
		var drift := _circular_diff(get_playback_position(), music_position())
		if absf(drift) > RESYNC_AFTER:
			start_position = music_position()
			start_usec = Time.get_ticks_usec()
			play(start_position)


## Rapproche l'horloge murale de l'horloge audio du haut-parleur de référence, de 5 % de l'écart par image.
func _steer_clock() -> void:
	var length := music_length()
	if length <= 0.0 or _origin_usec < 0:
		return
	var err := _circular_diff(get_playback_position(), music_position())
	if absf(err) < 0.5:      # un écart plus grand signale une position de lecture inexploitable : on l'ignore
		_origin_usec -= int(err * 0.05 * 1.0e6)


## Vrai si un auditeur (caméra active) se trouve assez près pour entendre ce haut-parleur dès maintenant.
func _audible_now() -> bool:
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	return camera != null and camera.global_position.distance_to(global_position) < MAX_DISTANCE


func _set_linear(value: float) -> void:
	volume_db = linear_to_db(maxf(value, 0.0001))


static func _circular_diff(a: float, b: float) -> float:
	var length := music_length()
	return fposmod(a - b + length * 0.5, length) - length * 0.5


static func _open_exists(path: String) -> bool:
	return ResourceLoader.exists(path) or FileAccess.file_exists(path)


static func _open(path: String) -> AudioStream:
	if ResourceLoader.exists(path):
		var loaded := load(path)
		if loaded is AudioStream:
			return loaded
	if FileAccess.file_exists(path):
		return AudioStreamOggVorbis.load_from_file(path)
	return null
