# 🌤️ Météo Villes

**Auteur : Alban VIDELOUP**

[![Publier Météo Villes](https://github.com/albanpjy/fin/actions/workflows/publish-meteo.yml/badge.svg)](https://github.com/albanpjy/fin/actions/workflows/publish-meteo.yml)

**🌐 Dashboard en ligne : <https://albanpjy.github.io/fin/meteo/>** —
régénéré automatiquement chaque jour à 5h30 UTC par une GitHub Action, et à
chaque push sur ce dossier.

Dashboard [Quarto](https://quarto.org/) en R qui présente chaque jour la météo
de cinq villes :

- Rueil-Malmaison (92)
- Granville (50)
- Servon (50170)
- Rennes (35)
- Casablanca (Maroc)

pour le jour même et les 15 jours suivants, avec un historique construit sur
la plus longue période disponible (réanalyses ERA5, depuis 1940).

## Données

Toutes les données viennent d'[Open-Meteo](https://open-meteo.com/) (API
gratuite, sans clé, licence CC BY 4.0) :

- **prévisions** (jour même + 15 jours) via l'API `forecast`, complétée par
  7 jours récemment observés pour raccorder l'historique sans trou ;
- **historique** via l'API `archive` (réanalyses ERA5), depuis le
  1er janvier 1940 — la durée maximale disponible chez ce fournisseur.

Les coordonnées des cinq villes sont fixées à l'avance dans
[`villes.csv`](villes.csv) plutôt que géocodées par nom à chaque rendu : une
recherche par nom serait ambiguë pour une commune homonyme (plusieurs communes
françaises s'appellent Servon — le code postal 50170 désigne sans ambiguïté
celle de la Manche, près du Mont-Saint-Michel).

## Indicateurs

- température, ressenti (température apparente : combine température,
  humidité et vent), humidité (agrégée depuis la série horaire, Open-Meteo ne
  fournissant pas d'agrégat quotidien natif), vent, indice UV ;
- écart à la normale saisonnière : comparaison de la prévision du jour à la
  moyenne historique du même jour de l'année (± 7 jours, toutes années
  confondues depuis 1940) ;
- records de chaleur et de froid par ville, et tendance annuelle des
  températures maximales depuis 1940.

## Architecture

- [`R/pipeline_meteo.R`](R/pipeline_meteo.R) — source unique des données et
  des calculs (lecture des villes, appels API, indicateurs), chargée par
  `index.qmd` ;
- [`index.qmd`](index.qmd) — le dashboard HTML (format `dashboard`,
  orientation `rows`, plotly/DT/ggplot2) ;
- [`villes.csv`](villes.csv) — la liste des villes suivies, avec leurs
  coordonnées géographiques.

Comme pour le Portfolio Tracker, un cache quotidien local
(`cache_meteo.rds`, gitignoré) évite de solliciter Open-Meteo à chaque
aperçu local le même jour pour les prévisions ; en cas de panne réseau, un
vieux cache sert de repli avec un avertissement.

L'historique (86 ans × 5 villes) fonctionne différemment : le retélécharger
en entier à chaque rendu saturerait vite l'API gratuite (observé en
pratique : rate-limit après deux rendus rapprochés). Il est donc mis en
cache dans [`historique.rds`](historique.rds), **committé dans le dépôt** et
mis à jour de façon incrémentale par le workflow — chaque rendu ne demande
que les jours manquants depuis la dernière fois (généralement 0 à quelques
jours), avec retry/backoff (`req_retry`, `req_throttle`) sur les appels
Open-Meteo pour absorber les erreurs transitoires (429/5xx).

## Commandes

```bash
cd meteo
quarto preview      # rendu + rechargement auto dans le navigateur
quarto render       # génère le HTML statique dans meteo/docs/ (non versionné)
```
