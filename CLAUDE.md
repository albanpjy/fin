# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Le projet

Portfolio Tracker : dashboard Quarto en R qui valorise et analyse un portefeuille
d'actions, d'ETF et d'OPCVM (**10 lignes maximum** — contrainte voulue par
l'utilisateur : 4 actions CAC 40, 5 ETF UCITS, 1 OPCVM) à partir des cours
Yahoo Finance. Cinq pages :
Vue d'ensemble, Théorie (MEDAF, ratios, frontière efficiente — pédagogique),
Performance, Risque, Couverture (options). **Auteur : Alban VIDELOUP** (champ
`author` du qmd, README, avertissement de l'onglet Couverture). Projet et
conversation utilisateur **en français** : interface du dashboard, README,
messages de commit et échanges se font en français. Style de code voulu par
l'auteur : **commentaires pédagogiques abondants** dans index.qmd (chaque
section du setup et chaque chunk d'affichage expliqués) — les préserver lors
des modifications.

Le dépôt est en cours de renommage `claude` → `fin` (branche de travail `fin`,
liens et badge déjà mis à jour) ; le renommage du dépôt lui-même se fait par
l'utilisateur dans Settings → General. URL de publication cible :
<https://albanpjy.github.io/fin/>. GitHub redirige automatiquement les anciens
liens/remotes après renommage.

## Commandes

```bash
quarto preview      # rendu + rechargement auto dans le navigateur
quarto render       # génère le HTML statique dans docs/ (non versionné)
```

```r
# Dépendances R (une seule fois)
install.packages(c("tidyverse", "tidyquant", "plotly", "DT"))
```

Il n'y a ni tests ni linter. Le rendu complet **nécessite un accès réseau à
Yahoo Finance** au premier rendu du jour ; les cours sont ensuite mis en cache
dans `cache_cours.rds` (gitignoré, invalidé au changement de date — supprimer le
fichier pour forcer un rafraîchissement ; en cas de panne réseau, le cache
périmé sert de repli avec un warning). Dans un environnement sans réseau
(conteneur distant), on peut au moins vérifier la syntaxe des chunks R en les
extrayant de `index.qmd` et en les passant à `parse(text = ...)` avec `Rscript`
(R seul suffit, sans les packages).

## Publication automatique (v3)

`.github/workflows/publish.yml` rend le dashboard et le déploie sur GitHub
Pages via la branche `gh-pages` (Pages configuré en « Deploy from a branch ») :
sur push (`main` et `fin`), chaque jour ouvré à 18 h UTC (cron), et manuellement
(`workflow_dispatch`). Points d'attention :

- le cron s'exécute sur le **workflow de la branche par défaut** du dépôt ;
- l'activation initiale de Pages a été faite à la main par l'utilisateur
  (Settings → Pages → Deploy from a branch → `gh-pages`) : le jeton du workflow
  n'a pas les droits d'administration nécessaires (`enablement: true` échoue en
  « Resource not accessible by integration ») ;
- les packages R viennent en binaire de Posit RSPM (`use-public-rspm`) et sont
  mis en cache (`actions/cache` sur `R_LIBS_USER`) ; `rmarkdown` est requis en
  plus des packages du dashboard pour que Quarto exécute les chunks R ;
- **TinyTeX est aussi mis en cache** (`actions/cache` sur `~/.TinyTeX`, clé
  indexée sur `rapport.qmd` + `restore-keys`) : après le premier run les paquets
  LaTeX sont restaurés en quelques secondes, ce qui accélère le rendu et évite
  les aléas de téléchargement (`no matching packages`). Bumper la clé si un
  besoin LaTeX change et que le cache doit repartir de zéro.

## Architecture

Deux documents Quarto partagent un même pipeline de calculs :

- **`R/pipeline.R`** — LA source unique des données et calculs (sections
  commentées 1 à 11), chargée par `source(..., encoding = "UTF-8")` depuis les
  deux qmd. Toute évolution de calcul se fait ici, jamais en double ;
- **`index.qmd`** — le dashboard HTML (format `dashboard`, orientation `rows`,
  plotly/DT) ; son setup ne contient que les échelles plotly (`scale_seq`,
  `scale_div`, `ligne_v`) ;
- **`rapport.qmd`** — le rapport PDF quotidien : LaTeX KOMA (`scrartcl`,
  `DIV=11`, microtype), `lang: fr` (typographie française), graphiques
  **ggplot2** statiques (dev `cairo_pdf` pour l'UTF-8), tableaux
  `knitr::kable(booktabs = TRUE)`. Pas d'emoji dans le texte du PDF (LaTeX).
  Le bouton « Rapport PDF » de la barre du dashboard pointe vers `rapport.pdf` ;
- `_quarto.yml` impose l'ordre de rendu `index.qmd` puis `rapport.qmd` :
  le premier télécharge et met en cache les cours, le second réutilise le
  cache (mêmes données garanties dans les deux documents).

`portfolio.csv` est l'unique source de données, une ligne par position. La
sortie va dans `docs/` (ignoré par git). Le workflow archive en plus chaque
jour ouvré une copie horodatée du PDF dans `exports/`
(`portfolio-tracker_AAAA-MM-JJ.pdf`), commitée sur `main` avec `[skip ci]`
dans le message pour éviter une boucle de déclenchements ; le rendu CI installe
TinyTeX via `quarto-actions/setup` (`tinytex: true`). ⚠️ Ne jamais écrire la
chaîne « [skip ci] » dans un message de commit ordinaire (même pour la citer) :
GitHub scanne le message entier et saute alors le workflow.

Le pipeline (`R/pipeline.R`) construit les objets réutilisés par tous les
chunks d'affichage :

1. `portfolio` — lecture du CSV (types explicites via `col_types`, ne pas retirer :
   la colonne `pmu` souvent vide serait sinon parsée en logique) ; un `warning`
   pédagogique se déclenche au-delà de 10 lignes ;
2. `prices` — historique `tq_get()` de tous les tickers depuis le plus ancien
   achat ; les `close` NA sont filtrés immédiatement ; l'horodatage du
   téléchargement est conservé (`horodatage_donnees`, stocké dans le cache via
   `telecharge_le`) et affiché en tête de la Vue d'ensemble (`info_donnees`,
   heure de Paris + date de dernière clôture). Les tickers absents de Yahoo
   sont scindés en `lignes_manuelles` (un `cours_manuel` est saisi dans le CSV
   → OPCVM non coté, ex. `FR0010036962.PA`) et `vrais_manquants` (écartés avec
   warning). Une **ligne manuelle** est valorisée à la main (colonne
   `manuelle` de `positions`, `cours` ← `cours_manuel`), comptée dans le
   patrimoine/allocations mais **exclue des analyses à historique** (elle
   n'existe pas dans `prices`, donc `positions_cotees` = `!manuelle` pilote
   `prix_larges`, `rendements`, `medaf`, frontière). Sa valeur constante est
   réinjectée dans `valeur_quotidienne` (`valeur_manuelle`) pour que courbe et
   total coïncident ; `note_manuelles` l'explicite dans les deux documents ;
3. prix de revient : si `pmu` est vide dans le CSV, il est calculé comme le
   cours de clôture du premier jour coté suivant `date_achat` (fonction
   `premier_cours_apres`) — c'est un contrat documenté dans le README ;
4. `positions` — valorisation au dernier cours ; toute position non valorisable
   (cours ou PMU manquant) est **écartée avec un `warning`** plutôt que de
   propager des NA dans les totaux, et la valuebox « Lignes valorisées » signale
   l'écart. Préserver ce comportement défensif : les données Yahoo sont
   régulièrement incomplètes (jour de cotation partiel, ticker renommé) et un NA
   non filtré fait planter les `if` des valueboxes ;
5. `prix_larges` / `valeur_quotidienne` — matrice large des cours depuis le
   dernier achat (pivot + `fill()` pour reporter le dernier cours connu les
   jours sans cotation) et série journalière de la valeur totale ;
6. `bench` — l'indice de marché (`indice_marche`, `^FCHI` par défaut) pour le
   MEDAF et la comparaison base 100, avec **repli sur CW8.PA** si Yahoo ne
   renvoie rien pour l'indice ;
7. `rendements`, `r_pf`, `r_bench`, `r_joint` — rendements quotidiens (lignes,
   portefeuille, marché) qui alimentent tous les indicateurs : Sharpe, Sortino,
   VaR/CVaR historiques, drawdowns, bêta ;
8. `medaf` — bêta, rendement attendu MEDAF et alpha de Jensen par ligne ;
9. la frontière efficiente : simulation Monte Carlo (`set.seed(42)`, 4 000
   pondérations Dirichlet via `rexp`) sur `mu`/`Sigma` annualisés ;
10. `payoffs` — les profils put protecteur / covered call / collar appliqués à
    `total_valeur` (strikes et primes = constantes indicatives du setup :
    `k_put`, `prime_put`, `k_call`, `prime_call`).

Constante clé : `taux_sans_risque` (3 %) en tête du setup — utilisée par Sharpe,
Sortino, MEDAF et la frontière.

Conventions d'affichage : helpers `eur()` / `pct()` / `num()` pour le format
français (espace des milliers, virgule décimale) ; graphiques en `plotly`,
tableaux en `DT`. Palette (guide dataviz interne) : séries catégorielles dans
l'ordre fixe `#2a78d6` (bleu), `#1baf7a` (aqua), `#eda100` (jaune) ; négatif/perte
`#e34948` ; divergent corrélations bleu↔rouge avec milieu gris `#f0efec` ;
séquentiel (frontière) rampe bleue `#cde2fb`→`#104281`. Réutiliser les variables
`col_*` / `scale_*` du setup plutôt que des hex en dur.

Dans le format dashboard de Quarto, chaque titre `# Niveau 1` est un onglet/page ;
les pages riches en texte (Théorie, Couverture) utilisent `{scrolling="true"}` et
des cartes markdown `::: {.card title="…"}` avec formules LaTeX (`$$…$$`).
Attention : pas de `#| title: !expr` (fragile) — pour un titre dynamique de
valuebox, passer `title` dans la liste retournée par le chunk.

Vérification sans réseau : en plus du parse-check, un smoke-test du pipeline
complet sur cours simulés est possible avec le seul package `tidyverse`
(binaire Ubuntu `r-cran-tidyverse`) en remplaçant `tq_get()` par un générateur
de marches aléatoires — voir l'historique de session si besoin de le recréer.

## Données

- Tickers au format **Yahoo Finance** (suffixe `.PA` Paris, `.AS` Amsterdam).
  Vérifiés le 13/07/2026 via une étape CI de diagnostic (`tq_get` sur des
  candidats) : `EWLDA.PA` **n'existe pas** sur Yahoo → on utilise `EWLD.PA`
  (Amundi MSCI World, part Dist) ; `CW8/DCAM/PSPS/PAEEM.PA` OK. L'OPCVM **Atout
  Vert Horizon n'est coté sous aucune forme sur Yahoo** (`FR0010036962.PA`,
  `F0GBR067L3.PA`, `0P00000LU4.F` → tous vides) : d'où le mécanisme
  `cours_manuel`. En cas de ligne écartée au rendu, suspecter d'abord un ticker
  d'ETF renommé (fusions de gammes Amundi/Lyxor) et refaire ce diagnostic.
- Les actions de `portfolio.csv` appartiennent au CAC 40 (composition du
  22/12/2025) ; l'indice évolue à chaque revue trimestrielle d'Euronext (mars,
  juin, septembre, décembre). Garder **10 lignes maximum** dans le CSV — les
  onglets d'analyse (corrélations, frontière, MEDAF) sont dimensionnés pour ça.

## Feuille de route (README)

- v1 (fait) : Vue d'ensemble · v2 (fait) : Théorie, Performance, Risque,
  Couverture · v3 (fait) : publication automatique GitHub Pages + cache des cours
- Pistes évoquées avec l'utilisateur pour la suite : journal de transactions
  (`transactions.csv`) avec PMU recalculé, dividendes (`tq_get(get =
  "dividends")`), onglet Rééquilibrage, Black-Scholes dans l'onglet Couverture.
  Refusé pour l'instant : `renv`.
