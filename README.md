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
| Tab | panneau de quête (épingles, recherche d'un texte ou d'une image) |
| Suppr | effacer la quête en cours |

Le jeu n'affiche aucune aide de commande (ni sous le lecteur, ni ailleurs) : le mode d'emploi est
un livre de la Bibliothèque, l'entrée « Mode d'emploi de Babel » du catalogue.

La quête en cours se garde d'une session à l'autre (`user://quete_en_cours.json`), son
effacement aussi ; au premier lancement (rien d'enregistré), c'est « La biblioteca de Babel ».

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
- Chaque livre porte au dos un titre court en lettres dorées (Lora), tiré de son adresse : le même
  que montre la fenêtre de lecture ; les livres d'images ont un double filet doré en tête et en
  pied. Un liseré sombre autour des lettres les détache des cuirs clairs. La dorure se fond dans le
  cuir entre 24 et 32 m.
- Une galerie a toujours le même aspect, quel que soit le chemin qui y mène (à pied, d'un saut,
  au-delà de 2^62 ou à 917 000 chiffres) : la hauteur et le cuir de ses livres et leurs titres se
  tirent d'une clé calculée sur ses vraies coordonnées (un hachage polynomial de leurs tranches de
  8 chiffres base 25, modulo deux nombres premiers, que le jeu suit pas à pas à travers retenues et
  emprunts sans relire les coordonnées, et qui vaut celui de la coordonnée relue en entier). Les
  titres et les livres d'images se calculent sur le fil d'un second service Python : marcher ne
  coûte presque rien à l'image (~0,1 ms par image pour les titres). Au-delà de la région habitée,
  les emplacements vides n'ont pas de filets de livre d'images (les étagères y restent garnies à
  l'écran ; ouvrir un de ces livres affiche l'erreur du service).
- Une musique d'ambiance, la même partout et synchronisée, sort d'un haut-parleur au milieu de
  chaque vestibule du niveau du bibliothécaire, et s'éteint avec la distance.
