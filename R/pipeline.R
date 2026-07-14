# ==============================================================================
# PORTFOLIO TRACKER — PIPELINE DE DONNÉES ET DE CALCULS
# Auteur : Alban VIDELOUP
#
# Ce fichier est la SOURCE UNIQUE des calculs du projet : il est chargé
# (via source()) à la fois par index.qmd (le dashboard HTML) et par
# rapport.qmd (le rapport PDF quotidien). Toute évolution du portefeuille,
# des indicateurs ou des données se fait ICI, une seule fois.
#
# Le déroulé, dans l'ordre :
#   1. lecture du portefeuille (portfolio.csv)
#   2. récupération des cours (Yahoo Finance, avec cache quotidien)
#   3. calcul des prix de revient (PMU)
#   4. valorisation des positions au dernier cours
#   5. série quotidienne de la valeur du portefeuille
#   6. benchmark (CAC 40) et rendements quotidiens
#   7. indicateurs de risque (volatilité, Sharpe, VaR, drawdown…)
#   8. MEDAF ligne par ligne (bêta, alpha)
#   9. frontière efficiente (simulation Monte Carlo)
#  10. profils de couverture par options (payoffs)
#  11. jeux de données prêts pour les graphiques (base 100, mensuel…)
# ==============================================================================

# ---- Librairies --------------------------------------------------------------
library(tidyverse)   # manipulation de données (dplyr, tidyr) et dates (lubridate)
library(tidyquant)   # tq_get() : téléchargement des cours depuis Yahoo Finance

# ---- Paramètres à ajuster selon vos hypothèses --------------------------------
taux_sans_risque <- 0.03    # taux annuel sans risque (ex. OAT 10 ans). Utilisé
                            # par le ratio de Sharpe, le Sortino, le MEDAF et
                            # la frontière efficiente.
indice_marche    <- "^FCHI" # le « marché » du MEDAF : ^FCHI = CAC 40 sur Yahoo.
                            # Autres exemples : ^STOXX50E (Euro Stoxx 50),
                            # ^GSPC (S&P 500).

# ---- Palette de couleurs (commune au dashboard et au PDF) ---------------------
# Séries catégorielles dans un ordre FIXE (bleu, aqua, jaune), rouge réservé
# aux pertes/valeurs négatives, rampe bleue pour les échelles continues,
# divergent bleu <-> rouge (milieu gris neutre) pour les corrélations.
col_s1 <- "#2a78d6"; col_s2 <- "#1baf7a"; col_s3 <- "#eda100"
col_neg <- "#e34948"; col_muted <- "#898781"; col_ink <- "#0b0b0b"

# ---- Petites fonctions de formatage à la française ----------------------------
# eur(1234.5) -> "1 234 €"   (espace des milliers)
# pct(0.042)  -> "4,2 %"     (virgule décimale)
# num(1.234)  -> "1,23"
eur <- function(x) paste0(format(round(x), big.mark = " ", scientific = FALSE, trim = TRUE), " €")
pct <- function(x) paste0(format(round(100 * x, 1), decimal.mark = ",", trim = TRUE), " %")
num <- function(x, d = 2) format(round(x, d), decimal.mark = ",", trim = TRUE)

