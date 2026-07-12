# 📊 Portfolio Tracker

Dashboard [Quarto](https://quarto.org/) en R pour suivre un portefeuille d'actions et d'ETF :
valorisation au dernier cours, plus/moins-values latentes, allocation sectorielle et
évolution de la valeur dans le temps. Les cours sont récupérés gratuitement sur
Yahoo Finance via [`tidyquant`](https://business-science.github.io/tidyquant/) (aucune clé API nécessaire).

Le portefeuille d'exemple contient **10 lignes** : 7 actions du CAC 40
(Air Liquide, Airbus, BNP Paribas, LVMH, Sanofi, Schneider Electric,
TotalEnergies) et 3 ETF UCITS (Amundi MSCI World CW8, BNP Paribas Easy S&P 500
ESE, Amundi PEA MSCI Emergents PAEEM).

## 📑 Les onglets

- **📊 Vue d'ensemble** — valorisation, allocation, évolution, détail des positions
- **📚 Théorie** — le MEDAF (CAPM) avec formules et exemples, les ratios
  (volatilité, Sharpe, Sortino, drawdown, VaR/CVaR, alpha/bêta) et la frontière
  efficiente de Markowitz
- **📈 Performance** — base 100 vs CAC 40 et MSCI World, rendements mensuels,
  contribution de chaque ligne
- **⚠️ Risque** — indicateurs (vol, Sharpe, Sortino, VaR, drawdown), corrélations,
  MEDAF appliqué ligne par ligne (bêta/alpha vs CAC 40), frontière efficiente
  simulée (4 000 portefeuilles Monte Carlo) avec votre allocation positionnée
- **🛡️ Couverture** — les options comme assurance de portefeuille : put
  protecteur, covered call et collar avec diagrammes de payoff appliqués à la
  valeur réelle du portefeuille, dimensionnement bêta-ajusté d'une couverture
  indicielle, scénarios types (vacances, crainte de krach…)

Paramètres ajustables en tête du chunk `setup` d'`index.qmd` : taux sans risque
(`taux_sans_risque`, 3 % par défaut), indice de marché (`indice_marche`, CAC 40),
strikes et primes indicatives des options.

## 🚀 Démarrage rapide

Prérequis : [R](https://cran.r-project.org/) (≥ 4.2) et [Quarto](https://quarto.org/docs/get-started/) (≥ 1.4).

```r
# Dans R : installer les dépendances (une seule fois)
install.packages(c("tidyverse", "tidyquant", "plotly", "DT"))
```

```bash
# Dans un terminal, à la racine du projet
quarto preview        # rendu + rechargement automatique dans le navigateur
# ou
quarto render         # génère le dashboard statique dans docs/
```

## ✏️ Personnaliser le portefeuille

Tout se passe dans **`portfolio.csv`** — une ligne par position :

| Colonne      | Description                                                                 |
|--------------|-----------------------------------------------------------------------------|
| `ticker`     | Ticker **Yahoo Finance** (`MC.PA` pour LVMH, `CW8.PA` pour l'ETF World…)     |
| `nom`        | Libellé affiché dans le dashboard                                            |
| `type`       | `Action` ou `ETF`                                                            |
| `secteur`    | Secteur libre, utilisé pour le treemap d'allocation                          |
| `quantite`   | Nombre de titres détenus                                                     |
| `date_achat` | Date d'achat au format `AAAA-MM-JJ`                                          |
| `pmu`        | Prix moyen unitaire d'achat en €. **Optionnel** : si vide, le cours de clôture du premier jour coté après `date_achat` est utilisé |

Remplacez les lignes d'exemple par vos vraies positions, puis relancez `quarto render`.

> ⚠️ Ce dépôt est public : n'y mettez vos positions réelles qu'en connaissance de cause.

## 🗂️ Structure du projet

```
├── _quarto.yml      # configuration du projet Quarto (sortie dans docs/)
├── index.qmd        # le dashboard (page « Vue d'ensemble »)
├── portfolio.csv    # les positions du portefeuille
└── docs/            # sortie HTML générée (non versionnée)
```

## 🗺️ Feuille de route

- [x] **v1 — Vue d'ensemble** : valueboxes (valeur, +/- value, perf YTD), treemap
  sectoriel, répartition Actions/ETF, courbe de valeur, tableau des positions
- [x] **v2 — Théorie, Performance, Risque, Couverture** : MEDAF, ratios et
  frontière efficiente (théorie + application aux 10 lignes), benchmark,
  corrélations, VaR, drawdown, stratégies de couverture par options
- [ ] **v3 — Publication automatique** : GitHub Action quotidienne qui re-génère le
  dashboard à la clôture des marchés et le publie sur GitHub Pages

## ⚠️ Avertissements

- Projet **pédagogique** : ce dashboard n'est pas un conseil en investissement.
- Les cours Yahoo Finance sont fournis avec un différé et sans garantie d'exactitude.
- La composition du CAC 40 évolue à chaque revue trimestrielle d'Euronext
  (prochaine revue : juin 2026) — pensez à mettre à jour `portfolio.csv`.
