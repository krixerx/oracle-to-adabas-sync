-- Adabas to Oracle migration — target model (hand-designed, deliberately different from the
-- Adabas source shape). Runs automatically on first Oracle container start
-- (gvenzl/oracle-free /container-entrypoint-initdb.d, executed as SYSDBA).
--
-- Schema owner POCAPP is created by the image via APP_USER env (docker-compose).
--
-- Domain: vehicles, their registration plates, and traffic fines. The source is
-- two flat Adabas files; the target is six related tables plus lookups. Nothing
-- here mirrors the source layout — that is the point.

ALTER SESSION SET CONTAINER = FREEPDB1;

ALTER USER pocapp QUOTA UNLIMITED ON users;

-- One generic lookup table for coded Adabas fields (domain + code -> description).
-- The classic Adabas one-file-many-code-tables pattern.
CREATE TABLE pocapp.code_lookup (
  domain       VARCHAR2(20)  NOT NULL,
  code         VARCHAR2(10)  NOT NULL,
  description  VARCHAR2(60)  NOT NULL,
  CONSTRAINT pk_code_lookup PRIMARY KEY (domain, code)
);

-- ---------------------------------------------------------------------------
-- Vehicle side. The Adabas VEHICLES file is FLAT and, because it has nowhere to
-- record a second registration plate, it holds one row PER PLATE - the same
-- physical vehicle repeated with a suffixed VIN. The target model separates the
-- two concepts: one row per vehicle, one row per plate.
-- ---------------------------------------------------------------------------

-- Standard vehicle types - the new model's own domain.
CREATE TABLE pocapp.vehicle_type (
  type_code    VARCHAR2(2)  NOT NULL,
  description  VARCHAR2(40) NOT NULL,
  CONSTRAINT pk_vehicle_type PRIMARY KEY (type_code)
);

-- Legacy/custom Adabas type code -> standard type. This is the "replacement"
-- table: the migration substitutes the standard code and keeps the original for
-- lineage. A code missing here is NOT an error - it lands on 'UN' and stays
-- visible in vehicle.source_vehicle_type.
CREATE TABLE pocapp.vehicle_type_map (
  source_type  VARCHAR2(8) NOT NULL,
  type_code    VARCHAR2(2) NOT NULL,
  CONSTRAINT pk_vehicle_type_map PRIMARY KEY (source_type),
  CONSTRAINT fk_vehicle_type_map FOREIGN KEY (type_code)
    REFERENCES pocapp.vehicle_type (type_code)
);

-- Powertrain classification of the new model.
CREATE TABLE pocapp.powertrain_type (
  code         VARCHAR2(6)  NOT NULL,
  description  VARCHAR2(60) NOT NULL,
  CONSTRAINT pk_powertrain_type PRIMARY KEY (code)
);

-- VIN decode rules. There is NO formula that gets the powertrain out of a VIN:
-- positions 1-3 (manufacturer) and 10 (model year) are standardised worldwide,
-- but 4-8 are the manufacturer's own descriptor and nothing standardises what
-- goes where. Decoding is therefore a LOOKUP against per-manufacturer patterns -
-- the same shape as NHTSA's vPIC database - and it lives in data so that adding
-- a manufacturer does not mean editing a pipeline.
--
-- `_` matches exactly one character (SQL LIKE), so the pattern shows at a glance
-- which position carries the signal:
--     FOR_E____________   Ford, position 5 = E
--     BMW____I_________   BMW,  position 8 = I
-- Most manufacturers have no rule at all; those vehicles fall back to the
-- free-text FUEL-DESC field, normalised in JavaScript.
CREATE TABLE pocapp.vin_powertrain_rule (
  rule_id          NUMBER        NOT NULL,
  vin_pattern      VARCHAR2(17)  NOT NULL,
  powertrain_code  VARCHAR2(6)   NOT NULL,
  priority         NUMBER(3)     DEFAULT 100 NOT NULL,  -- lowest wins on a tie
  note             VARCHAR2(60),
  CONSTRAINT pk_vin_rule  PRIMARY KEY (rule_id),
  CONSTRAINT fk_vin_rule  FOREIGN KEY (powertrain_code)
    REFERENCES pocapp.powertrain_type (code)
);