# ==============================================================================
# 1. LECTURE DU PORTEFEUILLE
# ==============================================================================
# portfolio.csv est LE fichier à modifier pour personnaliser le projet :
# une ligne par position, avec les colonnes :
#   ticker     : code Yahoo Finance (suffixe .PA = Paris, .AS = Amsterdam)
#   nom        : libellé affiché dans les graphiques
#   type       : "Action" ou "ETF"
#   secteur    : catégorie libre (sert aux graphiques d'allocation)
#   quantite   : nombre de titres détenus
#   date_achat : date d'achat au format AAAA-MM-JJ
#   pmu        : prix moyen d'achat en € — OPTIONNEL : laissé vide, il est
#                remplacé par le cours de clôture qui suit la date d'achat
#   cours_manuel : OPTIONNEL — pour les fonds absents de Yahoo Finance
#                (OPCVM bancaires non cotés) : la dernière valeur liquidative,
#                saisie à la main et à tenir à jour. Une ligne « manuelle »
#                exige aussi un pmu renseigné ; elle est valorisée dans le
#                patrimoine (valueboxes, tableaux, allocations) mais EXCLUE
#                des analyses à historique (évolution, corrélations, MEDAF,
#                frontière), faute de série de cours.
#
# ⚠️ Garder 10 lignes MAXIMUM : les analyses (corrélations, frontière
#    efficiente, MEDAF) sont dimensionnées pour rester lisibles.
#
# Les types de colonnes sont déclarés explicitement (col_types) : sans cela,
# une colonne pmu entièrement vide serait devinée comme logique (TRUE/FALSE)
# et ferait échouer les calculs.
portfolio <- read_csv(
  "portfolio.csv",
  col_types = cols(
    ticker     = col_character(),
    nom        = col_character(),
    type       = col_character(),
    secteur    = col_character(),
    quantite   = col_double(),
    date_achat = col_date(),
    pmu        = col_double(),
    cours_manuel = col_double()
  )
)

# Garde-fou pédagogique : on avertit si le CSV dépasse la taille prévue.
if (nrow(portfolio) > 10) {
  warning(
    "Le portefeuille compte ", nrow(portfolio), " lignes : les analyses ",
    "(corrélations, frontière efficiente, MEDAF) sont conçues pour 10 maximum."
  )
}

# ==============================================================================
# 2. COURS YAHOO FINANCE, AVEC CACHE QUOTIDIEN
# ==============================================================================
# Principe : le premier rendu du jour télécharge l'historique des cours et
# l'enregistre dans cache_cours.rds (fichier local, ignoré par git). Les
# rendus suivants relisent ce fichier : c'est instantané, ça évite de
# solliciter Yahoo à chaque aperçu, et ça garantit que le dashboard HTML et
# le rapport PDF d'une même journée reposent sur EXACTEMENT les mêmes
# données. Supprimer le fichier force un rafraîchissement. Si le
# téléchargement échoue (panne réseau) et qu'un vieux cache existe, on
# l'utilise en dépannage avec un avertissement.
n_lignes_csv  <- nrow(portfolio)
cache_fichier <- "cache_cours.rds"
cache_frais   <- file.exists(cache_fichier) &&
  as.Date(file.mtime(cache_fichier)) == Sys.Date()

if (cache_frais) {
  # --- Chemin rapide : un cache d'aujourd'hui existe, on le relit tel quel.
  cache  <- readRDS(cache_fichier)
  prices <- cache$prices
  bench  <- cache$bench
  # L'horodatage mémorisé au moment du téléchargement d'origine ; les vieux
  # caches (créés avant cette fonctionnalité) n'en ont pas -> date du fichier.
  horodatage_donnees <- cache$telecharge_le %||% file.mtime(cache_fichier)
} else {
  # --- Chemin complet : téléchargement depuis Yahoo Finance.
  # tq_get() renvoie une ligne par (ticker, jour de bourse) avec le cours de
  # clôture `close`. On télécharge depuis une semaine avant le premier achat
  # pour être sûr d'avoir un cours de référence pour le PMU.
  # tryCatch(...) : si Yahoo est injoignable, on récupère NULL au lieu de
  # faire planter tout le rendu, et on gère l'erreur juste après.
  horodatage_donnees <- Sys.time()   # heure de la requête Yahoo
  prices <- tryCatch(
    tq_get(
      unique(portfolio$ticker),
      from = min(portfolio$date_achat) - days(7),
      to   = Sys.Date()
    ) |>
      filter(!is.na(close)),   # les jours sans clôture (NA) sont éliminés
                               # tout de suite : un NA qui se propage dans les
                               # totaux ferait planter les affichages.
    error = function(e) NULL
  )
  bench_brut <- tryCatch(
    tq_get(indice_marche,
           from = min(portfolio$date_achat) - days(7),
           to   = Sys.Date()),
    error = function(e) NULL
  )
  bench <- if (is.data.frame(bench_brut)) {
    filter(bench_brut, !is.na(close))
  } else {
    tibble()   # tibble vide : le repli de la section 6 prendra le relais
  }

  if (is.null(prices) && file.exists(cache_fichier)) {
    # Panne réseau mais un cache (même vieux) existe : on dépanne avec.
    warning("Téléchargement impossible — cache du ",
            format(file.mtime(cache_fichier), "%d/%m/%Y"), " utilisé.")
    cache  <- readRDS(cache_fichier)
    prices <- cache$prices
    bench  <- cache$bench
    horodatage_donnees <- cache$telecharge_le %||% file.mtime(cache_fichier)
  } else if (is.null(prices)) {
    # Panne réseau et aucun cache : impossible de continuer, on s'arrête
    # avec un message clair plutôt qu'une cascade d'erreurs obscures.
    stop("Impossible de télécharger les cours et aucun cache disponible.")
  } else {
    # Téléchargement réussi : on enregistre le cache pour la journée,
    # horodatage compris (il sera affiché dans le dashboard et le PDF).
    saveRDS(
      list(prices = prices, bench = bench, telecharge_le = horodatage_donnees),
      cache_fichier
    )
  }
}

