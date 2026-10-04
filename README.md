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
- Chaque page est l'image de son adresse (hexagone, niveau, mur, étagère, livre, page) par une
  bijection en grands entiers, calculée par `python/babel.py` : un même livre montre toujours le
  même texte, et tout texte se retrouve à une adresse (recherche inverse).
- Un livre sur 50 environ est un livre d'images, reconnu à sa seule adresse : chacune de ses pages
  se lit comme une image de 50 × 64 pixels, un symbole par pixel, dans une palette fixe de 25 encres
  chaudes (noir de fumée, sépia, vélin, vermillon, ocre, vert-de-gris, indigo…).
- Le jeu lance le service Python au premier livre ouvert ; il faut Python 3.10 ou plus, sans
  autre paquet. Sans Python, la page ouverte affiche l'erreur. Le réglage de projet
  `babel/python_command` choisit l'interpréteur (par défaut `py -3`, `python`, puis `python3` sous
  Windows ; `python3` sous Linux).

## Recherche inverse

Le texte cherché est normalisé : minuscules, accents retirés, œ → oe, æ → ae, ß → ss, k et q → c,
w → v, y → i, blancs → espace, autres caractères retirés ; puis complété par des espaces jusqu'à
3200 symboles (la suite d'un texte plus long est ignorée). Une image est ajustée à 50 × 64 en gardant
ses proportions, bordée de l'encre la plus sombre, puis tramée aux 25 encres par Floyd–Steinberg.
L'ajustement ne lit que les points d'une grille calculée en arithmétique entière (au plus 4 × 4
points par pixel de la page, 200 × 256 points en tout ; formules dans l'en-tête de `python/babel.py`) :
le jeu et la ligne de commande lisent les mêmes pixels, donc une même image donne la même adresse
dans le jeu et hors du jeu, quelle que soit sa taille. La recherche de texte rend un livre de texte,
la recherche d'image un livre d'images.

```sh
python3 python/babel.py page 12:-3:0:4:17:205        # hexagone:niveau:mur:étagère:livre:page (mur 0-3, étagère 0-4, livre 0-31, page 0-409)
python3 python/babel.py page -12:-3:0:4:17:205       # un hexagone négatif s'écrit tel quel
python3 python/babel.py page "$(python3 python/babel.py search-text citation.txt)"
python3 python/babel.py search-text citation.txt     # adresse complète sur la sortie, forme courte sur l'erreur
echo "la bibliotheque de babel" | python3 python/babel.py search-text -
python3 python/babel.py search-image gravure.png     # PNG 8 bits seulement : convertir d'abord un JPG en PNG
python3 python/babel.py search-text citation.txt --json
```

Dans le jeu, `BookText.search_text_file(chemin)` et `BookText.search_image_file(chemin)` acceptent
un fichier texte, ou une image PNG, JPG ou WebP (Godot la décode et n'envoie au service que ses
points de grille : 140 Ko de requête pour une photo de 6000 × 4000).

Le service `python3 python/babel.py serve` lit une requête JSON par ligne et répond sur une ligne ;
une adresse y est `{"hexagon": "<décimal>", "level": "<décimal>", "wall": 0, "shelf": 0, "book": 0, "page": 0}`.

| `op` | Requête | Réponse |
|---|---|---|
| `ping` | — | `{"protocol": 2}` |
| `page` | `address`, `as_image` (facultatif) | `{"lines": [40 chaînes], "is_image": bool, "indices": base64}` ; `indices` (3200 encres 0-24, ligne par ligne) pour un livre d'images ou avec `as_image` |
| `search_text` | `text` | `{"address": …, "tries": n}` |
| `search_image` | `width`, `height` de l'image d'origine, et soit `samples` (base64 : les points de grille seuls, 4 octets RGBA par point, ligne de grille après ligne de grille ; ce qu'envoie le jeu), soit `rgba` (base64 : l'image complète, 4 octets par pixel) | `{"address": …, "tries": n}` |
| `is_image_book` | `books` : liste d'adresses de livres (`page` facultative) | `{"is_image": [bool…]}` |
| `display` | `address` | `{"short": "hexagone 1909…0195 (2234 chiffres) · …", "full": "h:n:m:é:l:p"}` |
| `palette` | — | `{"palette": ["#1a1410", … 25 encres], "width": 50, "height": 64}` |

Un champ `id` facultatif revient tel quel dans la réponse. Toute erreur répond `{"error": "…"}` sur
sa ligne et le service continue.

Tests de la bijection, de la recherche, du PNG et du service :

```sh
uv run --with pytest --with hypothesis pytest python/
godot --headless --path . -s tests/test_babel_service.gd   # temps de réponse, recherche d'image, absence de Python
```

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
