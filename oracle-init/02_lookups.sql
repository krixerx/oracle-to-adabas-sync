-- Lookup seed data. Row counts here are asserted by the reconcile step's
-- seed-count check (scripts/reconcile.ps1) — update both together.

ALTER SESSION SET CONTAINER = FREEPDB1;

INSERT INTO pocapp.code_lookup (domain, code, description) VALUES ('MARITAL_STATUS', 'S', 'Single');
INSERT INTO pocapp.code_lookup (domain, code, description) VALUES ('MARITAL_STATUS', 'M', 'Married');
INSERT INTO pocapp.code_lookup (domain, code, description) VALUES ('MARITAL_STATUS', 'D', 'Divorced');
INSERT INTO pocapp.code_lookup (domain, code, description) VALUES ('MARITAL_STATUS', 'W', 'Widowed');
INSERT INTO pocapp.code_lookup (domain, code, description) VALUES ('GENDER', 'M', 'Male');
INSERT INTO pocapp.code_lookup (domain, code, description) VALUES ('GENDER', 'F', 'Female');

COMMIT;
EXIT;
