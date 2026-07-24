# ==============================================================================
# MÉTÉO VILLES — PIPELINE DE DONNÉES ET DE CALCULS
# Auteur : Alban VIDELOUP
#
# Source unique des données et des calculs du projet météo, chargée (via
# source()) par index.qmd. Toute évolution des indicateurs ou des données se
# fait ICI, une seule fois.
#
# Source des données : Open-Meteo (https://open-meteo.com), API gratuite et
# sans clé, données sous licence CC BY 4.0 — attribution affichée dans
# l'onglet « À propos » du dashboard. Deux points d'entrée :
#   - API prévisions (api.open-meteo.com/v1/forecast) : jour même + 15 jours
#     à venir, complétée par les 7 derniers jours réellement observés
#     (paramètre past_days) pour combler le délai de publication des
#     réanalyses historiques ;
#   - API archive (archive-api.open-meteo.com/v1/archive) : réanalyses ERA5
#     depuis le 1er janvier 1940 (durée maximale disponible chez Open-Meteo)
#     jusqu'à quelques jours avant aujourd'hui.
#
# Le déroulé, dans l'ordre :
#   1. lecture des villes (villes.csv)
#   2. récupération des prévisions (jour même + 15 jours), avec cache
#      quotidien local
#   3. récupération de l'historique long terme (1940 → aujourd'hui - 7j)
#   4. mise en forme : table météo (codes OMM), humidité horaire agrégée
#   5. indicateurs dérivés : normales saisonnières, anomalies, records
#   6. jeux de données prêts pour les graphiques et tableaux du dashboard
# ==============================================================================

# ---- Librairies ---------------------------------------------------------------
library(tidyverse)   # manipulation de données (dplyr, tidyr) et dates (lubridate)
library(httr2)        # requêtes HTTP vers l'API Open-Meteo

# ---- Paramètres ----------------------------------------------------------------
url_previsions  <- "https://api.open-meteo.com/v1/forecast"
url_historique  <- "https://archive-api.open-meteo.com/v1/archive"

jours_prevision   <- 16          # jour même + 15 jours suivants
jours_passes_pont <- 7           # jours observés récents (comblent le délai
                                  # de publication des réanalyses ERA5, qui
                                  # accusent quelques jours de retard)
date_debut_historique <- as.Date("1940-01-01")  # début des réanalyses ERA5 :
                                  # c'est la durée maximale disponible
delai_archive <- 7                # marge (jours) avant aujourd'hui pour la
                                   # requête archive : les tout derniers jours
                                   # n'y sont pas encore publiés

fichier_cache <- "cache_meteo.rds"

# ---- Palette de couleurs (cohérente avec le projet Portfolio Tracker) ----------
# 5 couleurs catégorielles (une par ville, ordre fixe = ordre du CSV) : les 3
# premières reprennent la palette du Portfolio Tracker, complétées par 2
# teintes supplémentaires pour couvrir les 5 villes suivies ici.
col_s1 <- "#2a78d6"; col_s2 <- "#1baf7a"; col_s3 <- "#eda100"
col_s4 <- "#8456ce"; col_s5 <- "#e37b3a"
# Divergent bleu (plus froid que la normale) <-> rouge (plus chaud), milieu
# gris neutre : réutilisé pour les graphiques d'anomalie vs normale saisonnière.
scale_div <- list(list(0, "#104281"), list(0.5, "#f0efec"), list(1, "#c0302f"))

# ---- Petites fonctions de formatage à la française -----------------------------
deg  <- function(x) paste0(format(round(x, 1), decimal.mark = ",", trim = TRUE), " °C")
num1 <- function(x, d = 1) format(round(x, d), decimal.mark = ",", trim = TRUE)