- Les livres volés (ceux du catalogue, `stolen_books`, et celui qu'emporte le bibliothécaire)
  laissent un vide sur leur étagère et ne se visent pas. Le vide passe par la texture de données
  de la galerie (bit 21 du premier mot d'un livre : le nuanceur réduit sa boîte à un point), sous
  Forward+ comme sous Compatibility, et par un uniforme `ivec4` des façades peintes au loin (quatre
  livres absents par galerie au plus : les volés du catalogue sont dans des galeries distinctes,
  le bibliothécaire n'en porte qu'un ; quatre comparaisons d'entiers par pixel). Une galerie se
  reconnaît à sa clé (rien à faire pour les autres) puis, une fois par clé, à ses vraies
  coordonnées base 25 comparées exactement à celles des livres volés. Les clés des livres du
  catalogue (~30 ms par coordonnée de 656 000 chiffres) se calculent sur un fil au lancement.

## Les livres

- Format de Borges : 410 pages, 40 lignes par page, 80 caractères par ligne.
- 25 symboles : les 22 lettres `abcdefghijlmnoprstuvxz` (l'alphabet latin privé de k, q, w, y),
  l'espace, la virgule et le point.
- L'unité est le livre : chaque livre est l'image de son adresse (hexagone, niveau, mur, étagère,
  livre) par une bijection exacte, calculée par `python/babel.py`. Chacun des 25^1 312 000 livres
  possibles existe une fois et une seule ; un même livre montre toujours le même texte, et tout texte
  se retrouve dans un livre, à une adresse (recherche inverse), ses pages se suivant dans ce livre.
- La Bibliothèque est donc finie, mais immense : toute galerie dont l'hexagone et le niveau ont au
  plus 917 045 chiffres décimaux est pleine ; au-delà d'une dernière galerie à moitié garnie, les
  étagères sont vides. Une adresse trouvée par la recherche a un hexagone et un niveau d'environ
  917 000 chiffres décimaux : le jeu les garde en base 25 (la forme du service), les fait avancer
  de ±1 à chaque pas sans les relire, et les affiche en abrégé, « 1096…5346 (917047 chiffres) » :
  les 18 derniers chiffres suivent le pas, le reste se recalcule en arrière-plan quand ils
  débordent ; une retenue qui traverse toute la coordonnée se prépare d'avance sur un fil. Une
  coordonnée qui tient dans un entier (jusqu'à 2^62) s'écrit en entier. Après un saut, l'adresse
  s'affiche d'abord en nombre de chiffres seul, le temps que le service d'arrière-plan la résume.
  La distance du guidage de quête (« ≈ 10^N ») a un nombre de chiffres exact, tranché au ras d'une
  puissance de dix jusqu'à 20 000 chiffres base 25 (~28 000 chiffres décimaux) ; au-delà, il peut
  différer d'une unité quand la distance est à moins de 10^−9 près (en relatif) d'une puissance de dix.
- Un livre sur 144 exactement est un livre d'images, reconnu à son contenu (ses deux premiers
  symboles autres que l'espace sont des signes) et calculé depuis l'adresse sans calculer le livre :
  chacune de ses pages se lit comme une image de 50 × 64 pixels, un symbole par pixel, dans une
  palette fixe de 25 encres chaudes (noir de fumée, sépia, vélin, vermillon, ocre, vert-de-gris,
  indigo…).
- Le jeu lance le service Python au premier livre ouvert ; il faut Python 3.10 ou plus, sans
  autre paquet. Sans Python, la page ouverte affiche l'erreur. Le réglage de projet
  `babel/python_command` choisit l'interpréteur (par défaut `py -3`, `python`, puis `python3` sous
  Windows ; `python3` sous Linux) ; sous Windows, le lanceur `py` est remplacé par le python.exe
  qu'il choisit. Un service qui ne répond pas dans le délai (3 s pour une page, 10 s pour une
  recherche, 20 s au lancement) est arrêté, avec tous ses processus (un interpréteur lancé par un
  lanceur, `uv run` par exemple) : la page affiche l'erreur, le jeu ne se fige pas, et le service
  est relancé à la requête suivante ; après un lancement trop lent, la relance attend quelques
  secondes (5 s, doublées à chaque nouvel échec). Seul un Python absent reste un échec durable. Le
  lancement se fait sur un fil : le jeu ne l'attend que 2 s au plus, une fois, puis continue ; les
  requêtes suivantes échouent aussitôt (« se lance encore ») jusqu'à ce qu'il aboutisse. Un
  processus arrêté par le jeu (OS.kill l'attend) n'est plus interrogé : la sortie n'écrit aucune
  erreur « process does not exist ».

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
  ß → ss, k et q → c, w → v, y → i, blancs → espace ; apostrophes et traits d'union ou tirets →
  espace, « : » et « ; » → « , », « ! » « ? » « … » → « . », guillemets retirés (les espaces
  répétées ne sont pas fondues), autres caractères retirés ; puis complété par
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

Temps mesurés (Python 3.11, une machine de développement à 4 cœurs) : chaque opération est appelée
directement dans `babel.py` et chronométrée par `time.perf_counter()`, meilleur de 2 à 20 essais ;
texte d'une page : « La bibliothèque de Babel, » répété 100 fois ; texte de 410 pages : 1 312 000
symboles tirés au hasard ; image : 512 × 512 octets RGBA au hasard ; adresse proche :
(123456, -42, 1, 2, 3), adresse trouvée : celle du texte d'une page (cache des coordonnées vidé
avant chaque essai) ; page suivante : requête `page` par clé passée par `handle`, JSON compris ;
mémoire : `tracemalloc` autour d'un livre dont les 410 pages sont calculées.

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
page tournée. Le client du jeu (`scripts/book_text.gd`) demande ainsi les pages d'un livre déjà ouvert
par sa clé, renvoie l'adresse quand le service répond `unknown_key`, et lit chaque réponse sous un
délai : au-delà de 3 s (10 s pour une recherche), un chien de garde arrête le service et ses
descendants, l'appel rend l'erreur (`BookText.last_error`) et le service repart à la requête
suivante. Un second service, propre à un fil (`BookText.submit` / `take`), répond aux requêtes qui
ne doivent pas coûter une image : genres des livres d'une galerie, résumé d'une coordonnée. Le fil
principal n'attend jamais le verrou de sa file : requêtes et oublis attendent le verrou libre
(`BookText.flush`, à chaque image).

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
| `display` | `address` (page facultative) ou `key`, `full` (facultatif) | `{"short": "hexagone -1096…7662 (917047 chiffres) · …", "hexagon": {"sign", "digits", "lead", "tail", "low"}, "level": {…}}` (`low` : les 18 derniers chiffres) ; `full: true` ajoute `"full"` (décimal complet, ~1,5 s) |

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
godot --headless --path . -s tests/test_world.gd       # monde : apparition, livre visé, lecture, vestibule, balustrade, invocations, vides, sortie
godot --headless --path . -s tests/test_depth.gd       # profondeur, continuité de la lumière, coût d'un pas
godot --headless --path . -s tests/test_quest.gd       # quête : arithmétique, guidage, catalogue, épingles, Hud, carnet, quête gardée
godot --headless --path . -s tests/test_book_spine.gd  # titres des dos, texture des titres, livres absents
godot --headless --path . -s tests/test_ambient.gd     # musique d'ambiance
godot --headless --path . -s tests/test_babel_service.gd
tools/check_no_class_cache.sh                          # lancement sans réimport : cache de classes périmé ou vide, aucune erreur de script
```

`check_no_class_cache.sh` lance le jeu avec `--dossier-joueur` et `--log-file` dans son dossier
temporaire. Une écriture abandonnée (`<fichier>.partiel`, jeu tué pendant l'écriture) est retirée
au lancement suivant. Les fichiers du joueur (épingles, quête en cours, livre emporté) vont dans `user://`, ou dans le
dossier donné après `--` par `--dossier-joueur=<dossier>` (`QuestScript.user_dir`) : chaque test
qui crée le monde ou le Hud prend le sien (`user://essai_…`) et le retire en sortant ; les fichiers
du joueur ne sont jamais touchés. `test_world` relance le monde sur les mêmes fichiers (quête et
livre emporté gardés), tape les invocations par `push_input` dans la vraie scène, et lance en
sous-processus `tests/exit_scene.gd` (la scène principale, puis la fenêtre fermée comme par le
joueur) : aucune ligne « ERROR » à la sortie. Le premier pas juste après un saut (retenue sur
toute la coordonnée comprise) est mesuré tel quel, sans attente.

Les scripts de `scripts/` se référencent par `preload` (`const QuestScript := preload("res://scripts/quest.gd")`)
et non par leur `class_name` : le jeu se lance ainsi après un `pull` sans `--import`, avant que
`.godot/global_script_class_cache.cfg` connaisse les nouvelles classes. `tools/check_no_class_cache.sh`
le vérifie sur une copie du projet (cache périmé puis cache vide, scène principale ~120 images).

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

## Catalogue des quêtes

`data/quetes/catalogue.bcat` (métadonnées des œuvres, adresse de chaque livre et SHA-256 de ses
pages, aucun texte) est écrit par `tools/make_catalogue.py` sous une forme compacte : les
coordonnées de ~656 000 chiffres, qui partagent presque toutes leurs chiffres de tête, y sont
écrites par différence, et le JSON compressé (deflate) ; 0,90 Mo au lieu de 22,3 Mo, relu en
~0,2 s, la même structure en mémoire. Les épingles du joueur (`user://quetes_epinglees.json`)
s'enregistrent sous la même forme. `python3 tools/make_catalogue.py --from <catalogue>` récrit un
catalogue existant (livres relus à leur adresse, aller-retour vérifié).

## Secrets (développeurs)

Rien de ce qui suit n'apparaît dans le jeu (aucune aide, aucun indice à l'écran) : c'est le
fonctionnement, pour qui développe.

- **Le carnet.** La touche physique sous Échap (« ² » en AZERTY, « ` » en QWERTY,
  `Carnet.CARNET_KEY`) ouvre une page blanche où l'on écrit un mot dans l'alphabet de la
  Bibliothèque ; espace ou Entrée le referme. Un mot qui n'est pas une invocation valable ici
  s'efface en fondu (`Carnet.INVOCATIONS`, `Hud.can_invoke`). Échap ferme le carnet.
- **« aleph »** (avec une quête) : le bibliothécaire est porté par les vestibules jusqu'à
  l'hexagone du livre de la quête, au même niveau. **« zahir »** (avec une quête) : par le puits
  jusqu'au niveau du livre, au même hexagone. Sans quête, le mot s'efface.
- **« tlon »** (seulement en lisant : lecteur ouvert, ou carnet ouvert par-dessus) : le livre lu
  est emporté. Le bibliothécaire en porte un au plus : en emporter un autre rend le précédent à
  sa place. Le livre emporté est gardé d'une session à l'autre (`user://livre_emporte.json`, ~0,8 Mo
  à 917 000 chiffres, écrit sur un fil du moteur puis renommé d'un coup) et
  laisse un vide sur son étagère tant qu'il n'est pas rendu. La touche du carnet, carnet ouvert,
  ouvre le livre emporté dans le lecteur. Proposé, en attente de confirmation :
  `main.gd` `RETURN_CARRIED_ON_TLON` (vrai) — « tlon » en relisant le livre emporté le rend à sa
  place ; faux, rien ne se passe.
- **« sator »** : la galerie du livre du carré Sator (`destinations.sator` du catalogue), face à
  son mur, le livre ouvert à la page du carré. **« golem »** : le livre du commentaire de Rachi
  (`destinations.golem`, rempli plus tard) ; tant que la destination est vide, le mot s'efface.
- Un déplacement est un saut instantané (`place_origin`, galeries reconstruites) caché par un
  fondu au noir (0,2 s à l'aller, 0,2 s au retour) ; le bibliothécaire garde son orientation (et sa
  place dans la galerie), sauf pour « sator » et « golem ». Le bibliothécaire reste immobile tant
  qu'une raison le retient (`Player.hold` : saut, lecteur, panneau, carnet), dans tout ordre ; un
  saut invoqué pendant un autre part, à sa fin, de la galerie d'arrivée ; une invocation qui ne vaut
  plus à son tour (quête effacée entre-temps) s'oublie et la suivante part : un mot tapé, un
  atterrissage au plus. Coût sur le fil principal, au noir, à
  ~917 000 chiffres (test_world) : « aleph » et « zahir » ~30 à 60 ms, « sator » ~0,23 s (livre
  jamais ouvert compris).

## Organisation

- `scripts/main.gd` : tirage de la galerie, entretien des galeries voisines (degrés de détail, part réelle des lampes), entrées, environnement.
- `scripts/gallery.gd` : construction d'une galerie (géométrie, étagères, livres en MultiMesh, lampes), nuanceur de lumière commun, réserve d'éléments réutilisés, et repérage du livre visé.
- `scripts/far_view.gd` : anneaux du puits au loin et trompe-l'œil aux quatre bouts.
- `scripts/book_spine.gd` : titres des dos (tirage, capitales, codage de la texture des titres d'une galerie, atlas des glyphes).
- `scripts/ambient_speaker.gd` : haut-parleurs de la musique d'ambiance, horloge commune.
- `scripts/player.gd` : déplacement à la première personne et rayon de visée.
- `scripts/book_text.gd` : texte des pages.
- `scripts/reader.gd` : fenêtre de lecture.
- `scripts/hud.gd` : adresse, réticule, livre visé, encart et panneau de quête, quête gardée.
- `scripts/carnet.gd` : le carnet (invocations).
- `scripts/quest.gd` : quête, guidage, catalogue, épingles, fichiers du joueur.
