-- ═══════════════════════════════════════════════════════════════════════════════
--  ORACLE SPATIAL HEAT MAP — COMPLETE SETUP SCRIPT
--  Chicago Restaurant Health Violations Demo
-- ═══════════════════════════════════════════════════════════════════════════════
--
--  Database : Oracle Autonomous Database 23ai (Phoenix)
--  Schema   : SDO
--  Author   : Generated with Claude AI + Oracle SQLcl MCP
--  GitHub   : https://github.com/YOUR_ORG/oracle-spatial-heatmap
--
--  WHAT THIS DEMO SHOWS:
--  Since Oracle ADB 23ai, you can geocode any address string directly inside
--  the database using SDO_GCDR.ELOC_GEOCODE_AS_GEOM() — no external geocoding
--  service, no API key, no separate license. The result is stored as
--  MDSYS.SDO_GEOMETRY (SRID 4326 / WGS84), ready for spatial queries, indexing,
--  and export to any web map library.
--
--  STACK (all free / included with ADB):
--    Oracle ADB 23ai          — database engine
--    SDO_GCDR.ELOC_GEOCODE_AS_GEOM — built-in geocoder (HERE Maps, ADB only)
--    MDSYS.SPATIAL_INDEX_V2   — R-tree spatial index
--    SDO_UTIL.GETVERTICES()   — extract lat/lng from SDO_GEOMETRY
--    SDO_UTIL.TO_GEOJSON()    — export SDO_GEOMETRY as GeoJSON
--    ORDS (Auto-REST)         — REST endpoint, zero config, built into ADB
--    Leaflet.js + leaflet-heat — open-source web heat map renderer
--
--  HOSTING OPTIONS:
--    1. python -m http.server 8502   (serve the HTML file locally)
--    2. Oracle APEX static files     (embed as a fully functional APEX app)
--    3. OCI Object Storage + CDN     (production hosting)
--
--  PRODUCTION SECURITY:
--    - Replace AUTO_REST_AUTH => FALSE with TRUE and configure OAuth2
--    - Use ORDS.CREATE_PRIVILEGE + role mapping for fine-grained access
--    - Enable TLS and WAF in OCI for the ORDS endpoint
--
--  HOW TO RUN:
--    Step 1: Connect as ADMIN and run SECTION 1 (grants + ORDS schema enable)
--    Step 2: Connect as SDO and run SECTIONS 2–7
--    Step 3: Serve chicago_heatmap.html via python -m http.server 8502
--    Step 4: Open http://YOUR_IP:8502/chicago_heatmap.html
--
-- ═══════════════════════════════════════════════════════════════════════════════


-- ┌─────────────────────────────────────────────────────────────────────────────
-- │ SECTION 1 — ADMIN SETUP  (run as ADMIN)
-- └─────────────────────────────────────────────────────────────────────────────

-- 1a. Grant privileges to the SDO schema
GRANT CREATE SESSION,
      CREATE TABLE,
      CREATE VIEW,
      CREATE SEQUENCE,
      CREATE PROCEDURE,
      CREATE TYPE,
      UNLIMITED TABLESPACE
TO SDO;

GRANT EXECUTE ON MDSYS.SDO_GCDR TO SDO;
GRANT EXECUTE ON MDSYS.SDO_UTIL TO SDO;
GRANT EXECUTE ON MDSYS.SDO_GEOM TO SDO;

-- 1b. Grant network ACL so ELOC geocoder can reach elocation.oracle.com
BEGIN
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host => 'elocation.oracle.com',
    ace  => xs$ace_type(
              privilege_list => xs$name_list('connect','resolve'),
              principal_name => 'SDO',
              principal_type => xs_acl.ptype_db));

  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host => '*',
    ace  => xs$ace_type(
              privilege_list => xs$name_list('connect','resolve'),
              principal_name => 'ORDS_PUBLIC_USER',
              principal_type => xs_acl.ptype_db));
  COMMIT;
END;
/