# Phrase d'information affichée en tête du dashboard et du rapport PDF :
# quand les données ont été récupérées, et jusqu'à quelle clôture elles vont.
derniere_cloture <- max(prices$date)
info_donnees <- paste0(
  "Données Yahoo Finance récupérées le ",
  format(horodatage_donnees, "%d/%m/%Y à %H:%M", tz = "Europe/Paris"),
  " (heure de Paris) · dernière clôture disponible : ",
  format(derniere_cloture, "%d/%m/%Y"),
  if (cache_frais) " · source : cache local du jour" else " · source : téléchargement direct"
)

# Tickers présents dans le CSV mais inconnus de Yahoo. On les répartit en
# deux familles :
#   - lignes MANUELLES : un cours_manuel a été saisi dans le CSV (typiquement
#     un OPCVM bancaire non coté sur Yahoo, ex. Atout Vert Horizon). On les
#     garde : elles seront valorisées à la main en section 4, mais restent
#     hors des analyses à historique (évolution, corrélations, MEDAF,
#     frontière), faute de série de cours ;
#   - vrais MANQUANTS : ni Yahoo, ni cours_manuel (faute de frappe, ETF
#     renommé…). On les signale et on les écarte pour que le reste du projet
#     fonctionne quand même.
manquants        <- setdiff(unique(portfolio$ticker), unique(prices$symbol))
lignes_manuelles <- intersect(
  manquants,
  portfolio$ticker[!is.na(portfolio$cours_manuel)]
)
vrais_manquants  <- setdiff(manquants, lignes_manuelles)
if (length(vrais_manquants) > 0) {
  warning("Tickers sans données : ", paste(vrais_manquants, collapse = ", "))
  portfolio <- portfolio |> filter(!ticker %in% vrais_manquants)
}

# ==============================================================================
# 3. PRIX DE REVIENT (PMU)
# ==============================================================================
# Contrat documenté dans le README : si la colonne pmu du CSV est vide,
# on prend comme prix de revient le cours de clôture du PREMIER jour de
# cotation qui suit la date d'achat (la date d'achat elle-même peut tomber
# un week-end ou un jour férié).
premier_cours_apres <- function(tk, d) {
  p <- prices |> filter(symbol == tk, date >= d) |> arrange(date)
  if (nrow(p) == 0) NA_real_ else p$close[1]
}

# rowwise() applique le calcul ligne par ligne ; coalesce(a, b) garde a
# s'il est renseigné, sinon prend b — exactement la règle « pmu du CSV
# sinon cours après achat ».
portfolio <- portfolio |>
  rowwise() |>
  mutate(pmu = coalesce(pmu, premier_cours_apres(ticker, date_achat))) |>
  ungroup()

