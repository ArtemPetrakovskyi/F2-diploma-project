-- =============================================================================
-- Monte Carlo Uncertainty System: фізична схема бази даних (Data-as-Code)
-- СУБД: SQLite >= 3.37 (STRICT-таблиці), режим журналу WAL
-- Версія схеми: 1  |  Відповідає підрозділу 2.4 файлу docs/2_design.md
--
-- Конвенції:
--   * Час: TEXT у форматі ISO 8601 UTC з мілісекундами 'YYYY-MM-DDTHH:MM:SS.SSSZ';
--     канонічність перевіряє CHECK (strftime(...) = значення).
--   * Публічні ідентифікатори: UUID v4 у нижньому регістрі (TEXT, 36 символів);
--     внутрішні ключі INTEGER PRIMARY KEY назовні не передаються.
--   * Перелічення: TEXT + CHECK IN (...); значення = ім'я значення enum у proto
--     без префікса типу (RUN_STATUS_SUCCEEDED -> 'SUCCEEDED').
--   * Логічні значення: INTEGER 0 / 1.
--   * Схема однакова для БД профілю та тимчасової БД сеансу (режим «Гість»).
-- Параметри з'єднання (виставляє SqliteExperimentRepository при кожному відкритті):
--   PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;
--   PRAGMA synchronous = NORMAL; PRAGMA busy_timeout = 5000;
--   GUI відкриває файл як file:...?mode=ro та виставляє PRAGMA query_only = ON.
-- =============================================================================

PRAGMA foreign_keys = ON;

-- -----------------------------------------------------------------------------
-- Службові таблиці
-- -----------------------------------------------------------------------------
CREATE TABLE schema_migration (
    version     INTEGER PRIMARY KEY CHECK (version >= 1),
    applied_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
                        CHECK (strftime('%Y-%m-%dT%H:%M:%fZ', applied_at) = applied_at),
    checksum    TEXT    NOT NULL CHECK (length(checksum) = 64 AND checksum NOT GLOB '*[^0-9a-f]*')
) STRICT;

-- -----------------------------------------------------------------------------
-- Підобласть «Конфігурація експерименту»
-- -----------------------------------------------------------------------------
CREATE TABLE user_profile (
    id            INTEGER PRIMARY KEY,
    display_name  TEXT    NOT NULL COLLATE NOCASE
                          CHECK (length(display_name) BETWEEN 1 AND 64),
    created_at    TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
                          CHECK (strftime('%Y-%m-%dT%H:%M:%fZ', created_at) = created_at),
    deleted_at    TEXT    NULL
                          CHECK (deleted_at IS NULL OR strftime('%Y-%m-%dT%H:%M:%fZ', deleted_at) = deleted_at)
) STRICT;

CREATE TABLE physics_model (
    id             INTEGER PRIMARY KEY,
    code           TEXT    NOT NULL
                           CHECK (length(code) BETWEEN 2 AND 64 AND code GLOB '[a-z]*'
                                  AND code NOT GLOB '*[^a-z0-9_]*'),
    version        TEXT    NOT NULL CHECK (length(version) BETWEEN 5 AND 32),
    plugin_sha256  TEXT    NULL
                           CHECK (plugin_sha256 IS NULL
                                  OR (length(plugin_sha256) = 64 AND plugin_sha256 NOT GLOB '*[^0-9a-f]*')),
    registered_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
                           CHECK (strftime('%Y-%m-%dT%H:%M:%fZ', registered_at) = registered_at),
    UNIQUE (code, version)
) STRICT;