-- 1c. Enable ORDS for the SDO schema (creates /ords/sdo/ URL namespace)
BEGIN
  ORDS_ADMIN.ENABLE_SCHEMA(
    p_enabled             => TRUE,
    p_schema              => 'SDO',
    p_url_mapping_pattern => 'sdo');
  COMMIT;
END;
/


-- ┌─────────────────────────────────────────────────────────────────────────────
-- │ SECTION 2 — SOURCE TABLE  (run as SDO)
-- └─────────────────────────────────────────────────────────────────────────────
--
--  KEY TEACHING POINT:
--  The LOCATION column is type MDSYS.SDO_GEOMETRY — Oracle's native spatial type.
--  It stores geographic points as SDO_GEOMETRY(2001, 4326, SDO_POINT_TYPE(lng, lat, NULL))
--  where 2001 = 2D Point and 4326 = WGS84 (standard GPS / web map coordinate system).
--  The column starts NULL and is populated by the geocoder in Section 4.

CREATE TABLE restaurant_inspections (
    inspection_id     NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    restaurant_name   VARCHAR2(200)  NOT NULL,
    address           VARCHAR2(300)  NOT NULL,
    city              VARCHAR2(100)  DEFAULT 'Chicago',
    state             VARCHAR2(2)    DEFAULT 'IL',
    zip_code          VARCHAR2(10),
    violation_count   NUMBER(3)      DEFAULT 0,
    inspection_date   DATE           DEFAULT SYSDATE,
    location          MDSYS.SDO_GEOMETRY          -- NULL until geocoded
);


-- ┌─────────────────────────────────────────────────────────────────────────────
-- │ SECTION 3 — SAMPLE DATA  (21 Chicago restaurants)
-- └─────────────────────────────────────────────────────────────────────────────

INSERT INTO restaurant_inspections (restaurant_name, address, city, state, zip_code, violation_count) VALUES ('Au Cheval',            '800 W Randolph St',     'Chicago','IL','60661', 9);
INSERT INTO restaurant_inspections (restaurant_name, address, city, state, zip_code, violation_count) VALUES ('Green Street Smoked',  '112 N Green St',        'Chicago','IL','60607', 8);
INSERT INTO restaurant_inspections (restaurant_name, address, city, state, zip_code, violation_count) VALUES ('Kumas Corner',         '2900 W Belmont Ave',    'Chicago','IL','60618', 7);
INSERT INTO restaurant_inspections (restaurant_name, address, city, state, zip_code, violation_count) VALUES ('Xoco',                 '449 N Clark St',        'Chicago','IL','60654', 7);
INSERT INTO restaurant_inspections (restaurant_name, address, city, state, zip_code, violation_count) VALUES ('Blackbird',            '619 W Randolph St',     'Chicago','IL','60661', 6);
INSERT INTO restaurant_inspections (restaurant_name, address, city, state, zip_code, violation_count) VALUES ('Handlebar',            '2311 W North Ave',      'Chicago','IL','60647', 5);
INSERT INTO restaurant_inspections (restaurant_name, address, city, state, zip_code, violation_count) VALUES ('Giordanos',            '135 E Lake St',         'Chicago','IL','60601', 5);
INSERT INTO restaurant_inspections (restaurant_name, address, city, state, zip_code, violation_count) VALUES ('Ann Sathers',          '909 W Belmont Ave',     'Chicago','IL','60657', 4);
INSERT INTO restaurant_inspections (restaurant_name, address, city, state, zip_code, violation_count) VALUES ('Girl and the Goat',    '800 W Randolph St',     'Chicago','IL','60661', 4);
INSERT INTO restaurant_inspections (restaurant_name, address, city, state, zip_code, violation_count) VALUES ('Portillos Hot Dogs',   '100 W Ontario St',      'Chicago','IL','60654', 3);
INSERT INTO restaurant_inspections (restaurant_name, address, city, state, zip_code, violation_count) VALUES ('Dove Tail',            '1545 W Diversey Pkwy',  'Chicago','IL','60614', 3);
INSERT INTO restaurant_inspections (restaurant_name, address, city, state, zip_code, violation_count) VALUES ('Billy Goat Tavern',    '430 N Michigan Ave',    'Chicago','IL','60611', 3);
INSERT INTO restaurant_inspections (restaurant_name, address, city, state, zip_code, violation_count) VALUES ('Piece Brewery',        '1927 W North Ave',      'Chicago','IL','60622', 2);
INSERT INTO restaurant_inspections (restaurant_name, address, city, state, zip_code, violation_count) VALUES ('Lou Malnatis Pizzeria','439 N Wells St',         'Chicago','IL','60654', 2);
INSERT INTO restaurant_inspections (restaurant_name, address, city, state, zip_code, violation_count) VALUES ('Nookies',              '1746 N Wells St',       'Chicago','IL','60614', 2);
INSERT INTO restaurant_inspections (restaurant_name, address, city, state, zip_code, violation_count) VALUES ('Publican',             '837 W Fulton Market',   'Chicago','IL','60607', 2);
INSERT INTO restaurant_inspections (restaurant_name, address, city, state, zip_code, violation_count) VALUES ('Pequods Pizza',        '2207 N Clybourn Ave',   'Chicago','IL','60614', 1);
INSERT INTO restaurant_inspections (restaurant_name, address, city, state, zip_code, violation_count) VALUES ('Avec',                 '615 W Randolph St',     'Chicago','IL','60661', 1);
INSERT INTO restaurant_inspections (restaurant_name, address, city, state, zip_code, violation_count) VALUES ('Lula Cafe',            '2537 N Kedzie Blvd',    'Chicago','IL','60647', 1);
INSERT INTO restaurant_inspections (restaurant_name, address, city, state, zip_code, violation_count) VALUES ('Alinea',               '1723 N Halsted St',     'Chicago','IL','60614', 0);
-- 21st row added after initial setup to demonstrate live map update:
INSERT INTO restaurant_inspections (restaurant_name, address, city, state, zip_code, violation_count) VALUES ('Wrigleyville Dogs',   '1060 W Addison St',     'Chicago','IL','60613', 12);
COMMIT;


