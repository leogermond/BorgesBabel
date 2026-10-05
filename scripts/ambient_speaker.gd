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
## durée du morceau. Un haut-parleur créé démarre à cette position (play(from_position), à la première image libre), il ne redémarre
## jamais le morceau : décalage d'origine, recyclage de galerie et arrivée tardive tombent à la même phase, à quelques
## millisecondes près (une période de mixage). Tous les lecteurs partagent le même mélangeur : une fois lancés, ils ne
## dérivent pas entre eux. Le premier haut-parleur vivant sert de référence : l'horloge murale s'ajuste doucement
## sur son horloge audio (sans saut), et un haut-parleur qui s'écarterait de plus de 0,25 s se recale (rare).
## Garde : l'horloge murale avance pendant une pause de l'arbre, les lecteurs non. Après une pause (NOTIFICATION_UNPAUSED),
## ou une image de plus de STALL_USEC (0,5 s), resync_all() recale l'horloge sur la position de lecture de la référence
## et ramène sur elle tout lecteur qui s'en écarte de plus de RESYNC_TOLERANCE ; sans cette garde, les lecteurs se
## recaleraient un à un sur l'horloge murale, loin de la référence, et s'éloigneraient d'elle pour de bon.
##
## BUS « Ambiance » créé en code s'il manque (envoi vers Master) : AmbientSpeaker.set_bus_volume(db), set_bus_muted(bool).
##
## INTÉGRATION. gallery.gd : Gallery.set_speaker(wanted) pose le haut-parleur au milieu du vestibule +Z de la galerie,
## en (0 ; 2,4 ; 6), ou le retire (retire() : fondu de 1 s puis queue_free ; le nœud n'est plus la propriété de la
## galerie). main._update_galleries() l'appelle pour chaque case, une fois la galerie à sa place :
##   gallery.set_speaker(AmbientSpeaker.has_speaker(cell))
## Disposition : le vestibule de la case x est à z = 12·x + 6 ; has_speaker garde les cases x de −HALLWAYS_EACH_SIDE à
## HALLWAYS_EACH_SIDE − 1 du niveau du joueur, soit des haut-parleurs à z = −30, −18, −6, 6, 18, 30 : trois de chaque côté
## du centre de la galerie d'origine, symétriques. Le joueur reste entre z = −6 et 6 (l'origine change au milieu du
## vestibule) : tout vestibule à moins de MAX_DISTANCE (26 m) de lui est dans |z| ≤ 32, donc pourvu, et ceux à ±30 sont
## déjà à plus de 24 m (−44 dB). Au décalage _shift(±1), le joueur passe en z = ∓6 : le haut-parleur qui naît (à ±30)
## et celui qui part (à ∓42) sont à 36 m de lui, inaudibles, dans les deux sens. Au changement de niveau, les six
## haut-parleurs du niveau quitté partent en fondu de sortie et ceux du nouveau niveau, audibles, naissent en fondu
## d'entrée : create() fond l'entrée (FADE_IN, 0,5 s) de tout haut-parleur à moins de MAX_DISTANCE de la caméra active,
## ou quand il n'y a pas encore de caméra (naissance du monde) ; plus loin, il démarre à plein volume, inaudible.
## Pas de haut-parleur aux autres niveaux : à 3,4 m à la verticale le gain vaudrait −6 dB, trop pour une dalle de 0,4 m.
## Recyclage : une galerie relabellisée (readdress) garde son haut-parleur tant que sa case reste dans la règle ; une
## galerie qui quitte la règle appelle retire() (pas de queue_free direct, sinon le volume coupe net s'il restait audible).

const AmbientSpeakerScript := preload("res://scripts/ambient_speaker.gd")

const BUS := &"Ambiance"
const DEFAULT_PATH := "res://audio/ambiance.ogg"
const CUSTOM_PATH := "res://audio/ambiance_custom.ogg"

const HEIGHT := 2.4                     # hauteur du haut-parleur dans le couloir (plafond à 3 m)
const HALLWAYS_EACH_SIDE := 3           # vestibules pourvus de chaque côté du centre de la galerie d'origine
const UNIT_SIZE := 2.0                  # distance du gain 1 (modèle inverse : gain = unit_size / distance)
const MAX_DISTANCE := 26.0              # le moteur y ajoute une décroissance linéaire jusqu'à zéro
const MAX_DB := 0.0                     # plafond sous le haut-parleur (le modèle inverse tend vers l'infini en 0)
const FADE_IN := 0.5
const FADE_OUT := 1.0
const RESYNC_AFTER := 0.25              # écart de lecture (s) au-delà duquel un haut-parleur se recale
const RESYNC_EVERY := 4.0               # secondes entre deux contrôles de dérive
const STALL_USEC := 500000              # image plus longue (ou pause de l'arbre) : tous les lecteurs se recalent
const RESYNC_TOLERANCE := 0.1           # écart (s) à la référence toléré par resync_all (granularité du mixage)
## Départs par image, au plus : play() attend le mélangeur (0,5 ms, des dizaines de ms quand il mixe) ; un haut-parleur
## entré dans l'arbre démarre à la première image libre (dans son _process), jamais pendant le pas qui l'a créé.
const STARTS_PER_FRAME := 1