# ==============================================================================
# 1. LECTURE DES VILLES
# ==============================================================================
# villes.csv : une ligne par ville suivie, avec ses coordonnées géographiques
# (latitude/longitude en degrés décimaux, WGS84) déterminées à l'avance et
# interrogées directement — plutôt qu'un géocodage par nom à chaque rendu, ce
# qui serait ambigu pour une commune homonyme (ex. plusieurs « Servon » en
# France : le code postal 50170 désigne celle de la Manche, près du Mont-
# Saint-Michel, et ce n'est qu'avec ses coordonnées qu'on interroge la bonne).
villes <- read_csv(
  "villes.csv",
  col_types = cols(
    ville       = col_character(),
    code_postal = col_character(),
    pays        = col_character(),
    latitude    = col_double(),
    longitude   = col_double(),
    fuseau      = col_character()
  )
)

# ==============================================================================
# 2. TABLE DES CODES MÉTÉO OMM (WMO weather codes utilisés par Open-Meteo)
# ==============================================================================
table_meteo_omm <- tribble(
  ~code, ~libelle,                        ~emoji,
     0L, "Ciel clair",                     "☀️",
     1L, "Principalement clair",           "🌤️",
     2L, "Partiellement nuageux",          "⛅",
     3L, "Couvert",                        "☁️",
    45L, "Brouillard",                     "🌫️",
    48L, "Brouillard givrant",             "🌫️",
    51L, "Bruine légère",                  "🌦️",
    53L, "Bruine modérée",                 "🌦️",
    55L, "Bruine dense",                   "🌦️",
    56L, "Bruine verglaçante légère",      "🌦️",
    57L, "Bruine verglaçante dense",       "🌦️",
    61L, "Pluie légère",                   "🌧️",
    63L, "Pluie modérée",                  "🌧️",
    65L, "Pluie forte",                    "🌧️",
    66L, "Pluie verglaçante légère",       "🌧️",
    67L, "Pluie verglaçante forte",        "🌧️",
    71L, "Neige légère",                   "❄️",
    73L, "Neige modérée",                  "❄️",
    75L, "Neige forte",                    "❄️",
    77L, "Grains de neige",                "❄️",
    80L, "Averses de pluie légères",       "🌦️",
    81L, "Averses de pluie modérées",      "🌦️",
    82L, "Averses de pluie violentes",     "⛈️",
    85L, "Averses de neige légères",       "🌨️",
    86L, "Averses de neige fortes",        "🌨️",
    95L, "Orage",                          "⛈️",
    96L, "Orage avec grêle légère",        "⛈️",
    99L, "Orage avec grêle forte",         "⛈️"
)

libelle_meteo <- function(code) {
  i <- match(code, table_meteo_omm$code)
  ifelse(is.na(i), "Non renseigné", table_meteo_omm$libelle[i])
}
emoji_meteo <- function(code) {
  i <- match(code, table_meteo_omm$code)
  ifelse(is.na(i), "❓", table_meteo_omm$emoji[i])
}

# ==============================================================================
# 3. CACHE QUOTIDIEN
# ==============================================================================
# Même principe que le projet Portfolio Tracker : le premier rendu du jour
# télécharge tout (prévisions + historique) et enregistre le résultat dans
# cache_meteo.rds (fichier local, ignoré par git). Les rendus suivants de la
# même journée relisent ce fichier — instantané, et ça évite de solliciter
# Open-Meteo à chaque aperçu local. Supprimer le fichier force un
# rafraîchissement. En cas de panne réseau, un vieux cache sert de repli avec
# un avertissement plutôt que de faire échouer tout le rendu.
cache_frais <- file.exists(fichier_cache) &&
  as.Date(file.mtime(fichier_cache)) == Sys.Date()