# ==============================================================================
# 4. POSITIONS VALORISÉES AU DERNIER COURS
# ==============================================================================
# Pour chaque ticker, on isole la dernière ligne de cotation disponible
# (slice_max sur la date) : c'est le cours de valorisation.
derniers_cours <- prices |>
  group_by(symbol) |>
  slice_max(date, n = 1) |>
  ungroup() |>
  select(ticker = symbol, cours = close, date_cours = date)

# Puis on assemble la photographie du portefeuille :
#   investi = quantité × prix de revient   (ce qu'on a payé)
#   valeur  = quantité × dernier cours     (ce que ça vaut aujourd'hui)
#   pnl     = valeur - investi             (la plus/moins-value latente)
# Pour une ligne MANUELLE, le cours Yahoo est absent (NA après le join) :
# coalesce() lui substitue le cours_manuel du CSV, et la date de
# valorisation devient la dernière clôture connue du reste du portefeuille.
positions <- portfolio |>
  left_join(derniers_cours, by = "ticker") |>
  mutate(
    manuelle   = ticker %in% lignes_manuelles,
    cours      = coalesce(cours, cours_manuel),
    date_cours = coalesce(date_cours, derniere_cloture),
    investi = quantite * pmu,
    valeur  = quantite * cours,
    pnl     = valeur - investi,
    pnl_pct = pnl / investi
  )

# Comportement défensif IMPORTANT : une position sans cours ou sans PMU
# (données Yahoo incomplètes) est écartée avec un avertissement plutôt que
# de propager des NA dans les totaux — un NA non filtré ferait planter les
# affichages. La valuebox « Lignes valorisées » du dashboard signale l'écart.
ecartees <- positions |> filter(is.na(valeur) | is.na(investi))
if (nrow(ecartees) > 0) {
  warning(
    "Positions écartées (cours ou PMU indisponible) : ",
    paste(ecartees$ticker, collapse = ", ")
  )
  positions <- positions |> filter(!is.na(valeur), !is.na(investi))
}

# Le poids de chaque ligne se calcule APRÈS le filtrage, pour que la somme
# des poids fasse bien 100 %.
positions <- positions |> mutate(poids = valeur / sum(valeur))

total_valeur  <- sum(positions$valeur)
total_investi <- sum(positions$investi)
total_pnl     <- total_valeur - total_investi
total_pnl_pct <- total_pnl / total_investi

# Note affichée (dashboard + PDF) quand des lignes sont valorisées à la main :
# elles comptent dans le patrimoine mais pas dans les analyses à historique.
note_manuelles <- if (any(positions$manuelle)) {
  paste0(
    positions$nom[positions$manuelle] |> paste(collapse = ", "),
    " : ligne(s) valorisée(s) à la main (cours saisi dans le CSV, sans ",
    "historique) — compte(nt) dans le patrimoine et les allocations, mais ",
    "sont exclue(s) des analyses de performance et de risque (évolution, ",
    "corrélations, MEDAF, frontière efficiente)."
  )
} else {
  ""
}

# ==============================================================================
# 5. VALEUR QUOTIDIENNE DU PORTEFEUILLE
# ==============================================================================
# Objectif : une série « une date -> une valeur totale du portefeuille »
# depuis la date du DERNIER achat (portefeuille complet, donc comparable
# d'un jour à l'autre).
#
# Subtilité : tous les titres ne cotent pas tous les jours (jours fériés
# différents Paris/Amsterdam par exemple). On passe donc par un tableau
# « large » (une colonne par ticker), on reporte le dernier cours connu
# avec fill() vers le bas, et on ne garde que les dates où toutes les
# colonnes sont renseignées (drop_na). Les lignes manuelles (sans série de
# cours) sont naturellement absentes de `prices`, donc de `prix_larges`.
date_debut <- max(positions$date_achat)
positions_cotees <- positions |> filter(!manuelle)

prix_larges <- prices |>
  filter(symbol %in% positions_cotees$ticker, date >= date_debut) |>
  select(symbol, date, close) |>
  pivot_wider(names_from = symbol, values_from = close) |>
  arrange(date) |>
  fill(-date, .direction = "down") |>
  drop_na()

