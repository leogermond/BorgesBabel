#!/bin/sh
# Vérifie que le jeu se lance sans que .godot/global_script_class_cache.cfg connaisse
# les class_name récents (situation d'un pull sans réimport). Copie le projet, l'importe,
# puis remplace le cache par (1) un cache périmé qui ne connaît que Gallery, BookText, Hud,
# Player et Reader, (2) un cache vide ; à chaque fois, lance la scène principale ~120 images
# en headless et échoue au moindre « SCRIPT ERROR » / « Parse Error ».
#   tools/check_no_class_cache.sh [godot]      (godot : binaire, sinon $GODOT ou « godot »)
set -eu

GODOT="${1:-${GODOT:-godot}}"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for f in project.godot main.tscn scripts shaders fonts audio data; do
	[ -e "$SRC/$f" ] && cp -R "$SRC/$f" "$TMP/"
done

"$GODOT" --headless --path "$TMP" --log-file "$TMP/import.log" --import >/dev/null 2>&1 || true

entry() { # classe base fichier
	printf '{\n"base": &"%s",\n"class": &"%s",\n"icon": "",\n"is_abstract": false,\n"is_tool": false,\n"language": &"GDScript",\n"path": "res://scripts/%s.gd"\n}' "$2" "$1" "$3"
}
stale_cache() {
	printf 'list=['
	entry BookText RefCounted book_text; printf ', '
	entry Gallery Node3D gallery; printf ', '
	entry Hud CanvasLayer hud; printf ', '
	entry Player CharacterBody3D player; printf ', '
	entry Reader CanvasLayer reader
	printf ']\n'
}

status=0
for variant in stale empty; do
	if [ "$variant" = stale ]; then stale_cache; else printf 'list=[]\n'; fi > "$TMP/.godot/global_script_class_cache.cfg"
	LOG="$TMP/run-$variant.log"
	# Fichiers du joueur (quête en cours écrite au premier lancement) dans le dossier temporaire :
	# rien n'est écrit dans le user:// du jeu.
	# Journal du moteur aussi dans le dossier temporaire (--log-file) : rien dans le user:// du jeu.
	"$GODOT" --headless --path "$TMP" --log-file "$TMP/godot-$variant.log" --quit-after 120 -- "--dossier-joueur=$TMP/joueur" >"$LOG" 2>&1 || true
	if grep -E "SCRIPT ERROR|Parse Error|Could not find type" "$LOG"; then
		echo "ECHEC ($variant) : erreurs de script avec un cache de classes incomplet" >&2
		status=1
	else
		echo "OK ($variant) : aucune erreur de script avec un cache de classes incomplet"
	fi
done
exit $status