# ---- Fonctions de récupération, une ville à la fois ----------------------------
# Chaque appel est protégé par tryCatch : une ville en échec (API injoignable,
# coordonnées invalides…) est écartée avec un avertissement plutôt que de
# faire planter le rendu pour les quatre autres.
#
# req_retry() : réessaie automatiquement (avec backoff) en cas de réponse
# transitoire (429 = trop de requêtes, 5xx = erreur serveur) — observé en
# pratique sur Open-Meteo lors de deux rendus rapprochés (chaque rendu
# télécharge l'historique complet pour 5 villes). req_throttle() espace en
# plus les requêtes d'un même rendu pour ne pas déclencher la limite.
recupere_previsions_ville <- function(v) {
  tryCatch({
    resp <- request(url_previsions) |>
      req_throttle(rate = 1 / 2, realm = "open-meteo") |>
      req_retry(max_tries = 5, is_transient = \(resp) resp_status(resp) %in% c(429, 500, 502, 503, 504)) |>
      req_url_query(
        latitude   = v$latitude,
        longitude  = v$longitude,
        timezone   = v$fuseau,
        past_days  = jours_passes_pont,
        forecast_days = jours_prevision,
        current  = paste(c("temperature_2m", "relative_humidity_2m",
                            "apparent_temperature", "precipitation",
                            "weather_code", "wind_speed_10m", "is_day"),
                          collapse = ","),
        hourly   = "relative_humidity_2m",
        daily    = paste(c("weather_code", "temperature_2m_max", "temperature_2m_min",
                            "apparent_temperature_max", "apparent_temperature_min",
                            "sunrise", "sunset", "uv_index_max",
                            "precipitation_sum", "precipitation_probability_max",
                            "wind_speed_10m_max", "wind_gusts_10m_max"),
                          collapse = ",")
      ) |>
      req_perform()

    j <- resp_body_json(resp, simplifyVector = TRUE)

    quotidien <- as_tibble(j$daily) |>
      mutate(
        ville = v$ville,
        date  = as.Date(time),
        .before = 1
      ) |>
      select(-time)

    # Humidité : agrégée jour par jour à partir de la série horaire (Open-Meteo
    # ne fournit pas d'agrégat quotidien natif de l'humidité).
    horaire <- as_tibble(j$hourly) |>
      mutate(date = as.Date(time)) |>
      group_by(date) |>
      summarise(
        humidite_moy = mean(relative_humidity_2m, na.rm = TRUE),
        humidite_min = min(relative_humidity_2m, na.rm = TRUE),
        humidite_max = max(relative_humidity_2m, na.rm = TRUE),
        .groups = "drop"
      )

    quotidien <- left_join(quotidien, horaire, by = "date")

    actuel <- tibble(
      ville               = v$ville,
      instant             = as_datetime(j$current$time, tz = v$fuseau),
      temperature         = j$current$temperature_2m,
      ressenti            = j$current$apparent_temperature,
      humidite            = j$current$relative_humidity_2m,
      precipitation       = j$current$precipitation,
      vent                = j$current$wind_speed_10m,
      code_meteo          = j$current$weather_code,
      jour                = as.logical(j$current$is_day)
    )

    list(quotidien = quotidien, actuel = actuel, erreur = NA_character_)
  }, error = function(e) {
    list(quotidien = tibble(), actuel = tibble(), erreur = conditionMessage(e))
  })
}

recupere_historique_ville <- function(v) {
  tryCatch({
    resp <- request(url_historique) |>
      req_throttle(rate = 1 / 2, realm = "open-meteo") |>
      req_retry(max_tries = 5, is_transient = \(resp) resp_status(resp) %in% c(429, 500, 502, 503, 504)) |>
      req_url_query(
        latitude   = v$latitude,
        longitude  = v$longitude,
        timezone   = v$fuseau,
        start_date = format(date_debut_historique, "%Y-%m-%d"),
        end_date   = format(Sys.Date() - delai_archive, "%Y-%m-%d"),
        daily      = paste(c("temperature_2m_max", "temperature_2m_min",
                              "temperature_2m_mean", "precipitation_sum"),
                            collapse = ",")
      ) |>
      req_perform()

    j <- resp_body_json(resp, simplifyVector = TRUE)

    donnees <- as_tibble(j$daily) |>
      mutate(ville = v$ville, date = as.Date(time), .before = 1) |>
      select(-time)

    list(donnees = donnees, erreur = NA_character_)
  }, error = function(e) {
    list(donnees = tibble(), erreur = conditionMessage(e))
  })
}

