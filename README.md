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

L'unité est le livre. Chacun des 25^1 312 000 livres possibles (410 pages × 3200 symboles) existe
exactement une fois : `python/babel.py` réalise une bijection exacte entre ces livres et les
adresses de livres (hexagone, niveau, mur, étagère, livre). La Bibliothèque est donc finie mais
immense : toute galerie dont l'hexagone et le niveau ont au plus 917 045 chiffres décimaux est
pleine ; au-delà d'une dernière galerie à moitié garnie (emplacements 0 à 384), les étagères sont
vides. Une adresse prise au hasard, ou trouvée par une recherche, a un hexagone et un niveau
d'environ 917 000 chiffres décimaux chacun. Le détail (rang, région, mélange) est dans l'en-tête
de `python/babel.py`.

- **Texte.** Le texte cherché est normalisé : minuscules, accents retirés, œ → oe, æ → ae,
  ß → ss, k et q → c, w → v, y → i, blancs → espace, autres caractères retirés ; puis complété par
  des espaces jusqu'à la fin du livre. La recherche rend l'unique livre qui contient ce texte suivi
  seulement d'espaces ; un texte de plusieurs pages occupe les pages 0, 1, 2 … du même livre. Au-delà
  de 1 312 000 symboles (un livre), la suite est ignorée et la réponse le signale.
- **Livres d'images.** Un livre est un livre d'images quand ses deux premiers symboles autres que
  l'espace sont des signes (« , » ou « . ») ; les espaces ne comptent pas. C'est une propriété du
  contenu, qui touche exactement 1 livre sur 144. Un texte qui commence ainsi (par exemple « .. »)
  tombe donc dans un livre d'images, et la réponse le signale ; tout autre texte tombe dans un livre
  de texte. Chaque page d'un livre d'images se lit comme une image de 50 × 64 pixels dans la palette
  des 25 encres.
- **Image.** Une image est ajustée à 50 × 64 en gardant ses proportions, bordée de l'encre la plus
  sombre, puis tramée aux 25 encres par Floyd–Steinberg ; ses deux premiers pixels ne prennent que
  les encres des signes, ce qui écrit la marque des livres d'images. La recherche rend l'unique livre
  dont la page 0 est cette image et dont les pages suivantes sont d'encre 0. L'ajustement ne lit que
  les points d'une grille calculée en arithmétique entière (au plus 4 × 4 points par pixel de la page,
  200 × 256 points en tout) : le jeu et la ligne de commande lisent les mêmes pixels, donc une même
  image donne la même adresse dans le jeu et hors du jeu, quelle que soit sa taille.

Temps mesurés (Python 3.11, une machine de développement à 4 cœurs ; `.foreman/scratch/perf.py`) :

| Opération | Temps |
|---|---|
| recherche d'un texte d'une page / de 410 pages | 0,55 s / 1,9 s |
| recherche d'une image 512 × 512 | 0,54 s |
| page 0 d'un livre jamais ouvert (adresse proche / trouvée) | 3 ms / 0,11 s |
| page 409 d'un livre jamais ouvert (chaîne des 410 pages) | 0,8 à 0,9 s |
| page suivante d'un livre ouvert (service, par clé) | 6 ms |
| genres des 640 livres d'une galerie (proche / trouvée) | 15 ms / 0,14 s |
| mémoire d'un livre en cache, 410 pages calculées | 0,8 à 2,1 Mo |

### Ligne de commande

Une adresse s'écrit `hexagone:niveau:mur:étagère:livre[:page]` en décimal (mur 0-3, étagère 0-4,
livre 0-31, page 0-409), ou `b25:hexagone:niveau:…` avec hexagone et niveau en base 25 (rapide).
Le décimal complet d'une adresse trouvée compte ~1,8 million de chiffres : il s'écrit en ~1,5 s et se
relit en ~5 s, et dépasse la limite de 128 Ko d'un argument de commande sous Linux ; `page -` lit
l'adresse sur l'entrée standard.

```sh
python3 python/babel.py page 12:-3:0:4:17:205          # page 205 du livre (hexagone 12, niveau -3, mur 0, étagère 4, livre 17)
python3 python/babel.py page -12:-3:0:4:17 --page 205  # un hexagone négatif s'écrit tel quel
python3 python/babel.py search-text citation.txt | python3 python/babel.py page -
python3 python/babel.py search-text citation.txt --base25   # « b25:… » : rapide
python3 python/babel.py search-text citation.txt --json     # adresse JSON (base 25), clé, is_image
echo "la bibliotheque de babel" | python3 python/babel.py search-text - --base25
python3 python/babel.py search-image gravure.png --base25   # PNG 8 bits : convertir d'abord un JPG en PNG
```