-- ┌─────────────────────────────────────────────────────────────────────────────
-- │ SECTION 4 — GEOCODING  (the star of the show)
-- └─────────────────────────────────────────────────────────────────────────────
--
--  KEY TEACHING POINT — SDO_GCDR is a PL/SQL PACKAGE, not an API:
--
--  Since Oracle ADB 23ai (2023), you can geocode addresses directly in the
--  database using SDO_GCDR.ELOC_GEOCODE_AS_GEOM(). This is an Oracle PL/SQL
--  package function — you call it in a SQL statement. Your code never makes
--  an HTTP call to a geocoding service; Oracle handles the call to HERE Maps
--  internally through the ELOC service. No API key, no extra license, no cost.
--
--  TWO CALLING FORMS:
--
--  Form A — JSON input (ADB 23ai, single unstructured string):
--    SDO_GCDR.ELOC_GEOCODE_AS_GEOM(
--        JSON_OBJECT('address' VALUE '1600 Amphitheatre Pkwy, Mountain View, CA')
--    )
--
--  Form B — Structured input (street / city / state / zip / country):
--    SDO_GCDR.ELOC_GEOCODE_AS_GEOM(street, city, state, zip, 'US')
--
--  Both return: SDO_GEOMETRY(2001, 4326, SDO_POINT_TYPE(longitude, latitude, NULL))
--
--  SINGLE ADDRESS TEST — run this first to verify geocoding works:
SELECT v.x AS longitude, v.y AS latitude
FROM (
    SELECT SDO_GCDR.ELOC_GEOCODE_AS_GEOM(
        JSON_OBJECT('address' VALUE '1600 Amphitheatre Parkway, Mountain View, CA')
    ) AS geom FROM dual
) g,
TABLE(SDO_UTIL.GETVERTICES(g.geom)) v;
-- Expected result: LONGITUDE=-122.0839  LATITUDE=37.42305