# ---- Téléchargement (ou relecture du cache) ------------------------------------
if (cache_frais) {
  cache          <- readRDS(fichier_cache)
  previsions     <- cache$previsions
  actuel         <- cache$actuel
  historique     <- cache$historique
  villes_echouees <- cache$villes_echouees
  telecharge_le  <- cache$telecharge_le
} else {
  telecharge_le <- Sys.time()

  res_prev <- villes |> split(seq_len(nrow(villes))) |> map(recupere_previsions_ville)
  res_hist <- villes |> split(seq_len(nrow(villes))) |> map(recupere_historique_ville)

  previsions <- map_dfr(res_prev, "quotidien")
  actuel     <- map_dfr(res_prev, "actuel")
  historique <- map_dfr(res_hist, "donnees")

  erreurs_prev <- map_chr(res_prev, "erreur")
  erreurs_hist <- map_chr(res_hist, "erreur")
  en_echec <- !is.na(erreurs_prev) | !is.na(erreurs_hist)
  villes_echouees <- villes$ville[en_echec]
  # Détail (ville : raison) pour le journal de la CI — ne fait pas partie de
  # note_echecs (affiché dans le dashboard, qui reste concis pour l'utilisateur).
  detail_echecs <- paste0(
    villes$ville[en_echec], " : ",
    coalesce(erreurs_prev[en_echec], erreurs_hist[en_echec])
  )

  echec_total <- nrow(previsions) == 0 && nrow(historique) == 0

  if (echec_total && file.exists(fichier_cache)) {
    warning("Téléchargement Open-Meteo impossible — cache du ",
            format(file.mtime(fichier_cache), "%d/%m/%Y"), " utilisé.")
    cache          <- readRDS(fichier_cache)
    previsions     <- cache$previsions
    actuel         <- cache$actuel
    historique     <- cache$historique
    villes_echouees <- cache$villes_echouees
    telecharge_le  <- cache$telecharge_le
  } else if (echec_total) {
    stop("Impossible de récupérer les données Open-Meteo et aucun cache disponible.")
  } else {
    if (length(villes_echouees) > 0) {
      warning("Données indisponibles pour :\n", paste(detail_echecs, collapse = "\n"))
    }
    saveRDS(
      list(previsions = previsions, actuel = actuel, historique = historique,
           villes_echouees = villes_echouees, telecharge_le = telecharge_le),
      fichier_cache
    )
  }
}

info_donnees <- paste0(
  "Données Open-Meteo récupérées le ",
  format(telecharge_le, "%d/%m/%Y à %Hh%M", tz = "Europe/Paris"),
  " (heure de Paris)",
  if (cache_frais) " · source : cache local du jour" else " · source : téléchargement direct"
)

note_echecs <- if (length(villes_echouees) > 0) {
  paste0("Données indisponibles aujourd'hui pour : ", paste(villes_echouees, collapse = ", "), ".")
} else {
  ""
}

# Un ordre fixe des villes, réutilisé partout (facettes, couleurs, tableaux).
ordre_villes <- villes$ville
couleurs_villes <- setNames(c(col_s1, col_s2, col_s3, col_s4, col_s5)[seq_along(ordre_villes)], ordre_villes)
previsions <- previsions |> mutate(ville = factor(ville, levels = ordre_villes))
actuel     <- actuel     |> mutate(ville = factor(ville, levels = ordre_villes))
historique <- historique |> mutate(ville = factor(ville, levels = ordre_villes))

# Libellés et icônes lisibles, ajoutés une fois pour toutes.
previsions <- previsions |>
  mutate(
    libelle_meteo = libelle_meteo(weather_code),
    emoji_meteo   = emoji_meteo(weather_code),
    amplitude     = temperature_2m_max - temperature_2m_min
  )
actuel <- actuel |>
  mutate(libelle_meteo = libelle_meteo(code_meteo), emoji_meteo = emoji_meteo(code_meteo))

# ==============================================================================
# 4. NORMALES SAISONNIÈRES ET ANOMALIES
# ==============================================================================
# Pour chaque ville et chaque jour de l'année (1 à 366), la normale
# saisonnière est la moyenne des températures observées ce jour-là (± une
# fenêtre de quelques jours, tous les ans confondus depuis 1940) : une
# comparaison plus robuste qu'un simple jour-pour-jour, qui lisserait trop peu
# la variabilité météo d'une année sur l'autre.
fenetre_normale <- 7  # jours de part et d'autre du jour cible