CREATE TABLE pocapp.vehicle (
  vehicle_id           NUMBER GENERATED ALWAYS AS IDENTITY,
  source_isn           NUMBER        NOT NULL,   -- ISN of the row the vehicle came from
  vin                  VARCHAR2(17)  NOT NULL,   -- BASE VIN: the source VIN cut to 17.
                                                 -- UNIQUE is what turns the duplicated
                                                 -- source rows into one vehicle.
  owner_national_id    VARCHAR2(8),              -- the registered owner; an identifier
                                                 -- only, no person table in this model
  make                 VARCHAR2(30),
  model                VARCHAR2(30),
  color                VARCHAR2(15),
  year_built           NUMBER(4),
  source_vehicle_type  VARCHAR2(8),              -- the legacy code, kept as found
  vehicle_type_code    VARCHAR2(2),              -- the standard code it maps to
  -- Powertrain, derived rather than copied - there is no field in the source
  -- that holds it. Both inputs are kept so any row can be argued about later:
  -- source_fuel_desc is the raw free text, powertrain_source says which
  -- strategy actually decided (VIN_RULE / VIN_RULE_CONFLICT / FUEL_DESC /
  -- UNKNOWN). A derived value without its provenance is not auditable.
  source_fuel_desc     VARCHAR2(20),
  powertrain_code      VARCHAR2(6),
  powertrain_source    VARCHAR2(20),
  CONSTRAINT pk_vehicle      PRIMARY KEY (vehicle_id),
  CONSTRAINT uq_vehicle_isn  UNIQUE (source_isn),
  CONSTRAINT uq_vehicle_vin  UNIQUE (vin),
  CONSTRAINT fk_vehicle_type FOREIGN KEY (vehicle_type_code)
    REFERENCES pocapp.vehicle_type (type_code),
  CONSTRAINT fk_vehicle_pt   FOREIGN KEY (powertrain_code)
    REFERENCES pocapp.powertrain_type (code)
);

-- 1 to 3 plates per vehicle. The upper bound is declarative: PK (vehicle_id,
-- plate_seq) plus the CHECK allows at most three rows. The lower bound falls out
-- of the load - a vehicle only exists because a plate_seq = 1 row created it -
-- and cannot be expressed as a constraint without a trigger.
CREATE TABLE pocapp.vehicle_plate (
  vehicle_id  NUMBER      NOT NULL,
  plate_seq   NUMBER(1)   NOT NULL,
  plate_no    VARCHAR2(15),                      -- nullable: real Adabas data has a
                                                 -- vehicle with no registration number
                                                 -- (found 2026-08-05, ISN 158)
  source_isn  NUMBER      NOT NULL,              -- the duplicate row this plate came from
  -- A registration is never deleted, it EXPIRES: NULL means still current.
  -- From Adabas BD PLATE-EXPIRY (numeric YYYYMMDD), which the lab added to
  -- file 12 - the legacy file had no such field, and AJ DATE-ACQ is a
  -- different fact that must not be repurposed.
  expiry_date DATE,
  CONSTRAINT pk_vehicle_plate      PRIMARY KEY (vehicle_id, plate_seq),
  CONSTRAINT ck_vehicle_plate_seq  CHECK (plate_seq BETWEEN 1 AND 3),
  CONSTRAINT uq_vehicle_plate_isn  UNIQUE (source_isn),
  CONSTRAINT fk_vehicle_plate      FOREIGN KEY (vehicle_id)
    REFERENCES pocapp.vehicle (vehicle_id)
);

-- Plates are how fines find their vehicle, so this lookup path gets its own index.
CREATE INDEX pocapp.ix_vehicle_plate_no ON pocapp.vehicle_plate (plate_no);

