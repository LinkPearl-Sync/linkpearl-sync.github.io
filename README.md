# linkpearl-sync.github.io

Page de présentation de [Linkpearl Sync](https://github.com/LinkPearl-Sync/linkpearl-sync-plugin),
servie par GitHub Pages sur <https://linkpearl-sync.github.io/>.

Des pages statiques, sans outil de construction :

- `index.html`, l'accueil ;
- `expert.html`, le fonctionnement (connexion, chiffrement, transferts, ce que voit un service,
  fédération) et le guide d'auto-hébergement pas à pas ;
- `reseau.html`, l'état du cercle ouvert ;
- `heberger.html`, le générateur de la commande d'installation d'un service ;
- `install.sh`, le script que cette commande lance ;
- leurs images dans `assets/`.

## Langues

L'accueil existe dans les quatre langues du client de FFXIV (ja, en, de, fr). Ses textes sont
dans l'objet `T` de son script ; le HTML statique porte l'anglais, qui sert aussi aux aperçus de
lien.

`expert.html`, `reseau.html` et `heberger.html` n'existent qu'en anglais et en français, comme
les README du plugin : un texte technique mal traduit induirait en erreur. En allemand ou en
japonais, seuls le menu et un avis sont traduits, et la page s'affiche en anglais.

Toutes les pages choisissent la langue de la même façon : `#ja` dans l'adresse, sinon le
dernier choix (clé `lang` du stockage local, commune aux quatre pages), sinon la langue du
navigateur, sinon l'anglais.

## Ce qui doit suivre les autres dépôts

Ces pages, `install.sh` compris, décrivent l'état du code publié. Les relire quand le plugin ou
le rendez-vous change de comportement : connexion, relais, options de `lprdv`, fichiers joints à
une release.

`assets/banner.png` et `assets/logo.png` sont des copies de `Linkpearl/Assets/Images/banner.png`
et `Linkpearl/Assets/Images/logo.png` du dépôt du plugin (le second est aussi `Plugin_Logo.png`
à sa racine) : les recopier si ceux-là changent.

## Publication

`.github/workflows/pages.yml` assemble et publie le site. Il tourne à chaque push sur `main`, à
la demande de la publication du plugin (`gh workflow run`, avec le secret `SITE_DISPATCH_TOKEN`
du dépôt du plugin), et chaque heure à la minute 17, pour rattraper un déclenchement manqué.

- **`repo.json`**, le dépôt Dalamud servi sur <https://linkpearl-sync.github.io/repo.json>,
  n'est pas dans ce dépôt : le workflow le reprend du dépôt du plugin. Il vérifie d'abord que
  c'est un tableau non vide dont chaque entrée a `InternalName`, `AssemblyVersion` et
  `DownloadLinkInstall` ; sinon le déploiement échoue et l'ancien reste en ligne.
- **`reseau.json`**, l'état public du cercle ouvert que `reseau.html` affiche, n'y est pas non
  plus : `scripts/reseau.py`, en Python standard, le demande à l'autorité
  (`rdv.linkpearl.eorzea.events:47900`, trame `NetworkStatusQuery`). Si l'autorité ne répond
  pas ou répond de travers, il reprend l'instantané déjà publié ; sans l'un ni l'autre, il
  n'écrit rien, le reste du site part quand même et la page dit l'état indisponible. Elle
  signale aussi un instantané de plus de trois heures.
- Seuls `*.html`, `install.sh`, `assets/` et `.nojekyll` sont publiés : un nouveau fichier à la
  racine doit être ajouté à la ligne `cp` de `pages.yml`.

## Le script d'installation

`install.sh` installe ou met à jour un service de rendez-vous en une commande :

```sh
curl -fsSL https://linkpearl-sync.github.io/install.sh | sudo bash -s -- [options]
```

Il prend la dernière release du rendez-vous et la vérifie par `lprdv.sha256`, qui couvre le
binaire et les trois unités systemd ; rien n'est posé si une somme ne correspond pas. Il crée le
compte `lprdv`, pose l'unité générique et écrit les options du service dans un complément,
`/etc/systemd/system/lprdv.service.d/options.conf`. Il ne touche jamais à `/var/lib/lprdv`. Il
exige Linux x86-64, systemd, curl et sha256sum.

- `--port N` (47900 par défaut ; 47901, celui de la console, est refusé), `--public-address
  NOM[:port]`, `--label TEXTE` (64 octets UTF-8, sans `"` `\` `$` `%` ni accent grave),
  `--no-announce` : les options de configuration. L'une d'elles réécrit tout le complément, et
  les options omises reprennent leur valeur par défaut. Relancé sans aucune, il met à jour le
  binaire et les unités et garde le complément tel quel.
- `--no-firewall` : sinon, il ouvre le port dans ufw ou firewalld s'ils sont actifs.
- La mise à jour automatique (`lprdv-update.timer`, chaque heure, décalée au hasard jusqu'à une
  heure) est posée et activée. `--no-auto-update` la coupe sans toucher aux options du service,
  `--auto-update` la rallume. Relancé sans option, il garde le choix déjà fait ; une
  installation d'avant le minuteur le reçoit actif. Avec une option de configuration mais sans
  aucune des deux, il la rallume : c'est pourquoi `heberger.html` écrit toujours l'une ou
  l'autre.
- `LPRDV_RELEASES` remplace l'adresse des releases, pour un essai.

Les règles de validation sont les mêmes dans `install.sh` et `heberger.html` (le bloc
commenté de chacun) : en changer une, c'est changer l'autre.

`.github/workflows/install.yml` passe `shellcheck`, puis exécute le script pour de vrai, avec
systemd et sudo, sur un runner jetable : refus des options invalides, première installation,
unité de mise à jour lancée sous systemd, relance sans option, mise à niveau d'une installation
sans minuteur, minuteur coupé puis rallumé. Il tourne à chaque push ou pull request qui touche
`install.sh` ou le workflow, à la demande, et chaque lundi, parce que la dernière release du
rendez-vous peut changer sans que ce dépôt bouge. Une modification de `heberger.html` seule ne
le lance pas.

## Aperçu local

`python3 -m http.server` puis <http://localhost:8000>. `repo.json` y manque, sans effet sur les
pages. `reseau.json` aussi : `reseau.html` dit alors l'état indisponible, sauf après
`python3 scripts/reseau.py reseau.json [HÔTE [PORT]]` à la racine (le fichier est ignoré par
git).
