# Bibliothèque de Babel

Un petit jeu Godot 4.7 (GDScript) d'après « La Bibliothèque de Babel » de Jorge Luis Borges.
Le bibliothécaire apparaît dans une galerie hexagonale tirée au hasard ; il marche de galerie
en galerie et lit les livres.

## Lancer

```sh
godot --path .            # joue la scène principale
godot -e --path .         # ouvre le projet dans l'éditeur
```

Dans VS Code, Ctrl+Maj+B lance le jeu avec le Godot Windows natif
(`C:\Users\germond\AppData\Local\Programs\Godot\Godot_v4.7.2-stable_win64.exe`, tâche
« Lancer le jeu » de `.vscode/tasks.json`). Sous WSLg, Godot Linux rend en OpenGL sans accès
direct au GPU et la souris reste libre ; le Godot Windows capture la souris et rend en Vulkan.

## Commandes

| Touche | Geste |
|---|---|
| ZQSD (AZERTY), WASD (QWERTY), flèches | marcher |
| souris | regarder |
| E ou clic gauche, sur un livre | ouvrir le livre |
| ← → (ou Page préc. / Page suiv., ou les boutons) | tourner la page |
| E ou Échap, livre ouvert | refermer le livre |
| Échap | libérer ou reprendre la souris |

## La Bibliothèque

- Chaque galerie est un hexagone. Quatre murs portent chacun 5 étagères de 32 livres ;
  les deux autres s'ouvrent sur un vestibule étroit qui mène à la galerie voisine.
  Au centre, un puits d'aération bordé d'une balustrade basse laisse voir les niveaux
  du dessus et du dessous. Deux lampes sphériques, transversales, éclairent chaque galerie.
- L'adresse de la galerie (hexagone, niveau) s'affiche en haut à gauche. Elle est tirée au
  hasard au lancement ; l'hexagone avance ou recule d'un cran à chaque vestibule franchi.
- Les galeries se construisent autour du bibliothécaire : deux de chaque côté le long des
  vestibules, et un niveau au-dessus et au-dessous.

## Les livres

- Format de Borges : 410 pages, 40 lignes par page, 80 caractères par ligne.
- 25 symboles : les 22 lettres `abcdefghijlmnoprstuvxz` (l'alphabet latin privé de k, q, w, y),
  l'espace, la virgule et le point.
- Chaque page se calcule à la demande à partir de son adresse complète (hexagone, niveau,
  mur, étagère, livre, page) passée par SHA-256 : un même livre montre toujours le même texte.

## Tests

```sh
godot --headless --path . --import
godot --headless --path . -s tests/test_book_text.gd   # texte : déterminisme, 40 × 80, alphabet, diversité
godot --headless --path . -s tests/test_world.gd       # monde : apparition, livre visé, lecture, vestibule, balustrade
```

Captures de rendu dans un écran virtuel Xvfb (paquet `xvfb`), sans fenêtre :

```sh
xvfb-run -a -s "-screen 0 1600x900x24" godot --rendering-driver opengl3 --path . -s tests/render_shots.gd
```

Les PNG vont dans `.foreman/scratch/screenshots` (ou dans le dossier passé après `--`).

Chaque test affiche ses vérifications et sort avec le code 0 quand toutes passent.

## Organisation

- `scripts/main.gd` : tirage de la galerie, entretien des galeries voisines, entrées, environnement.
- `scripts/gallery.gd` : construction d'une galerie (géométrie, étagères, livres en MultiMesh, lampes) et repérage du livre visé.
- `scripts/player.gd` : déplacement à la première personne et rayon de visée.
- `scripts/book_text.gd` : texte des pages.
- `scripts/reader.gd` : fenêtre de lecture.
- `scripts/hud.gd` : adresse, réticule, livre visé.
