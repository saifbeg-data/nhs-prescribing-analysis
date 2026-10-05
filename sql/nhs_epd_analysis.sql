-- =====================================================================
-- NHS England Community Prescribing, July 2026
-- Source: NHS Business Services Authority (NHSBSA),
--         English Prescribing Dataset (EPD) with SNOMED code
-- Licence: Open Government Licence v3.0
-- Database: PostgreSQL 18 (database name: nhs_prescribing)
-- Raw file: EPD_SNOMED_202607.csv (about 7.25 GB, 18,601,776 rows)
-- =====================================================================
-- Order of work:
--   1. Staging table (all TEXT, so the load never fails on formatting)
--   2. Load the CSV with psql \copy
--   3. Typed table "epd" (real dates and numbers)
--   4. Data-quality checks
--   5. Seven aggregated views used by the Power BI dashboard
--   6. Optional: 1,000-row sample for the repository
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Staging table (every column is TEXT, same order as the CSV header)
-- ---------------------------------------------------------------------
CREATE UNLOGGED TABLE IF NOT EXISTS stg_epd (
  year_month TEXT, regional_office_name TEXT, regional_office_code TEXT,
  icb_name TEXT, icb_code TEXT, pco_name TEXT, pco_code TEXT,
  practice_name TEXT, practice_code TEXT,
  address_1 TEXT, address_2 TEXT, address_3 TEXT, address_4 TEXT, postcode TEXT,
  bnf_chemical_substance_code TEXT, bnf_chemical_substance TEXT,
  bnf_presentation_code TEXT, bnf_presentation_name TEXT, bnf_chapter_plus_code TEXT,
  quantity TEXT, items TEXT, total_quantity TEXT, adq_usage TEXT,
  nic TEXT, actual_cost TEXT, unidentified TEXT, snomed_code TEXT
);


-- ---------------------------------------------------------------------
-- 2. Load (run this in psql / SQL Shell, NOT in the pgAdmin query tool).
--    \copy reads the file on your own computer and is much faster
--    than the pgAdmin import wizard for multi-GB files.
--    Must be written on ONE line:
-- ---------------------------------------------------------------------
-- \copy stg_epd FROM 'C:/Data/EPD_SNOMED_202607.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

-- Row count must match the file (18,601,776 for July 2026):
-- SELECT COUNT(*) FROM stg_epd;


-- ---------------------------------------------------------------------
-- 3. Typed table.
--    - month: text '2026-07' becomes a real date (first day of month)
--    - numbers arrive as quoted text such as "24.44" or "1."
--      NULLIF turns empty strings into NULL, then we cast.
--    - The four address columns and the PCO columns are dropped
--      because the analysis does not need them.
-- ---------------------------------------------------------------------
CREATE TABLE epd AS
SELECT
  to_date(year_month || '-01', 'YYYY-MM-DD')   AS month,
  regional_office_name,
  icb_name, icb_code,
  practice_code, practice_name, postcode,
  bnf_chemical_substance_code, bnf_chemical_substance,
  bnf_presentation_code, bnf_presentation_name,
  bnf_chapter_plus_code,
  NULLIF(quantity,'')::numeric                 AS quantity,
  NULLIF(items,'')::int                        AS items,
  NULLIF(total_quantity,'')::numeric           AS total_quantity,
  NULLIF(adq_usage,'')::numeric                AS adq_usage,
  NULLIF(nic,'')::numeric(14,2)                AS nic,
  NULLIF(actual_cost,'')::numeric(14,2)        AS actual_cost,
  unidentified,
  snomed_code
FROM stg_epd;

-- Every query below scans the whole table, so indexes would not help.
ANALYZE epd;

-- Row counts must match between the two tables:
-- SELECT COUNT(*) FROM epd;      -- 18,601,776


-- ---------------------------------------------------------------------
-- 4. Data-quality checks
--    Result for July 2026: 0 null costs, 0 negative costs, 0 zero-item
--    rows, 15,017 rows flagged UNIDENTIFIED = 'Y' (about 0.08%),
--    9,284 practices, 1,767 distinct chemical substances.
-- ---------------------------------------------------------------------
SELECT
  COUNT(*)                                       AS total_rows,
  COUNT(*) FILTER (WHERE actual_cost IS NULL)    AS null_cost,
  COUNT(*) FILTER (WHERE actual_cost < 0)        AS negative_cost,
  COUNT(*) FILTER (WHERE items = 0)              AS zero_items,
  COUNT(*) FILTER (WHERE unidentified = 'Y')     AS unidentified_rows,
  COUNT(DISTINCT practice_code)                  AS practices,
  COUNT(DISTINCT bnf_chemical_substance_code)    AS chemicals
FROM epd;


-- ---------------------------------------------------------------------
-- 5. Views for Power BI (each one is small, so the .pbix stays light)
-- ---------------------------------------------------------------------

