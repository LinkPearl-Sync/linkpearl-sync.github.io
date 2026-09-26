# linkpearl-sync.github.io

Page de présentation de [Linkpearl Sync](https://github.com/LinkPearl-Sync/linkpearl-sync-plugin),
servie par GitHub Pages sur <https://linkpearl-sync.github.io/>.

Des pages statiques, sans outil de construction : `index.html` (l'accueil), `expert.html` (le
fonctionnement, la fédération et le guide d'auto-hébergement), `reseau.html` (l'état du cercle
ouvert) et leurs images dans `assets/`.
Pousser sur `main` publie, par GitHub Actions.

`expert.html` et `reseau.html` n'existent qu'en anglais et en français, comme les README du plugin : un texte
technique mal traduit induirait en erreur. Elles décrivent l'état du code publié ; les relire quand
le plugin ou le rendez-vous change de comportement (connexion, relais, options de `lprdv`).

- `assets/banner.png` et `assets/logo.png` sont des copies de
  `Linkpearl/Assets/Images/banner.png` et `Plugin_Logo.png` du dépôt du plugin : les recopier
  si ceux-là changent.
- `repo.json`, le dépôt Dalamud servi sur <https://linkpearl-sync.github.io/repo.json>, n'est
  pas dans ce dépôt : `.github/workflows/pages.yml` le reprend du dépôt du plugin à chaque
  déploiement. La publication du plugin déclenche ce workflow, et un passage horaire rattrape
  un déclenchement manqué.
- `reseau.json`, l'état public du cercle ouvert que `reseau.html` affiche, n'est pas dans ce
  dépôt non plus : le même workflow le demande à l'autorité (`rdv.linkpearl.eorzea.events`,
  trame `NetworkStatusQuery`) par `scripts/reseau.py`, en Python standard. Si l'autorité ne
  répond pas, il reprend l'instantané déjà publié ; sans l'un ni l'autre, la page dit que
  l'état est indisponible. Essai local : `python3 scripts/reseau.py reseau.json`.

- La page existe dans les quatre langues du client de FFXIV (ja, en, de, fr). Les textes sont
  dans l'objet `T` du script de `index.html` ; le HTML statique porte l'anglais, qui sert aussi
  aux aperçus de lien. Langue retenue : `#ja` dans l'adresse, sinon le dernier choix, sinon celle
  du navigateur, sinon l'anglais.

Aperçu local : `python3 -m http.server` puis <http://localhost:8000> (sans `repo.json`).