distance_circulaire <- function(a, b, periode = 366) {
  d <- abs(a - b) %% periode
  pmin(d, periode - d)
}

calcule_normale <- function(jour_cible, hist_ville) {
  hist_ville |>
    filter(distance_circulaire(yday(date), jour_cible) <= fenetre_normale) |>
    summarise(
      tmax_normal = mean(temperature_2m_max, na.rm = TRUE),
      tmin_normal = mean(temperature_2m_min, na.rm = TRUE),
      .groups = "drop"
    )
}

normales_du_jour <- previsions |>
  filter(date == Sys.Date()) |>
  distinct(ville, date) |>
  mutate(jour_annee = yday(date)) |>
  rowwise() |>
  mutate(normale = list(calcule_normale(jour_annee, filter(historique, as.character(ville) == as.character(.data$ville))))) |>
  ungroup() |>
  unnest(normale)

previsions_jour <- previsions |>
  filter(date == Sys.Date()) |>
  left_join(normales_du_jour |> select(ville, tmax_normal, tmin_normal), by = "ville") |>
  mutate(
    anomalie_tmax = temperature_2m_max - tmax_normal,
    anomalie_tmin = temperature_2m_min - tmin_normal
  )

# ==============================================================================
# 5. RECORDS HISTORIQUES PAR VILLE
# ==============================================================================
records <- historique |>
  filter(!is.na(temperature_2m_max), !is.na(temperature_2m_min)) |>
  group_by(ville) |>
  summarise(
    record_chaud       = max(temperature_2m_max, na.rm = TRUE),
    date_record_chaud  = date[which.max(temperature_2m_max)],
    record_froid       = min(temperature_2m_min, na.rm = TRUE),
    date_record_froid  = date[which.min(temperature_2m_min)],
    debut_historique   = min(date),
    fin_historique      = max(date),
    .groups = "drop"
  )

# Moyenne annuelle des maximales, une ligne par (ville, année) : sert au
# graphique de tendance long terme. Année courante exclue si incomplète
# (moins de 300 jours de données) pour ne pas fausser la moyenne.
tendance_annuelle <- historique |>
  mutate(annee = year(date)) |>
  group_by(ville, annee) |>
  summarise(
    tmax_moy = mean(temperature_2m_max, na.rm = TRUE),
    tmin_moy = mean(temperature_2m_min, na.rm = TRUE),
    n_jours  = n(),
    .groups = "drop"
  ) |>
  filter(n_jours >= 300)

# ==============================================================================
# 6. INDICE UV ET CONFORT DU JOUR — CLASSES DE LECTURE RAPIDE
# ==============================================================================
classe_uv <- function(uv) {
  cut(uv,
      breaks = c(-Inf, 2, 5, 7, 10, Inf),
      labels = c("Faible", "Modéré", "Élevé", "Très élevé", "Extrême"),
      right = TRUE)
}

previsions <- previsions |> mutate(classe_uv = classe_uv(uv_index_max))

# ==============================================================================
# 7. RÉSUMÉ DU JOUR — POUR LES VALUEBOXES DU DASHBOARD
# ==============================================================================
# Codes OMM d'orage (grêle comprise) : sert au repérage d'une alerte simple.
codes_orage <- c(95L, 96L, 99L)

ville_plus_chaude  <- as.character(actuel$ville[which.max(actuel$temperature)])
temp_plus_chaude   <- max(actuel$temperature, na.rm = TRUE)
ville_plus_froide  <- as.character(actuel$ville[which.min(actuel$temperature)])
temp_plus_froide   <- min(actuel$temperature, na.rm = TRUE)

anomalie_moyenne <- mean(previsions_jour$anomalie_tmax, na.rm = TRUE)

villes_en_alerte <- actuel$ville[actuel$code_meteo %in% codes_orage | actuel$vent >= 60]
alerte_texte <- if (length(villes_en_alerte) > 0) {
  paste0("Vigilance : ", paste(villes_en_alerte, collapse = ", "))
} else {
  "Aucune alerte en cours"
}