# Valeur constante des lignes manuelles (une seule valorisation connue) :
# on la reporte sur toute la période pour que la courbe de valeur et le
# total du portefeuille coïncident. Approximation assumée — un OPCVM
# valorisé à un seul point est supposé stable sur l'historique ; l'effet
# sur la volatilité mesurée est négligeable pour une petite ligne, et c'est
# le comportement attendu d'un fonds patrimonial peu volatil.
valeur_manuelle <- sum(positions$valeur[positions$manuelle])

# Retour au format long pour multiplier chaque cours par la quantité
# détenue, puis somme par date : c'est la valeur totale quotidienne.
valeur_quotidienne <- prix_larges |>
  pivot_longer(-date, names_to = "ticker", values_to = "close") |>
  left_join(select(positions_cotees, ticker, quantite), by = "ticker") |>
  group_by(date) |>
  summarise(valeur = sum(close * quantite) + valeur_manuelle, .groups = "drop")

# Performance depuis le début de l'année (YTD, « year to date ») :
# valeur actuelle rapportée à la première valeur de l'année en cours.
valeur_debut_annee <- valeur_quotidienne |>
  filter(year(date) == year(Sys.Date())) |>
  slice_min(date, n = 1) |>
  pull(valeur)

perf_ytd <- last(arrange(valeur_quotidienne, date)$valeur) / valeur_debut_annee - 1

# ==============================================================================
# 6. BENCHMARK (CAC 40) ET RENDEMENTS QUOTIDIENS
# ==============================================================================
# Repli de sécurité : si Yahoo n'a rien renvoyé pour l'indice (ça arrive),
# l'ETF Monde CW8 sert de proxy de marché — moins précis pour le MEDAF,
# mais le projet reste fonctionnel.
if (nrow(bench) == 0) {
  bench <- prices |> filter(symbol == "CW8.PA")
}

# Le rendement quotidien r_t = P_t / P_{t-1} - 1 est LA matière première de
# toute l'analyse : volatilité, Sharpe, VaR, bêta… lag() décale la série
# d'un jour pour faire le rapport « aujourd'hui / hier ».
r_pf <- valeur_quotidienne |>
  arrange(date) |>
  mutate(r = valeur / lag(valeur) - 1) |>
  drop_na()

r_bench <- bench |>
  filter(date >= date_debut) |>
  arrange(date) |>
  transmute(date, r_m = close / lag(close) - 1) |>
  drop_na()

# Rendements quotidiens de CHAQUE ligne (matrice dates × tickers) :
# alimente les corrélations, le MEDAF par ligne et la frontière efficiente.
rendements <- prix_larges |>
  mutate(across(-date, ~ .x / lag(.x) - 1)) |>
  drop_na()

# Appariement portefeuille/marché sur les dates communes (inner_join) :
# indispensable pour calculer un bêta cohérent.
r_joint <- inner_join(select(r_pf, date, r), r_bench, by = "date")

# ==============================================================================
# 7. INDICATEURS DE RISQUE DU PORTEFEUILLE
# ==============================================================================
# Toutes les formules sont expliquées avec exemples dans l'onglet Théorie
# du dashboard.
rf_j <- taux_sans_risque / 252   # taux sans risque ramené au jour (252 séances/an)
n_j  <- nrow(r_pf)               # nombre de jours de bourse observés

# Rendement annualisé GÉOMÉTRIQUE : (produit des (1+r))^(252/n) - 1.
# Plus honnête que la moyenne arithmétique × 252 car il capture la
# composition des rendements.
ret_annualise <- prod(1 + r_pf$r)^(252 / n_j) - 1

# Volatilité annualisée : écart-type quotidien × racine de 252.
vol_annuelle  <- sd(r_pf$r) * sqrt(252)

# Sharpe : excès de rendement par unité de risque total.
sharpe        <- (ret_annualise - taux_sans_risque) / vol_annuelle