-- GEOCODE ALL ROWS in one UPDATE statement:
UPDATE restaurant_inspections
SET    location = SDO_GCDR.ELOC_GEOCODE_AS_GEOM(
                     address, city, state, zip_code, 'US'
                 )
WHERE  location IS NULL;
COMMIT;

-- Verify all 21 rows geocoded:
SELECT COUNT(*) AS total, COUNT(location) AS geocoded
FROM   restaurant_inspections;
-- Expected: TOTAL=21  GEOCODED=21


-- ┌─────────────────────────────────────────────────────────────────────────────
-- │ SECTION 5 — SPATIAL INDEX
-- └─────────────────────────────────────────────────────────────────────────────
--
--  KEY TEACHING POINT:
--  Oracle Spatial REQUIRES metadata registration before indexing.
--  USER_SDO_GEOM_METADATA is Oracle's spatial catalog.
--  GEODETIC=TRUE tells the index to use great-circle distance math
--  (correct for longitude/latitude coordinates on a sphere).

-- 5a. Register spatial metadata (mandatory before CREATE INDEX)
DELETE FROM user_sdo_geom_metadata
WHERE  table_name = 'RESTAURANT_INSPECTIONS' AND column_name = 'LOCATION';

INSERT INTO user_sdo_geom_metadata (table_name, column_name, diminfo, srid)
VALUES (
    'RESTAURANT_INSPECTIONS', 'LOCATION',
    MDSYS.SDO_DIM_ARRAY(
        MDSYS.SDO_DIM_ELEMENT('LONGITUDE', -88.5, -87.2, 0.00001),
        MDSYS.SDO_DIM_ELEMENT('LATITUDE',   41.4,  42.2, 0.00001)
    ),
    4326
);
COMMIT;

-- 5b. Create R-tree spatial index
CREATE INDEX restaurant_location_idx
ON restaurant_inspections(location)
INDEXTYPE IS MDSYS.SPATIAL_INDEX_V2
PARAMETERS ('layer_gtype=POINT GEODETIC=TRUE');

-- Verify index is VALID:
SELECT index_name, domidx_status, domidx_opstatus
FROM   user_indexes
WHERE  index_name = 'RESTAURANT_LOCATION_IDX';
-- Expected: VALID / VALID


-- ┌─────────────────────────────────────────────────────────────────────────────
-- │ SECTION 6 — COORDINATE EXTRACTION VIEW
-- └─────────────────────────────────────────────────────────────────────────────
--
--  KEY TEACHING POINT — Three ways to extract coordinates from SDO_GEOMETRY,
--  all verified to return identical results on ADB 23ai:
--
--  ┌──────────────────────────────────┬────────────────────────────────────────┐
--  │ Method                           │ Best for                               │
--  ├──────────────────────────────────┼────────────────────────────────────────┤
--  │ GETVERTICES (recommended)        │ All geometry types (Point/Line/Polygon)│
--  │   TABLE(SDO_UTIL.GETVERTICES(g)) │ v.x=lng, v.y=lat, v.z=elevation        │
--  ├──────────────────────────────────┼────────────────────────────────────────┤
--  │ TO_GEOJSON + JSON_VALUE          │ When GeoJSON output is also needed     │
--  │   JSON_VALUE(TO_GEOJSON(loc),    │ Extra function call cost               │
--  │   '$.coordinates[0]')            │                                        │
--  ├──────────────────────────────────┼────────────────────────────────────────┤
--  │ SDO_MIN_MBR_ORDINATE             │ Bounding box analysis                  │
--  │   SDO_GEOM.SDO_MIN_MBR_ORDINATE  │ ordinate 1=X(lng), 2=Y(lat)            │
--  │   (loc, 1)                       │                                        │
--  └──────────────────────────────────┴────────────────────────────────────────┘
--
--  COORDINATE ORDER WARNING — the most common mistake:
--    Oracle stores: SDO_POINT_TYPE(LONGITUDE, LATITUDE)  ← X first
--    GETVERTICES:   v.x = longitude,  v.y = latitude
--    Leaflet.js:    L.marker([LATITUDE, LONGITUDE])      ← lat first!
--    Always pass:   L.marker([v.y, v.x])

