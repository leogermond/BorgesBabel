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
- Les galeries se construisent autour du bibliothécaire, sur une centaine de mètres : huit de
  chaque côté le long des vestibules sur trois niveaux, quatre niveaux par le puits, et les
  diagonales que le regard enfile d'un puits voisin à l'autre (un niveau par galerie). Plus loin,
  le puits garde ses anneaux jusqu'à trente niveaux. Trois degrés de détail : complète (avec
  collisionneurs) pour la galerie du bibliothécaire et ses deux voisines, éclairée (livres un à
  un, vraies lampes) tout près, lointaine (façades de livres peintes) au-delà.
- Une seule lumière, quel que soit le détail : toutes les surfaces partagent un nuanceur qui
  calcule, pixel par pixel, la lumière de chaque lampe de la Bibliothèque par la formule même de
  Godot pour une OmniLight3D. Une lampe proche de l'œil (moins de 7 m) éclaire en partie par une
  vraie OmniLight3D, et le nuanceur ajoute exactement le reste : la somme ne dépend pas du détail,
  et une vraie lampe ne naît ou ne s'éteint qu'à part nulle. Une galerie lointaine reçoit donc la
  lumière d'une galerie proche ; ses livres peints ont les hauteurs et les cuirs des vrais, tirés
  de la même graine.
- La brume, exponentielle, se fond entièrement dans sa couleur entre 70 et 90 m. Une galerie qui
  naît ou disparaît à un pas est hors de vue, ou au-delà de 90 m : en franchissant un vestibule
  ou un niveau, rien ne change d'éclat à l'image.

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
La recherche de texte rend un livre de texte, la recherche d'image un livre d'images.

```sh
python3 python/babel.py page 12:-3:0:4:17:205        # hexagone:niveau:mur:étagère:livre:page (mur 0-3, étagère 0-4, livre 0-31, page 0-409)
python3 python/babel.py search-text citation.txt     # adresse complète sur la sortie, forme courte sur l'erreur
echo "la bibliotheque de babel" | python3 python/babel.py search-text -
python3 python/babel.py search-image gravure.png     # PNG 8 bits seulement : convertir d'abord un JPG en PNG
python3 python/babel.py search-text citation.txt --json
```

Dans le jeu, `BookText.search_text_file(chemin)` et `BookText.search_image_file(chemin)` acceptent
un fichier texte, ou une image PNG, JPG ou WebP (Godot la décode et envoie ses pixels au service).

Le service `python3 python/babel.py serve` lit une requête JSON par ligne et répond sur une ligne ;
une adresse y est `{"hexagon": "<décimal>", "level": "<décimal>", "wall": 0, "shelf": 0, "book": 0, "page": 0}`.

| `op` | Requête | Réponse |
|---|---|---|
| `ping` | — | `{"protocol": 1}` |
| `page` | `address`, `as_image` (facultatif) | `{"lines": [40 chaînes], "is_image": bool, "indices": base64}` ; `indices` (3200 encres 0-24, ligne par ligne) pour un livre d'images ou avec `as_image` |
| `search_text` | `text` | `{"address": …, "tries": n}` |
| `search_image` | `width`, `height`, `rgba` (base64, 4 octets par pixel) | `{"address": …, "tries": n}` |
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
godot --headless --path . -s tests/test_depth.gd       # profondeur, continuité de la lumière, coût d'un pas
```

`test_depth` relève, en 1 871 points fixes de la Bibliothèque (le long du vestibule, des diagonales
et du puits), la lumière des lampes renvoyée vers l'œil, fois le reste de brume, juste avant et
juste après le passage d'un vestibule ou d'un niveau, l'œil restant au même point. Tout écart de
plus de 1 % (+ 1e-4) en un point en vue est un saut d'éclat et fait échouer le test ; il vérifie
aussi qu'aucune galerie ne naît ou ne disparaît en vue en deçà de 90 m, que chaque lampe en partie
réelle a sa OmniLight3D, et qu'un pas coûte moins de 8 ms.

Captures de rendu dans un écran virtuel Xvfb (paquet `xvfb`), sans fenêtre :

```sh
xvfb-run -a -s "-screen 0 1600x900x24" godot --rendering-driver opengl3 --path . -s tests/render_shots.gd
```

Les PNG vont dans `.foreman/scratch/screenshots` (ou dans le dossier passé après `--`).

Chaque test affiche ses vérifications et sort avec le code 0 quand toutes passent.

## Organisation

- `scripts/main.gd` : tirage de la galerie, entretien des galeries voisines (degrés de détail, part réelle des lampes), entrées, environnement.
- `scripts/gallery.gd` : construction d'une galerie (géométrie, étagères, livres en MultiMesh, lampes), nuanceur de lumière commun, réserve d'éléments réutilisés, et repérage du livre visé.
- `scripts/far_view.gd` : anneaux du puits au loin et trompe-l'œil aux quatre bouts.
- `scripts/player.gd` : déplacement à la première personne et rayon de visée.
- `scripts/book_text.gd` : texte des pages.
- `scripts/reader.gd` : fenêtre de lecture.
- `scripts/hud.gd` : adresse, réticule, livre visé.
