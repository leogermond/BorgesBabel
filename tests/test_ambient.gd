extends SceneTree
## Vérifie la musique d'ambiance et les haut-parleurs : fichier OGG (format, durée, boucle), modèle d'atténuation,
## horloge commune et synchronisation des haut-parleurs créés à des instants différents, bus « Ambiance ».
## Le niveau (crête, RMS), la couture de boucle et la non-répétition se mesurent sur le WAV de rendu :
## python3 tools/make_ambiance.py --check
## godot --headless --path . -s tests/test_ambient.gd

const Speaker := preload("res://scripts/ambient_speaker.gd")
const MAX_BYTES := 10 * 1024 * 1024

var _failures := 0


func _initialize() -> void:
	# --- le fichier et le flux
	var path := "res://audio/ambiance.ogg"
	_check(FileAccess.file_exists(path), "audio/ambiance.ogg est livré avec le jeu")
	var info := _ogg_info(path)
	_check(info.get("valid", false), "l'en-tête est un flux Ogg Vorbis")
	_check(info.get("channels", 0) == 1, "mono (lu : %s)" % info.get("channels", 0))
	_check(info.get("rate", 0) in [22050, 32000], "fréquence d'échantillonnage 22050 ou 32000 Hz (lu : %s)" % info.get("rate", 0))
	_check(info.get("seconds", 0.0) >= 600.0, "au moins 10 minutes de matière avant la boucle (lu : %.1f s)" % info.get("seconds", 0.0))
	_check(info.get("bytes", MAX_BYTES + 1) <= MAX_BYTES, "au plus 10 Mo (lu : %.2f Mo)" % (info.get("bytes", 0) / 1048576.0))

	var stream := Speaker.load_stream()
	_check(stream is AudioStreamOggVorbis, "le flux se charge (AudioStreamOggVorbis) sans fichier .import suivi")
	if stream != null:
		_check(stream.get_length() >= 600.0, "le flux dure %.1f s" % stream.get_length())
		_check(absf(stream.get_length() - info.get("seconds", 0.0)) < 1.0, "durée du flux = durée du fichier (écart %.2f s)" % absf(stream.get_length() - info.get("seconds", 0.0)))
		_check((stream as AudioStreamOggVorbis).loop and (stream as AudioStreamOggVorbis).loop_offset == 0.0, "la boucle est réglée dans le code : tout le morceau")
	_check(Speaker.stream_path() == Speaker.DEFAULT_PATH or FileAccess.file_exists(Speaker.CUSTOM_PATH), "ambiance_custom.ogg prime seulement s'il existe")

	# --- atténuation : inverse de la distance, unit_size 2 m, max_distance 26 m
	var speaker := Speaker.create(0.0)
	_check(speaker.attenuation_model == AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE, "atténuation en inverse de la distance")
	_check(is_equal_approx(speaker.unit_size, 2.0) and is_equal_approx(speaker.max_distance, 26.0), "unit_size 2 m, max_distance 26 m")
	_check(speaker.bus == &"Ambiance", "le haut-parleur joue sur le bus Ambiance")
	var table := {}
	var previous := 2.0
	var monotonic := true
	for d: float in [0.0, 2.0, 6.0, 12.0, 24.0, 26.0]:
		table[d] = Speaker.gain_at(d)
		monotonic = monotonic and table[d] < previous or d == 0.0
		previous = table[d]
	print("  gain : ", ", ".join(table.keys().map(func(d: float) -> String: return "%d m = %.4f (%.1f dB)" % [d, table[d], linear_to_db(maxf(table[d], 1e-6))])))
	_check(table[0.0] == 1.0, "0 m : gain 1 (0 dB)")
	_check(monotonic, "le gain décroît strictement de 0 à 6, 12, 24 puis 26 m")
	_check(table[6.0] > table[12.0] and table[12.0] > table[24.0] and table[24.0] > table[26.0], "6 m > 12 m > 24 m > 26 m")
	_check(absf(linear_to_db(table[6.0]) + 12.0) < 1.0, "6 m ≈ −12 dB (lu : %.1f dB)" % linear_to_db(table[6.0]))
	_check(absf(linear_to_db(table[12.0]) + 21.0) < 1.0, "12 m ≈ −21 dB (lu : %.1f dB)" % linear_to_db(table[12.0]))
	_check(linear_to_db(table[24.0]) < -40.0, "24 m quasi muet, sous −40 dB (lu : %.1f dB)" % linear_to_db(table[24.0]))
	_check(table[26.0] == 0.0, "silence total à 26 m")
	_check(Speaker.gain_at(0.001) <= 1.0 and Speaker.gain_at(1.0) > 0.9, "sous le haut-parleur (≤ 2 m) le volume reste plein, sans explosion (1 m : %.2f)" % Speaker.gain_at(1.0))
	# Dans une galerie les deux couloirs voisins, à 6 m, s'additionnent : environ 6 dB sous le plein volume du couloir.
	var centre: float = 2.0 * table[6.0]
	var hallway: float = 1.0 + Speaker.gain_at(12.0)
	_check(centre < hallway and linear_to_db(centre / hallway) > -9.0 and linear_to_db(centre / hallway) < -4.0,
		"centre de galerie : %.1f dB sous le couloir" % linear_to_db(centre / hallway))

	# --- bus
	var count_before := AudioServer.bus_count
	Speaker.set_bus_volume(-6.0)
	var index := AudioServer.get_bus_index("Ambiance")
	_check(index >= 0, "le bus Ambiance est créé en code")
	_check(is_equal_approx(Speaker.bus_volume(), -6.0), "volume global du bus")
	Speaker.set_bus_muted(true)
	_check(Speaker.bus_muted() and AudioServer.is_bus_mute(index), "sourdine globale")
	Speaker.set_bus_muted(false)
	Speaker.set_bus_volume(0.0)
	Speaker.ensure_bus_name()
	_check(AudioServer.bus_count == count_before or AudioServer.bus_count == count_before + 1, "le bus n'est créé qu'une fois")
	_check(AudioServer.get_bus_send(index) == &"Master", "le bus part vers Master")
	var buses_now := AudioServer.bus_count
	Speaker.create()
	_check(AudioServer.bus_count == buses_now, "create() ne multiplie pas les bus")

	# --- horloge commune et synchronisation
	if stream != null:
		var length := Speaker.music_length()
		var p0 := Speaker.music_position()
		_check(p0 >= 0.0 and p0 < length, "music_position ∈ [0 ; durée[")
		var speakers: Array[AmbientSpeaker] = []
		var arrivals: Array[float] = []
		var worst := 0.0
		for i in 4:
			var s := Speaker.create(0.0)
			var clock_before := Speaker.music_position()
			root.add_child(s)
			await process_frame
			var clock_after := Speaker.music_position()
			speakers.append(s)
			arrivals.append(s.start_position)
			# Le haut-parleur démarre à l'horloge globale du moment de son entrée dans l'arbre.
			worst = maxf(worst, minf(absf(Speaker._circular_diff(s.start_position, clock_before)), absf(Speaker._circular_diff(s.start_position, clock_after))))
			if worst > 0.05:
				print("    (arrivée %d : départ %.3f s, horloge %.3f → %.3f s)" % [i, s.start_position, clock_before, clock_after])
			await create_timer(0.18).timeout
		_check(worst < 0.05, "4 haut-parleurs créés à 180 ms d'écart démarrent à l'horloge commune, à %.1f ms près (< 50 ms)" % (worst * 1000.0))
		var spread := arrivals[3] - arrivals[0]
		_check(spread > 0.4 and spread < 0.8, "les positions de départ avancent avec l'horloge (écart %.2f s sur 3 × 180 ms)" % spread)
		var phase_spread := 0.0
		for i in 4:
			var phase: float = Speaker._circular_diff(speakers[i].expected_position(), Speaker.music_position())
			phase_spread = maxf(phase_spread, absf(phase))
		_check(phase_spread < 0.1, "position attendue de chaque haut-parleur = horloge, à %.1f ms près (< 100 ms, l'horloge suit doucement la lecture)" % (phase_spread * 1000.0))
		var playing_count := 0
		for s in speakers:
			playing_count += int(s.playing)
		print("  lecture effective : %d / 4 haut-parleurs (pilote audio : %s)" % [playing_count, AudioServer.get_driver_name()])
		if playing_count == 4:
			var ref: float = speakers[0].get_playback_position()
			var gap := 0.0
			for s in speakers:
				gap = maxf(gap, absf(Speaker._circular_diff(s.get_playback_position(), ref)))
			print("  écart de position de lecture entre lecteurs : %.1f ms (granularité du mixeur du pilote Dummy)" % (gap * 1000.0))
			_check(gap < 0.15, "positions de lecture des 4 lecteurs à moins de 150 ms (pilote Dummy, blocs de mixage larges) (lu : %.1f ms)" % (gap * 1000.0))

		# Recyclage : retirer tous les haut-parleurs puis en créer un nouveau ne redémarre pas le morceau.
		var before := Speaker.music_position()
		for s in speakers:
			s.free()
		await create_timer(0.12).timeout
		var late := Speaker.create(0.0)
		root.add_child(late)
		await process_frame
		var expected := fposmod(before + 0.12, length)
		_check(absf(Speaker._circular_diff(late.start_position, expected)) < 0.1,
			"après libération de tous les haut-parleurs, le suivant reprend à %.2f s (attendu %.2f s)" % [late.start_position, expected])
		late.retire(0.0)

	speaker.free()
	print("test_ambient : %s" % ("OK" if _failures == 0 else "%d échec(s)" % _failures))
	quit(1 if _failures else 0)


## Lit l'en-tête Vorbis (canaux, fréquence) et la dernière position granulaire (durée) d'un fichier Ogg.
func _ogg_info(path: String) -> Dictionary:
	var bytes := FileAccess.get_file_as_bytes(path)
	var out := {"bytes": bytes.size(), "valid": false}
	if bytes.size() < 64 or bytes.slice(0, 4).get_string_from_ascii() != "OggS":
		return out
	var table := 27 + bytes[26]
	if bytes[table] != 1 or bytes.slice(table + 1, table + 7).get_string_from_ascii() != "vorbis":
		return out
	out["channels"] = bytes[table + 11]
	out["rate"] = bytes.decode_u32(table + 12)
	var at := bytes.size() - 14
	while at > 0:
		if bytes[at] == 0x4F and bytes[at + 1] == 0x67 and bytes[at + 2] == 0x67 and bytes[at + 3] == 0x53:
			break
		at -= 1
	out["valid"] = at > 0
	out["seconds"] = float(bytes.decode_s64(at + 6)) / float(out["rate"])
	return out


func _check(condition: bool, label: String) -> void:
	print(("  ok    " if condition else "  ÉCHEC ") + label)
	if not condition:
		_failures += 1