# Sortino : même idée mais seule la volatilité BAISSIÈRE (pmin(x, 0) ne
# garde que les jours sous l'objectif) est comptée comme du risque.
downside      <- sqrt(mean(pmin(r_pf$r - rf_j, 0)^2)) * sqrt(252)
sortino       <- (ret_annualise - taux_sans_risque) / downside

# VaR historique 95 % à 1 jour : le 5e centile des rendements observés.
# Lecture : un jour sur vingt, la perte dépasse ce seuil.
var95_pct  <- -quantile(r_pf$r, 0.05, names = FALSE)
var95_eur  <- var95_pct * total_valeur
# CVaR (Expected Shortfall) : perte MOYENNE dans ces 5 % de pires jours.
cvar95_pct <- -mean(r_pf$r[r_pf$r <= quantile(r_pf$r, 0.05)])

# Drawdown : à chaque date, l'écart entre la valeur cumulée et son plus
# haut historique (cummax). Le minimum de cette série = drawdown maximal.
drawdowns <- r_pf |>
  mutate(cum = cumprod(1 + r), pic = cummax(cum), drawdown = cum / pic - 1)
dd_max <- min(drawdowns$drawdown)

# Bêta du portefeuille entier vs le marché : Cov(r_p, r_m) / Var(r_m).
# Sert notamment à dimensionner la couverture (onglet 🛡️ du dashboard).
beta_pf <- cov(r_joint$r, r_joint$r_m) / var(r_joint$r_m)

# ==============================================================================
# 8. MEDAF LIGNE PAR LIGNE (BÊTA ET ALPHA DE JENSEN)
# ==============================================================================
# Pour chaque titre : son bêta vs le CAC 40, son rendement réalisé annualisé,
# le rendement que le MEDAF « exigerait » compte tenu de ce bêta, et l'alpha
# (l'écart entre les deux : + = a fait mieux que son risque ne le justifie).
ret_marche_annuel <- prod(1 + r_bench$r_m)^(252 / nrow(r_bench)) - 1

medaf <- rendements |>
  pivot_longer(-date, names_to = "ticker", values_to = "ri") |>
  inner_join(r_bench, by = "date") |>
  group_by(ticker) |>
  summarise(
    beta        = cov(ri, r_m) / var(r_m),
    ret_realise = prod(1 + ri)^(252 / n()) - 1,
    .groups = "drop"
  ) |>
  mutate(
    ret_medaf = taux_sans_risque + beta * (ret_marche_annuel - taux_sans_risque),
    alpha     = ret_realise - ret_medaf
  ) |>
  left_join(select(positions, ticker, nom), by = "ticker") |>
  arrange(desc(beta))

# ==============================================================================
# 9. FRONTIÈRE EFFICIENTE (SIMULATION MONTE CARLO)
# ==============================================================================
# Méthode : on tire au hasard 4 000 jeux de pondérations, on calcule le
# couple (risque, rendement) de chacun à partir des rendements espérés (mu)
# et de la matrice de covariance (Sigma) annualisés, et on trace le nuage.
# L'enveloppe supérieure du nuage dessine la frontière efficiente.
mat_r <- rendements |> select(-date) |> as.matrix()
mu    <- colMeans(mat_r) * 252     # rendements espérés annualisés par titre
Sigma <- cov(mat_r) * 252          # covariances annualisées
labs_actifs <- positions$nom[match(colnames(mat_r), positions$ticker)]

set.seed(42)   # graine fixée : la simulation est reproductible d'un rendu à l'autre
n_actifs <- ncol(mat_r)
n_sim    <- 4000
# Tirages exponentiels normalisés ligne à ligne = pondérations positives de
# somme 1 (distribution de Dirichlet) : chaque ligne de W est un portefeuille.
W <- matrix(rexp(n_sim * n_actifs), ncol = n_actifs)
W <- W / rowSums(W)
ret_sim    <- as.vector(W %*% mu)                 # rendement de chaque simulation
vol_sim    <- sqrt(rowSums((W %*% Sigma) * W))    # volatilité : sqrt(w' Sigma w)
sharpe_sim <- (ret_sim - taux_sans_risque) / vol_sim

