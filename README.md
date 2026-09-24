# linkpearl-sync.github.io

Page de présentation de [Linkpearl Sync](https://github.com/LinkPearl-Sync/linkpearl-sync-plugin),
servie par GitHub Pages sur <https://linkpearl-sync.github.io/>.

Une seule page statique, sans outil de construction : `index.html` et ses images dans `assets/`.
Pousser sur `main` publie, par GitHub Actions.

- `assets/banner.png` et `assets/logo.png` sont des copies de
  `Linkpearl/Assets/Images/banner.png` et `Plugin_Logo.png` du dépôt du plugin : les recopier
  si ceux-là changent.
- `repo.json`, le dépôt Dalamud servi sur <https://linkpearl-sync.github.io/repo.json>, n'est
  pas dans ce dépôt : `.github/workflows/pages.yml` le reprend du dépôt du plugin à chaque
  déploiement. La publication du plugin déclenche ce workflow, et un passage horaire rattrape
  un déclenchement manqué.

Aperçu local : `python3 -m http.server` puis <http://localhost:8000> (sans `repo.json`).