-- ---------------------------------------------------------------------------
-- Traffic fines. Adabas file 20 is one record per fine, carrying a
-- multiple-value field (the offences seen in one stop) and a periodic group
-- (part payments). Both become child tables here.
--
-- A fine records the PLATE the camera read, never the vehicle. Resolving plate
-- -> vehicle is the migration's job, and it is the reason the plate table
-- matters: a fine written against '344RG94-2' belongs to the same car as one
-- written against '344RG94'.
-- ---------------------------------------------------------------------------
CREATE TABLE pocapp.traffic_fine (
  fine_id               NUMBER GENERATED ALWAYS AS IDENTITY,
  source_isn            NUMBER        NOT NULL,
  fine_no               VARCHAR2(10)  NOT NULL,
  vehicle_id            NUMBER,                  -- NULL when the plate matched nothing:
                                                 -- foreign or long-deregistered vehicles
  plate_no              VARCHAR2(15),            -- as recorded, kept even when unresolved
  offence_date          DATE,                    -- from numeric YYYYMMDD
  location              VARCHAR2(30),
  amount                NUMBER(9,2),             -- from Adabas packed P7.2
  status_code           VARCHAR2(1),             -- code kept
  status                VARCHAR2(30),            -- description resolved via code_lookup
  offender_national_id  VARCHAR2(8),
  CONSTRAINT pk_traffic_fine     PRIMARY KEY (fine_id),
  CONSTRAINT uq_traffic_fine_isn UNIQUE (source_isn),
  CONSTRAINT uq_traffic_fine_no  UNIQUE (fine_no),
  CONSTRAINT fk_traffic_fine_veh FOREIGN KEY (vehicle_id)
    REFERENCES pocapp.vehicle (vehicle_id)
);

-- MU OFFENCE-CODE -> one row per offence.
CREATE TABLE pocapp.traffic_fine_offence (
  fine_id       NUMBER       NOT NULL,
  seq_no        NUMBER(3)    NOT NULL,           -- MU occurrence_index
  offence_code  VARCHAR2(4)  NOT NULL,
  offence_desc  VARCHAR2(60),                    -- resolved via code_lookup
  CONSTRAINT pk_fine_offence PRIMARY KEY (fine_id, seq_no),
  CONSTRAINT fk_fine_offence FOREIGN KEY (fine_id)
    REFERENCES pocapp.traffic_fine (fine_id)
);

-- PE PAYMENT -> one row per part payment.
CREATE TABLE pocapp.traffic_fine_payment (
  fine_id      NUMBER       NOT NULL,
  seq_no       NUMBER(3)    NOT NULL,            -- PE occurrence_index
  paid_date    DATE,
  paid_amount  NUMBER(9,2),
  method_code  VARCHAR2(2),
  method       VARCHAR2(30),                     -- resolved via code_lookup
  CONSTRAINT pk_fine_payment PRIMARY KEY (fine_id, seq_no),
  CONSTRAINT fk_fine_payment FOREIGN KEY (fine_id)
    REFERENCES pocapp.traffic_fine (fine_id)
);

-- Source rows the target model cannot accept as they stand. Quarantining them is
-- the point: a migration that silently drops or silently orphans what does not
-- fit cannot be reconciled. Two kinds land here - a fourth plate on one VIN
-- (dropped, it has nowhere to go) and a fine whose plate matched no vehicle
-- (loaded, but with vehicle_id NULL, and recorded here so it is not invisible).
CREATE TABLE pocapp.migration_reject (
  reject_id    NUMBER GENERATED ALWAYS AS IDENTITY,
  source_file  VARCHAR2(30)  NOT NULL,
  source_isn   NUMBER        NOT NULL,
  reason       VARCHAR2(60)  NOT NULL,
  detail       VARCHAR2(200),
  CONSTRAINT pk_migration_reject PRIMARY KEY (reject_id)
);

EXIT;
