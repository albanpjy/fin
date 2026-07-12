# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Le projet

Portfolio Tracker : dashboard Quarto en R qui valorise un portefeuille d'actions
et d'ETF (les 40 valeurs du CAC 40 + 4 ETF UCITS) à partir des cours Yahoo Finance.
Projet et conversation utilisateur **en français** : interface du dashboard,
README, messages de commit et échanges se font en français.

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
Yahoo Finance** ; dans un environnement sans réseau (conteneur distant), on peut
au moins vérifier la syntaxe des chunks R en les extrayant de `index.qmd` et en
les passant à `parse(text = ...)` avec `Rscript` (R seul suffit, sans les packages).

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
5. `valeur_quotidienne` — série journalière de la valeur totale depuis le
   dernier achat (pivot large + `fill()` pour reporter le dernier cours connu
   les jours sans cotation), base du graphique d'évolution et de la perf YTD.

Conventions d'affichage : helpers `eur()` / `pct()` pour le format français
(espace des milliers, virgule décimale) ; graphiques en `plotly`, tableaux en `DT`.

Dans le format dashboard de Quarto, chaque titre `# Niveau 1` est un onglet/page
(actuellement une seule page « Vue d'ensemble ») — c'est le mécanisme prévu pour
les pages Performance et Risque de la v2.

## Données

- Tickers au format **Yahoo Finance** (suffixe `.PA` Paris, `.AS` Amsterdam —
  ArcelorMittal est `MT.AS`). En cas de ligne écartée au rendu, suspecter
  d'abord un ticker d'ETF renommé (fusions de gammes Amundi/Lyxor).
- La composition du CAC 40 dans `portfolio.csv` date du 22/12/2025 (entrée
  d'Eiffage, sortie d'Edenred) ; elle évolue à chaque revue trimestrielle
  d'Euronext (mars, juin, septembre, décembre).

## Feuille de route (README)

- v2 : pages Performance (benchmark, rendements mensuels) et Risque
  (volatilité, drawdown, Sharpe, corrélations)
- v3 : GitHub Action quotidienne qui re-rend le dashboard et publie `docs/`
  sur GitHub Pages