# Où se situe VOTRE allocation actuelle dans ce nuage ?
w_pf <- positions$poids[match(colnames(mat_r), positions$ticker)]
w_pf <- w_pf / sum(w_pf)
ret_pf_th <- sum(w_pf * mu)
vol_pf_th <- sqrt(t(w_pf) %*% Sigma %*% w_pf)[1, 1]
i_tangent <- which.max(sharpe_sim)   # la simulation au meilleur Sharpe

# ==============================================================================
# 10. COUVERTURE PAR OPTIONS — PROFILS DE PAYOFF
# ==============================================================================
# Strikes et primes INDICATIFS (ordres de grandeur pour ~3 mois d'échéance) ;
# les vraies primes dépendent de la volatilité implicite du moment.
k_put <- 0.95; prime_put <- 0.025    # put protecteur : strike 95 %, prime 2,5 %
k_call <- 1.05; prime_call <- 0.015  # call vendu : strike 105 %, prime 1,5 %

# Pour chaque scénario de marché (de -30 % à +30 %), la valeur finale du
# portefeuille selon la stratégie :
#   nu       : sans couverture (on subit le marché)
#   put_prot : + un put acheté  -> plancher à (K_put - prime)
#   covered  : + un call vendu  -> prime encaissée mais hausse plafonnée
#   collar   : put acheté financé par call vendu -> tunnel [plancher, plafond]
payoffs <- tibble(sc = seq(0.70, 1.30, by = 0.005)) |>
  mutate(
    nu       = sc * total_valeur,
    put_prot = nu + pmax(k_put * total_valeur - nu, 0) - prime_put * total_valeur,
    covered  = nu + prime_call * total_valeur - pmax(nu - k_call * total_valeur, 0),
    collar   = nu + pmax(k_put * total_valeur - nu, 0) -
               pmax(nu - k_call * total_valeur, 0) -
               (prime_put - prime_call) * total_valeur
  )

# Dimensionnement d'une couverture indicielle (options PXA sur CAC 40,
# quotité 10 € par point) : nombre de puts = V × bêta / (indice × quotité).
cac_niveau   <- last(arrange(bench, date)$close)
n_puts_exact <- (total_valeur * beta_pf) / (cac_niveau * 10)

# ==============================================================================
# 11. JEUX DE DONNÉES PRÊTS POUR LES GRAPHIQUES
# ==============================================================================
# Préparés ici une seule fois pour que le dashboard (plotly) et le rapport
# PDF (ggplot2) tracent EXACTEMENT les mêmes données.

# Base 100 : chaque série divisée par sa première valeur puis × 100 — toutes
# partent de 100, ce qui rend comparables un portefeuille en euros et des
# indices en points. À la fin, 112 se lit « +12 % depuis le départ ».
b100 <- bind_rows(
  valeur_quotidienne |>
    arrange(date) |>
    transmute(date, serie = "Portefeuille", indice = valeur / first(valeur) * 100),
  bench |>
    filter(date >= date_debut) |>
    arrange(date) |>
    transmute(date, serie = "CAC 40", indice = close / first(close) * 100),
  prices |>
    filter(symbol == "CW8.PA", date >= date_debut) |>
    arrange(date) |>
    transmute(date, serie = "MSCI World (CW8)", indice = close / first(close) * 100)
) |>
  mutate(serie = factor(serie, levels = c("Portefeuille", "CAC 40", "MSCI World (CW8)")))

# Rendements mensuels : dernière valeur de chaque mois, puis variation
# d'un mois sur l'autre.
mensuel <- valeur_quotidienne |>
  mutate(mois = floor_date(date, "month")) |>
  group_by(mois) |>
  summarise(fin = last(valeur), .groups = "drop") |>
  mutate(r = fin / lag(fin) - 1) |>
  drop_na()

# Contribution de chaque ligne : la +/- value en euros, triée.
contrib <- positions |> arrange(pnl)

# Matrice des corrélations des rendements quotidiens entre les lignes.
corr <- cor(mat_r)