static var _stream: AudioStream
static var _stream_loaded := false
static var _origin_usec := -1           # musique à la position 0 à cet instant (Time.get_ticks_usec)
static var _reference: AudioStreamPlayer3D
static var _speakers: Array = []        # haut-parleurs dans l'arbre
static var _last_tick_usec := -1        # dernière image vue par _watch_clock
static var _last_tick_frame := -1
static var _resync_requested := false
static var resync_count := 0            # recalages faits par resync_all (pour contrôle)
static var _start_frame := -1
static var _starts := 0
## Toutes les lectures lancées (_play_from) que le serveur audio n'a pas encore rendues, en références
## faibles (une référence forte retarderait leur remise) : retirées dès qu'elles n'existent plus. Une
## lecture remplacée par un recalage (play) s'arrête d'elle-même et y reste jusqu'à sa remise.
static var _stopped: Array[WeakRef] = []
## Vrai après silence_all : un haut-parleur qui entre ensuite dans l'arbre (le monde tourne encore
## pendant l'attente) reste muet.
static var _silenced := false

var start_position := 0.0               # position de départ réelle, pour contrôle
var start_usec := 0
var started := false                    # vrai une fois la lecture lancée
var _fade_in := FADE_IN
var _retiring := false
var _since_check := 0.0
var _fade_tween: Tween


## Un haut-parleur prêt à entrer dans l'arbre : il démarre à la première image libre, à la position de l'horloge globale.
static func create(fade_in: float = FADE_IN) -> AmbientSpeakerScript:
	var speaker := AmbientSpeakerScript.new()
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


## Vrai pour les cases (dz, dy relatives à l'origine) dont le vestibule reçoit un haut-parleur : niveau du joueur,
## vestibules à z = 12·dz + 6 entre −30 et 30 m (voir l'en-tête).
static func has_speaker(cell: Vector2i) -> bool:
	return cell.y == 0 and cell.x >= -HALLWAYS_EACH_SIDE and cell.x < HALLWAYS_EACH_SIDE


## Les haut-parleurs vivants (dans l'arbre), retirés ou non.
static func speakers() -> Array:
	return _speakers.filter(func(s: Variant) -> bool: return is_instance_valid(s))


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


## Fait taire tous les haut-parleurs et attend que le serveur audio ait rendu leurs lectures : il
## ne les libère qu'à une image du jeu (sa mise à jour sur le fil principal), après que son
## mélangeur (son propre fil, à son rythme) les a vues arrêtées. La condition est observée sur les
## lectures elles-mêmes (toutes rendues : _stopped vide), vérifiée à chaque image, sous une
## échéance (`timeout_msec`) qui ne sert qu'en cas de panne du serveur audio. À appeler
## avant de quitter (BabelService à la fermeture de la fenêtre ; les tests avant quit()) : rien ne
## reste alors en vie à la sortie du moteur. Vrai si toutes les lectures sont rendues.
static func silence_all(tree: SceneTree, timeout_msec := 5000) -> bool:
	_silenced = true
	for speaker: Variant in _speakers.duplicate():
		if is_instance_valid(speaker):
			speaker._retiring = true   # plus de départ ni de recalage
			speaker._silence()
	var deadline := Time.get_ticks_msec() + timeout_msec
	_prune_stopped()
	while not _stopped.is_empty() and Time.get_ticks_msec() < deadline:
		await tree.process_frame
		_prune_stopped()
	return _stopped.is_empty()


## Arrête la lecture et lâche le flux (la lecture, suivie dans _stopped, sera rendue à une image).
func _silence() -> void:
	stop()
	stream = null


## play(from), la lecture lancée suivie jusqu'à sa remise (voir _stopped, silence_all).
func _play_from(from_position: float) -> void:
	play(from_position)
	if has_stream_playback():
		_stopped.append(weakref(get_stream_playback()))


static func _prune_stopped() -> void:
	if not _stopped.is_empty():
		_stopped = _stopped.filter(func(playback: WeakRef) -> bool: return playback.get_ref() != null)


