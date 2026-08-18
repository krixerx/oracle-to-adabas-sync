-- Lookup seed data. Row counts here are asserted by the reconcile step's
-- seed-count check (scripts/reconcile.ps1) — update both together.

ALTER SESSION SET CONTAINER = FREEPDB1;

-- Fine status, as the legacy system coded it.
INSERT INTO pocapp.code_lookup (domain, code, description) VALUES ('FINE_STATUS', 'I', 'Issued');
INSERT INTO pocapp.code_lookup (domain, code, description) VALUES ('FINE_STATUS', 'P', 'Paid');
INSERT INTO pocapp.code_lookup (domain, code, description) VALUES ('FINE_STATUS', 'C', 'Cancelled');
INSERT INTO pocapp.code_lookup (domain, code, description) VALUES ('FINE_STATUS', 'A', 'Appealed');

-- Offence codes (the multiple-value field on a fine).
INSERT INTO pocapp.code_lookup (domain, code, description) VALUES ('OFFENCE', 'SPD1', 'Speeding, up to 20 km/h over the limit');
INSERT INTO pocapp.code_lookup (domain, code, description) VALUES ('OFFENCE', 'SPD2', 'Speeding, more than 20 km/h over the limit');
INSERT INTO pocapp.code_lookup (domain, code, description) VALUES ('OFFENCE', 'RLGT', 'Failing to stop at a red light');
INSERT INTO pocapp.code_lookup (domain, code, description) VALUES ('OFFENCE', 'SBLT', 'Seat belt not worn');
INSERT INTO pocapp.code_lookup (domain, code, description) VALUES ('OFFENCE', 'MOBP', 'Using a mobile phone while driving');
INSERT INTO pocapp.code_lookup (domain, code, description) VALUES ('OFFENCE', 'PARK', 'Illegal parking');

-- Payment methods (the periodic group on a fine).
INSERT INTO pocapp.code_lookup (domain, code, description) VALUES ('PAY_METHOD', 'CA', 'Cash');
INSERT INTO pocapp.code_lookup (domain, code, description) VALUES ('PAY_METHOD', 'CC', 'Card');
INSERT INTO pocapp.code_lookup (domain, code, description) VALUES ('PAY_METHOD', 'BT', 'Bank transfer');

-- Powertrain classification.
INSERT INTO pocapp.powertrain_type (code, description) VALUES ('EV',     'Battery electric - plug-in, no engine');
INSERT INTO pocapp.powertrain_type (code, description) VALUES ('PHEV',   'Plug-in hybrid - battery and engine, chargeable');
INSERT INTO pocapp.powertrain_type (code, description) VALUES ('HEV',    'Hybrid - engine and small battery, not chargeable');
INSERT INTO pocapp.powertrain_type (code, description) VALUES ('PETROL', 'Petrol - internal combustion only');
INSERT INTO pocapp.powertrain_type (code, description) VALUES ('UN',     'Unknown - neither the VIN nor the fuel text said');

-- VIN decode rules, per manufacturer. `_` matches one character, so the pattern
-- shows which position carries the signal. Two manufacturers, two different
-- positions, two different alphabets - which is exactly why this is a table and
-- not an algorithm. Everything else falls back to the free-text FUEL-DESC.
INSERT INTO pocapp.vin_powertrain_rule (rule_id, vin_pattern, powertrain_code, priority, note) VALUES (1, 'FOR_E____________', 'EV', 100, 'Ford: VIN position 5 carries the engine code');
INSERT INTO pocapp.vin_powertrain_rule (rule_id, vin_pattern, powertrain_code, priority, note) VALUES (2, 'FOR_P____________', 'PHEV', 100, 'Ford: VIN position 5 carries the engine code');
INSERT INTO pocapp.vin_powertrain_rule (rule_id, vin_pattern, powertrain_code, priority, note) VALUES (3, 'FOR_H____________', 'HEV', 100, 'Ford: VIN position 5 carries the engine code');
INSERT INTO pocapp.vin_powertrain_rule (rule_id, vin_pattern, powertrain_code, priority, note) VALUES (4, 'FOR_G____________', 'PETROL', 100, 'Ford: VIN position 5 carries the engine code');
INSERT INTO pocapp.vin_powertrain_rule (rule_id, vin_pattern, powertrain_code, priority, note) VALUES (5, 'BMW____I_________', 'EV', 100, 'BMW: VIN position 8, and a different alphabet');
INSERT INTO pocapp.vin_powertrain_rule (rule_id, vin_pattern, powertrain_code, priority, note) VALUES (6, 'BMW____X_________', 'PHEV', 100, 'BMW: VIN position 8, and a different alphabet');
INSERT INTO pocapp.vin_powertrain_rule (rule_id, vin_pattern, powertrain_code, priority, note) VALUES (7, 'BMW____A_________', 'HEV', 100, 'BMW: VIN position 8, and a different alphabet');
INSERT INTO pocapp.vin_powertrain_rule (rule_id, vin_pattern, powertrain_code, priority, note) VALUES (8, 'BMW____B_________', 'PETROL', 100, 'BMW: VIN position 8, and a different alphabet');

-- Standard vehicle types of the new model.
INSERT INTO pocapp.vehicle_type (type_code, description) VALUES ('PC', 'Passenger car');
INSERT INTO pocapp.vehicle_type (type_code, description) VALUES ('LC', 'Light commercial vehicle');
INSERT INTO pocapp.vehicle_type (type_code, description) VALUES ('HT', 'Heavy truck');
INSERT INTO pocapp.vehicle_type (type_code, description) VALUES ('MC', 'Motorcycle');
INSERT INTO pocapp.vehicle_type (type_code, description) VALUES ('BU', 'Bus');
INSERT INTO pocapp.vehicle_type (type_code, description) VALUES ('UN', 'Unknown');

-- Custom codes as the legacy application spelled them -> the standard type.
-- The left-hand side must match natural/SEEDVEH.NSP's #TYPES table; 'X-OLD' is
-- deliberately absent from here so the unmapped path is exercised on real rows.
INSERT INTO pocapp.vehicle_type_map (source_type, type_code) VALUES ('SEDAN',   'PC');
INSERT INTO pocapp.vehicle_type_map (source_type, type_code) VALUES ('ESTATE',  'PC');
INSERT INTO pocapp.vehicle_type_map (source_type, type_code) VALUES ('HATCH',   'PC');
INSERT INTO pocapp.vehicle_type_map (source_type, type_code) VALUES ('COUPE',   'PC');
INSERT INTO pocapp.vehicle_type_map (source_type, type_code) VALUES ('PICKUP',  'LC');
INSERT INTO pocapp.vehicle_type_map (source_type, type_code) VALUES ('VAN-C',   'LC');
INSERT INTO pocapp.vehicle_type_map (source_type, type_code) VALUES ('LORRY',   'HT');
INSERT INTO pocapp.vehicle_type_map (source_type, type_code) VALUES ('MBIKE',   'MC');
INSERT INTO pocapp.vehicle_type_map (source_type, type_code) VALUES ('MINIBUS', 'BU');

COMMIT;
EXIT;