CREATE TABLE experiment (
    id               INTEGER PRIMARY KEY,
    uuid             TEXT    NOT NULL UNIQUE
                             CHECK (length(uuid) = 36
                                    AND uuid GLOB '????????-????-4???-[89ab]???-????????????'
                                    AND uuid NOT GLOB '*[^0-9a-f-]*'),
    owner_id         INTEGER NULL REFERENCES user_profile (id) ON DELETE RESTRICT,
    model_id         INTEGER NOT NULL REFERENCES physics_model (id) ON DELETE RESTRICT,
    title            TEXT    NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
    integrator       TEXT    NOT NULL CHECK (integrator IN ('RK4', 'DOPRI5')),
    step_s           REAL    NULL CHECK (step_s > 0 AND step_s <= 1),
    rtol             REAL    NULL CHECK (rtol > 0 AND rtol < 1),
    atol             REAL    NULL CHECK (atol > 0),
    impact_height_m  REAL    NOT NULL DEFAULT 0,
    max_steps        INTEGER NOT NULL DEFAULT 100000 CHECK (max_steps BETWEEN 100 AND 10000000),
    frozen_at        TEXT    NULL
                             CHECK (frozen_at IS NULL OR strftime('%Y-%m-%dT%H:%M:%fZ', frozen_at) = frozen_at),
    created_at       TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
                             CHECK (strftime('%Y-%m-%dT%H:%M:%fZ', created_at) = created_at),
    updated_at       TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
                             CHECK (strftime('%Y-%m-%dT%H:%M:%fZ', updated_at) = updated_at),
    deleted_at       TEXT    NULL
                             CHECK (deleted_at IS NULL OR strftime('%Y-%m-%dT%H:%M:%fZ', deleted_at) = deleted_at),
    row_version      INTEGER NOT NULL DEFAULT 1 CHECK (row_version >= 1),
    CHECK ((integrator = 'RK4'    AND step_s IS NOT NULL AND rtol IS NULL AND atol IS NULL)
        OR (integrator = 'DOPRI5' AND step_s IS NULL AND rtol IS NOT NULL AND atol IS NOT NULL)),
    CHECK (updated_at >= created_at)
) STRICT;

CREATE TABLE input_quantity (
    id                INTEGER PRIMARY KEY,
    experiment_id     INTEGER NOT NULL REFERENCES experiment (id) ON DELETE CASCADE,
    ordinal           INTEGER NOT NULL CHECK (ordinal BETWEEN 0 AND 63),
    code              TEXT    NOT NULL
                              CHECK (length(code) BETWEEN 1 AND 32 AND code GLOB '[a-z]*'
                                     AND code NOT GLOB '*[^a-z0-9_]*'),
    unit              TEXT    NOT NULL CHECK (length(unit) BETWEEN 1 AND 16),
    distribution      TEXT    NULL
                              CHECK (distribution IN ('NORMAL', 'UNIFORM', 'TRIANGULAR', 'TRUNCATED_NORMAL',
                                                      'LOGNORMAL', 'WEIBULL', 'EMPIRICAL')),
    fixed_value       REAL    NULL,
    empirical_values  BLOB    NULL,
    empirical_count   INTEGER NULL CHECK (empirical_count BETWEEN 2 AND 1000000),
    UNIQUE (experiment_id, ordinal),
    UNIQUE (experiment_id, code),
    CHECK ((distribution IS NULL) = (fixed_value IS NOT NULL)),
    CHECK ((coalesce(distribution, '') = 'EMPIRICAL') = (empirical_values IS NOT NULL)),
    CHECK ((empirical_values IS NULL) = (empirical_count IS NULL)),
    CHECK (empirical_values IS NULL OR length(empirical_values) = 8 * empirical_count)
) STRICT;

CREATE TABLE distribution_parameter (
    input_id  INTEGER NOT NULL REFERENCES input_quantity (id) ON DELETE CASCADE,
    name      TEXT    NOT NULL
                      CHECK (name IN ('MEAN', 'STD', 'LOWER', 'UPPER', 'MODE',
                                      'SHAPE', 'SCALE', 'LOCATION', 'LOG_MEAN', 'LOG_STD')),
    value     REAL    NOT NULL,
    PRIMARY KEY (input_id, name)
) STRICT, WITHOUT ROWID;