## Oublie le flux partagé et l'état commun (à la sortie du jeu, par l'autoload BabelService).
static func release_shared() -> void:
	_stream = null
	_stream_loaded = false
	_reference = null
	_speakers.clear()
	_stopped.clear()
	_silenced = false


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
	if _fade_tween != null:
		_fade_tween.kill()   # un fondu d'entrée inachevé repart de son volume du moment
	_fade_tween = create_tween()
	_fade_tween.tween_method(_set_linear, db_to_linear(volume_db), 0.0, fade_out)
	_fade_tween.tween_callback(queue_free)


## Lance la lecture à l'horloge globale, en fondu d'entrée si un auditeur l'entend déjà.
func _start() -> void:
	started = true
	_watch_clock()   # une pause qui vient de finir recale l'horloge avant ce départ
	if _reference == null or not is_instance_valid(_reference):
		_reference = self
	start_position = music_position()
	start_usec = Time.get_ticks_usec()
	var fade := _fade_in > 0.0 and _audible_now()
	if fade:
		volume_db = -80.0
	_play_from(start_position)
	if fade:
		_fade_tween = create_tween()
		_fade_tween.tween_method(_set_linear, 0.0, 1.0, _fade_in)


func _enter_tree() -> void:
	if _silenced:
		_retiring = true
		stream = null
		return
	if not _speakers.has(self):
		_speakers.append(self)


func _exit_tree() -> void:
	_speakers.erase(self)
	if _reference == self:
		_reference = null
	# Hors de l'arbre (il n'y revient jamais : retiré, ou sa galerie libérée), il se tait et lâche le
	# flux ; le serveur audio rend sa lecture à une image suivante (voir silence_all).
	_silence()


func _notification(what: int) -> void:
	if what == NOTIFICATION_UNPAUSED:
		_resync_requested = true


func _process(delta: float) -> void:
	_watch_clock()
	if not started:
		if stream != null and not _retiring and _may_start():
			_start()
		return
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
			_play_from(start_position)


## Vrai si un départ tient encore dans le budget de l'image (STARTS_PER_FRAME).
static func _may_start() -> bool:
	var frame := Engine.get_process_frames()
	if frame != _start_frame:
		_start_frame = frame
		_starts = 0
	if _starts >= STARTS_PER_FRAME:
		return false
	_starts += 1
	return true


## Une fois par image (le premier haut-parleur qui passe) : après une pause de l'arbre, ou une image de plus de
## STALL_USEC, tous les lecteurs se recalent ensemble (resync_all).
static func _watch_clock() -> void:
	var frame := Engine.get_process_frames()
	if frame == _last_tick_frame:
		return
	_last_tick_frame = frame
	_prune_stopped()
	var now := Time.get_ticks_usec()
	var stalled := _last_tick_usec >= 0 and now - _last_tick_usec > STALL_USEC
	_last_tick_usec = now
	if stalled or _resync_requested:
		_resync_requested = false
		resync_all()


## Recale l'horloge globale sur la position de lecture du haut-parleur de référence (le premier qui joue), puis ramène
## sur elle tout lecteur qui s'en écarte de plus de RESYNC_TOLERANCE. Aucun lecteur ne revient à l'horloge murale
## seule : après une pause, tous reprennent là où la référence s'est arrêtée, ensemble.
static func resync_all() -> void:
	var length := music_length()
	if length <= 0.0:
		return
	var reference: AudioStreamPlayer3D = _reference if is_instance_valid(_reference) and _reference.playing else null
	if reference == null:
		for s: AmbientSpeakerScript in speakers():
			if s.playing:
				reference = s
				break
	if reference == null:
		return
	_reference = reference
	resync_count += 1
	var position := reference.get_playback_position()
	var now := Time.get_ticks_usec()
	_origin_usec = now - int(position * 1.0e6)
	for s: AmbientSpeakerScript in speakers():
		if not s.playing:
			continue
		if s != reference and absf(_circular_diff(s.get_playback_position(), position)) > RESYNC_TOLERANCE:
			s._play_from(position)
		s.start_position = s.get_playback_position() if s != reference else position
		s.start_usec = now
		s._since_check = 0.0


## Rapproche l'horloge murale de l'horloge audio du haut-parleur de référence, de 5 % de l'écart par image.
func _steer_clock() -> void:
	var length := music_length()
	if length <= 0.0 or _origin_usec < 0:
		return
	var err := _circular_diff(get_playback_position(), music_position())
	if absf(err) < 0.5:      # un écart plus grand signale une position de lecture inexploitable : on l'ignore
		_origin_usec -= int(err * 0.05 * 1.0e6)


## Vrai si un auditeur (caméra active) se trouve assez près pour entendre ce haut-parleur dès maintenant, ou s'il n'y
## a pas encore de caméra (le monde naît : on entrera en fondu).
func _audible_now() -> bool:
	if not is_inside_tree():
		return false
	var camera := get_viewport().get_camera_3d()
	return camera == null or camera.global_position.distance_to(global_position) < MAX_DISTANCE


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