-- 5.1 Headline numbers (KPI cards)
CREATE OR REPLACE VIEW vw_kpi AS
SELECT SUM(items)                                          AS total_items,
       ROUND(SUM(actual_cost))                             AS total_actual_cost,
       ROUND(SUM(nic))                                     AS total_nic,
       COUNT(DISTINCT practice_code)                       AS practices,
       COUNT(DISTINCT bnf_chemical_substance_code)         AS chemicals,
       ROUND(SUM(actual_cost) / NULLIF(SUM(items),0), 2)   AS cost_per_item
FROM epd;

-- 5.2 Items versus cost by BNF chapter
CREATE OR REPLACE VIEW vw_chapter AS
SELECT bnf_chapter_plus_code                               AS chapter,
       SUM(items)                                          AS items,
       ROUND(SUM(actual_cost))                             AS actual_cost,
       ROUND(100 * SUM(actual_cost) / SUM(SUM(actual_cost)) OVER (), 2) AS cost_share_pct,
       ROUND(SUM(actual_cost) / NULLIF(SUM(items),0), 2)   AS cost_per_item
FROM epd
GROUP BY bnf_chapter_plus_code;

-- 5.3 Top 20 chemical substances by cost
CREATE OR REPLACE VIEW vw_top_drugs AS
SELECT bnf_chemical_substance                              AS drug,
       SUM(items)                                          AS items,
       ROUND(SUM(actual_cost))                             AS actual_cost,
       ROUND(SUM(actual_cost) / NULLIF(SUM(items),0), 2)   AS cost_per_item
FROM epd
GROUP BY bnf_chemical_substance
ORDER BY SUM(actual_cost) DESC
LIMIT 20;

-- 5.4 Pareto: cumulative share of cost by drug rank
CREATE OR REPLACE VIEW vw_pareto AS
WITH d AS (
  SELECT bnf_chemical_substance AS drug,
         SUM(actual_cost)       AS cost,
         SUM(items)             AS items
  FROM epd
  GROUP BY bnf_chemical_substance
)
SELECT ROW_NUMBER() OVER (ORDER BY cost DESC, drug)        AS rank,
       drug,
       items,
       ROUND(cost)                                         AS actual_cost,
       ROUND(100 * SUM(cost) OVER (ORDER BY cost DESC, drug
             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
             / SUM(cost) OVER (), 2)                       AS cum_share_pct
FROM d;

-- 5.5 Region (England's seven NHS regions)
CREATE OR REPLACE VIEW vw_region AS
SELECT regional_office_name                                AS region,
       COUNT(DISTINCT practice_code)                       AS practices,
       SUM(items)                                          AS items,
       ROUND(SUM(actual_cost))                             AS actual_cost,
       ROUND(SUM(actual_cost) / NULLIF(SUM(items),0), 2)   AS cost_per_item
FROM epd
GROUP BY regional_office_name;

-- 5.6 Integrated Care Board (ICB)
CREATE OR REPLACE VIEW vw_icb AS
SELECT icb_name,
       COUNT(DISTINCT practice_code)                       AS practices,
       SUM(items)                                          AS items,
       ROUND(SUM(actual_cost))                             AS actual_cost,
       ROUND(SUM(items)::numeric / COUNT(DISTINCT practice_code)) AS items_per_practice
FROM epd
GROUP BY icb_name;

-- 5.7 Net Ingredient Cost (NIC) versus actual cost, by chapter
CREATE OR REPLACE VIEW vw_nic_vs_actual AS
SELECT bnf_chapter_plus_code                               AS chapter,
       ROUND(SUM(nic))                                     AS nic,
       ROUND(SUM(actual_cost))                             AS actual_cost,
       ROUND(SUM(nic) - SUM(actual_cost))                  AS nic_minus_actual
FROM epd
GROUP BY bnf_chapter_plus_code;


-- ---------------------------------------------------------------------
-- 6. Headline Pareto numbers quoted in the README
--    Result: 44 drugs reach 50% of cost, 179 drugs reach 80%
--    (out of 1,767).
-- ---------------------------------------------------------------------
SELECT
  MIN(rank) FILTER (WHERE cum_share_pct >= 50) AS drugs_for_50pct,
  MIN(rank) FILTER (WHERE cum_share_pct >= 80) AS drugs_for_80pct
FROM vw_pareto;


-- ---------------------------------------------------------------------
-- 7. Optional: random 1,000-row sample for the repository.
--    Run in psql (one line), pick your own output folder:
-- ---------------------------------------------------------------------
-- \copy (SELECT * FROM epd ORDER BY random() LIMIT 1000) TO 'C:/Projects/nhs-prescribing-analysis/data/epd_sample_1000_rows.csv' WITH (FORMAT csv, HEADER true)


-- ---------------------------------------------------------------------
-- 8. Optional cleanup after the analysis (frees about 8 GB):
-- ---------------------------------------------------------------------
-- DROP TABLE stg_epd;
