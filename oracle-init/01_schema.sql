-- Oracle to Adabas sync #1 — target model (hand-designed, deliberately different from the
-- Adabas source shape). Runs automatically on first Oracle container start
-- (gvenzl/oracle-free /container-entrypoint-initdb.d, executed as SYSDBA).
--
-- Schema owner POCAPP is created by the image via APP_USER env (docker-compose).

ALTER SESSION SET CONTAINER = FREEPDB1;

ALTER USER pocapp QUOTA UNLIMITED ON users;

-- One generic lookup table for coded Adabas fields (domain + code -> description).
CREATE TABLE pocapp.code_lookup (
  domain       VARCHAR2(20)  NOT NULL,
  code         VARCHAR2(10)  NOT NULL,
  description  VARCHAR2(60)  NOT NULL,
  CONSTRAINT pk_code_lookup PRIMARY KEY (domain, code)
);

-- EMPLOYEES file is split over four tables (EMPLOYEE + three children).
CREATE TABLE pocapp.employee (
  emp_id               NUMBER GENERATED ALWAYS AS IDENTITY,
  source_isn           NUMBER        NOT NULL,   -- Adabas ISN (migration lineage)
  personnel_id         VARCHAR2(8)   NOT NULL,
  first_name           VARCHAR2(30),
  middle_name          VARCHAR2(30),
  last_name            VARCHAR2(30)  NOT NULL,
  birth_date           DATE,                      -- from numeric YYYYMMDD
  gender_code          VARCHAR2(1),               -- code kept, validated by mapping
  marital_status       VARCHAR2(30),              -- DESCRIPTION resolved via code_lookup
  dept_code            VARCHAR2(6),
  job_title            VARCHAR2(30),
  city                 VARCHAR2(30),
  postal_code          VARCHAR2(10),
  country_code         VARCHAR2(3),
  CONSTRAINT pk_employee            PRIMARY KEY (emp_id),
  CONSTRAINT uq_employee_isn        UNIQUE (source_isn),
  CONSTRAINT uq_employee_personnel  UNIQUE (personnel_id)
);

CREATE TABLE pocapp.employee_address_line (
  emp_id        NUMBER        NOT NULL,
  line_no       NUMBER(3)     NOT NULL,           -- MU occurrence_index
  address_line  VARCHAR2(60)  NOT NULL,
  CONSTRAINT pk_emp_addr PRIMARY KEY (emp_id, line_no),
  CONSTRAINT fk_emp_addr FOREIGN KEY (emp_id) REFERENCES pocapp.employee (emp_id)
);

CREATE TABLE pocapp.employee_language (
  emp_id         NUMBER       NOT NULL,
  seq_no         NUMBER(3)    NOT NULL,           -- MU occurrence_index
  language_code  VARCHAR2(3)  NOT NULL,
  CONSTRAINT pk_emp_lang PRIMARY KEY (emp_id, seq_no),
  CONSTRAINT fk_emp_lang FOREIGN KEY (emp_id) REFERENCES pocapp.employee (emp_id)
);

CREATE TABLE pocapp.employee_income (
  emp_id         NUMBER       NOT NULL,
  seq_no         NUMBER(3)    NOT NULL,           -- PE occurrence_index
  currency_code  VARCHAR2(3),
  salary_amount  NUMBER(12),
  CONSTRAINT pk_emp_income PRIMARY KEY (emp_id, seq_no),
  CONSTRAINT fk_emp_income FOREIGN KEY (emp_id) REFERENCES pocapp.employee (emp_id)
);

-- Second Adabas file (VEHICLES), joined to EMPLOYEE via personnel_id during mapping.
CREATE TABLE pocapp.vehicle (
  vehicle_id  NUMBER GENERATED ALWAYS AS IDENTITY,
  source_isn  NUMBER        NOT NULL,
  emp_id      NUMBER,                              -- resolved by Hop lookup; NULL = orphan
  reg_num     VARCHAR2(15),                        -- nullable: real Adabas data has
                                                   -- vehicles without a registration
                                                   -- number (found 2026-08-05, ISN 158)
  make        VARCHAR2(30),
  model       VARCHAR2(30),
  color       VARCHAR2(15),
  year_built  NUMBER(4),
  CONSTRAINT pk_vehicle     PRIMARY KEY (vehicle_id),
  CONSTRAINT uq_vehicle_isn UNIQUE (source_isn),
  CONSTRAINT fk_vehicle_emp FOREIGN KEY (emp_id) REFERENCES pocapp.employee (emp_id)
);

EXIT;