CREATE OR REPLACE VIEW restaurant_geojson_v AS
SELECT
    r.inspection_id,
    r.restaurant_name,
    r.address || ', ' || r.city || ', ' || r.state || ' ' || r.zip_code AS full_address,
    r.violation_count,
    TO_CHAR(r.inspection_date, 'YYYY-MM-DD')               AS inspection_date,
    -- Full GeoJSON Point geometry (for ORDS /geojson endpoint)
    SDO_UTIL.TO_GEOJSON(r.location)                        AS geojson_point,
    -- Coordinates via GETVERTICES (preferred — works for all geometry types)
    v.x                                                    AS longitude,
    v.y                                                    AS latitude,
    -- Normalised heat intensity 0.0–1.0 using analytic window function
    -- Oracle computes this in one SQL pass — no JavaScript math needed
    ROUND(r.violation_count /
          NULLIF(MAX(r.violation_count) OVER (), 0), 4)    AS heat_intensity
FROM  restaurant_inspections r,
      TABLE(SDO_UTIL.GETVERTICES(r.location)) v
WHERE r.location IS NOT NULL;

-- Quick verification:
SELECT restaurant_name, violation_count,
       ROUND(longitude,5) AS lng, ROUND(latitude,5) AS lat, heat_intensity
FROM   restaurant_geojson_v
ORDER  BY violation_count DESC;


-- ┌─────────────────────────────────────────────────────────────────────────────
-- │ SECTION 7 — ORDS REST ENDPOINT (Auto-REST method)
-- └─────────────────────────────────────────────────────────────────────────────
--
--  KEY TEACHING POINT — Two approaches to ORDS, one is far simpler:
--
--  APPROACH A: Manual module (ORDS.DEFINE_MODULE + DEFINE_TEMPLATE + DEFINE_HANDLER)
--    → Requires SET_MODULE_ORIGINS_ALLOWED for CORS
--    → CORS may still not work from all browser origins on ADB
--    → 20+ lines of PL/SQL
--
--  APPROACH B: Auto-REST (ORDS.ENABLE_OBJECT) ← THIS IS WHAT WE USE
--    → Mirrors the Oracle CDC project pattern exactly
--    → CORS handled automatically by ADB
--    → Works with python -m http.server and from any browser
--    → 5 lines of PL/SQL
--    → URL: /ords/{schema}/{alias}/
--
--  LIVE URL after running this script:
--    https://YOUR-ADB.adb.us-phoenix-1.oraclecloudapps.com/ords/sdo/violations/
--
--  PRODUCTION: Replace p_auto_rest_auth => FALSE with TRUE and configure OAuth2:
--    ORDS.CREATE_PRIVILEGE(p_name => 'heatmap.read', p_role_name => 'heatmap_role');
--    Then issue OAuth2 client credentials from Database Actions → REST → Security.

BEGIN
  -- Enable Auto-REST on the view — creates GET /ords/sdo/violations/
  ORDS.ENABLE_OBJECT(
    p_enabled        => TRUE,
    p_object         => 'RESTAURANT_GEOJSON_V',
    p_object_type    => 'VIEW',
    p_object_alias   => 'violations',
    p_auto_rest_auth => FALSE        -- set TRUE + OAuth2 for production
  );

  -- Enable Auto-REST on the base table — creates GET/POST /ords/sdo/inspections/
  ORDS.ENABLE_OBJECT(
    p_enabled        => TRUE,
    p_object         => 'RESTAURANT_INSPECTIONS',
    p_object_type    => 'TABLE',
    p_object_alias   => 'inspections',
    p_auto_rest_auth => FALSE
  );

  COMMIT;
END;
/

