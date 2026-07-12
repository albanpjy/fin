# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Le projet

Portfolio Tracker : dashboard Quarto en R qui valorise et analyse un portefeuille
d'actions et d'ETF (**10 lignes maximum** — contrainte voulue par l'utilisateur :
7 actions CAC 40 + 3 ETF UCITS) à partir des cours Yahoo Finance. Cinq pages :
Vue d'ensemble, Théorie (MEDAF, ratios, frontière efficiente — pédagogique),
Performance, Risque, Couverture (options). Projet et conversation utilisateur
**en français** : interface du dashboard, README, messages de commit et échanges
se font en français.

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
Pages (<https://albanpjy.github.io/claude/>) : sur push (`main` et la branche de
session), chaque jour ouvré à 18 h UTC (cron), et manuellement
(`workflow_dispatch`). Points d'attention :

- le cron s'exécute sur le **workflow de la branche par défaut** du dépôt ;
- Pages est activé par le workflow lui-même (`actions/configure-pages` avec
  `enablement: true`) — pas de réglage manuel requis ;
- les packages R viennent en binaire de Posit RSPM (`use-public-rspm`) et sont
  mis en cache (`actions/cache` sur `R_LIBS_USER`) ; `rmarkdown` est requis en
  plus des packages du dashboard pour que Quarto exécute les chunks R.

## Architecture

Tout le dashboard tient dans `index.qmd` (format `dashboard` de Quarto,
orientation `rows`) ; `portfolio.csv` est l'unique source de données, une ligne
par position. La sortie va dans `docs/` (configuré dans `_quarto.yml`, ignoré
par git — destiné à GitHub Pages en v3).

Le chunk `setup` de `index.qmd` construit un pipeline dont les objets sont
réutilisés par tous les chunks d'affichage :

1. `portfolio` — lecture du CSV (types explicites via `col_types`, ne pas retirer :
   la colonne `pmu` souvent vide serait sinon parsée en logique) ;
2. `prices` — historique `tq_get()` de tous les tickers depuis le plus ancien
   achat ; les `close` NA sont filtrés immédiatement ;
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

- Tickers au format **Yahoo Finance** (suffixe `.PA` Paris, `.AS` Amsterdam —
  ArcelorMittal est `MT.AS`). En cas de ligne écartée au rendu, suspecter
  d'abord un ticker d'ETF renommé (fusions de gammes Amundi/Lyxor).
- Les 7 actions de `portfolio.csv` appartiennent au CAC 40 (composition du
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
