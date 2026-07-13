# 🗄️ Archives des rapports PDF

Ce dossier reçoit **un rapport PDF par jour de bourse**, déposé automatiquement
par la GitHub Action après la clôture d'Euronext (workflow
`.github/workflows/publish.yml`, étape « Archiver le rapport PDF du jour »).

- Nommage : `portfolio-tracker_AAAA-MM-JJ.pdf`
- Source : le rendu LaTeX de `rapport.qmd` (mêmes données que le dashboard
  du jour, grâce au cache de cours partagé)
- Le commit d'archivage porte la mention `[skip ci]` pour ne pas re-déclencher
  le workflow en boucle.

Le rapport le plus récent est aussi accessible directement depuis le dashboard
en ligne via le bouton « Rapport PDF » : <https://albanpjy.github.io/fin/rapport.pdf>.