-- Verify (should match GGADMIN CDC project pattern):
SELECT parsing_object, object_alias, status, auto_rest_auth
FROM   user_ords_enabled_objects
ORDER  BY parsing_object;
-- Expected:
--   RESTAURANT_GEOJSON_V     violations   ENABLED  DISABLED
--   RESTAURANT_INSPECTIONS   inspections  ENABLED  DISABLED


-- ┌─────────────────────────────────────────────────────────────────────────────
-- │ SECTION 8 — SPATIAL QUERY PATTERNS (use the R-tree index)
-- └─────────────────────────────────────────────────────────────────────────────

-- 8a. SDO_WITHIN_DISTANCE — all restaurants within 2km of a point
SELECT restaurant_name, violation_count,
       ROUND(SDO_GEOM.SDO_DISTANCE(
           location,
           MDSYS.SDO_GEOMETRY(2001,4326,MDSYS.SDO_POINT_TYPE(-87.6466,41.8843,NULL),NULL,NULL),
           0.005,'unit=meter'
       )) AS dist_m
FROM   restaurant_inspections
WHERE  SDO_WITHIN_DISTANCE(
           location,
           MDSYS.SDO_GEOMETRY(2001,4326,MDSYS.SDO_POINT_TYPE(-87.6466,41.8843,NULL),NULL,NULL),
           'distance=2000 unit=meter') = 'TRUE'
ORDER  BY dist_m;

-- 8b. SDO_NN — 5 nearest neighbours to a point
SELECT restaurant_name, violation_count
FROM   restaurant_inspections
WHERE  SDO_NN(
           location,
           MDSYS.SDO_GEOMETRY(2001,4326,MDSYS.SDO_POINT_TYPE(-87.6466,41.8843,NULL),NULL,NULL),
           'sdo_num_res=5') = 'TRUE';

-- 8c. Grid aggregation — violation density per ~1km cell (feeds the heat map)
WITH g AS (SELECT 0.01 AS cell_size FROM dual)
SELECT
    ROUND(SDO_GEOM.SDO_MIN_MBR_ORDINATE(location,1)/g.cell_size)*g.cell_size AS grid_lon,
    ROUND(SDO_GEOM.SDO_MIN_MBR_ORDINATE(location,2)/g.cell_size)*g.cell_size AS grid_lat,
    COUNT(*)              AS restaurant_count,
    SUM(violation_count)  AS total_violations,
    ROUND(SUM(violation_count)/NULLIF(MAX(SUM(violation_count)) OVER(),0),4) AS heat_intensity
FROM restaurant_inspections, g
WHERE location IS NOT NULL
GROUP BY
    ROUND(SDO_GEOM.SDO_MIN_MBR_ORDINATE(location,1)/g.cell_size)*g.cell_size,
    ROUND(SDO_GEOM.SDO_MIN_MBR_ORDINATE(location,2)/g.cell_size)*g.cell_size
ORDER BY total_violations DESC;


-- ┌─────────────────────────────────────────────────────────────────────────────
-- │ SECTION 9 — ADD A NEW RESTAURANT (live map update demo)
-- └─────────────────────────────────────────────────────────────────────────────
--
--  Run this INSERT, then click "Fetch Live Data" in the heat map.
--  The new point appears immediately. Notice the heat_intensity of ALL rows
--  recalculates automatically because the view uses MAX() OVER () — a single
--  SQL analytic window function that recomputes across the entire result set.

INSERT INTO restaurant_inspections
    (restaurant_name, address, city, state, zip_code, violation_count, location)
VALUES (
    'Wrigleyville Dogs',
    '1060 W Addison St', 'Chicago', 'IL', '60613',
    12,
    SDO_GCDR.ELOC_GEOCODE_AS_GEOM(
        '1060 W Addison St', 'Chicago', 'IL', '60613', 'US'
    )
);
COMMIT;
-- New point: lng=-87.65562  lat=41.9472  (near Wrigley Field — north of cluster)
-- violation_count=12 beats the previous max of 9
-- → appears as brightest red dot on the heat map
-- → all other rows' heat_intensity values recalculate downward