La forme courte (abrégée) part sur l'erreur standard, avec les avis (texte tronqué, livre d'images).

### Service JSON (protocole 3)

Dans le jeu, `BookText.search_text_file(chemin)` et `BookText.search_image_file(chemin)` acceptent
un fichier texte, ou une image PNG, JPG ou WebP (Godot la décode et n'envoie au service que ses
points de grille). Le service `python3 python/babel.py serve` lit une requête JSON par ligne et répond
sur une ligne. Une adresse de livre y est
`{"hexagon": "<base 25>", "level": "<base 25>", "wall": 0, "shelf": 0, "book": 0}` : hexagone et
niveau sont des chaînes en base 25 signées (`-` facultatif, chiffres `0123456789abcdefghijklmno`,
poids fort en premier, `"0"` pour zéro ; la notation de `int(texte, 25)`), lues et écrites en temps
linéaire. Un entier JSON est aussi accepté pour une petite coordonnée. Un livre se désigne par
`address`, ou par `key`, la clé rendue par une réponse précédente : le service garde les 256 dernières
clés et le contenu des 4 derniers livres ouverts, ce qui évite de renvoyer 1,3 Mo d'adresse à chaque
page tournée.

| `op` | Requête | Réponse |
|---|---|---|
| `ping` | — | `{"protocol": 3}` |
| `palette` | — | `{"palette": ["#1a1410", … 25 encres], "width": 50, "height": 64}` |
| `book_info` | `address` ou `key` | `{"key", "exists": true, "is_image", "address", "short"}`, ou `{"exists": false}` pour un emplacement vide |
| `page` | `address` ou `key`, `page` (0-409, 0 par défaut ; aussi lue dans `address`), `as_image` (facultatif) | `{"key", "page", "lines": [40 chaînes], "is_image", "indices"}` ; `indices` (base64 des 3200 encres 0-24, ligne par ligne) pour un livre d'images ou avec `as_image` |
| `pages` | `address` ou `key`, `pages` : liste de 1 à 410 numéros, `as_image` (facultatif) | `{"key", "is_image", "pages": [{"page", "lines", "indices"?}, …]}` |
| `search_text` | `text` | `{"address", "key", "is_image", "text_pages": pages occupées, "truncated": bool, "notice"?}` |
| `search_image` | `width`, `height` de l'image d'origine, et soit `samples` (base64 : les points de grille seuls, 4 octets RGBA par point, ligne de grille après ligne de grille ; ce qu'envoie le jeu), soit `rgba` (base64 : l'image complète) | `{"address", "key", "is_image": true}` |
| `is_image_book` | `books` : liste d'adresses de livres, ou `gallery` : `{"hexagon", "level"}` | `{"is_image": [true, false ou null (emplacement vide) …]}` ; pour `gallery`, 640 valeurs dans l'ordre (mur·5 + étagère)·32 + livre |
| `display` | `address` (page facultative) ou `key`, `full` (facultatif) | `{"short": "hexagone -1096…7662 (917047 chiffres) · …", "hexagon": {"sign", "digits", "lead", "tail"}, "level": {…}}` ; `full: true` ajoute `"full"` (décimal complet, ~1,5 s) |

Un champ `id` facultatif revient tel quel dans la réponse. Toute erreur répond
`{"error": "…", "code": "…"}` sur sa ligne et le service continue ; `code` vaut `bad_request`,
`unknown_op`, `unknown_key` (clé oubliée : renvoyer l'adresse), `empty_slot` (adresse hors de la
région habitée) ou `internal`.

Tests de la bijection, de la recherche, du PNG et du service :

```sh
uv run --with pytest --with hypothesis pytest python/            # ~1 min 30 ; les cas lents sont marqués
uv run --with pytest --with hypothesis pytest python/ -m slow    # texte de 410 pages, texte plus long qu'un livre
uv run --no-project --python 3.10 --with pytest --with hypothesis pytest python/
godot --headless --path . -s tests/test_babel_service.gd         # temps de réponse, recherche d'image, absence de Python
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