CREATE TABLE correlation_coefficient (
    experiment_id  INTEGER NOT NULL,
    i              INTEGER NOT NULL,
    j              INTEGER NOT NULL,
    rho            REAL    NOT NULL CHECK (rho > -1.0 AND rho < 1.0 AND rho <> 0.0),
    PRIMARY KEY (experiment_id, i, j),
    CHECK (i < j),
    FOREIGN KEY (experiment_id, i) REFERENCES input_quantity (experiment_id, ordinal) ON DELETE CASCADE,
    FOREIGN KEY (experiment_id, j) REFERENCES input_quantity (experiment_id, ordinal) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;

-- -----------------------------------------------------------------------------
-- Підобласть «Запуск»
-- -----------------------------------------------------------------------------
CREATE TABLE environment (
    id              INTEGER PRIMARY KEY,
    engine_version  TEXT NOT NULL CHECK (length(engine_version) BETWEEN 5 AND 32),
    python_version  TEXT NOT NULL CHECK (length(python_version) BETWEEN 5 AND 32),
    numpy_version   TEXT NOT NULL CHECK (length(numpy_version) BETWEEN 5 AND 32),
    scipy_version   TEXT NOT NULL CHECK (length(scipy_version) BETWEEN 5 AND 32),
    platform        TEXT NOT NULL CHECK (length(platform) BETWEEN 1 AND 128),
    UNIQUE (engine_version, python_version, numpy_version, scipy_version, platform)
) STRICT;

CREATE TABLE simulation_run (
    id                  INTEGER PRIMARY KEY,
    uuid                TEXT    NOT NULL UNIQUE
                                CHECK (length(uuid) = 36
                                       AND uuid GLOB '????????-????-4???-[89ab]???-????????????'
                                       AND uuid NOT GLOB '*[^0-9a-f-]*'),
    experiment_id       INTEGER NOT NULL REFERENCES experiment (id) ON DELETE CASCADE,
    environment_id      INTEGER NOT NULL REFERENCES environment (id) ON DELETE RESTRICT,
    reproduces_run_id   INTEGER NULL REFERENCES simulation_run (id) ON DELETE SET NULL,
    kind                TEXT    NOT NULL CHECK (kind IN ('MONTE_CARLO', 'SOBOL', 'OAT')),
    status              TEXT    NOT NULL DEFAULT 'QUEUED'
                                CHECK (status IN ('QUEUED', 'RUNNING', 'SUCCEEDED', 'FAILED', 'CANCELLED')),
    failure_reason      TEXT    NULL
                                CHECK (failure_reason IN ('FAILURE_RATE_EXCEEDED', 'WORKER_CRASHED',
                                                          'CHUNK_TIMEOUT', 'DERIVATIVE_FAILED', 'INTERNAL')),
    root_seed           INTEGER NOT NULL CHECK (root_seed BETWEEN 0 AND 9223372036854775807),
    chunk_size          INTEGER NOT NULL CHECK (chunk_size BETWEEN 1 AND 1000000),
    workers             INTEGER NOT NULL CHECK (workers BETWEEN 1 AND 256),
    n_max               INTEGER NOT NULL CHECK (n_max BETWEEN 1 AND 10000000),
    sobol_base_n        INTEGER NULL
                                CHECK (sobol_base_n IS NULL
                                       OR (sobol_base_n >= 2 AND (sobol_base_n & (sobol_base_n - 1)) = 0)),
    target_quantity     TEXT    NULL
                                CHECK (target_quantity IN ('RANGE', 'TIME_OF_FLIGHT', 'MAX_HEIGHT',
                                                           'IMPACT_X', 'IMPACT_Z')),
    target_std_error    REAL    NULL CHECK (target_std_error > 0),
    n_planned           INTEGER NOT NULL DEFAULT 0 CHECK (n_planned >= 0),
    n_completed         INTEGER NOT NULL DEFAULT 0 CHECK (n_completed >= 0),
    n_failed            INTEGER NOT NULL DEFAULT 0 CHECK (n_failed >= 0),
    target_reached      INTEGER NULL CHECK (target_reached IN (0, 1)),
    samples_stored      INTEGER NOT NULL DEFAULT 0 CHECK (samples_stored IN (0, 1)),
    reproduction_match  INTEGER NULL CHECK (reproduction_match IN (0, 1)),
    created_at          TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
                                CHECK (strftime('%Y-%m-%dT%H:%M:%fZ', created_at) = created_at),
    started_at          TEXT    NULL
                                CHECK (started_at IS NULL OR strftime('%Y-%m-%dT%H:%M:%fZ', started_at) = started_at),
    finished_at         TEXT    NULL
                                CHECK (finished_at IS NULL OR strftime('%Y-%m-%dT%H:%M:%fZ', finished_at) = finished_at),
    CHECK ((status = 'FAILED') = (failure_reason IS NOT NULL)),
    CHECK ((kind = 'SOBOL') = (sobol_base_n IS NOT NULL)),
    CHECK ((target_quantity IS NULL) = (target_std_error IS NULL)),
    CHECK (target_reached IS NULL OR target_std_error IS NOT NULL),
    CHECK (n_failed <= n_completed AND n_completed <= n_planned AND n_planned <= n_max),
    CHECK (reproduction_match IS NULL OR reproduces_run_id IS NOT NULL),
    CHECK ((status IN ('SUCCEEDED', 'FAILED', 'CANCELLED')) = (finished_at IS NOT NULL)),
    CHECK (finished_at IS NULL OR started_at IS NULL OR finished_at >= started_at)
) STRICT;

CREATE TABLE run_status_event (
    run_id   INTEGER NOT NULL REFERENCES simulation_run (id) ON DELETE CASCADE,
    seq      INTEGER NOT NULL CHECK (seq >= 1),
    status   TEXT    NOT NULL
                     CHECK (status IN ('QUEUED', 'RUNNING', 'SUCCEEDED', 'FAILED', 'CANCELLED')),
    at       TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
                     CHECK (strftime('%Y-%m-%dT%H:%M:%fZ', at) = at),
    PRIMARY KEY (run_id, seq)
) STRICT, WITHOUT ROWID;

-- Великі BLOB: звичайна rowid-таблиця (WITHOUT ROWID не рекомендована для рядків > ~1/20 сторінки).
-- Дайджест sha256 чанка записується завжди (порівняння в ReproduceRun); payload - лише при store_samples.
CREATE TABLE output_sample (
    run_id       INTEGER NOT NULL REFERENCES simulation_run (id) ON DELETE CASCADE,
    quantity     TEXT    NOT NULL
                         CHECK (quantity IN ('RANGE', 'TIME_OF_FLIGHT', 'MAX_HEIGHT', 'IMPACT_X', 'IMPACT_Z')),
    chunk_index  INTEGER NOT NULL CHECK (chunk_index >= 0),
    n_values     INTEGER NOT NULL CHECK (n_values BETWEEN 1 AND 1000000),
    codec        TEXT    NULL CHECK (codec IN ('ZLIB_F64LE', 'RAW_F64LE')),
    payload      BLOB    NULL,
    sha256       TEXT    NOT NULL CHECK (length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
    PRIMARY KEY (run_id, quantity, chunk_index),
    CHECK ((payload IS NULL) = (codec IS NULL))
) STRICT;

CREATE TABLE convergence_point (
    run_id          INTEGER NOT NULL REFERENCES simulation_run (id) ON DELETE CASCADE,
    quantity        TEXT    NOT NULL
                            CHECK (quantity IN ('RANGE', 'TIME_OF_FLIGHT', 'MAX_HEIGHT', 'IMPACT_X', 'IMPACT_Z')),
    n               INTEGER NOT NULL CHECK (n >= 2),
    mean            REAL    NOT NULL,
    std             REAL    NOT NULL CHECK (std >= 0),
    std_error_mean  REAL    NOT NULL CHECK (std_error_mean >= 0),
    PRIMARY KEY (run_id, quantity, n)
) STRICT, WITHOUT ROWID;

-- -----------------------------------------------------------------------------
-- Підобласть «Результати аналізу»
-- -----------------------------------------------------------------------------
CREATE TABLE statistic_result (
    run_id    INTEGER NOT NULL REFERENCES simulation_run (id) ON DELETE CASCADE,
    quantity  TEXT    NOT NULL
                      CHECK (quantity IN ('RANGE', 'TIME_OF_FLIGHT', 'MAX_HEIGHT', 'IMPACT_X', 'IMPACT_Z')),
    metric    TEXT    NOT NULL
                      CHECK (metric IN ('MEAN', 'MEDIAN', 'VARIANCE', 'STD', 'SKEWNESS', 'KURTOSIS',
                                        'STD_ERROR_MEAN', 'QUANTILE')),
    level     REAL    NOT NULL DEFAULT 0 CHECK (level >= 0 AND level < 1),
    value     REAL    NOT NULL,
    PRIMARY KEY (run_id, quantity, metric, level),
    CHECK ((metric = 'QUANTILE') = (level > 0))
) STRICT, WITHOUT ROWID;

CREATE TABLE interval_result (
    run_id               INTEGER NOT NULL REFERENCES simulation_run (id) ON DELETE CASCADE,
    quantity             TEXT    NOT NULL
                                 CHECK (quantity IN ('RANGE', 'TIME_OF_FLIGHT', 'MAX_HEIGHT', 'IMPACT_X', 'IMPACT_Z')),
    kind                 TEXT    NOT NULL
                                 CHECK (kind IN ('COVERAGE_SHORTEST', 'CI_MEAN_STUDENT', 'CI_BOOTSTRAP_PERCENTILE')),
    probability          REAL    NOT NULL CHECK (probability > 0 AND probability < 1),
    lower                REAL    NOT NULL,
    upper                REAL    NOT NULL,
    bootstrap_resamples  INTEGER NULL CHECK (bootstrap_resamples BETWEEN 100 AND 100000),
    PRIMARY KEY (run_id, quantity, kind, probability),
    CHECK (lower <= upper),
    CHECK ((kind = 'CI_BOOTSTRAP_PERCENTILE') = (bootstrap_resamples IS NOT NULL))
) STRICT, WITHOUT ROWID;

CREATE TABLE normality_test (
    run_id       INTEGER NOT NULL REFERENCES simulation_run (id) ON DELETE CASCADE,
    quantity     TEXT    NOT NULL
                         CHECK (quantity IN ('RANGE', 'TIME_OF_FLIGHT', 'MAX_HEIGHT', 'IMPACT_X', 'IMPACT_Z')),
    test         TEXT    NOT NULL CHECK (test IN ('DAGOSTINO_PEARSON', 'SHAPIRO_WILK')),
    statistic    REAL    NOT NULL,
    p_value      REAL    NOT NULL CHECK (p_value BETWEEN 0 AND 1),
    sample_size  INTEGER NOT NULL CHECK (sample_size >= 8),
    PRIMARY KEY (run_id, quantity, test),
    CHECK (test <> 'SHAPIRO_WILK' OR sample_size <= 5000)
) STRICT, WITHOUT ROWID;

CREATE TABLE dispersion_ellipse (
    run_id       INTEGER NOT NULL REFERENCES simulation_run (id) ON DELETE CASCADE,
    probability  REAL    NOT NULL CHECK (probability > 0 AND probability < 1),
    center_x     REAL    NOT NULL,
    center_z     REAL    NOT NULL,
    semi_major   REAL    NOT NULL CHECK (semi_major >= 0),
    semi_minor   REAL    NOT NULL CHECK (semi_minor >= 0),
    angle_rad    REAL    NOT NULL CHECK (angle_rad > -1.5707963267948966 AND angle_rad <= 1.5707963267948966),
    PRIMARY KEY (run_id, probability),
    CHECK (semi_minor <= semi_major)
) STRICT, WITHOUT ROWID;

CREATE TABLE sensitivity_index (
    run_id    INTEGER NOT NULL REFERENCES simulation_run (id) ON DELETE CASCADE,
    input_id  INTEGER NOT NULL REFERENCES input_quantity (id) ON DELETE CASCADE,
    quantity  TEXT    NOT NULL
                      CHECK (quantity IN ('RANGE', 'TIME_OF_FLIGHT', 'MAX_HEIGHT', 'IMPACT_X', 'IMPACT_Z')),
    method    TEXT    NOT NULL
                      CHECK (method IN ('SOBOL_FIRST', 'SOBOL_TOTAL', 'SRC', 'OAT', 'GUM_COEFFICIENT')),
    value     REAL    NOT NULL,
    ci_lower  REAL    NULL,
    ci_upper  REAL    NULL,
    PRIMARY KEY (run_id, input_id, quantity, method),
    CHECK ((ci_lower IS NULL) = (ci_upper IS NULL)),
    CHECK (ci_lower IS NULL OR ci_lower <= ci_upper)
) STRICT, WITHOUT ROWID;

CREATE TABLE gum_validation (
    run_id             INTEGER NOT NULL REFERENCES simulation_run (id) ON DELETE CASCADE,
    quantity           TEXT    NOT NULL
                               CHECK (quantity IN ('RANGE', 'TIME_OF_FLIGHT', 'MAX_HEIGHT', 'IMPACT_X', 'IMPACT_Z')),
    y_at_estimate      REAL    NOT NULL,
    u_gum              REAL    NOT NULL CHECK (u_gum >= 0),
    u_mc               REAL    NOT NULL CHECK (u_mc >= 0),
    rel_deviation      REAL    NULL CHECK (rel_deviation >= 0),
    mean_shift         REAL    NULL CHECK (mean_shift >= 0),
    reference_mean     REAL    NULL,
    reference_std      REAL    NULL CHECK (reference_std >= 0),
    model_evaluations  INTEGER NOT NULL CHECK (model_evaluations >= 1),
    PRIMARY KEY (run_id, quantity),
    CHECK ((u_mc = 0) = (rel_deviation IS NULL)),
    CHECK ((u_mc = 0) = (mean_shift IS NULL)),
    CHECK ((reference_mean IS NULL) = (reference_std IS NULL))
) STRICT, WITHOUT ROWID;

CREATE TABLE report_export (
    id          INTEGER PRIMARY KEY,
    run_id      INTEGER NOT NULL REFERENCES simulation_run (id) ON DELETE CASCADE,
    format      TEXT    NOT NULL CHECK (format IN ('PDF', 'HTML', 'CSV')),
    file_name   TEXT    NOT NULL
                        CHECK (length(file_name) BETWEEN 1 AND 255 AND file_name NOT GLOB '*[/\]*'),
    sha256      TEXT    NOT NULL CHECK (length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
    size_bytes  INTEGER NOT NULL CHECK (size_bytes >= 0),
    created_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
                        CHECK (strftime('%Y-%m-%dT%H:%M:%fZ', created_at) = created_at)
) STRICT;

-- -----------------------------------------------------------------------------
-- Індекси (B-tree). Індекси за PRIMARY KEY та UNIQUE створюються автоматично.
-- -----------------------------------------------------------------------------
-- Унікальність імені лише серед активних профілів (soft delete)
CREATE UNIQUE INDEX ux_user_profile_active_name
    ON user_profile (display_name) WHERE deleted_at IS NULL;
-- ListExperiments: фільтр за власником, keyset-пагінація (created_at DESC, id DESC); FK owner_id
CREATE INDEX ix_experiment_owner_created
    ON experiment (owner_id, created_at DESC, id DESC);
-- FK model_id (перевірка RESTRICT при видаленні моделі)
CREATE INDEX ix_experiment_model ON experiment (model_id);
-- Список запусків експерименту (GetExperiment, ReproduceRun)
CREATE INDEX ix_run_experiment_created ON simulation_run (experiment_id, created_at DESC);
-- FK environment_id та reproduces_run_id
CREATE INDEX ix_run_environment ON simulation_run (environment_id);
CREATE INDEX ix_run_reproduces ON simulation_run (reproduces_run_id) WHERE reproduces_run_id IS NOT NULL;
-- Пошук активного запуску (обмеження «один активний запуск», відновлення після аварії)
CREATE INDEX ix_run_active ON simulation_run (status) WHERE status IN ('QUEUED', 'RUNNING');
-- FK input_id у результатах чутливості (каскадне видалення вхідної величини)
CREATE INDEX ix_sensitivity_input ON sensitivity_index (input_id);
-- FK run_id у журналі експорту
CREATE INDEX ix_report_run ON report_export (run_id);

-- -----------------------------------------------------------------------------
-- Тригери цілісності
-- -----------------------------------------------------------------------------
-- (1) Перший запуск «заморожує» конфігурацію експерименту (умова відтворюваності за seed)
CREATE TRIGGER trg_run_freeze_experiment
AFTER INSERT ON simulation_run
BEGIN
    UPDATE experiment SET frozen_at = coalesce(frozen_at, NEW.created_at) WHERE id = NEW.experiment_id;
END;

CREATE TRIGGER trg_experiment_frozen
BEFORE UPDATE OF model_id, integrator, step_s, rtol, atol, impact_height_m, max_steps ON experiment
WHEN OLD.frozen_at IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'experiment_config_frozen');
END;

CREATE TRIGGER trg_input_frozen_ins BEFORE INSERT ON input_quantity
WHEN (SELECT frozen_at FROM experiment WHERE id = NEW.experiment_id) IS NOT NULL
BEGIN SELECT RAISE(ABORT, 'experiment_config_frozen'); END;

CREATE TRIGGER trg_input_frozen_upd BEFORE UPDATE ON input_quantity
WHEN (SELECT frozen_at FROM experiment WHERE id = OLD.experiment_id) IS NOT NULL
BEGIN SELECT RAISE(ABORT, 'experiment_config_frozen'); END;

CREATE TRIGGER trg_param_frozen_ins BEFORE INSERT ON distribution_parameter
WHEN (SELECT e.frozen_at FROM experiment e JOIN input_quantity q ON q.experiment_id = e.id
      WHERE q.id = NEW.input_id) IS NOT NULL
BEGIN SELECT RAISE(ABORT, 'experiment_config_frozen'); END;

CREATE TRIGGER trg_param_frozen_upd BEFORE UPDATE ON distribution_parameter
WHEN (SELECT e.frozen_at FROM experiment e JOIN input_quantity q ON q.experiment_id = e.id
      WHERE q.id = OLD.input_id) IS NOT NULL
BEGIN SELECT RAISE(ABORT, 'experiment_config_frozen'); END;

CREATE TRIGGER trg_corr_frozen_ins BEFORE INSERT ON correlation_coefficient
WHEN (SELECT frozen_at FROM experiment WHERE id = NEW.experiment_id) IS NOT NULL
BEGIN SELECT RAISE(ABORT, 'experiment_config_frozen'); END;

CREATE TRIGGER trg_corr_frozen_upd BEFORE UPDATE ON correlation_coefficient
WHEN (SELECT frozen_at FROM experiment WHERE id = OLD.experiment_id) IS NOT NULL
BEGIN SELECT RAISE(ABORT, 'experiment_config_frozen'); END;

-- (2) Результат чутливості посилається лише на вхідну величину того самого експерименту
CREATE TRIGGER trg_sensitivity_same_experiment
BEFORE INSERT ON sensitivity_index
WHEN (SELECT experiment_id FROM simulation_run WHERE id = NEW.run_id)
     IS NOT (SELECT experiment_id FROM input_quantity WHERE id = NEW.input_id)
BEGIN
    SELECT RAISE(ABORT, 'sensitivity_input_foreign_experiment');
END;

-- (3) Журнал змін статусу запуску (аудит)
CREATE TRIGGER trg_run_status_event_ins
AFTER INSERT ON simulation_run
BEGIN
    INSERT INTO run_status_event (run_id, seq, status, at) VALUES (NEW.id, 1, NEW.status, NEW.created_at);
END;

CREATE TRIGGER trg_run_status_event_upd
AFTER UPDATE OF status ON simulation_run
WHEN NEW.status IS NOT OLD.status
BEGIN
    INSERT INTO run_status_event (run_id, seq, status)
    VALUES (NEW.id, (SELECT coalesce(max(seq), 0) + 1 FROM run_status_event WHERE run_id = NEW.id), NEW.status);
END;

-- (4) Допустимі переходи статусу: QUEUED -> RUNNING | CANCELLED | FAILED;
--     RUNNING -> SUCCEEDED | FAILED | CANCELLED; термінальні статуси незмінні
CREATE TRIGGER trg_run_status_transition
BEFORE UPDATE OF status ON simulation_run
WHEN NEW.status IS NOT OLD.status
 AND NOT ((OLD.status = 'QUEUED'  AND NEW.status IN ('RUNNING', 'CANCELLED', 'FAILED'))
       OR (OLD.status = 'RUNNING' AND NEW.status IN ('SUCCEEDED', 'FAILED', 'CANCELLED')))
BEGIN
    SELECT RAISE(ABORT, 'invalid_run_status_transition');
END;

-- Рядок schema_migration (version = 1, checksum = SHA-256 цього файлу) та PRAGMA user_version = 1
-- записує засіб міграцій у тій самій транзакції, що й DDL.