-- ┌─────────────────────────────────────────────────────────────────────────────
-- │ SECTION 10 — DEPLOYMENT & HOSTING REFERENCE
-- └─────────────────────────────────────────────────────────────────────────────
--
--  OPTION 1: Python HTTP server (development / demo)
--  ─────────────────────────────────────────────────
--  1. Save chicago_heatmap.html to a directory
--  2. cd /path/to/that/directory
--  3. python -m http.server 8502
--  4. Open http://YOUR_IP:8502/chicago_heatmap.html
--  No proxy needed — the HTML fetches ORDS directly via Auto-REST.
--
--  OPTION 2: Oracle APEX (production, zero extra infrastructure)
--  ─────────────────────────────────────────────────────────────
--  1. In APEX: App Builder → Shared Components → Static Application Files
--  2. Upload chicago_heatmap.html
--  3. Create a blank APEX page with a single HTML region
--  4. In the region source, use an iframe:
--       <iframe src="#APP_FILES#chicago_heatmap.html"
--               style="width:100%;height:calc(100vh - 60px);border:none;"></iframe>
--  5. Or embed the full HTML directly in an APEX page using "Page HTML Header"
--     and a region with the Leaflet map div.
--  The ORDS Auto-REST endpoint lives on the same ADB instance as APEX —
--  same origin, no CORS at all when served through APEX.
--
--  OPTION 3: OCI Object Storage + CloudFront CDN (scalable)
--  ──────────────────────────────────────────────────────────
--  1. Create a public Object Storage bucket
--  2. Upload chicago_heatmap.html
--  3. Enable Static Website hosting on the bucket
--  4. Use OCI CDN or Cloudflare in front for performance
--
--  PRODUCTION OAUTH2 ORDS SECURITY:
--  ──────────────────────────────────
--  -- 1. Create a role and privilege
--  BEGIN
--    ORDS.CREATE_ROLE('heatmap_reader');
--    ORDS.CREATE_PRIVILEGE(
--      p_name        => 'heatmap.read',
--      p_role_name   => 'heatmap_reader',
--      p_label       => 'Heat Map Read Access',
--      p_description => 'Access to restaurant violations data'
--    );
--    ORDS.CREATE_PRIVILEGE_MAPPING(
--      p_privilege_name => 'heatmap.read',
--      p_pattern        => '/violations/*'
--    );
--    COMMIT;
--  END;
--  /
--  -- 2. In Database Actions → REST → Security → OAuth Clients
--  --    Create a client, issue client_credentials grant
--  -- 3. In HTML: fetch token first, then pass as Bearer header:
--  --    fetch(ORDS_URL, { headers: { Authorization: 'Bearer ' + token } })


-- ┌─────────────────────────────────────────────────────────────────────────────
-- │ FINAL VERIFICATION — run after all sections complete
-- └─────────────────────────────────────────────────────────────────────────────

SELECT
    (SELECT COUNT(*) FROM restaurant_inspections)            AS total_rows,
    (SELECT COUNT(*) FROM restaurant_inspections
     WHERE location IS NOT NULL)                             AS geocoded_rows,
    (SELECT COUNT(*) FROM user_sdo_geom_metadata
     WHERE table_name='RESTAURANT_INSPECTIONS')              AS spatial_metadata,
    (SELECT COUNT(*) FROM user_indexes
     WHERE index_name='RESTAURANT_LOCATION_IDX'
       AND domidx_status='VALID')                            AS spatial_index_valid,
    (SELECT COUNT(*) FROM user_ords_enabled_objects
     WHERE status='ENABLED')                                 AS autorest_objects,
    (SELECT COUNT(*) FROM restaurant_geojson_v)              AS view_rows
FROM dual;
-- Expected: 21 / 21 / 1 / 1 / 2 / 21

-- ═══════════════════════════════════════════════════════════════════════════════
--  END OF SCRIPT
--  chicago_heatmap.html + this SQL file = complete self-contained demo
--  Serve: python -m http.server 8502
--  Or embed in Oracle APEX as a static file
-- ═══════════════════════════════════════════════════════════════════════════════
